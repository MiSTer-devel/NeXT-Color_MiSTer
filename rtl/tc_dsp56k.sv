//============================================================================
//  tc_dsp56k -- the NeXTstation Turbo Color's DSP56001 in the FPGA: the
//  68040's host port at $02008000..$02008007 (Previous r1851
//  ioMemTabTurbo.c:130-137, mask $1E007), the DSP DMA channel, SCR2's DSP
//  bits and the DSP itself (rtl/dsp56k: the Falcon_MiSTer DSP56001 core,
//  apolkosnik/Falcon_MiSTer rtl/falcon/dsp, with the NeXT memory map, IRQB
//  and start modes, and next_dsp_periph for the NeXT host bus).
//
//  One DSP clock per clk, 2 per instruction cycle: 12.5 MIPS at 25 MHz, a
//  real 25 MHz 56001.  (NEXT_DSP_ARM in the qsf selects rtl/tc_dsp.sv, the
//  DSP on the ARM, instead.)
//
//  "dsp.c:n" / "dsp_core.c:n" / "sysReg.c:n" = Previous r1851 src/dsp and src.
//
//  Host port registers (byte addresses; addr2 = longword, big-endian lanes):
//    $8000 ICR CVR ISR IVR, $8004 TRX0 RXH/TXH RXM/TXM RXL/TXL -- the
//  56001's host interface exactly (next_dsp_periph).
//
//  SCR2 (tc_scr scr2_out; sysReg.c:363-395, 405-415, 489-503):
//    bit 31 DSP_RESET: 0 -> 1 starts the DSP in mode {~bit 28, ~bit 27}
//           (DSP_Start), 1 -> 0 resets it (DSP_Reset); the DSP core is held
//           while it is 0, the host port only reset at the 1 -> 0 edge
//    bit 30 DSP_BLK_END: DMA block end raises the DSP's IRQB (DSP_SetIRQB)
//    bit 29 DSP_UNPKD: Turbo unpacked DMA, 4 bytes per word (dsp.c:146-148)
//    bit 23 DSP_TXD_EN: the DSP's port C bit 1 (TXD) low interrupts
//    bit  5 DSP_MEM_EN: the DSP's external memory (8K words, DSP_EnableMemory)
//  Interrupt (scr_check_dsp_interrupt, sysReg.c:527-535): int_dsp = HREQ in
//  interrupt mode, or TXD low with DSP_TXD_EN -> status bit 14 INT_DSP_L4.
//
//  DMA (dsp.c DSP_HandleDMA:139-172): with HM != 0 and a request, one byte
//  per request through the PC chip's DSP channel (tc_tdma dd_*): the byte
//  counter starts at 4 - HM (24-bit: H M L; 16-bit: M L; 8-bit: L) or 4
//  when unpacked (pad, H, M, L), and each byte goes to / comes from
//  register TRXL - counter.  A request moves a byte in the channel's
//  direction only: to the DSP on TXDE, from it on RXDF (with TREQ and RREQ
//  both set Previous also moves stale RX words).
//
//  No SSI / SCI connector: the SSI slot link is tied off.
//
//  Device port contract (tc_machine): stb 1-cycle, ack 1 clock later.
//============================================================================

module tc_dsp56k #(
	parameter CLK_HZ = 28500000
)(
	input             clk,
	input             reset,
	// device port: $02008000 + {addr2, 2'b00}
	input             stb,
	input             we,
	input             addr2,
	input       [3:0] be,
	input      [31:0] wdata,
	output reg [31:0] rdata,
	output reg        ack,
	// SCR2 (tc_scr scr2_out)
	input      [31:0] scr2,
	// -> interrupt status bit 14 (INT_DSP_L4)
	output            int_dsp,
	// the PC chip's DSP DMA channel (tc_tdma dd_*)
	output reg        dd_req,       // level until dd_ack
	output reg        dd_we,        // 1 = a byte to memory (DSP -> host)
	output reg  [7:0] dd_wdata,
	input             dd_ack,
	input       [7:0] dd_rdata,
	input             dd_avail,     // ENABLE and Next < Limit
	input             dd_blkend     // pulse: the channel reached Limit
);

// SCR2's DSP bits
wire       dsp_run  = scr2[31];
wire       blk_end  = scr2[30];
wire       unpacked = scr2[29];
wire [1:0] dsp_mode = {~scr2[28], ~scr2[27]};
wire       txd_en   = scr2[23];
wire       mem_en   = scr2[5];
/* verilator lint_off UNUSEDSIGNAL */
wire [24:0] unused_scr2 = {scr2[26:24], scr2[22:6], scr2[4:0]};
/* verilator lint_on UNUSEDSIGNAL */

// DSP_RESET 1 -> 0: DSP_Reset (the host port too); the core is held while 0
reg dsp_run_d;
always @(posedge clk) dsp_run_d <= reset ? 1'b0 : dsp_run;
wire per_rst  = reset || (dsp_run_d && !dsp_run);
wire core_rst = reset || !dsp_run;

//----------------------------------------------------------------------------
// the DSP
//----------------------------------------------------------------------------

wire        running, run_start, run_direct, boot_we;
wire  [9:0] boot_pos;
wire  [8:0] boot_addr;
wire [23:0] boot_data;
wire        perx_rd, perx_wr, pery_rd, pery_wr;
wire  [5:0] perx_addr, pery_addr;
wire [23:0] perx_wdata, perx_rdata, pery_wdata, pery_rdata;
wire        soft_reset, hc_ack;
wire        int_host_rcv, int_host_trx, int_host_cmd, int_ssi_rcv, int_ssi_trx;
wire        msk_host_rcv, msk_host_trx, msk_host_cmd, msk_ssi_rcv, msk_ssi_trx;
wire [23:0] ipr;
wire  [4:0] hc_vector;
wire        irqb = dd_blkend && blk_end;              // DSP_SetIRQB
/* verilator lint_off UNUSEDSIGNAL */
wire        retire;
/* verilator lint_on UNUSEDSIGNAL */

dsp56k_core u_core (
	.clk(clk), .rst(core_rst),
	.run(running), .run_start(run_start), .boot_pos(boot_pos),
	.boot_we(boot_we), .boot_addr(boot_addr), .boot_data(boot_data),
	.start_direct(run_direct), .start_mode(dsp_mode), .mem_en(mem_en), .irqb(irqb),
	.perx_rd(perx_rd), .perx_wr(perx_wr), .perx_addr(perx_addr),
	.perx_wdata(perx_wdata), .perx_rdata(perx_rdata),
	.pery_rd(pery_rd), .pery_wr(pery_wr), .pery_addr(pery_addr),
	.pery_wdata(pery_wdata), .pery_rdata(pery_rdata),
	.per_soft_reset(soft_reset),
	.int_host_rcv(int_host_rcv), .int_host_trx(int_host_trx), .int_host_cmd(int_host_cmd),
	.int_ssi_rcv(int_ssi_rcv), .int_ssi_trx(int_ssi_trx),
	.msk_host_rcv(msk_host_rcv), .msk_host_trx(msk_host_trx), .msk_host_cmd(msk_host_cmd),
	.msk_ssi_rcv(msk_ssi_rcv), .msk_ssi_trx(msk_ssi_trx),
	.ipr(ipr), .hc_vector(hc_vector), .hc_ack(hc_ack),
	.retire(retire));

wire [31:0] bus_dout;
wire        hreq;
wire  [7:0] dma_dout, icr, isr;
wire  [1:0] dma_mode;
wire        dma_tx, init_pulse, txd_low;
wire        dma_stb, dma_we;
wire  [2:0] dma_addr;
reg   [2:0] dma_addr_q;          // the register of the byte in flight
/* verilator lint_off UNUSEDSIGNAL */
wire  [7:0] ivr;
wire [15:0] ssi_tx_data;
wire        ssi_tx_valid, ssi_hs_play_req;
/* verilator lint_on UNUSEDSIGNAL */

next_dsp_periph u_periph (
	.clk(clk), .rst(per_rst),
	.bus_stb(stb), .bus_we(we), .bus_addr2(addr2), .bus_be(be),
	.bus_din(wdata), .bus_dout(bus_dout), .hreq(hreq), .ivr(ivr),
	.dma_stb(dma_stb), .dma_we(dma_we), .dma_addr(dma_addr), .dma_din(dd_rdata),
	.dma_dout(dma_dout), .dma_mode(dma_mode), .dma_tx(dma_tx), .init_pulse(init_pulse),
	.dsp_run(dsp_run), .start_mode(dsp_mode), .run_direct(run_direct), .txd_low(txd_low),
	.icr_o(icr), .isr_o(isr),
	.running(running), .run_start(run_start), .boot_pos(boot_pos),
	.boot_we(boot_we), .boot_addr(boot_addr), .boot_data(boot_data),
	.perx_rd(perx_rd), .perx_wr(perx_wr), .perx_addr(perx_addr),
	.perx_wdata(perx_wdata), .perx_rdata(perx_rdata),
	.pery_rd(pery_rd), .pery_wr(pery_wr), .pery_addr(pery_addr),
	.pery_wdata(pery_wdata), .pery_rdata(pery_rdata),
	.soft_reset(soft_reset), .hc_ack(hc_ack),
	.int_host_rcv(int_host_rcv), .int_host_trx(int_host_trx), .int_host_cmd(int_host_cmd),
	.int_ssi_rcv(int_ssi_rcv), .int_ssi_trx(int_ssi_trx),
	.msk_host_rcv(msk_host_rcv), .msk_host_trx(msk_host_trx), .msk_host_cmd(msk_host_cmd),
	.msk_ssi_rcv(msk_ssi_rcv), .msk_ssi_trx(msk_ssi_trx),
	.ipr_out(ipr), .hc_vector(hc_vector),
	// no SSI connector: the slot link is idle
	.ssi_slot_stb(1'b0), .ssi_tx_en(1'b0), .ssi_frame(1'b0),
	.ssi_rx_en(1'b0), .ssi_rx_frame(1'b0), .ssi_rx_data(16'd0),
	.ssi_tx_data(ssi_tx_data), .ssi_tx_valid(ssi_tx_valid),
	.ssi_hs_play_req(ssi_hs_play_req));

// DSP_HandleHREQ: the host interrupt only in interrupt (PIO) mode
assign int_dsp = (dma_mode == 2'd0 && hreq) || (txd_en && txd_low);

//----------------------------------------------------------------------------
// CPU access: the register values before this clock's changes
//----------------------------------------------------------------------------

always @(posedge clk) begin
	ack <= stb;
	if (stb) rdata <= bus_dout;
end

//----------------------------------------------------------------------------
// DMA (DSP_HandleDMA)
//----------------------------------------------------------------------------

reg  [2:0] dma_ctr;              // dma_address_counter
wire [2:0] ctr_start = unpacked ? 3'd4 : (3'd4 - {1'b0, dma_mode});
wire [2:0] ctr_use   = ((dma_ctr == 3'd0) ? ctr_start : dma_ctr) - 3'd1;
wire [2:0] ctr_reg   = 3'd7 - ctr_use;                // TRXL - counter (TRX0 for 3)
wire       dma_rq    = dma_tx ? (icr[1] && isr[1]) : (icr[0] && isr[0]);
wire       dma_go    = (dma_mode != 2'd0) && dma_rq && dd_avail && !dd_req && !stb;
// the host port byte access of this clock: a byte from the DSP is read when
// requested, a byte to the DSP written when the channel delivers it
wire       dma_rd_now = dma_go && !dma_tx;
wire       dma_wr_now = dd_req && dd_ack && !dd_we;
assign dma_stb  = dma_rd_now || dma_wr_now;
assign dma_we   = dma_wr_now;
assign dma_addr = dma_rd_now ? ctr_reg : dma_addr_q;

always @(posedge clk) begin
	if (per_rst) begin
		dd_req <= 1'b0; dd_we <= 1'b0; dd_wdata <= 8'd0;
		dma_ctr <= 3'd0; dma_addr_q <= 3'd0;
	end
	else begin
		if (dd_req && dd_ack)
			dd_req <= 1'b0;
		else if (dma_go) begin
			dd_req     <= 1'b1;
			dd_we      <= !dma_tx;
			dma_ctr    <= ctr_use;
			dma_addr_q <= ctr_reg;
			if (!dma_tx) dd_wdata <= dma_dout;
		end
		// INIT: the counter restarts (dsp_core.c:1179-1192); a TX-side INIT
		// drops a byte not yet delivered (tc_dsp.sv)
		if (init_pulse) begin
			dma_ctr <= 3'd0;
			if (icr[1] && dd_req && !dd_we && !dd_ack) dd_req <= 1'b0;
		end
	end
end

endmodule
