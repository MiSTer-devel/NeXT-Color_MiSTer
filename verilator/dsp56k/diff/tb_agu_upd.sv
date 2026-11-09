// tb_agu_upd -- dsp56k_agu_upd (rtl/dsp56k/dsp56k_agu.sv) against the
// original agu_upd() function of dsp56k_core.sv (Hatari dsp_update_rn*),
// on random and boundary operands of every M class.
//   build: verilator --binary -Irtl/dsp56k verilator/dsp56k/diff/tb_agu_upd.sv \
//       rtl/dsp56k/dsp56k_agu.sv --top-module tb_agu_upd && obj_dir/Vtb_agu_upd
module tb_agu_upd;
    function automatic [15:0] rev16(input [15:0] v);
        integer k;
        begin for (k = 0; k < 16; k = k + 1) rev16[k] = v[15-k]; end
    endfunction
    function automatic [15:0] smear(input [15:0] v);
        reg [15:0] t;
        begin
            t = v; t = t | (t >> 1); t = t | (t >> 2); t = t | (t >> 4); t = t | (t >> 8);
            smear = t;
        end
    endfunction
    function automatic [16:0] agu_upd(input [15:0] r, input [15:0] md, input [15:0] m);
        reg [16:0] rr17, lob, hib, modulo;
        reg [15:0] bufmask, absm, lsb;
        reg [17:0] t;
        begin
            if (m == 16'hffff) agu_upd = {1'b1, r + md};
            else if (m == 16'h0000) begin
                lsb = md & (16'd0 - md);
                agu_upd = {1'b1, rev16(rev16(r) + rev16(lsb))};
            end else if (m[15] == 1'b0) begin
                rr17 = {1'b1, r}; modulo = {1'b0, m} + 17'd1; bufmask = smear(m);
                lob = rr17 & ~{1'b0, bufmask}; hib = lob + {1'b0, m};
                absm = md[15] ? (16'd0 - md) : md;
                t = {1'b0, rr17} + {{2{md[15]}}, md};
                if ((absm & bufmask) != 16'd0) begin
                    if ({1'b0, absm} > modulo) agu_upd = {1'b1, r};
                    else begin
                        if (t > {1'b0, hib}) t = t - {1'b0, modulo};
                        else if (t < {1'b0, lob}) t = t + {1'b0, modulo};
                        agu_upd = {1'b1, t[15:0]};
                    end
                end else agu_upd = {1'b1, t[15:0]};
            end else agu_upd = {1'b0, r};
        end
    endfunction

    reg  [15:0] r, md, m;
    wire [16:0] u;
    dsp56k_agu_upd dut (.r(r), .md(md), .m(m), .u(u));

    integer i, errs = 0, n = 0;
    reg [31:0] x;
    task check;
        begin
            #1;
            n = n + 1;
            if (u !== agu_upd(r, md, m)) begin
                errs = errs + 1;
                if (errs < 10) $display("FAIL r %h md %h m %h: dut %h ref %h", r, md, m, u, agu_upd(r, md, m));
            end
        end
    endtask
    initial begin
        for (i = 0; i < 4000000; i = i + 1) begin
            x = $urandom;
            case (x[2:0])
                3'd0: m = 16'hffff;
                3'd1: m = 16'h0000;
                3'd2: m = {1'b1, x[18:4]};
                3'd3: m = {8'd0, x[11:4]};
                default: m = {1'b0, x[18:4]};
            endcase
            x = $urandom;
            r = x[15:0];
            case (x[18:16])
                3'd0: md = 16'h0001;
                3'd1: md = 16'hffff;
                3'd2: md = m + {14'd0, x[21:20]} - 16'd1;
                3'd3: md = 16'd0 - m - {14'd0, x[21:20]};
                3'd4: md = 16'h8000 | x[22:20];
                default: md = x[31:16];
            endcase
            check;
        end
        $display("tb_agu_upd: %0d vectors, %0d errors", n, errs);
        $finish;
    end
endmodule
