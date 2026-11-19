//============================================================================
//  tb_next_enet_bridge -- self-checking unit test of rtl/next_enet_bridge.sv
//  (Verilator --timing): the mailbox the core publishes for Main's
//  next_enet daemon (support/next/next_enet.cpp).
//
//  Checks, for every OSD "Network interface" value through the same mapping
//  as NeXT-Color.sv (eth0, None, eth1, macvlan, tap0 -> NB_MODE_ 1, 0, 2, 3,
//  4):
//  - the init order after reset: MAGIC = 0 first, then TX_WPTR, RX_WPTR,
//    RX_RPTR, GUEST_MAC, NET_MODE ({valid, mode} at +0x28) and MAGIC =
//    "NXTETH02" last, so Main never sees the new magic with a stale mode;
//  - None (enable low): the mailbox is cleared, no NET_MODE and no MAGIC;
//  - a transmit with None completes at once (the MAC does not wedge).
//
//  Prints "PASS: ..." or "FAIL: ..." and exits non-zero on failure.
//  Run: bash verilator/unit/run_tb_next_enet_bridge.sh
//============================================================================
`timescale 1ns/1ps

module tb_next_enet_bridge;

localparam [28:0] BASE   = 29'h03FE0000;
localparam [63:0] MAGIC2 = 64'h4E58544554483032;   // "NXTETH02"
localparam [47:0] MAC    = 48'h00000F123456;

logic        clk = 1'b0;
always #5 clk = ~clk;

logic        reset = 1'b1;
logic        enable = 1'b0;
logic  [2:0] net_mode = 3'd0;
logic        btx_req = 1'b0;
logic [10:0] btx_len = 11'd0;
wire  [10:0] btx_addr;
wire         btx_rd, btx_done;
logic  [7:0] btx_q = 8'd0;
logic        btx_ack = 1'b0;
wire         brx_start, brx_valid;
wire  [10:0] brx_len;
wire   [7:0] brx_data;
logic        brx_ready = 1'b1;
wire         m_req, m_we;
wire  [28:0] m_addr;
wire  [63:0] m_wdata;
logic [63:0] m_rdata = 64'd0;
logic        m_ack = 1'b0;

next_enet_bridge #(.CLK_HZ(10000000)) dut (
	.clk(clk), .reset(reset), .enable(enable), .net_mode(net_mode),
	.btx_req(btx_req), .btx_len(btx_len), .btx_addr(btx_addr), .btx_rd(btx_rd),
	.btx_q(btx_q), .btx_ack(btx_ack), .btx_done(btx_done),
	.brx_start(brx_start), .brx_len(brx_len), .brx_valid(brx_valid),
	.brx_data(brx_data), .brx_ready(brx_ready),
	.guest_mac(MAC),
	.m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata),
	.m_rdata(m_rdata), .m_ack(m_ack)
);

// the mailbox: word offsets 0..5, and the order of the writes
logic [63:0] mb [0:5];
int          wlog [$];
always @(posedge clk) begin
	m_ack <= 1'b0;
	if (m_req && !m_ack) begin
		m_ack <= 1'b1;
		if (m_we) begin
			if (m_addr >= BASE && m_addr < BASE + 29'd6) begin
				mb[m_addr - BASE] <= m_wdata;
				wlog.push_back(int'(m_addr - BASE));
			end
		end
		else m_rdata <= (m_addr >= BASE && m_addr < BASE + 29'd6) ? mb[m_addr - BASE] : 64'd0;
	end
end

int checks = 0, errors = 0;
task automatic check(input bit cond, input string msg);
	checks++;
	if (!cond) begin
		errors++;
		$display("FAIL: %s", msg);
	end
endtask

// NeXT-Color.sv's mapping
function automatic [2:0] osd_to_mode(input [2:0] osd);
	case (osd)
		3'd0: osd_to_mode = 3'd1;
		3'd2: osd_to_mode = 3'd2;
		3'd3: osd_to_mode = 3'd3;
		3'd4: osd_to_mode = 3'd4;
		default: osd_to_mode = 3'd0;
	endcase
endfunction

task automatic run_reset(input [2:0] osd);
	int i;
	@(negedge clk);
	reset = 1'b1;
	net_mode = osd_to_mode(osd);
	enable = (net_mode != 3'd0);
	for (i = 0; i < 6; i++) mb[i] = 64'hDEAD_BEEF_DEAD_BEEF;   // a previous core's leftovers
	wlog.delete();
	repeat (3) @(negedge clk);
	reset = 1'b0;
	repeat (200) @(negedge clk);
endtask

initial begin : watchdog
	#5ms;
	$display("FAIL: tb_next_enet_bridge timed out");
	$fatal(1, "timeout");
end

initial begin : test
	int osd, i, nd;
	string order;
	int exp_on  [$] = '{0, 1, 2, 3, 4, 5, 0};
	int exp_off [$] = '{0, 1, 2, 3, 4};

	for (osd = 0; osd < 5; osd++) begin
		run_reset(3'(osd));
		order = "";
		foreach (wlog[i]) order = {order, $sformatf(" %0d", wlog[i])};
		if (osd == 1) begin
			check(wlog == exp_off, $sformatf("None: writes%s (want 0 1 2 3 4)", order));
			check(mb[0] == 64'd0, $sformatf("None: MAGIC %016x, want 0", mb[0]));
			check(mb[5] == 64'hDEAD_BEEF_DEAD_BEEF, "None: NET_MODE untouched");
		end
		else begin
			check(wlog == exp_on, $sformatf("OSD %0d: writes%s (want 0 1 2 3 4 5 0)", osd, order));
			check(mb[0] == MAGIC2, $sformatf("OSD %0d: MAGIC %016x", osd, mb[0]));
			check(mb[5] == {1'b1, 60'd0, osd_to_mode(3'(osd))},
			      $sformatf("OSD %0d: NET_MODE %016x", osd, mb[5]));
			check(mb[4] == {1'b1, 15'd0, MAC}, $sformatf("OSD %0d: GUEST_MAC %016x", osd, mb[4]));
			check(mb[1] == 0 && mb[2] == 0 && mb[3] == 0, $sformatf("OSD %0d: ring pointers cleared", osd));
		end
	end
	check(osd_to_mode(3'd0) == 3'd1 && osd_to_mode(3'd1) == 3'd0 && osd_to_mode(3'd2) == 3'd2 &&
	      osd_to_mode(3'd3) == 3'd3 && osd_to_mode(3'd4) == 3'd4, "OSD -> NB_MODE_ mapping");

	// None: a guest transmit is completed at once (a disconnected wire)
	run_reset(3'd1);
	nd = 0;
	@(negedge clk); btx_len = 11'd60; btx_req = 1'b1;
	for (i = 0; i < 20; i++) begin
		@(negedge clk);
		if (btx_done) nd++;
	end
	btx_req = 1'b0;
	check(nd == 1, $sformatf("None: a transmit completes once (%0d)", nd));

	if (errors == 0)
		$display("PASS: tb_next_enet_bridge (%0d checks)", checks);
	else
		$display("FAIL: tb_next_enet_bridge (%0d of %0d checks failed)", errors, checks);
	if (errors != 0) $fatal(1, "tb_next_enet_bridge failed");
	$finish;
end

endmodule
