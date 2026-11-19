// Unit test of rtl/tc_scc.sv + rtl/z8530_scc.sv against the NeXTSTEP 3.3
// kernel's zs driver, as disassembled from /sdmach: _zsint ($0409af94) loops
// reading RR3 until 0; the RX handler ($04099bfc) reads RR1 + data while RR0
// RX-available; the TX handler ($0409a436) writes data while RR0 TBE and
// issues Reset Tx IP only when its queue is empty.  Channel A at 9600 with
// WR1 $13, full duplex, 60 bytes each way.  Fails if the ISR is busy more
// than 20% of the time (the model without IP_DATASHEET spins ~85%).
`timescale 1ns/1ps
module tb_tc_scc_zs;

localparam CLK_HZ = 33000000;

reg clk = 0;
always #15.151 clk = !clk;       // 33 MHz

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
	repeat (us * 33) @(posedge clk);
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

localparam NB = 60;
integer nt = 0, nr = 0, isr_n = 0, rr3_polls = 0;
real isr_t = 0, t_start = 0;
initial t_start = 0;

task automatic tx_handler;            // 0409a436
	reg [7:0] r0;
	begin
		delay_us(1);
		wr(3'd1, 8'h00); rd(3'd1, r0);
		while (r0[2]) begin
			if (nt >= NB) begin delay_us(1); wr(3'd1, 8'h28); r0 = 0; end
			else begin
				delay_us(1); wr(3'd3, 8'h41 + (nt % 26)); nt = nt + 1; delay_us(1);
				wr(3'd1, 8'h00); rd(3'd1, r0);
			end
		end
	end
endtask

task automatic rx_handler;            // 04099bfc
	reg [7:0] r0, r1, d;
	begin
		do begin
			delay_us(1); wr(3'd1, 8'h01); delay_us(1); rd(3'd1, r1);
			delay_us(1); rd(3'd3, d);
			if (d !== 8'h30 + (nr % 64)) begin $display("FAIL zs RX #%0d got %02x want %02x", nr, d, 8'h30 + (nr % 64)); errors++; end
			nr = nr + 1;
			if (r1[4]) wr(3'd1, 8'h30);
			delay_us(1); wr(3'd1, 8'h00); rd(3'd1, r0);
		end while (r0[0]);
	end
endtask

task automatic zsint;                 // 0409af94
	reg [7:0] r3;
	real t0;
	begin
		isr_n = isr_n + 1; t0 = $realtime;
		forever begin
			delay_us(1); wr(3'd1, 8'h03); delay_us(1); rd(3'd1, r3);
			rr3_polls = rr3_polls + 1;
			if (r3 == 0) break;
			if (r3[5]) rx_handler();
			if (r3[4]) tx_handler();
			if (rr3_polls > 200000) begin $display("FAIL zsint never returns"); errors++; $finish; end
		end
		isr_t = isr_t + ($realtime - t0);
	end
endtask

task automatic kick_tx;
	begin t_start = $realtime; tx_handler(); end
endtask

reg [7:0] q;
integer i;
initial begin
	repeat (20) @(posedge clk);
	reset = 0;
	repeat (20) @(posedge clk);

	// --- NeXTSTEP zs driver emulation (kernel 3.3: _zsint, RX/TX handlers) ---
	// channel A 9600 8N1 x16 from PCLK, WR1 $13 (RX all, TxIE, ExtIE), WR9 $0A
	wr(3'd4, 8'h0a);
	wr(3'd1, 8'h09); wr(3'd1, 8'hc0); delay_us(10);
	wr(3'd1, 8'h04); wr(3'd1, 8'h44);
	wr(3'd1, 8'h03); wr(3'd1, 8'hc0);
	wr(3'd1, 8'h05); wr(3'd1, 8'h60);
	wr(3'd1, 8'h0b); wr(3'd1, 8'h50);
	wr(3'd1, 8'h0e); wr(3'd1, 8'h02);
	wr(3'd1, 8'h0c); wr(3'd1, 8'h0a);
	wr(3'd1, 8'h0d); wr(3'd1, 8'h00);
	wr(3'd1, 8'h0e); wr(3'd1, 8'h03);
	wr(3'd1, 8'h03); wr(3'd1, 8'hc1);
	wr(3'd1, 8'h05); wr(3'd1, 8'hea);
	wr(3'd1, 8'h0f); wr(3'd1, 8'h00);
	wr(3'd1, 8'h01); wr(3'd1, 8'h13);
	wr(3'd1, 8'h09); wr(3'd1, 8'h0a);
	fork
		begin : rxsrc
			integer k;
			delay_us(500);
			for (k = 0; k < NB; k = k + 1) send_rx(8'h30 + (k % 64), 9600.0);
		end
		begin : txmon
			integer k;
			for (k = 0; k < NB; k = k + 1) expect_tx(8'h41 + (k % 26), 9600.0);
		end
		begin : drv
			kick_tx();                       // zsstart: first byte from process level
			while (nr < NB || nt < NB) begin
				if (irq) zsint();
				else @(posedge clk);
			end
		end
	join
	$display("zs: tx %0d rx %0d  isr entries %0d  rr3 polls %0d  isr time %0.1f%%",
	         nt, nr, isr_n, rr3_polls, 100.0 * isr_t / ($realtime - t_start));
	if (100.0 * isr_t / ($realtime - t_start) > 20.0) begin $display("FAIL ISR busy > 20%%"); errors++; end
	if (errors == 0) $display("PASS tb_tc_scc_zs");
	else $display("FAIL tb_tc_scc_zs: %0d error(s)", errors);
	$finish;
end

initial begin
	#900ms;
	$display("FAIL tb_tc_scc_zs: timeout");
	$finish;
end

endmodule
