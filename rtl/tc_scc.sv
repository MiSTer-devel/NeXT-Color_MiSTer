//============================================================================
//  tc_scc -- Z8530 SCC at $02018000 ($02118000 alias).
//
//  The chip is rtl/z8530_scc.sv (from Apple-Lisa_MiSTer: both channels,
//  async mode, BRG, x1/16/32/64 clocking, local loopback, 4-byte FIFOs,
//  interrupts and vectors), on the tc_machine device port, plus the Turbo's
//  serial clock select register:
//
//    +0 control B   +1 control A   +2 data B   +3 data A   (bytes)
//    +4 clock select (long; the ROM writes $0A, scc_calc_baud_tc $01008b30,
//       hardware-summary 11.1; Previous SCC_Clock_Read/Write: read back)
//
//  Byte lanes (big-endian be): +0 = be[3] = [31:24], +1 = be[2], +2 = be[1],
//  +3 = be[0].  The ROM uses byte accesses; with several lanes the lowest
//  address wins.
//
//  Clocks (the byte at +4, lane 3; Previous scc.c scc_clock_write):
//    PCLK   bits 5:4 (Turbo "system clock"): 0 = 3.6864, 1/2 = 4, 3 = 10 MHz
//           (WR14[1] = 1 takes the BRG from here)
//    RTxC   bit 1 (SCLKA_4_MHZ) / bit 3 (SCLKB_4_MHZ): channel A / B 4 MHz,
//           else 3.6864 MHz (the ROM's scc_calc_baud_tc writes $0A)
//  NeXTSTEP 3.3's _zsintsetup ($0401a448) writes $30 on a Turbo; its _zs_tc
//  ($04099b24) then weighs PCLK = 10 MHz (returned with bit 17, WR14 PCLK)
//  against RTxC = 3.684 MHz and keeps the closer: MIDI's 31250 baud is PCLK
//  TC 8, 9600 is RTxC TC 10.  (On the 68030 machines, type $139, it writes
//  $0A and weighs PCLK 3.684 against RTxC 4 MHz.)
//  all as clk strobes from phase accumulators.  Clearing clksel bit 7 after
//  it was set is a hard reset of the chip (Previous scc_clock_write, Turbo).
//
//  The ROM POST (post_scc_test $010048a6) runs both channels in local
//  loopback (WR14 $11, x16, TC $0A, RTxC) and polls up to ~5000 x 18 us per
//  step, so a real-timed character (~1 ms) passes.
//
//  Serial: both channels' TxD/RxD come out (port A = NeXTSTEP's ttya, the
//  alternate console, MIDI unit 0; port B = ttyb, MIDI unit 1); the top
//  routes them to the MiSTer UART and the MT32-pi.  CTS/DCD are held
//  asserted so the auto enables never gate the channels.  No SCC DMA
//  (INT_SCC_DMA).
//
//  Device port contract (tc_machine): stb 1-cycle, ack 1-cycle later.  A
//  read presents RD for the stb cycle and latches the byte; the chip pops
//  its RX FIFO on the falling edge of RD, the cycle after.
//============================================================================

module tc_scc
#(
	parameter CLK_HZ = 33000000
)
(
	input             clk,
	input             reset,

	input             stb,
	input             we,
	input             a2,            // 1 = clock select register (+4)
	input       [3:0] be,
	input      [31:0] wdata,
	output reg [31:0] rdata,
	output reg        ack,

	output            irq,           // INT_SCC

	output            txd_a,         // serial port A
	input             rxd_a,
	output            txd_b,         // serial port B
	input             rxd_b
);

reg [31:0] clksel;

// the register this access addresses: 0 ctrl B, 1 ctrl A, 2 data B, 3 data A
wire [1:0] reg_i = be[3] ? 2'd0 : be[2] ? 2'd1 : be[1] ? 2'd2 : 2'd3;
wire [7:0] wb    = (reg_i == 2'd0) ? wdata[31:24] : (reg_i == 2'd1) ? wdata[23:16] :
                   (reg_i == 2'd2) ? wdata[15:8]  : wdata[7:0];

wire       chip = stb && !a2;
wire [7:0] scc_dout;

//---------------------------------------------------------------------------
// Serial clock strobes
//---------------------------------------------------------------------------
localparam [25:0] HZ_3684 = 26'd3686400;
localparam [25:0] HZ_4000 = 26'd4000000;
localparam [25:0] HZ_10M  = 26'd10000000;
localparam [25:0] HZ_CLK  = CLK_HZ;

reg [25:0] acc_3684 = 0, acc_4000 = 0, acc_10m = 0;
reg        en_3684, en_4000, en_10m;
always @(posedge clk) begin
	en_3684 <= 0;
	en_4000 <= 0;
	en_10m  <= 0;
	if (acc_3684 + HZ_3684 >= HZ_CLK) begin acc_3684 <= acc_3684 + HZ_3684 - HZ_CLK; en_3684 <= 1; end
	else acc_3684 <= acc_3684 + HZ_3684;
	if (acc_4000 + HZ_4000 >= HZ_CLK) begin acc_4000 <= acc_4000 + HZ_4000 - HZ_CLK; en_4000 <= 1; end
	else acc_4000 <= acc_4000 + HZ_4000;
	if (acc_10m + HZ_10M >= HZ_CLK) begin acc_10m <= acc_10m + HZ_10M - HZ_CLK; en_10m <= 1; end
	else acc_10m <= acc_10m + HZ_10M;
end

// the register is the byte at +4: lane 3
wire [7:0] clkb = clksel[31:24];
wire pclk_en  = (clkb[5:4] == 2'd3) ? en_10m  :
                (clkb[5:4] != 2'd0) ? en_4000 : en_3684;
wire rtxca_en = clkb[1] ? en_4000 : en_3684;
wire rtxcb_en = clkb[3] ? en_4000 : en_3684;

//---------------------------------------------------------------------------
// Reset: the machine reset, or clksel bit 7 going 1 -> 0
//---------------------------------------------------------------------------
reg clk_rst;
reg scc_rst_n;
always @(posedge clk) begin
	clk_rst   <= stb && a2 && we && be[3] && clkb[7] && !wdata[31];
	scc_rst_n <= !(reset || clk_rst);
end

//---------------------------------------------------------------------------
// Bus
//---------------------------------------------------------------------------
always @(posedge clk) begin
	ack <= 0;
	if (reset) begin
		clksel <= 0;
		rdata  <= 0;
	end
	else if (stb) begin
		ack <= 1;
		if (a2) begin
			rdata <= clksel;
			if (we) begin
				if (be[3]) clksel[31:24] <= wdata[31:24];
				if (be[2]) clksel[23:16] <= wdata[23:16];
				if (be[1]) clksel[15:8]  <= wdata[15:8];
				if (be[0]) clksel[7:0]   <= wdata[7:0];
			end
		end
		else rdata <= {4{scc_dout}};
	end
end

//---------------------------------------------------------------------------
// The chip
//---------------------------------------------------------------------------
wire int_n;
assign irq = !int_n;


z8530_scc #(
	.SOFT_RESET_EN(1),
	.RR8_CTRL_POP(1),
	.UNIPLUS_BAUD_PATCH_B(0),
	.AUTO_ENABLES_EN(1),
	.RTXC_XTAL_FULLRATE_A(1),
	.RTXC_XTAL_FULLRATE_B(1),
	.BRG_SRC_RUNTIME(1),
	.SHARED_WR2_WR9_B(1),
	.IP_DATASHEET(1),
	.TX_DATASHEET(1)
) scc (
	.clk(clk), .pclk(clk), .sclk(clk),
	.pclk_en(pclk_en), .sclk_en(pclk_en),
	.rtxca_en(rtxca_en), .rtxcb_en(rtxcb_en),
	.reset_n(scc_rst_n),

	.cs_n(!chip), .rd_n(!(chip && !we)), .wr_n(!(chip && we)),
	.a_b(reg_i[0]), .d_c(reg_i[1]),
	.data_in(wb), .data_out(scc_dout), .data_oe(),

	.int_n(int_n), .intack_n(1'b1),

	.rxca(1'b0), .txca(1'b0), .rxda(rxd_a), .txda(txd_a),
	.ctsa_n(1'b0), .dcda_n(1'b0), .synca_n(1'b1), .rtsa_n(), .dtra_n(),

	.rxcb(1'b0), .txcb(1'b0), .rxdb(rxd_b), .txdb(txd_b),
	.ctsb_n(1'b0), .dcdb_n(1'b0), .syncb_n(1'b1), .rtsb_n(), .dtrb_n()
);

endmodule
