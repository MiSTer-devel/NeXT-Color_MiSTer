// tb_diff -- differential test of rtl/dsp56k/dsp56k_core.sv against
// Previous's (Hatari's) DSP56001 interpreter (Main_MiSTer support/next/dsp56k).
//
// For each seed: random registers (AGU in linear, modulo and bit-reverse
// modes), random internal / external memory (the program is random words,
// biased to parallel-move ALU instructions), then both models run the same
// program instruction by instruction.  After every instruction the full
// register state is compared, and the RTL instruction length in clocks is
// compared with Hatari's dsp_core.instr_cycle (cycle exactness, the timing
// the host port and DMA see).  At the end of a program all memories are
// compared.  An undefined opcode is compared (Hatari: 100 cycles, the pc
// stays) and then replaced by a new random word in both models.
//
// A program ends early (not a failure) where the models are known not to
// be comparable: a peripheral access (X/Y:$FFC0-$FFFF; no peripherals are
// attached here), OMR mode 1 (bootstrap ROM), and
// SWI / WAIT / STOP / RESET / ILLEGAL (documented deviations) are never
// generated.
//
// Build/run: verilator/dsp56k/diff/run_diff.sh [nseeds] [ninsn] [seed0]

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <random>
#include "Vdsp56k_core.h"
#include "Vdsp56k_core___024root.h"
#include "verilated.h"

extern "C" {
#include "dsp_core.h"
#include "dsp_cpu.h"
#include "dsp_disasm.h"
void next_dsp_log(int, const char *, ...) {}
void dsp_link_hrx_read(void) {}
void dsp_link_txd(int) {}
void dsp_link_hi_reset(void) {}
void dsp_link_hc_taken(void) {}
}

static Vdsp56k_core *top;
static uint64_t clk_count;
static bool per_touch;
static int verbose;
static FILE *devnull;

// RTL memory writes of the current instruction: (memory, address)
struct Wr { int m; uint32_t a; };
static Wr wrs[64];
static int nwr;
#define R (top->rootp)
static void rec_writes() {
    if (nwr > 60) return;
    if (R->dsp56k_core__DOT__pint_we_a) wrs[nwr++] = {0, R->dsp56k_core__DOT__pint_addr_a};
    if (R->dsp56k_core__DOT__pint_we_b) wrs[nwr++] = {0, R->dsp56k_core__DOT__pint_addr_b};
    if (R->dsp56k_core__DOT__xint_we)   wrs[nwr++] = {1, R->dsp56k_core__DOT__xint_addr};
    if (R->dsp56k_core__DOT__yint_we)   wrs[nwr++] = {2, R->dsp56k_core__DOT__yint_addr};
    if (R->dsp56k_core__DOT__ext_we_a)  wrs[nwr++] = {3, R->dsp56k_core__DOT__ext_addr_a};
    if (R->dsp56k_core__DOT__ext_we_b)  wrs[nwr++] = {3, R->dsp56k_core__DOT__ext_addr_b};
}

static void tick() {
    top->clk = 0; top->eval();
    rec_writes();
    top->clk = 1; top->eval();
    clk_count++;
    if (top->perx_rd || top->perx_wr || top->pery_rd || top->pery_wr) per_touch = true;
}

static uint32_t ext_c[8192];
static void host_irq(int) {}

struct St {
    uint32_t x0, x1, y0, y1, a0, a1, a2, b0, b1, b2;
    uint32_t r[8], n[8], m[8];
    uint32_t sr, omr, sp, la, lc, pc;
    uint32_t ssh[16], ssl[16];
};

static void get_rtl(St &s) {
    s.x0 = R->dsp56k_core__DOT__x0; s.x1 = R->dsp56k_core__DOT__x1;
    s.y0 = R->dsp56k_core__DOT__y0; s.y1 = R->dsp56k_core__DOT__y1;
    s.a0 = R->dsp56k_core__DOT__a0; s.a1 = R->dsp56k_core__DOT__a1; s.a2 = R->dsp56k_core__DOT__a2;
    s.b0 = R->dsp56k_core__DOT__b0; s.b1 = R->dsp56k_core__DOT__b1; s.b2 = R->dsp56k_core__DOT__b2;
    for (int i = 0; i < 8; i++) {
        s.r[i] = R->dsp56k_core__DOT__rr[i];
        s.n[i] = R->dsp56k_core__DOT__nn[i];
        s.m[i] = R->dsp56k_core__DOT__mm[i];
    }
    s.sr = R->dsp56k_core__DOT__sr; s.omr = R->dsp56k_core__DOT__omr;
    s.sp = R->dsp56k_core__DOT__sp; s.la = R->dsp56k_core__DOT__la;
    s.lc = R->dsp56k_core__DOT__lc & 0xffff; s.pc = R->dsp56k_core__DOT__pc;
    for (int i = 0; i < 16; i++) {
        s.ssh[i] = R->dsp56k_core__DOT__stk_h[i];
        s.ssl[i] = R->dsp56k_core__DOT__stk_l[i];
    }
}

static void get_c(St &s) {
    uint32_t *g = dsp_core.registers;
    s.x0 = g[DSP_REG_X0]; s.x1 = g[DSP_REG_X1]; s.y0 = g[DSP_REG_Y0]; s.y1 = g[DSP_REG_Y1];
    s.a0 = g[DSP_REG_A0]; s.a1 = g[DSP_REG_A1]; s.a2 = g[DSP_REG_A2] & 0xff;
    s.b0 = g[DSP_REG_B0]; s.b1 = g[DSP_REG_B1]; s.b2 = g[DSP_REG_B2] & 0xff;
    for (int i = 0; i < 8; i++) {
        s.r[i] = g[DSP_REG_R0 + i] & 0xffff;
        s.n[i] = g[DSP_REG_N0 + i] & 0xffff;
        s.m[i] = g[DSP_REG_M0 + i] & 0xffff;
    }
    s.sr = g[DSP_REG_SR] & 0xffff; s.omr = g[DSP_REG_OMR] & 0xff;
    s.sp = g[DSP_REG_SP] & 0x3f; s.la = g[DSP_REG_LA] & 0xffff;
    s.lc = g[DSP_REG_LC] & 0xffff; s.pc = dsp_core.pc;
    for (int i = 0; i < 16; i++) {
        s.ssh[i] = dsp_core.stack[0][i];
        s.ssl[i] = dsp_core.stack[1][i];
    }
}

static int diff_st(const St &a, const St &b) {
    int bad = 0;
#define CK(f) if (a.f != b.f) { printf("  %-4s rtl %06x  c %06x\n", #f, a.f, b.f); bad++; }
    CK(x0) CK(x1) CK(y0) CK(y1) CK(a0) CK(a1) CK(a2) CK(b0) CK(b1) CK(b2)
    for (int i = 0; i < 8; i++) {
        if (a.r[i] != b.r[i]) { printf("  r%d   rtl %04x  c %04x\n", i, a.r[i], b.r[i]); bad++; }
        if (a.n[i] != b.n[i]) { printf("  n%d   rtl %04x  c %04x\n", i, a.n[i], b.n[i]); bad++; }
        if (a.m[i] != b.m[i]) { printf("  m%d   rtl %04x  c %04x\n", i, a.m[i], b.m[i]); bad++; }
    }
    CK(sr) CK(omr) CK(sp) CK(la) CK(lc) CK(pc)
    for (int i = 1; i < 16; i++) {
        if (a.ssh[i] != b.ssh[i]) { printf("  ssh%d rtl %04x  c %04x\n", i, a.ssh[i], b.ssh[i]); bad++; }
        if (a.ssl[i] != b.ssl[i]) { printf("  ssl%d rtl %04x  c %04x\n", i, a.ssl[i], b.ssl[i]); bad++; }
    }
#undef CK
    return bad;
}

static std::mt19937_64 rng;
static uint32_t rnd(uint32_t n) { return (uint32_t)(rng() % n); }
static uint32_t r24() { return (uint32_t)(rng() & 0xffffff); }

// interesting 24-bit data: corner values for saturation / rounding
static uint32_t data24() {
    switch (rnd(10)) {
    case 0: { static const uint32_t k[] = {0x000000, 0x800000, 0x7fffff, 0xffffff, 0x000001,
                                           0x400000, 0xc00000, 0x800001, 0x3fffff, 0x7ffffe};
              return k[rnd(10)]; }
    case 1: return (rnd(2) ? 0x800000 : 0x000000) | rnd(0x1000);
    case 2: return (rnd(2) ? 0x7ff000 : 0xfff000) | rnd(0x1000);
    default: return r24();
    }
}

static uint32_t insn_word() {
    uint32_t w;
    for (;;) {
        if (rnd(100) < 72) {
            w = (rnd(15) + 1) << 20 | (r24() & 0xfffff);       // parallel move + ALU
        } else {
            w = r24() & 0x0fffff;
        }
        if (w == 0x000005 || w == 0x000006 || w == 0x000084 || w == 0x000086 || w == 0x000087)
            continue;
        // known RTL / Previous differences on encodings real code does not use:
        // DO and the bit jumps with an absolute ea (mode 6: a third word),
        // MOVEM S,P:ea (Previous maps P writes with A15 like Y, reads not)
        uint32_t hi = w >> 16;
        if ((hi == 0x06 || hi == 0x0a || hi == 0x0b) && ((w >> 11) & 0x1f) == 0x0e) continue;
        if (hi == 0x07 && !(w & 0x8000)) continue;
        return w;
    }
}

struct Init {
    uint32_t x0, x1, y0, y1, a0, a1, a2, b0, b1, b2;
    uint16_t r[8], n[8], m[8];
    uint16_t sr; uint8_t omr;
    uint32_t pint[512], xint[256], yint[256];
    uint32_t ext[8192];
};

static void make_init(Init &in) {
    in.x0 = data24(); in.x1 = data24(); in.y0 = data24(); in.y1 = data24();
    in.a0 = data24(); in.a1 = data24(); in.b0 = data24(); in.b1 = data24();
    switch (rnd(3)) {
    case 0: in.a2 = (in.a1 & 0x800000) ? 0xff : 0; break;
    default: in.a2 = rnd(256);
    }
    switch (rnd(3)) {
    case 0: in.b2 = (in.b1 & 0x800000) ? 0xff : 0; break;
    default: in.b2 = rnd(256);
    }
    for (int i = 0; i < 8; i++) {
        uint32_t k = rnd(100);
        if (k < 45) {                         // linear
            in.m[i] = 0xffff;
            in.r[i] = rnd(0x8000);
            in.n[i] = rnd(4) ? (uint16_t)(rnd(65) - 32) : (uint16_t)rnd(0x10000);
        } else if (k < 80) {                  // modulo
            uint32_t mod = rnd(4) ? rnd(255) + 1 : rnd(0x3fff) + 1;
            uint32_t p = 1; while (p < mod + 1) p <<= 1;
            uint32_t base = (rnd(0x8000) / p) * p;
            in.m[i] = mod;
            in.r[i] = base + rnd(mod + 1);
            in.n[i] = rnd(3) ? (uint16_t)(rnd(2 * mod + 3) - mod - 1) : (uint16_t)(rnd(0x200) - 0x100);
        } else if (k < 92) {                  // bit reverse
            in.m[i] = 0;
            in.r[i] = rnd(0x100);
            in.n[i] = 1u << rnd(8);
        } else {                              // reserved / odd modifiers
            in.m[i] = rnd(0x10000);
            in.r[i] = rnd(0x8000);
            in.n[i] = rnd(0x10000);
        }
    }
    // SR: scaling S1:S0, C/V/L etc. random; interrupt mask 3 (no interrupts)
    in.sr = (rnd(4) << 10) | 0x0300 | rnd(0x80);
    in.omr = rnd(2) ? 0x04 : 0x00;           // DE (ROM tables) on / off, mode 0
    for (int i = 0; i < 512; i++) in.pint[i] = insn_word();
    for (int i = 0; i < 256; i++) { in.xint[i] = data24(); in.yint[i] = data24(); }
    for (int i = 0; i < 8192; i++) in.ext[i] = rnd(2) ? insn_word() : data24();
}

static void load_rtl(const Init &in) {
    // reset, then start directly in mode 0 at P:$0000
    top->rst = 1; top->run = 0; top->run_start = 0; tick(); tick();
    top->rst = 0; tick();
    R->dsp56k_core__DOT__x0 = in.x0; R->dsp56k_core__DOT__x1 = in.x1;
    R->dsp56k_core__DOT__y0 = in.y0; R->dsp56k_core__DOT__y1 = in.y1;
    R->dsp56k_core__DOT__a0 = in.a0; R->dsp56k_core__DOT__a1 = in.a1; R->dsp56k_core__DOT__a2 = in.a2;
    R->dsp56k_core__DOT__b0 = in.b0; R->dsp56k_core__DOT__b1 = in.b1; R->dsp56k_core__DOT__b2 = in.b2;
    for (int i = 0; i < 8; i++) {
        R->dsp56k_core__DOT__rr[i] = in.r[i];
        R->dsp56k_core__DOT__nn[i] = in.n[i];
        R->dsp56k_core__DOT__mm[i] = in.m[i];
    }
    R->dsp56k_core__DOT__sr = in.sr;
    for (int i = 0; i < 512; i++) R->dsp56k_core__DOT__u_pint__DOT__mem[i] = in.pint[i];
    for (int i = 0; i < 256; i++) {
        R->dsp56k_core__DOT__u_xint__DOT__mem[i] = in.xint[i];
        R->dsp56k_core__DOT__u_yint__DOT__mem[i] = in.yint[i];
    }
    for (int i = 0; i < 8192; i++) R->dsp56k_core__DOT__u_ext__DOT__mem[i] = in.ext[i];
    top->run_start = 1; top->start_direct = 1; top->start_mode = 0;
    tick();
    top->run_start = 0;
    R->dsp56k_core__DOT__omr = in.omr;
    top->run = 1;
}

static void load_c(const Init &in) {
    dsp_core_init(host_irq);
    dsp_core_config_ramext(ext_c, 8192);
    dsp56k_init_cpu();
    dsp_core_reset();
    dsp_core_start(0, 0);
    dsp_core.running = 1;
    uint32_t *g = dsp_core.registers;
    g[DSP_REG_X0] = in.x0; g[DSP_REG_X1] = in.x1; g[DSP_REG_Y0] = in.y0; g[DSP_REG_Y1] = in.y1;
    g[DSP_REG_A0] = in.a0; g[DSP_REG_A1] = in.a1; g[DSP_REG_A2] = in.a2;
    g[DSP_REG_B0] = in.b0; g[DSP_REG_B1] = in.b1; g[DSP_REG_B2] = in.b2;
    for (int i = 0; i < 8; i++) {
        g[DSP_REG_R0 + i] = in.r[i]; g[DSP_REG_N0 + i] = in.n[i]; g[DSP_REG_M0 + i] = in.m[i];
    }
    g[DSP_REG_SR] = in.sr;
    g[DSP_REG_OMR] = in.omr; dsp_core.mode = 0;
    for (int i = 0; i < 512; i++) dsp_core.ramint[DSP_SPACE_P][i] = in.pint[i];
    for (int i = 0; i < 256; i++) {
        dsp_core.ramint[DSP_SPACE_X][i] = in.xint[i];
        dsp_core.ramint[DSP_SPACE_Y][i] = in.yint[i];
    }
    memcpy(ext_c, in.ext, sizeof(ext_c));
}

static int cmp_mem() {
    int bad = 0;
    for (int i = 0; i < 512 && bad < 8; i++)
        if ((uint32_t)R->dsp56k_core__DOT__u_pint__DOT__mem[i] != (dsp_core.ramint[DSP_SPACE_P][i] & 0xffffff)) {
            printf("  P:%03x rtl %06x c %06x\n", i, (uint32_t)R->dsp56k_core__DOT__u_pint__DOT__mem[i],
                   dsp_core.ramint[DSP_SPACE_P][i]); bad++; }
    for (int i = 0; i < 256 && bad < 8; i++) {
        if ((uint32_t)R->dsp56k_core__DOT__u_xint__DOT__mem[i] != (dsp_core.ramint[DSP_SPACE_X][i] & 0xffffff)) {
            printf("  X:%03x rtl %06x c %06x\n", i, (uint32_t)R->dsp56k_core__DOT__u_xint__DOT__mem[i],
                   dsp_core.ramint[DSP_SPACE_X][i]); bad++; }
        if ((uint32_t)R->dsp56k_core__DOT__u_yint__DOT__mem[i] != (dsp_core.ramint[DSP_SPACE_Y][i] & 0xffffff)) {
            printf("  Y:%03x rtl %06x c %06x\n", i, (uint32_t)R->dsp56k_core__DOT__u_yint__DOT__mem[i],
                   dsp_core.ramint[DSP_SPACE_Y][i]); bad++; }
    }
    for (int i = 0; i < 8192 && bad < 8; i++)
        if ((uint32_t)R->dsp56k_core__DOT__u_ext__DOT__mem[i] != (ext_c[i] & 0xffffff)) {
            printf("  E:%04x rtl %06x c %06x\n", i, (uint32_t)R->dsp56k_core__DOT__u_ext__DOT__mem[i], ext_c[i]); bad++; }
    return bad;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    int nseeds = argc > 1 ? atoi(argv[1]) : 200;
    int ninsn  = argc > 2 ? atoi(argv[2]) : 2000;
    uint64_t seed0 = argc > 3 ? strtoull(argv[3], 0, 0) : 1;
    verbose = argc > 4 ? atoi(argv[4]) : 0;
    devnull = fopen("/dev/null", "w");
    top = new Vdsp56k_core;
    top->mem_en = 1; top->irqb = 0;
    top->perx_rdata = 0; top->pery_rdata = 0;
    top->int_host_rcv = 0; top->int_host_trx = 1; top->int_host_cmd = 0;
    top->int_ssi_rcv = 0; top->int_ssi_trx = 0;
    top->msk_host_rcv = 0; top->msk_host_trx = 0; top->msk_host_cmd = 0;
    top->msk_ssi_rcv = 0; top->msk_ssi_trx = 0;
    top->ipr = 0; top->hc_vector = 0x12; top->boot_we = 0; top->boot_pos = 0;

    static Init in;
    long total = 0, fails = 0, ends_per = 0, ends_und = 0, ends_mode = 0, ends_hang = 0, ends_stop = 0;
    for (int s = 0; s < nseeds; s++) {
        uint64_t seed = seed0 + s;
        rng.seed(seed * 0x9e3779b97f4a7c15ull + 12345);
        make_init(in);
        load_rtl(in);
        load_c(in);
        int k;
        bool failed = false;
        bool stop_nocmp = false;   // ended on an incomparable instruction: skip the memory check
        for (k = 0; k < ninsn; k++) {
            uint16_t pc_before = dsp_core.pc;
            St before; get_c(before);
            char dis[160] = "";
            if (verbose) {
                dsp56k_disasm(DSP_DISASM_MODE, devnull);
                snprintf(dis, sizeof dis, "%s", dsp56k_getInstructionText());
                if (verbose > 1) printf("%s", dis);
            }
            per_touch = false;
            nwr = 0;
            uint64_t c0 = clk_count;
            int guard = 0;
            do { tick(); } while (!top->retire && ++guard < 400);
            if (!top->retire && (R->dsp56k_core__DOT__state == 3 || R->dsp56k_core__DOT__state == 4)) {
                ends_stop++; stop_nocmp = true; break;   // WAIT / STOP (self-modified code): RTL deviation
            }
            if (!top->retire) { ends_hang++; printf("seed %llu insn %d: RTL hang (state %d)\n",
                (unsigned long long)seed, k, R->dsp56k_core__DOT__state); failed = true; break; }
            uint64_t rtl_cyc = clk_count - c0 - (k == 0 ? 2 : 0);   // first: + idle and fetch clocks
            uint32_t op = dsp_core.ramint[DSP_SPACE_P][pc_before & 0x1ff];
            if (pc_before >= 0x200) op = ext_c[pc_before & 0x1fff];
            dsp56k_execute_instruction();
            uint32_t c_cyc = dsp_core.instr_cycle;
            if (per_touch) { ends_per++; stop_nocmp = true; break; }
            if (dsp_core.mode == 1 || (dsp_core.registers[DSP_REG_OMR] & 3) == 1) { ends_mode++; stop_nocmp = true; break; }
            // Hatari's bit-reverse with a zero modifier sets bit 16 (see dsp56k_core.sv)
            for (int i = 0; i < 8; i++) dsp_core.registers[DSP_REG_R0 + i] &= 0xffff;
            St a, b;
            get_rtl(a); get_c(b);
            int bad = diff_st(a, b);
            for (int i = 0; i < nwr; i++) {
                uint32_t rv, cv; const char *nm;
                uint32_t ad = wrs[i].a;
                switch (wrs[i].m) {
                case 0: nm = "P"; rv = R->dsp56k_core__DOT__u_pint__DOT__mem[ad]; cv = dsp_core.ramint[DSP_SPACE_P][ad]; break;
                case 1: nm = "X"; rv = R->dsp56k_core__DOT__u_xint__DOT__mem[ad]; cv = dsp_core.ramint[DSP_SPACE_X][ad]; break;
                case 2: nm = "Y"; rv = R->dsp56k_core__DOT__u_yint__DOT__mem[ad]; cv = dsp_core.ramint[DSP_SPACE_Y][ad]; break;
                default: nm = "E"; rv = R->dsp56k_core__DOT__u_ext__DOT__mem[ad]; cv = ext_c[ad]; break;
                }
                if ((rv & 0xffffff) != (cv & 0xffffff)) { printf("  write %s:%04x rtl %06x c %06x\n", nm, ad, rv, cv); bad++; }
            }
            if (rtl_cyc != c_cyc) { printf("  cycles rtl %llu c %u\n", (unsigned long long)rtl_cyc, c_cyc); bad++; }
            if (bad) {
                printf("seed %llu insn %d: pc %04x op %06x MISMATCH\n",
                       (unsigned long long)seed, k, pc_before, op);
                if (verbose) {
                    printf("  %s", dis);
                    printf("  before: x %06x %06x y %06x %06x a %02x:%06x:%06x b %02x:%06x:%06x sr %04x omr %02x sp %02x\n",
                           before.x1, before.x0, before.y1, before.y0, before.a2, before.a1, before.a0,
                           before.b2, before.b1, before.b0, before.sr, before.omr, before.sp);
                    for (int i = 0; i < 8; i++)
                        printf("    r%d %04x n%d %04x m%d %04x\n", i, before.r[i], i, before.n[i], i, before.m[i]);
                    printf("    la %04x lc %04x ssh %04x ssl %04x\n", before.la, before.lc,
                           before.ssh[before.sp & 15], before.ssl[before.sp & 15]);
                }
                failed = true; break;
            }
            total++;
            if (c_cyc >= 100 && dsp_core.pc == pc_before) {
                // undefined opcode (Hatari: +100 cycles, pc stays): replace the
                // word in both models, including the RTL's prefetched opcode
                ends_und++;
                uint32_t w = insn_word();
                if (pc_before < 0x200) {
                    dsp_core.ramint[DSP_SPACE_P][pc_before] = w;
                    R->dsp56k_core__DOT__u_pint__DOT__mem[pc_before] = w;
                } else {
                    ext_c[pc_before & 0x1fff] = w;
                    R->dsp56k_core__DOT__u_ext__DOT__mem[pc_before & 0x1fff] = w;
                }
                if (R->dsp56k_core__DOT__fa_ext) R->dsp56k_core__DOT__u_ext__DOT__q_a = w;
                else R->dsp56k_core__DOT__u_pint__DOT__q_a = w;
            }
        }
        if (!failed && !stop_nocmp && cmp_mem()) {
            printf("seed %llu: memory MISMATCH after %d insns\n", (unsigned long long)seed, k);
            failed = true;
        }
        if (failed) fails++;
    }
    printf("tb_diff: %d seeds, %ld instructions compared, %ld failing seeds "
           "(ended early: %ld periph, %ld mode1, %ld wait/stop, %ld hang; %ld undefined opcodes replaced)\n",
           nseeds, total, fails, ends_per, ends_mode, ends_stop, ends_hang, ends_und);
    delete top;
    return fails ? 1 : 0;
}
