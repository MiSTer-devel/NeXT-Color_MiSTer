# DSP56001 in Cyclone V DSP blocks: survey, plan, results

Branch `ap68040-bcopy`, from f91467b.  Question: can moving the FPGA DSP56001's
arithmetic (`rtl/dsp56k`) into the Cyclone V variable-precision DSP blocks
make it much cheaper in ALMs, or easier to time?

**Short answer: no, only a little.**  The 56001 spends its ALMs on control and
multiplexing, not on arithmetic.  The one worthwhile move, the AGU
address-update adders, is implemented here.

- It saves about 100 ALMs in the standalone core and about 190 ALMs in the
  full design, uses 16 DSP blocks, and is timing-neutral.
- f91467b does not fit the device in the same build; this commit fits
  (41,470 ALMs, 99 %).
- Bigger savings would have to come from non-DSP restructuring (see "Where
  the ALMs are").

## 1. Survey

### Fit report (bcopy57, `~/Development/NeXT-Color-bcopy57`, whole design 41,125 ALMs)

| entity | ALMs | regs | M10K bits | DSP |
|---|---:|---:|---:|---:|
| `tc_dsp56k` (total) | 6,565 | 2,648 | 236,544 | 1 |
| `dsp56k_core` (own logic) | 5,292 | 1,830 | | |
| `dsp56k_alu` | 642 | 212 | | 1 |
| `dsp56k_dec` x2 (E1 and registered copies) | 52 + 54 | 0 | | |
| `next_dsp_periph` | 486 | 559 | 3,072 | |
| memories (P/X/Y internal, ROM, 8K ext) | 0 | | 233,472 | |

### Standalone `dsp56k_core`, same device, 33 MHz clock

Built in `~/Development/NeXT-Color-dspblk/exp` (`run.sh`, all pins virtual).
These are bound experiments: each removes one piece of logic to show what it
costs.  Two of them break the function, so they are not usable designs.

| variant | ALMs | DSP | worst setup slack at 33 MHz |
|---|---:|---:|---:|
| baseline | 6,195 | 1 | +2.16 ns |
| AGU modulo and bit-reverse removed (linear only) | 5,717 (-478) | 1 | +2.52 |
| both ALU 57-bit adders removed (XOR in their place) | 6,178 (-17) | 1 | +0.93 |
| new AGU module, adders in fabric | 6,274 (+79) | 1 | +0.83 |
| **new AGU module, adders in DSP blocks (this commit)** | **6,096 (-99)** | **17** | **+1.43** |

Fit-to-fit slack noise is about ±1.3 ns here, so the slack column only shows
that nothing got worse.

What these numbers show:

- **ALU arithmetic is nearly free.**  The 24x24 multiply is already one DSP
  block (27x27 mode).  The 57-bit add/subtract and the second adder
  (ADC/SBC/rounding) are carry chains, about 1 ALM per 2 bits.  Removing
  both saves 17 ALMs.  The ALU's 642 ALMs are operand-select muxes (the 8-way
  multiplier sources, the pre-shift/abs/neg cases), the flag logic and the
  result mux.  A DSP block cannot absorb any of that.
- **Why the multiply output is not in the block's registers:** the product
  goes into a 56-bit operand mux (`spre`) before it is registered, together
  with the shifted, sign-extended and accumulator sources.  Quartus therefore
  packs only the multiplier.  There is no async reset involved; the ALU
  registers have none.
- **The accumulators cannot live in the DSP block.**  A and B are written by
  parallel moves, by A0/A1/A2 register writes, DIV, NORM, Tcc and L: moves,
  and read through the limiter every instruction.  The block's accumulator
  feedback can only be preset with a constant (`loadconst`).  A 56-bit
  operand also cannot enter the block's adder: only 18/27-bit operands or a
  chainin from another block's product are possible, so D + P needs three or
  four chained blocks.  That replaces ~30 ALMs and adds ~10 ns.
- **The DSP-block chain is slower than fabric.**  An unregistered
  18x18 sum-of-2 is about 3-4 ns; a 16-bit carry chain is about 1-1.5 ns.
  The critical path of the standalone core is the last clock (EL):
  `ir_q` -> instruction effects -> next PC -> fetch address into the P/ext
  RAM, about 28 of 30.3 ns.  The ALU add is on it, through the flags into the
  condition codes and the loop logic.  The AGU is on the first clock (E1),
  which has slack.
- **Where the ALMs are:** in `dsp56k_core`'s own 5.3k, of which:
  - the next-state muxes of every register for the EL write port (24 AGU
    registers x 16 bits, each with AGU commit, register write, NORM and
    pipeline sources; A/B with ~10 sources each);
  - the 30-way register read mux (`sval`);
  - the memory access plan and region logic (computed twice: E1 and delayed
    issue);
  - the 16-entry x 32-bit hardware stack in registers, with three write
    ports and forwarding (`stk_rd`);
  - the decoder, instantiated twice;
  - the AGU's modulo/bit-reverse logic: 478 ALMs for the two units, the one
    sizeable arithmetic block.

## 2. Plan: candidates and estimates

| candidate | ALM saving | DSP blocks | timing | verdict |
|---|---:|---:|---|---|
| 24x24 multiply in a 27x27 block | already done | 1 | - | as is |
| MAC add/accumulate in the block (A/B kept in the block) | none realistic | 3-4 | worse (+~10 ns on EL path) | no: A/B have ~10 write sources; a 56-bit addend cannot enter the block |
| ALU add/sub, round, DIV adder in blocks | <= 17 measured (ALU), ~25 (DIV) | 3-4 each | worse (EL critical path) | no |
| Product kept in the DSP output register, mux moved after it | ~0 (mux moves, flops stay) | 0 | E1 better, EL worse | no: EL is the critical clock |
| **AGU update adders (t, rev, hib, \|Md\|-M, wrap down/up, two bound compares) in m18x18_sumof2 blocks** | **~100 measured** | **16** | **neutral (E1, two blocks deep)** | **done** |
| AGU negations (-Nn, -Md) in blocks | ~30 | 4 | E1 gets 3 blocks deep | marginal, not done |
| Small EL adders (pc+1..3, int_fetch+1/2, LC-1, SP+-1, NORM Rn+-1) | ~8 each | 1 each | worse (EL) | no |
| Bit masks / bit select as multiplies by 2^n | ~10 each | 2-3 each | worse | no |
| Wide muxes as sum-of-products (one-hot x data) | ~6-9 per block | many, long chains | worse | no |

The offload rate of a DSP block is about 9-11 ALMs per block, as measured:
178 ALMs for 16 blocks against the same RTL in fabric.  With ~50 free blocks
in the full design (bcopy/softdsp use 61-62 of 112), the most any DSP-block
scheme could save is a few hundred ALMs.  Every such scheme puts 3-4 ns
combinational blocks on paths that are already near the 30.3 ns limit.

Cycle timing is untouched: the AGU change is purely combinational within the
same clock, so instruction lengths, host-port and DMA timing are as before.

## 3. Implementation

- `rtl/dsp56k/dsp56k_agu.sv` (new):
  - `dsp56k_agu_upd` replaces the `agu_upd()` function of `dsp56k_core.sv`
    (Hatari `dsp_update_rn*`: linear, bit-reverse, modulo, no-update).  It is
    written as eight independent 18-bit add/subtracts and a final select.
    Values are offset by -65536 against Hatari's `{1,R}` form, so all
    operands fit 18-bit signed.  `|Md| > M+1` becomes `|Md|-M >= 2`, and
    `t -/+ (M+1)` becomes `t +/- ~M`, so no +1 adders are needed.
  - `dsp56k_addsub18` is one `cyclonev_mac` in `m18x18_sumof2` mode
    (`a*1 +- b*1`, no registers) when `DSP56K_DSPBLK` is defined, and a plain
    adder otherwise (Verilator, or to compare).
- `dsp56k_core.sv`:
  - two `dsp56k_agu_upd` instances (one per address unit, E1);
  - `calc_ea()` takes the update result;
  - the modifier selection is `agu_md()`.
- `files.qip`: the new file.  `NeXT-Color.qsf`: `DSP56K_DSPBLK=1`.

## 4. Verification

- **New differential testbench** `verilator/dsp56k/diff/` (`run_diff.sh`,
  `tb_diff.cpp`).  It runs `dsp56k_core` against Previous's (Hatari's)
  DSP56001 interpreter from `Main_MiSTer-softdsp/support/next/dsp56k`, on
  random programs.
  - The programs are biased to parallel-move ALU instructions, with random
    registers and corner-case data (saturation, $800000/$7FFFFF, rounding
    boundaries, all scaling modes).  AGU registers are set up in linear,
    modulo (small and large M), bit-reverse and reserved-M modes.
  - After every instruction it compares all registers, the stack, every
    memory word written and the instruction length in clocks (cycle
    exactness).  At the end it compares all memory.
  - Undefined opcodes are compared, then replaced in both models.  Programs
    end where the models cannot be compared: peripheral accesses (none are
    attached), OMR mode 1, and WAIT/STOP reached through self-modified code.
- **Results.**
  - 20,000 programs and 8.0 M instructions: the log of the modified RTL is
    byte-identical to the log of f91467b.
  - The testbench catches real faults.  A first version of the new AGU, with
    an 18-bit overflow, failed 8 extra seeds.
  - `tb_agu_upd.sv`: 4 M random and boundary vectors of `dsp56k_agu_upd`
    against the original `agu_upd()`, 0 errors.
  - `verilator/dsp56k/tb_dsp56k.sv` (host port, bootstrap, DMA, external
    RAM): PASS.
- **Pre-existing RTL vs Previous differences.**  0.3 % of programs (60 of
  20,000) fail the same way on f91467b and on this commit.  All are
  encodings real code does not use, or reachable only through self-modified
  code:
  - "102-cycle" undefined forms of MOVEP and the parallel moves;
  - DO/JSET/JSSET/JCLR with an absolute ea (three words);
  - MOVEM S,P:ea with A15 set: Previous maps P writes like Y, but not P
    reads;
  - a few JSSET/JSCLR stack-entry and interrupt corner cases.

  The generator avoids the common ones.  They are listed as follow-ups, not
  fixed here.

## 5. Full build

`~/Development/NeXT-Color-dspblk` (this commit) against
`~/Development/NeXT-Color-dspblk-base` (f91467b, same box, same settings):

| | f91467b (base) | this commit |
|---|---:|---:|
| fit | **does not fit**: 4,205 LABs needed, 4,191 in the device | fits |
| ALMs (whole design) | 41,663 (fitter estimate) | 41,470 (99 %) |
| DSP blocks | 62 | 78 |
| M10K bits | 2,238,277 | 2,238,277 |
| registers | 33,266 | 36,032 |
| setup slack, 33 MHz bus clock (general[0]) | - (no timing, fit failed) | -0.772 ns |
| setup slack, 66 MHz CPU clock (general[2]) | - | -4.148 ns |
| setup slack, 99 MHz (general[1]) | - | -0.082 ns |
| setup slack, HDMI | - | -1.167 ns |

`tc_dsp56k` in this build: 6,427 ALMs and 17 DSP blocks.  `dsp56k_core`'s own
logic is 4,917 ALMs.  Each `dsp56k_agu_upd` is 45 / 43 ALMs plus 8 DSP blocks.
The ALU is 661 ALMs and 1 DSP block.  Both builds use seed 7 and the same box;
in the base build the fitter stops before timing analysis.

Timing in the full build (worst setup paths):

- 33 MHz: the worst path is the SDRAM `sdram_beat32` `line_handoff` ->
  `line_data` path, -0.77 ns, outside the DSP.
- Next are the DSP's external-RAM read paths (`u_ext` port A -> read-data mux
  -> `next_dsp_periph` / core registers), -0.62 ns and better.  These were
  already the worst DSP paths in the standalone fit, before the change, and
  they do not go through the AGU blocks.  With the device 99 % full they get
  longer.
- 66 MHz: the AP68040 backend `ex_u.sz` -> `dc1_*`, -4.15 ns.  That is the
  known CPU-clock problem, handled in another session.

So the change is timing-neutral where it acts.  In this build, the ~190 ALMs
it frees make the difference between the design fitting and not fitting.
Timing closure of the 99 %-full design is still open.  The bcopy build of
2026-11-06, an earlier revision, met 33 MHz at +0.171 ns.

## Follow-ups (not done here)

Bigger ALM savings in the DSP are non-DSP-block work.  Estimates are from the
survey above, not measured:

- Put the hardware stack (16 x 32 bits in registers, three write ports,
  forwarding) in MLAB/M10K by serializing its writes.
- Drop the second decoder copy (`u_decq`) by registering the decoded fields
  of the first.
- Reduce the E1 / delayed-issue duplication of the memory-access plan.
- Look at the pre-existing differences against Previous listed above,
  especially the stack/interrupt corner cases.
