// DSP56001 memory primitives for the Falcon DSP (falcon_dsp).
//
// Standard Intel inference templates so Quartus maps them to M10K:
//   dsp_ram_tdp : true dual-port RAM, registered read on both ports
//                 (read-during-write on the same port returns the new data,
//                 mixed-port read-during-write is "don't care"; the DSP core
//                 never relies on it, it forwards write data itself).
//   dsp_ram_sp  : single-port RAM, registered read.
// Contents power up as zero (Hatari memsets its RAM arrays at init).

module dsp_ram_tdp #(
    parameter AW = 9,
    parameter DW = 24
) (
    input               clk,
    input               we_a,
    input      [AW-1:0] addr_a,
    input      [DW-1:0] d_a,
    output reg [DW-1:0] q_a,
    input               we_b,
    input      [AW-1:0] addr_b,
    input      [DW-1:0] d_b,
    output reg [DW-1:0] q_b
);
    reg [DW-1:0] mem [0:(1<<AW)-1] /*verilator public_flat_rw*/;

`ifdef VERILATOR
    // simulation: power-up contents zero (M10K power up as zero on the FPGA)
    integer i;
    initial begin
        for (i = 0; i < (1<<AW); i = i + 1) mem[i] = {DW{1'b0}};
    end
`endif

    /* verilator lint_off MULTIDRIVEN */
    always @(posedge clk) begin
        if (we_a) begin
            mem[addr_a] <= d_a;
            q_a <= d_a;
        end else
            q_a <= mem[addr_a];
    end

    always @(posedge clk) begin
        if (we_b) begin
            mem[addr_b] <= d_b;
            q_b <= d_b;
        end else
            q_b <= mem[addr_b];
    end
    /* verilator lint_on MULTIDRIVEN */
endmodule

module dsp_ram_sp #(
    parameter AW = 8,
    parameter DW = 24
) (
    input               clk,
    input               we,
    input      [AW-1:0] addr,
    input      [DW-1:0] d,
    output reg [DW-1:0] q
);
    reg [DW-1:0] mem [0:(1<<AW)-1] /*verilator public_flat_rw*/;

`ifdef VERILATOR
    // simulation: power-up contents zero (M10K power up as zero on the FPGA)
    integer i;
    initial begin
        for (i = 0; i < (1<<AW); i = i + 1) mem[i] = {DW{1'b0}};
    end
`endif

    always @(posedge clk) begin
        if (we) mem[addr] <= d;
        q <= mem[addr];
    end
endmodule

// 16 x 16 LUT RAM (Cyclone V MLAB): synchronous write, asynchronous read.
// A read in the clock of a write to the same address returns the old word
// (the write lands at the clock edge); the stack below relies on that.
module dsp_lutram16 (
    input             clk,
    input             we,
    input       [3:0] wa,
    input      [15:0] d,
    input       [3:0] ra,
    output     [15:0] q
);
    (* ramstyle = "MLAB, no_rw_check" *) reg [15:0] mem [0:15];

`ifdef VERILATOR
    integer i;
    initial begin
        for (i = 0; i < 16; i = i + 1) mem[i] = 16'd0;
    end
`endif

    always @(posedge clk) begin
        if (we) mem[wa] <= d;
    end
    assign q = mem[ra];
endmodule

// DSP56001 hardware stack (SSH/SSL, 16 entries) as a live-value table.
// The core writes up to three entries in one last clock (EL), in the order
// a (SSH and SSL separately), b, c (both halves), and reads four entries
// combinationally in that clock (and the SP entry in any clock).  Each write
// port has its own MLAB bank, one copy per read port; a 2-bit tag per entry
// and half says which bank holds the live word (0: reset, reads 0, as the
// register version that cleared all entries on reset).  Same results in the
// same clocks as the register array it replaces, at ~24 MLABs instead of
// ~1,000 ALMs of registers and multiplexers.
module dsp56k_stk (
    input             clk,
    input             rst,
    input             we,          // EL of an executing instruction
    input             wa_h, wa_l,
    input       [3:0] wa_i,
    input      [15:0] wa_hv, wa_lv,
    input             wb_h,
    input       [3:0] wb_i,
    input      [15:0] wb_hv, wb_lv,
    input             wc_h,
    input       [3:0] wc_i,
    input      [15:0] wc_hv, wc_lv,
    input  [4*4-1:0]  ra,          // four read addresses, port p at ra[4p+3:4p]
    output [4*16-1:0] qh,          // SSH of port p at qh[16p+15:16p]
    output [4*16-1:0] ql           // SSL of port p
);
    reg [1:0] th [0:15];
    reg [1:0] tl [0:15];

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < 16; i = i + 1) begin th[i] <= 2'd0; tl[i] <= 2'd0; end
        end else if (we) begin
            for (i = 0; i < 16; i = i + 1) begin
                if (wc_h && wc_i == i[3:0]) begin th[i] <= 2'd3; tl[i] <= 2'd3; end
                else if (wb_h && wb_i == i[3:0]) begin th[i] <= 2'd2; tl[i] <= 2'd2; end
                else begin
                    if (wa_h && wa_i == i[3:0]) th[i] <= 2'd1;
                    if (wa_l && wa_i == i[3:0]) tl[i] <= 2'd1;
                end
            end
        end
    end

    wire wea_h = we && !rst && wa_h;
    wire wea_l = we && !rst && wa_l;
    wire web   = we && !rst && wb_h;
    wire wec   = we && !rst && wc_h;

    genvar p;
    generate
        for (p = 0; p < 4; p = p + 1) begin : g_port
            wire [3:0]  a = ra[4*p+3:4*p];
            wire [15:0] ah, al, bh, bl, ch, cl;
            dsp_lutram16 u_ah (.clk(clk), .we(wea_h), .wa(wa_i), .d(wa_hv), .ra(a), .q(ah));
            dsp_lutram16 u_al (.clk(clk), .we(wea_l), .wa(wa_i), .d(wa_lv), .ra(a), .q(al));
            dsp_lutram16 u_bh (.clk(clk), .we(web),   .wa(wb_i), .d(wb_hv), .ra(a), .q(bh));
            dsp_lutram16 u_bl (.clk(clk), .we(web),   .wa(wb_i), .d(wb_lv), .ra(a), .q(bl));
            dsp_lutram16 u_ch (.clk(clk), .we(wec),   .wa(wc_i), .d(wc_hv), .ra(a), .q(ch));
            dsp_lutram16 u_cl (.clk(clk), .we(wec),   .wa(wc_i), .d(wc_lv), .ra(a), .q(cl));
            wire [1:0] sh = th[a];
            wire [1:0] sl = tl[a];
            assign qh[16*p+15:16*p] = (sh == 2'd1) ? ah : (sh == 2'd2) ? bh : (sh == 2'd3) ? ch : 16'd0;
            assign ql[16*p+15:16*p] = (sl == 2'd1) ? al : (sl == 2'd2) ? bl : (sl == 2'd3) ? cl : 16'd0;
        end
    endgenerate
endmodule
