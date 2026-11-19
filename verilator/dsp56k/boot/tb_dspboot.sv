// tb_dspboot -- replay libdsp DSPBoot() (dsp-17.12 DSPBoot.c) against
// rtl/tc_dsp56k.sv with a Music Kit monitor: script from lod2script.py.
// PIO only, polling ISR TXDE / RXDF like the mapped-mode libdsp loops.
//
//   Build: verilator --binary --timing -I../../../rtl/dsp56k tb_dspboot.sv \
//     ../../../rtl/tc_dsp56k.sv ../../../rtl/dsp56k/*.sv --top-module tb_dspboot
//   obj_dir/Vtb_dspboot +script=mkmon_A_8k.script   (or: bash run.sh)
`timescale 1ns/1ps
module tb_dspboot;

reg clk = 0;
always #19.2 clk = ~clk;                 // 26 MHz

reg         reset = 1;
reg         stb = 0, we = 0, addr2 = 0;
reg   [3:0] be = 0;
reg  [31:0] wdata = 0;
wire [31:0] rdata;
wire        ack;
reg  [31:0] scr2 = 0;
wire        int_dsp;
wire        dd_req, dd_we;
wire  [7:0] dd_wdata;

tc_dsp56k #(.CLK_HZ(26000000)) dut (
	.clk(clk), .reset(reset),
	.stb(stb), .we(we), .addr2(addr2), .be(be), .wdata(wdata),
	.rdata(rdata), .ack(ack),
	.scr2(scr2), .int_dsp(int_dsp),
	.dd_req(dd_req), .dd_we(dd_we), .dd_wdata(dd_wdata), .dd_ack(1'b0),
	.dd_rdata(8'd0), .dd_avail(1'b0), .dd_blkend(1'b0));

integer errors = 0;
reg [31:0] script [0:65535];
reg [31:0] d;
integer pc, ntx, nrx;
string fn;

task automatic cyc(input integer n); repeat (n) @(posedge clk); endtask
task automatic wr(input a2, input [3:0] b, input [31:0] v);
	@(negedge clk); stb = 1; we = 1; addr2 = a2; be = b; wdata = v;
	@(negedge clk); stb = 0; we = 0;
endtask
task automatic rd(input a2, input [3:0] b, output [31:0] v);
	@(negedge clk); stb = 1; we = 0; addr2 = a2; be = b;
	@(negedge clk); stb = 0;
	v = rdata;
endtask

task automatic dump(input string why);
	reg [31:0] r;
	rd(1'b0, 4'b1111, r);
	$display("%s: script %0d (tx %0d rx %0d) ICR %02x CVR %02x ISR %02x IVR %02x  HSR %02x HCR %02x  running %0d pc %04x",
		why, pc, ntx, nrx, r[31:24], r[23:16], r[15:8], r[7:0],
		dut.u_periph.hsr, dut.u_periph.hcr, dut.running, dut.u_core.pc);
endtask

task automatic wait_isr(input integer bitn, input integer tmo, output bit ok);
	reg [31:0] v; integer i;
	ok = 0;
	for (i = 0; i < tmo && !ok; i = i + 1) begin
		rd(1'b0, 4'b0010, v);
		if (v[8 + bitn]) ok = 1;
		else cyc(4);
	end
endtask

bit ok;
integer bytemode = 0, gap = 0, nmsg = 0;
task automatic host_gap; if (gap > 0) cyc(1 + ($urandom % gap)); endtask
task automatic tx_word(input [23:0] w);
	if (bytemode) begin
		wr(1'b1, 4'b0100, {8'd0, w[23:16], 16'd0});
		wr(1'b1, 4'b0010, {16'd0, w[15:8], 8'd0});
		wr(1'b1, 4'b0001, {24'd0, w[7:0]});
	end else wr(1'b1, 4'b0111, {8'd0, w});
endtask
task automatic rx_word(output [23:0] w);
	reg [31:0] v;
	if (bytemode) begin
		rd(1'b1, 4'b0100, v); w[23:16] = v[23:16];
		rd(1'b1, 4'b0010, v); w[15:8]  = v[15:8];
		rd(1'b1, 4'b0001, v); w[7:0]   = v[7:0];
	end else begin rd(1'b1, 4'b0111, v); w = v[23:0]; end
endtask
initial begin
	if (!$value$plusargs("script=%s", fn)) fn = "mkmon_A_8k.script";
	void'($value$plusargs("bytemode=%d", bytemode));
	void'($value$plusargs("gap=%d", gap));
	$readmemh(fn, script);
	cyc(5); reset = 0; cyc(5);
	// SCR2: DSP_MEM_EN, mode 1, DSP_RESET 1 -> 0 -> 1
	// dsp_dev_reset_chip: scr2 &= 07FFFFFF (MEM_EN off for dma_chip != 313),
	// |= MODE_B, |= DSP_RESET, &= ~MODE_B, MEM_EN on; then ICR = 0
	scr2 = 32'h8000_10a0; cyc(10);
	scr2 = scr2 & 32'h07ff_ffdf; cyc(3);
	scr2 = scr2 | 32'h1000_0000; cyc(3);
	scr2 = scr2 | 32'h8000_0000; cyc(3);
	scr2 = scr2 & 32'hefff_ffff; cyc(3);
	scr2 = scr2 | 32'h0000_0020; cyc(3);
	wr(1'b0, 4'b1000, 32'h0000_0000);
	pc = 0; ntx = 0; nrx = 0;
	while (script[pc] != 0) begin
		case (script[pc][31:24])
		8'h01: begin
			wait_isr(1, 20000, ok);
			if (!ok) begin dump("FAIL TXDE timeout"); errors++; break; end
			host_gap; tx_word(script[pc][23:0]); ntx++;
		end
		8'h02, 8'h04, 8'h09: begin
			wait_isr(0, (script[pc][31:24] == 8'h04) ? 20000 : 200000, ok);
			if (!ok && script[pc][31:24] == 8'h04) begin dump("no more DSP words"); pc++; continue; end
			if (!ok) begin dump("FAIL RXDF timeout"); errors++; break; end
			host_gap; rx_word(d[23:0]); nrx++;
			if (script[pc][31:24] == 8'h02 && d[23:0] !== script[pc][23:0]) begin
				$display("FAIL RX %06x expected %06x (script %0d)", d[23:0], script[pc][23:0], pc);
				errors++;
			end else if (script[pc][31:24] == 8'h04 && (nmsg > 0 || d[23:0] !== 24'h0f0000)) begin
				// after DSP_MS_N: exactly one DSP message, DM_IDLE
				if (errors < 4) $display("FAIL DSP message %0d = %06x (want one DM_IDLE $0F0000)", nmsg, d[23:0]);
				errors++; nmsg++;
			end else begin
				if (script[pc][31:24] == 8'h04) nmsg++;
				$display("RX %06x (script %0d, after %0d TX)  t=%0t", d[23:0], pc, ntx, $time);
			end
		end
		8'h03: begin
			wr(1'b0, 4'b1000, {script[pc][7:0], 24'd0});
			$display("ICR <- %02x (script %0d)", script[pc][7:0], pc);
		end
		8'h05: begin                       // host command: CVR = $80|vec, wait HC clear
			host_gap;
			wr(1'b0, 4'b0100, {8'd0, 8'h80 | script[pc][7:0], 16'd0});
			ok = 0;
			for (int i = 0; i < 20000 && !ok; i++) begin
				rd(1'b0, 4'b0100, d); if (!d[23]) ok = 1; else cyc(4);
			end
			if (!ok) begin dump("FAIL HC not cleared"); errors++; break; end
			$display("HC $%02x done (script %0d)", script[pc][7:0], pc);
		end
		8'h06, 8'h07: begin                // wait ISR & mask == 0 (06) / == mask (07)
			ok = 0;
			for (int i = 0; i < 200000 && !ok; i++) begin
				rd(1'b0, 4'b0010, d);
				if (script[pc][31:24] == 8'h06 ? ((d[15:8] & script[pc][7:0]) == 0)
				                                : ((d[15:8] & script[pc][7:0]) == script[pc][7:0])) ok = 1;
				else cyc(4);
			end
			if (!ok) begin dump($sformatf("FAIL ISR wait %s %02x", script[pc][31:24] == 8'h06 ? "clear" : "set", script[pc][7:0])); errors++; break; end
		end
		8'h08: begin                       // check x:<addr> == next entry (internal X RAM)
			cyc(200);
			if (dut.u_core.u_xint.mem[script[pc][7:0]] !== script[pc+1][23:0]) begin
				$display("FAIL x:%02x = %06x, expected %06x", script[pc][7:0],
				         dut.u_core.u_xint.mem[script[pc][7:0]], script[pc+1][23:0]);
				errors++;
			end else $display("ok: x:%02x = %06x", script[pc][7:0], script[pc+1][23:0]);
			pc++;
		end
		8'h0a: begin                       // read words until opcode (bits 23:16) == data[7:0], max 4
			ok = 0;
			for (int k = 0; k < 4 && !ok; k++) begin
				wait_isr(0, 20000, ok);
				if (!ok) break;
				rx_word(d[23:0]); nrx++;
				$display("RX %06x (script %0d, until opcode %02x)", d[23:0], pc, script[pc][7:0]);
				ok = (d[23:16] == script[pc][7:0]);
			end
			if (!ok) begin dump($sformatf("FAIL no DSP message %02x", script[pc][7:0])); errors++; break; end
		end
		default: ;
		endcase
		pc++;
	end
	dump("end");
	if (errors == 0) $display("PASS");
	else $display("FAILED: %0d errors", errors);
	$finish;
end

integer trace = 0;
reg [4:0] hcr_q = 0;
initial void'($value$plusargs("trace=%d", trace));
always @(posedge clk) if (trace != 0 && dut.running) begin
	if (dut.u_periph.perx_rd && dut.u_periph.perx_addr == 6'h2b)
		$display("  [%0t] HRX rd %06x pc %04x r3 %04x m3 %04x", $time, dut.u_periph.rtx, dut.u_core.pc, dut.u_core.rr[3], dut.u_core.mm[3]);
	if (trace > 1 && dut.u_periph.hcr != hcr_q)
		$display("  [%0t] HCR %02x -> %02x pc %04x hsr %02x", $time, hcr_q, dut.u_periph.hcr, dut.u_core.pc, dut.u_periph.hsr);
	hcr_q <= dut.u_periph.hcr;
	if (dut.u_periph.perx_wr && dut.u_periph.perx_addr == 6'h2b)
		$display("  [%0t] HTX wr %06x pc %04x", $time, dut.u_periph.perx_wdata, dut.u_core.pc);
end
initial begin
	#2s $display("FAIL: global timeout"); dump("timeout"); $finish;
end
endmodule
