// tb_tc_vram -- unit bench of the CPU beat port of rtl/tc_vram.sv, against
// the DDR3 model ddr3_model.sv (random BUSY), clk_sys 33 MHz / clk_ram 99 MHz
// phase aligned as on the board.
//
// The requester plays tc_machine's S_IDLE/S_MEM loop: req registered, dropped
// on the edge that sees ack, raised again for the next beat one edge later.
// Checks: exactly one ack per request and none without one; read data
// against a shadow copy (kept-line hits and misses, writes into the kept
// line, byte enables); the DDR3 contents at the end.  Reports clk_sys per
// beat for a longword fill, with the scan-out idle (clk_vid stopped after
// lines 0 and 1) and running (1120x832 power-on timing).
`timescale 1ns/1ps

module tb_tc_vram;

reg clk_sys = 0, clk_ram = 0, clk_vid = 0;
reg vid_run = 0;
always #15 clk_sys = ~clk_sys;          // 33.3 MHz
always #5  clk_ram = ~clk_ram;          // 100 MHz, rising edges aligned with clk_sys
always #5  if (vid_run) clk_vid = ~clk_vid;

reg         reset = 1, reset_vid = 1;
reg         req = 0, we = 0;
reg  [20:2] addr = 0;
reg   [3:0] be = 0;
reg  [31:0] wdata = 0;
wire        ack;
wire [31:0] rdata;

wire        DDRAM_BUSY, DDRAM_DOUT_READY, DDRAM_RD, DDRAM_WE;
wire  [7:0] DDRAM_BURSTCNT, DDRAM_BE;
wire [28:0] DDRAM_ADDR;
wire [63:0] DDRAM_DOUT, DDRAM_DIN;
wire  [7:0] vga_r, vga_g, vga_b;
wire        vga_hs, vga_vs, vga_de, vbl_pulse;

tc_vram dut (
	.clk_sys(clk_sys), .clk_ram(clk_ram), .clk_vid(clk_vid),
	.reset(reset), .reset_vid(reset_vid), .ddr_hold(1'b0),
	.req(req), .we(we), .addr(addr), .be(be), .wdata(wdata),
	.ack(ack), .rdata(rdata),
	.hreg(32'h31048118), .vreg(32'h10430340), .video_enable(1'b1),
	.pal_we(3'd0), .pal_n(4'd0), .pal_d(8'd0), .vbl_pulse(vbl_pulse),
	.vga_r(vga_r), .vga_g(vga_g), .vga_b(vga_b),
	.vga_hs(vga_hs), .vga_vs(vga_vs), .vga_de(vga_de),
	.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD),
	.DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE)
);

wire [63:0] peek_data;
ddr3_model ddr (
	.clk(clk_ram), .busy(DDRAM_BUSY), .burstcnt(DDRAM_BURSTCNT), .addr(DDRAM_ADDR),
	.dout(DDRAM_DOUT), .dout_ready(DDRAM_DOUT_READY), .rd(DDRAM_RD),
	.din(DDRAM_DIN), .be(DDRAM_BE), .we(DDRAM_WE),
	.peek_addr(18'd0), .peek_data(peek_data),
	.poke_en(1'b0), .poke_addr(18'd0), .poke_data(64'd0)
);

integer errors = 0;
integer issued = 0, acks = 0;

// the shadow: 256 longwords at VRAM $40000
localparam [20:2] SBASE = 19'h10000;
reg [31:0] shadow [0:255];
integer i;
initial for (i = 0; i < 256; i = i + 1) shadow[i] = 32'd0;

// ack accounting: a stray ack shows as a count mismatch at the end, or as an
// early completion of a later beat (wrong read data)
reg req_d = 0;
always @(posedge clk_sys) begin
	req_d <= req;
	if (!reset && ack) begin
		acks = acks + 1;
		if (!req_d) begin
			$display("ERROR %0t: ack with no request up", $time);
			errors = errors + 1;
		end
	end
end

task automatic beat(input bit w, input [20:2] a, input [3:0] b, input [31:0] d, output [31:0] q);
	begin
		@(posedge clk_sys);
		req <= 1; we <= w; addr <= a; be <= b; wdata <= d;
		issued = issued + 1;
		@(posedge clk_sys);
		while (!ack) @(posedge clk_sys);
		q = rdata;
		req <= 0;                       // dropped on the edge that sees ack
	end
endtask

function automatic [31:0] merge(input [31:0] o, input [31:0] n, input [3:0] b);
	merge = {b[3] ? n[31:24] : o[31:24], b[2] ? n[23:16] : o[23:16],
	         b[1] ? n[15:8]  : o[15:8],  b[0] ? n[7:0]   : o[7:0]};
endfunction

task automatic random_mix(input integer n);
	integer k, idx;
	reg [31:0] q, d;
	reg  [3:0] b;
	bit        w;
	begin
		for (k = 0; k < n; k = k + 1) begin
			idx = $urandom_range(0, 255);
			w   = $urandom_range(0, 1);
			if (w) begin
				d = $urandom;
				case ($urandom_range(0, 3))
				0: b = 4'hF;
				1: b = 4'b1100 >> (2 * $urandom_range(0, 1));
				2: b = 4'b0001 << $urandom_range(0, 3);
				default: b = $urandom_range(1, 15);
				endcase
				beat(1, SBASE + idx, b, d, q);
				shadow[idx] = merge(shadow[idx], d, b);
			end
			else begin
				beat(0, SBASE + idx, 4'hF, 32'd0, q);
				if (q !== shadow[idx]) begin
					$display("ERROR %0t: read [%0d] = %08X, expected %08X", $time, idx, q, shadow[idx]);
					errors = errors + 1;
				end
			end
		end
	end
endtask

// a longword fill of n beats from VRAM long address a0; returns clk_sys cycles
task automatic fill(input [20:2] a0, input integer n, output integer cyc);
	integer k;
	reg [31:0] q;
	time t0;
	begin
		@(posedge clk_sys);
		t0 = $time;
		for (k = 0; k < n; k = k + 1) beat(1, a0 + k, 4'hF, 32'hA5000000 + k, q);
		cyc = ($time - t0) / 30;
	end
endtask

task automatic check_ddr;
	integer k;
	reg [63:0] w;
	reg [31:0] l;
	begin
		repeat (20) @(posedge clk_sys);     // a posted write may still be on its way
		for (k = 0; k < 256; k = k + 1) begin
			w = ddr.mem[(SBASE + k) >> 1];
			l = k[0] ? w[63:32] : w[31:0];
			l = {l[7:0], l[15:8], l[23:16], l[31:24]};
			if (l !== shadow[k]) begin
				$display("ERROR: DDR3 [%0d] = %08X, expected %08X", k, l, shadow[k]);
				errors = errors + 1;
			end
		end
	end
endtask

// queue coverage (tc_vram's posted-write queue): deepest fill, cycles full
integer wq_max = 0, wq_full_cyc = 0;
always @(posedge clk_sys) begin
	if (4'(dut.wq_wp - dut.wq_rp_sys) > wq_max) wq_max = 4'(dut.wq_wp - dut.wq_rp_sys);
	if (dut.wq_full && req && we) wq_full_cyc = wq_full_cyc + 1;
end

integer c_idle, c_vid;
localparam integer N = 4000;

initial begin
	repeat (4) @(posedge clk_sys);
	reset <= 0;
	reset_vid <= 0;
	// let the engine fetch lines 0 and 1 (clk_vid stopped: no more lines wanted)
	repeat (2000) @(posedge clk_sys);

	random_mix(3000);
	check_ddr();

	fill(19'h20000, N, c_idle);
	$display("fill, scan-out idle:    %0d beats, %0d clk_sys, %0.2f clk_sys/beat", N, c_idle, c_idle * 1.0 / N);

	vid_run = 1;
	repeat (40000) @(posedge clk_sys);  // into the visible frame, fetch running
	fill(19'h30000, N, c_vid);
	$display("fill, scan-out running: %0d beats, %0d clk_sys, %0.2f clk_sys/beat", N, c_vid, c_vid * 1.0 / N);

	random_mix(3000);
	check_ddr();
	repeat (50) @(posedge clk_sys);
	if (acks != issued) begin
		$display("ERROR: %0d acks for %0d requests", acks, issued);
		errors = errors + 1;
	end

	$display("write queue: deepest %0d of 8, %0d clk_sys with a write waiting on a full queue", wq_max, wq_full_cyc);
	if (errors == 0) $display("PASS tb_tc_vram");
	else             $display("FAIL tb_tc_vram: %0d errors", errors);
	$finish;
end

endmodule
