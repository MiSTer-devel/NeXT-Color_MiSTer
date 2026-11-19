// DSP56001 AGU address update (Hatari dsp_update_rn / dsp_update_rn_bitreverse
// / dsp_update_rn_modulo), one unit, with its adders in Cyclone V DSP blocks.
//
// Same function as the agu_upd() it replaces in dsp56k_core.sv, bit for bit:
//   M = $FFFF       linear:      R + Md
//   M = $0000       bit reverse: rev(rev(R) + rev(lowest set bit of Md))
//   M = $0001-$7FFF modulo M+1   (Hatari's lower/upper bound rule)
//   M = $8000-$FFFE no update    (valid = 0)
// Md is the signed modifier (+-1, +-Nn).
//
// The arithmetic is eight independent 18-bit add/subtract operations, written
// so that none feeds another except through the final selection:
//   t   = R + Md                linear result (low 16 bits) and modulo sum
//   rv  = rev(R) + rev(lsb)     bit-reverse sum
//   hib = lob + M               upper bound of the modulo buffer
//   ca  = |Md| - M              |Md| > M + 1  <=>  ca >= 2
//   tm  = t + ~M  (= t - (M+1)) wrap down
//   tp  = t - ~M  (= t + (M+1)) wrap up
//   chi = hib - t               t > hib  <=>  chi < 0
//   clo = t - lob               t < lob  <=>  clo < 0
// t, rv, hib and ca come from the inputs; tm, tp, chi and clo take t (and
// hib), so the chain is two blocks deep.  -Md (for |Md| and the lowest set
// bit) stays in the fabric (one 16-bit negate).
//
// DSP56K_DSPBLK (Quartus): every add/subtract is one cyclonev_mac in
// m18x18_sumof2 mode, a*1 +- b*1, no registers; otherwise (simulation, or
// to compare) plain fabric adders.

module dsp56k_addsub18 (
    input  signed [17:0] a,
    input  signed [17:0] b,
    input                sub,      // 1: a - b
    output signed [18:0] s
);
`ifdef DSP56K_DSPBLK
    wire [36:0] r;
    cyclonev_mac #(
        .operation_mode("m18x18_sumof2"),
        .ax_width(18), .ay_scan_in_width(19), .bx_width(18), .by_width(19),
        .result_a_width(37),
        .operand_source_max("input"), .operand_source_may("input"),
        .operand_source_mbx("input"), .operand_source_mby("input"),
        .signed_max("true"), .signed_may("true"), .signed_mbx("true"), .signed_mby("true"),
        .ax_clock("none"), .ay_scan_in_clock("none"), .bx_clock("none"), .by_clock("none"),
        .sub_clock("none"), .negate_clock("none"), .accumulate_clock("none"),
        .load_const_clock("none"), .output_clock("none"),
        .coef_sel_a_clock("none"), .coef_sel_b_clock("none")
    ) u_mac (
        .ax(a), .ay(19'sd1), .bx(b), .by(19'sd1),
        .sub(sub), .negate(1'b0), .accumulate(1'b0), .loadconst(1'b0),
        .clk(3'b000), .ena(3'b111), .aclr(2'b00),
        .resulta(r)
    );
    assign s = r[18:0];
`else
`ifdef FI_SUB_IGNORED
    assign s = a + b;                       // fault: sub port ignored
`elsif FI_SUB_SWAP
    assign s = sub ? (b - a) : (a + b);     // fault: operands swapped on sub
`else
    assign s = sub ? (a - b) : (a + b);
`endif
`endif
endmodule

module dsp56k_agu_upd (
    input  [15:0] r,
    input  [15:0] md,
    input  [15:0] m,
    output [16:0] u          // {valid, new value}
);
    function automatic [15:0] rev16(input [15:0] v);
        integer k;
        begin
            for (k = 0; k < 16; k = k + 1) rev16[k] = v[15-k];
        end
    endfunction

    wire [15:0] neg_md  = 16'd0 - md;
    wire [15:0] lsb     = md & neg_md;
    wire [15:0] absm    = md[15] ? neg_md : md;
    wire [15:0] bufmask = m | (m >> 1) | (m >> 2) | (m >> 3) | (m >> 4) | (m >> 5) |
                          (m >> 6) | (m >> 7) | (m >> 8) | (m >> 9) | (m >> 10) |
                          (m >> 11) | (m >> 12) | (m >> 13) | (m >> 14) | (m >> 15);
    // Hatari works on {1,R} (17 bits); everything here is 65536 lower, which
    // changes no comparison and no low 16 bits, and keeps the operands within
    // 18-bit signed: t in [-32768, 98302], hib in [0, 98302]
    wire [15:0] lob     = r & ~bufmask;

    wire signed [17:0] s_rr  = {2'b00, r};
    wire signed [17:0] s_md  = {{2{md[15]}}, md};
    wire signed [17:0] s_m   = {2'b00, m};
    wire signed [17:0] s_nm  = ~s_m;                  // -(M+1)
    wire signed [17:0] s_lob = {2'b00, lob};

    wire signed [18:0] t19, rv19, hib19, ca19, tm19, tp19, chi19, clo19;
    dsp56k_addsub18 a_t   (.a(s_rr), .b(s_md), .sub(1'b0), .s(t19));
    dsp56k_addsub18 a_rv  (.a({2'b00, rev16(r)}), .b({2'b00, rev16(lsb)}), .sub(1'b0), .s(rv19));
    dsp56k_addsub18 a_hib (.a(s_lob), .b(s_m), .sub(1'b0), .s(hib19));
    dsp56k_addsub18 a_ca  (.a({2'b00, absm}), .b(s_m), .sub(1'b1), .s(ca19));
    // tm / tp / chi / clo take t (two blocks deep)
    wire signed [17:0] s_t   = t19[17:0];
    dsp56k_addsub18 a_tm  (.a(s_t), .b(s_nm), .sub(1'b0), .s(tm19));
    dsp56k_addsub18 a_tp  (.a(s_t), .b(s_nm), .sub(1'b1), .s(tp19));
    dsp56k_addsub18 a_chi (.a(hib19[17:0]), .b(s_t), .sub(1'b1), .s(chi19));
    dsp56k_addsub18 a_clo (.a(s_t), .b(s_lob), .sub(1'b1), .s(clo19));

    // |Md| > M + 1  <=>  |Md| - M >= 2
    wire        too_far = !ca19[18] && (ca19[17:1] != 17'd0);
    wire        t_hi    = chi19[18];
    wire        t_lo    = clo19[18];

    reg  [16:0] uo;
    always @* begin
        if (m == 16'hffff)
            uo = {1'b1, t19[15:0]};
        else if (m == 16'h0000)
            uo = {1'b1, rev16(rv19[15:0])};
        else if (m[15] == 1'b0) begin
            if ((absm & bufmask) != 16'd0) begin
                if (too_far)   uo = {1'b1, r};
                else if (t_hi) uo = {1'b1, tm19[15:0]};
                else if (t_lo) uo = {1'b1, tp19[15:0]};
                else           uo = {1'b1, t19[15:0]};
            end else
                uo = {1'b1, t19[15:0]};
        end else
            uo = {1'b0, r};
    end
    assign u = uo;
endmodule
