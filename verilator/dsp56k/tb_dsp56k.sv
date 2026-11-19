// tb_dsp56k -- directed test of rtl/tc_dsp56k.sv (the FPGA DSP56001 behind
// the NeXT host port): SCR2 start in mode 1, host bootstrap ended by HF0,
// PIO words both ways, the external RAM (X with A15, P / X aliasing), DMA
// in 24-bit mode both ways, the TRX0 pad byte of unpacked DMA, and a DSP
// reset through SCR2.
//
//   Build: verilator --binary --timing -Irtl/dsp56k verilator/dsp56k/tb_dsp56k.sv \
//       rtl/tc_dsp56k.sv rtl/dsp56k/*.sv --top-module tb_dsp56k && obj_dir/Vtb_dsp56k

`timescale 1ns/1ps
module tb_dsp56k;

reg clk = 0;
always #17.5 clk = ~clk;                 // 28.5 MHz

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
reg         dd_ack = 0;
reg   [7:0] dd_rdata = 0;
reg         dd_avail = 0;
reg         dd_blkend = 0;

tc_dsp56k #(.CLK_HZ(28500000)) dut (
	.clk(clk), .reset(reset),
	.stb(stb), .we(we), .addr2(addr2), .be(be), .wdata(wdata),
	.rdata(rdata), .ack(ack),
	.scr2(scr2), .int_dsp(int_dsp),
	.dd_req(dd_req), .dd_we(dd_we), .dd_wdata(dd_wdata), .dd_ack(dd_ack),
	.dd_rdata(dd_rdata), .dd_avail(dd_avail), .dd_blkend(dd_blkend));

integer errors = 0;

task automatic cyc(input integer n);
	repeat (n) @(posedge clk);
endtask

task automatic wr(input a2, input [3:0] b, input [31:0] d);
	@(negedge clk); stb = 1; we = 1; addr2 = a2; be = b; wdata = d;
	@(negedge clk); stb = 0; we = 0;
endtask

task automatic rd(input a2, input [3:0] b, output [31:0] d);
	@(negedge clk); stb = 1; we = 0; addr2 = a2; be = b;
	@(negedge clk); stb = 0;
	d = rdata;
endtask

function automatic [7:0] isr_of(input [31:0] w0); isr_of = w0[15:8]; endfunction

task automatic wait_isr(input integer bitn, input integer tmo);
	reg [31:0] d; integer i;
	begin
		for (i = 0; i < tmo; i = i + 1) begin
			rd(1'b0, 4'b0010, d);
			if (d[8 + bitn]) i = tmo + 1;
		end
		if (i == tmo) begin $display("FAIL: ISR bit %0d timeout", bitn); errors = errors + 1; end
	end
endtask

task automatic tx(input [23:0] w);
	wait_isr(1, 1000);                   // TXDE
	wr(1'b1, 4'b0111, {8'd0, w});
endtask

task automatic rx(input [23:0] expect_w);
	reg [31:0] d;
	begin
		wait_isr(0, 5000);               // RXDF
		rd(1'b1, 4'b0111, d);
		if (d[23:0] !== expect_w) begin
			$display("FAIL: RX %06x, expected %06x", d[23:0], expect_w); errors = errors + 1;
		end else $display("ok: RX %06x", d[23:0]);
	end
endtask

// the DSP program: echo host words through X:$8100 (external RAM, X half)
// and P:$1100 / X:$1100 (aliased, A15 = 0)
reg [23:0] prog [0:15];
initial begin
	prog[0]  = 24'h0aa980; prog[1]  = 24'h000000;   // 0: JCLR #0,X:$FFE9,0   (HRDF)
	prog[2]  = 24'h54f000; prog[3]  = 24'h00ffeb;   // 2: MOVE X:$FFEB,A1     (HRX)
	prog[4]  = 24'h547000; prog[5]  = 24'h008100;   // 4: MOVE A1,X:$8100
	prog[6]  = 24'h54f000; prog[7]  = 24'h008100;   // 6: MOVE X:$8100,A1
	prog[8]  = 24'h0aa981; prog[9]  = 24'h000008;   // 8: JCLR #1,X:$FFE9,8   (HTDE)
	prog[10] = 24'h547000; prog[11] = 24'h00ffeb;   // a: MOVE A1,X:$FFEB     (HTX)
	prog[12] = 24'h0c0000;                          // c: JMP 0
end

reg [31:0] d;
reg [23:0] got;
integer i, k;

// a DMA channel model: grants a request after a few clocks
reg [7:0] dmabuf [0:15];
integer   dmai = 0;
reg [7:0] dmasrc [0:15];
integer   dmaj = 0;
always @(posedge clk) begin
	dd_ack <= 1'b0;
	if (dd_req && !dd_ack && dd_avail && ($random & 3) == 0) begin
		dd_ack <= 1'b1;
		if (dd_we) begin dmabuf[dmai] <= dd_wdata; dmai <= dmai + 1; end
		else begin dd_rdata <= dmasrc[dmaj]; dmaj <= dmaj + 1; end
	end
end

initial begin
	cyc(5); reset = 0; cyc(5);
	// SCR2: DSP_MEM_EN, mode 1 (bit 28 = 1, bit 27 = 0), then DSP_RESET 0 -> 1
	scr2 = 32'h1000_0020; cyc(3);
	scr2 = 32'h9000_0020; cyc(3);
	// host bootstrap: 13 words, then HF0 ends it
	for (i = 0; i < 13; i = i + 1) wr(1'b1, 4'b0111, {8'd0, prog[i]});
	wr(1'b0, 4'b1000, 32'h0800_0000);    // ICR HF0
	cyc(10);
	if (!dut.running) begin $display("FAIL: DSP not running after HF0"); errors = errors + 1; end
	wr(1'b0, 4'b1000, 32'h0000_0000);    // ICR 0

	// PIO echo
	tx(24'h123456); rx(24'h123456);
	tx(24'hABCDEF); rx(24'hABCDEF);
	if (dut.u_core.u_ext.mem[13'h1100] !== 24'hABCDEF) begin
		$display("FAIL: ext RAM X:$8100 -> ext[$1100] = %06x", dut.u_core.u_ext.mem[13'h1100]); errors = errors + 1;
	end else $display("ok: X:$8100 is ext[$1100]");

	// DSP -> host DMA, 24-bit (HM 01), RREQ: three bytes H M L per word
	dd_avail = 1;
	wr(1'b0, 4'b1000, 32'h2100_0000);    // ICR HM=01 RREQ
	tx(24'h010203);
	tx(24'h0A0B0C);
	cyc(400);
	if (dmai != 6 || dmabuf[0] != 8'h01 || dmabuf[1] != 8'h02 || dmabuf[2] != 8'h03 ||
	    dmabuf[3] != 8'h0A || dmabuf[4] != 8'h0B || dmabuf[5] != 8'h0C) begin
		$display("FAIL: DMA from DSP: %0d bytes %02x %02x %02x %02x %02x %02x", dmai,
		         dmabuf[0], dmabuf[1], dmabuf[2], dmabuf[3], dmabuf[4], dmabuf[5]);
		errors = errors + 1;
	end else $display("ok: DMA DSP -> host 6 bytes");
	if (int_dsp) begin $display("FAIL: int_dsp in DMA mode"); errors = errors + 1; end

	// host -> DSP DMA, 24-bit, TREQ alone: the DSP echoes in PIO
	wr(1'b0, 4'b1000, 32'h8000_0000 | 32'h0300_0000);   // INIT both sides (ICR 0 + INIT, RREQ|TREQ)
	dmasrc[0] = 8'h11; dmasrc[1] = 8'h22; dmasrc[2] = 8'h33;
	dmasrc[3] = 8'h44; dmasrc[4] = 8'h55; dmasrc[5] = 8'h66;
	dd_avail = 1;
	wr(1'b0, 4'b1000, 32'h2200_0000);    // ICR HM=01 TREQ
	k = 0;
	for (i = 0; i < 2000 && k < 2; i = i + 1) begin
		if (dmaj == 6) dd_avail = 0;
		rd(1'b0, 4'b0010, d);
		if (d[8]) begin
			rd(1'b1, 4'b0111, d);
			got = d[23:0];
			if (k == 0 && got !== 24'h112233) begin $display("FAIL: DMA to DSP word 0 %06x", got); errors = errors + 1; end
			if (k == 1 && got !== 24'h445566) begin $display("FAIL: DMA to DSP word 1 %06x", got); errors = errors + 1; end
			k = k + 1;
		end
	end
	if (k != 2) begin $display("FAIL: DMA to DSP: %0d words echoed", k); errors = errors + 1; end
	else $display("ok: DMA host -> DSP 2 words");

	// unpacked DMA from the DSP: TRX0 (0), H, M, L
	dd_avail = 0;
	wr(1'b0, 4'b1000, 32'h0000_0000);
	scr2 = scr2 | 32'h2000_0000;         // DSP_UNPKD
	dmai = 0;
	dd_avail = 1;
	wr(1'b0, 4'b1000, 32'h2100_0000);
	tx(24'h778899);
	cyc(400);
	if (dmai != 4 || dmabuf[0] != 8'h00 || dmabuf[1] != 8'h77 || dmabuf[2] != 8'h88 || dmabuf[3] != 8'h99) begin
		$display("FAIL: unpacked DMA %0d bytes %02x %02x %02x %02x", dmai, dmabuf[0], dmabuf[1], dmabuf[2], dmabuf[3]);
		errors = errors + 1;
	end else $display("ok: unpacked DMA pad H M L");

	// DSP reset through SCR2: host side back to its reset values
	scr2 = 32'h1000_0020; cyc(5);
	rd(1'b0, 4'b1111, d);
	if (d !== 32'h0012_060F) begin $display("FAIL: after DSP reset ICR..IVR %08x", d); errors = errors + 1; end
	else $display("ok: DSP reset -> ICR 00 CVR 12 ISR 06 IVR 0F");
	if (dut.running) begin $display("FAIL: running after DSP reset"); errors = errors + 1; end

	if (errors == 0) $display("PASS");
	else $display("FAILED: %0d errors", errors);
	$finish;
end

initial begin
	#20ms $display("FAIL: timeout"); $finish;
end

endmodule
