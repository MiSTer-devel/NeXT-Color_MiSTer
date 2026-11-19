// Unit test of rtl/tc_scc.sv + rtl/z8530_scc.sv (Z8530 SCC).
//
//  1. The ROM POST (post_scc_test $010048a6): ctrl A read, WR9 $CA, the
//     20-byte table tbl_scc_init $010195f4 to ctrl A then ctrl B (local
//     loopback, x16, BRG from RTxC, TC $0A), RR0 TX-empty, data $40 on each
//     channel, RR0 RX-available, data read back == $40.
//  2. scc_init_channel at 9600 baud from PCLK (WR14 $03): a character on
//     channel A's TXD (the MiSTer UART) with the right bit time; a second
//     one survives WR5 TxEnable being cleared halfway through it.
//  3. A character driven into RXD A arrives in RR8 and raises INT_SCC with
//     WR1 RX-interrupt-on-all and WR9 MIE.
//  4. MIDI as NeXTSTEP sets it up (clock select $30 = PCLK 10 MHz, TC 8,
//     x16): 31250 baud out and in, channel A, then channel B via uart_b.
//  5. Under the same clock select, 9600 from RTxC (TC 10) for the console.
`timescale 1ns/1ps
module tb_tc_scc
#(
	parameter CLK_HZ = 33000000   // the core's clk_sys: 33 MHz, 25 MHz on the fork
);

reg clk = 0;
always #(500000000.0 / CLK_HZ) clk = !clk;

reg         reset = 1;
reg         stb = 0, we = 0, a2 = 0;
reg   [3:0] be = 0;
reg  [31:0] wdata = 0;
wire [31:0] rdata;
wire        ack, irq, txd_a;
reg         rxd_a = 1;
reg         uart_b = 0;      // NeXT-Color.sv status[9]: port B on the UART

tc_scc #(.CLK_HZ(CLK_HZ)) dut (
	.clk(clk), .reset(reset),
	.stb(stb), .we(we), .a2(a2), .be(be), .wdata(wdata),
	.rdata(rdata), .ack(ack),
	.irq(irq),
	.txd_a(ch_txd_a), .rxd_a(uart_b ? 1'b1 : rxd_a),
	.txd_b(ch_txd_b), .rxd_b(uart_b ? rxd_a : 1'b1));

// the MiSTer UART as NeXT-Color.sv routes it (status[9] = uart_b)
wire ch_txd_a, ch_txd_b;
assign txd_a = uart_b ? ch_txd_b : ch_txd_a;

integer errors = 0;

// byte access at +off (0 ctrl B, 1 ctrl A, 2 data B, 3 data A, 4 clock)
task automatic bus(input bit w, input [2:0] off, input [7:0] d, output [7:0] q);
	reg [1:0] lane;
	begin
		lane = 2'd3 - off[1:0];
		@(posedge clk);
		stb <= 1; we <= w; a2 <= off[2];
		be <= 4'b1 << lane;
		wdata <= {4{d}};
		@(posedge clk);
		stb <= 0; we <= 0;
		@(posedge clk);
		while (!ack) @(posedge clk);
		q = rdata[lane*8 +: 8];
		// the 68040 bus never strobes back to back
		repeat (3) @(posedge clk);
	end
endtask

task automatic wr(input [2:0] off, input [7:0] d);
	reg [7:0] q;
	bus(1, off, d, q);
endtask

task automatic rd(input [2:0] off, output [7:0] q);
	bus(0, off, 8'h00, q);
endtask

task automatic delay_us(input integer us);
	repeat (us * (CLK_HZ / 1000000)) @(posedge clk);
endtask

// RR0 poll as the ROM does: clr.b ctrl (pointer 0), read, mask
task automatic poll_rr0(input [2:0] ctrl, input [7:0] mask, input integer tries, output bit ok);
	reg [7:0] q;
	integer i;
	begin
		ok = 0;
		for (i = 0; i < tries && !ok; i = i + 1) begin
			delay_us(9);
			wr(ctrl, 8'h00);
			delay_us(9);
			rd(ctrl, q);
			if (q & mask) ok = 1;
		end
	end
endtask

reg [7:0] tbl [0:19];
initial begin
	tbl[0]=8'h04; tbl[1]=8'h44; tbl[2]=8'h0b; tbl[3]=8'h50; tbl[4]=8'h0e;
	tbl[5]=8'h10; tbl[6]=8'h0c; tbl[7]=8'h0a; tbl[8]=8'h0d; tbl[9]=8'h00;
	tbl[10]=8'h0e; tbl[11]=8'h11; tbl[12]=8'h0a; tbl[13]=8'h00; tbl[14]=8'h03;
	tbl[15]=8'hc1; tbl[16]=8'h05; tbl[17]=8'hea; tbl[18]=8'h0f; tbl[19]=8'h00;
end

task automatic post_channel(input [2:0] ctrl, input [2:0] data, input integer code_base);
	reg [7:0] q;
	bit ok;
	begin
		rd(ctrl, q);
		poll_rr0(ctrl, 8'h04, 5000, ok);
		if (!ok) begin $display("FAIL POST ch%s: TX buffer never empty", ctrl[0] ? "A" : "B"); errors++; end
		wr(data, 8'h40);
		poll_rr0(ctrl, 8'h01, 5000, ok);
		if (!ok) begin $display("FAIL POST ch%s: RX char never available", ctrl[0] ? "A" : "B"); errors++; end
		rd(data, q);
		if (q !== 8'h40) begin $display("FAIL POST ch%s: read back %02x, want 40", ctrl[0] ? "A" : "B", q); errors++; end
		else $display("ok   POST ch%s loopback $40 at %0t", ctrl[0] ? "A" : "B", $time);
	end
endtask

// measure one character on txd_a: start bit falling edge to stop bit
task automatic expect_tx(input [7:0] c, input real baud);
	real t0, t1, bit_ns;
	reg [7:0] got;
	integer i;
	begin
		bit_ns = 1.0e9 / baud;
		@(negedge txd_a);
		t0 = $realtime;
		#(bit_ns * 1.5);
		for (i = 0; i < 8; i = i + 1) begin
			got[i] = txd_a;
			#(bit_ns);
		end
		if (txd_a !== 1'b1) begin $display("FAIL TX: no stop bit"); errors++; end
		if (got !== c) begin $display("FAIL TX: got %02x want %02x", got, c); errors++; end
		else $display("ok   TX on UART $%02x at %0.0f baud", got, baud);
	end
endtask

task automatic send_rx(input [7:0] c, input real baud);
	real bit_ns;
	integer i;
	begin
		bit_ns = 1.0e9 / baud;
		rxd_a = 0; #(bit_ns);
		for (i = 0; i < 8; i = i + 1) begin rxd_a = c[i]; #(bit_ns); end
		rxd_a = 1; #(bit_ns * 2);
	end
endtask

reg [7:0] q;
integer i;
initial begin
	repeat (20) @(posedge clk);
	reset = 0;
	repeat (20) @(posedge clk);

	// --- 1. post_scc_test ---------------------------------------------
	rd(3'd1, q);
	delay_us(9); wr(3'd1, 8'h09);
	delay_us(9); wr(3'd1, 8'hca);
	delay_us(10);                              // the force-reset stretch
	for (i = 0; i < 20; i = i + 1) begin delay_us(9); wr(3'd1, tbl[i]); end
	delay_us(9); rd(3'd0, q);
	for (i = 0; i < 20; i = i + 1) begin delay_us(9); wr(3'd0, tbl[i]); end
	delay_us(9); rd(3'd1, q);
	post_channel(3'd1, 3'd3, 1);
	post_channel(3'd0, 3'd2, 5);

	// --- 2. scc_init_channel A, 9600 8N1 x16, BRG from PCLK ------------
	// TC = 3686400 / (2 * 16 * 9600) - 2 = 10
	wr(3'd4, 8'h0a);                           // clock select (scc_calc_baud_tc)
	wr(3'd1, 8'h09); wr(3'd1, 8'hc0);          // WR9 hardware reset
	delay_us(10);
	wr(3'd1, 8'h09); wr(3'd1, 8'h02);
	wr(3'd1, 8'h0b); wr(3'd1, 8'h50);
	wr(3'd1, 8'h30); wr(3'd1, 8'h10);
	wr(3'd1, 8'h04); wr(3'd1, 8'h44);
	wr(3'd1, 8'h03); wr(3'd1, 8'hc0);
	wr(3'd1, 8'h05); wr(3'd1, 8'h60);
	wr(3'd1, 8'h0e); wr(3'd1, 8'h02);          // BRG source PCLK
	wr(3'd1, 8'h0c); wr(3'd1, 8'h0a);
	wr(3'd1, 8'h0d); wr(3'd1, 8'h00);
	wr(3'd1, 8'h0e); wr(3'd1, 8'h03);          // + BRG enable
	wr(3'd1, 8'h03); wr(3'd1, 8'hc1);
	wr(3'd1, 8'h05); wr(3'd1, 8'hea);
	fork
		expect_tx(8'h4e, 9600.0);
		wr(3'd3, 8'h4e);
	join
	// WR5 TxEnable dropped mid-character (zsparam): the character completes
	fork
		expect_tx(8'hb5, 9600.0);
		begin
			wr(3'd3, 8'hb5);
			delay_us(450);                     // ~4 bits in
			wr(3'd1, 8'h05); wr(3'd1, 8'h60);  // TxEnable off
			delay_us(3000);
			wr(3'd1, 8'h05); wr(3'd1, 8'hea);  // back on
		end
	join

	// --- 3. RX from the UART, interrupt -------------------------------
	wr(3'd1, 8'h01); wr(3'd1, 8'h10);          // WR1 RX int on all chars
	wr(3'd1, 8'h09); wr(3'd1, 8'h0a);          // WR9 MIE | NV (via channel A)
	if (irq) begin $display("FAIL INT: asserted before RX"); errors++; end
	send_rx(8'h5a, 9600.0);
	delay_us(20);
	if (!irq) begin $display("FAIL INT: INT_SCC not raised by RX"); errors++; end
	else $display("ok   INT_SCC on RX");
	wr(3'd1, 8'h00); rd(3'd1, q);
	if (!(q & 8'h01)) begin $display("FAIL RX: RR0 RX available clear"); errors++; end
	rd(3'd3, q);
	if (q !== 8'h5a) begin $display("FAIL RX: got %02x want 5a", q); errors++; end
	else $display("ok   RX ch A $5a");
	delay_us(5);
	if (irq) begin $display("FAIL INT: still asserted after the RX FIFO drained"); errors++; end

	// WR9 through channel B (shared register): MIE off
	wr(3'd0, 8'h09); wr(3'd0, 8'h00);
	send_rx(8'h33, 9600.0);
	delay_us(20);
	if (irq) begin $display("FAIL INT: WR9 written via channel B did not clear MIE"); errors++; end
	else $display("ok   WR9 shared through channel B");

	// --- 4. MIDI (NeXTSTEP mididriver deviceInit + kernel _zsintsetup/_zs_tc):
	// clock select $30 = PCLK 10 MHz, BRG from PCLK (WR14 $02|1), TC 8, x16
	// -> 10e6 / (2 * 16 * (8 + 2)) = 31250 baud; on channel A, then channel B
	// with uart_b (MIDI unit 1).  Measured on hardware with PCLK left at
	// 3.6864 MHz: 11520 baud, "UART break" on the MT32-pi.
	wr(3'd4, 8'h30);
	wr(3'd1, 8'h09); wr(3'd1, 8'hc0); delay_us(10);
	for (i = 0; i < 2; i = i + 1) begin : midi_ch
		reg [2:0] c, d;
		c = i ? 3'd0 : 3'd1;                   // ctrl B / ctrl A
		d = i ? 3'd2 : 3'd3;                   // data B / data A
		uart_b = (i == 1);
		wr(c, 8'h0b); wr(c, 8'h50);
		wr(c, 8'h04); wr(c, 8'h44);
		wr(c, 8'h03); wr(c, 8'hc0);
		wr(c, 8'h05); wr(c, 8'he2);
		wr(c, 8'h0e); wr(c, 8'h00);
		wr(c, 8'h0c); wr(c, 8'h08);
		wr(c, 8'h0d); wr(c, 8'h00);
		wr(c, 8'h0e); wr(c, 8'h02);
		wr(c, 8'h0e); wr(c, 8'h03);
		wr(c, 8'h03); wr(c, 8'hc1);
		wr(c, 8'h05); wr(c, 8'h6a);
		fork
			expect_tx(i ? 8'h91 : 8'h90, 31250.0);
			wr(d, i ? 8'h91 : 8'h90);
		join
		// and a MIDI byte in on the same port
		fork
			send_rx(8'h3c, 31250.0);
		join
		delay_us(100);
		wr(c, 8'h00); rd(c, q);
		if (!q[0]) begin $display("FAIL MIDI ch%s: no RX", i ? "B" : "A"); errors++; end
		rd(d, q);
		if (q !== 8'h3c) begin $display("FAIL MIDI ch%s RX: got %02x want 3c", i ? "B" : "A", q); errors++; end
		else $display("ok   MIDI ch%s RX $3c at 31250 baud", i ? "B" : "A");
	end
	uart_b = 0;

	// --- 5. the login console under the same clock select: _zs_tc takes
	// RTxC 3.6864 MHz for 9600 (TC 10, WR14 $00|1) -- RTxC must stay put.
	wr(3'd1, 8'h09); wr(3'd1, 8'h80); delay_us(10);  // channel A reset
	wr(3'd1, 8'h0b); wr(3'd1, 8'h50);
	wr(3'd1, 8'h04); wr(3'd1, 8'h44);
	wr(3'd1, 8'h03); wr(3'd1, 8'hc0);
	wr(3'd1, 8'h05); wr(3'd1, 8'he2);
	wr(3'd1, 8'h0e); wr(3'd1, 8'h00);
	wr(3'd1, 8'h0c); wr(3'd1, 8'h0a);
	wr(3'd1, 8'h0d); wr(3'd1, 8'h00);
	wr(3'd1, 8'h0e); wr(3'd1, 8'h01);
	wr(3'd1, 8'h03); wr(3'd1, 8'hc1);
	wr(3'd1, 8'h05); wr(3'd1, 8'h6a);
	fork
		expect_tx(8'h6c, 9600.0);
		wr(3'd3, 8'h6c);
	join

	if (errors == 0) $display("PASS tb_tc_scc");
	else $display("FAIL tb_tc_scc: %0d error(s)", errors);
	$finish;
end

initial begin
	#200ms;
	$display("FAIL tb_tc_scc: timeout");
	$finish;
end

endmodule
