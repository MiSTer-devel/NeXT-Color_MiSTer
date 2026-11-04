// tb_fl.sv - next_ap68040 with SNOOP = 2 (copyback data cache, a line
// flushed before each DMA beat) against a 1 MB RAM, a tc_machine-style
// flush requester and level-4 interrupts.
//
// The program (mkprog.py) loops TRAP #0 -> movea.l -12(a6),a0;
// movea.l 4(a0),a0; jsr (a0).  The bench fails when an instruction
// retires inside the table (the NeXTSTEP panic: the JSR took callp + 4),
// on an exception vector it did not expect, or when the core stalls.
//
//   +seed=N         random seed
//   +cycles=N       run length (default 2M)
//   +flush=N        a flush every ~N clocks (0: none; default 40)
//   +irq=N          a level-4 interrupt every ~N clocks (0: none; default 300)
//   +lat=N          RAM latency 1..N clocks (default 3)
`timescale 1ns/1ps
module tb_fl;

reg clk = 0, nreset = 0;
always #5 clk = ~clk;
// next_ap68040's CPU2X clock: 2 x clk, rising edges aligned with clk's
reg clk_cpu = 1;
always #2.5 clk_cpu = ~clk_cpu;

int unsigned seed = 1, cycles = 2000000, fl_every = 40, irq_every = 300, lat_max = 3;
int unsigned cyc = 0;

reg  [2:0] ipl = 3'b111;
wire       bus_req, bus_write, bus_instr;
wire [1:0] bus_size;
wire [31:0] bus_addr, bus_wdata;
wire [2:0] bus_fc;
reg        bus_ack = 0;
reg [31:0] bus_rdata = 0;

reg        fl_req = 0;
reg [31:4] fl_addr = 0;
wire       fl_done, fl_dirty, fill_stb, sb_pending;
wire [127:0] fl_line;
wire [31:4] fill_line;
wire [31:0] dbg_pc;

next_ap68040 #(.FPU_REVISION(8'h41), .SNOOP(2)) dut (
	.clk(clk), .clk_cpu(clk_cpu), .nreset(nreset), .ipl(ipl), .berr(1'b0),
	.bus_req(bus_req), .bus_write(bus_write), .bus_instr(bus_instr), .bus_size(bus_size),
	.bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_fc(bus_fc), .bus_ack(bus_ack), .bus_rdata(bus_rdata),
	.snoop_stb(1'b0), .snoop_addr(32'd0), .snoop_full(),
	.fl_req(fl_req), .fl_addr(fl_addr), .fl_done(fl_done), .fl_dirty(fl_dirty), .fl_line(fl_line),
	.fill_stb(fill_stb), .fill_line(fill_line), .sb_pending(sb_pending),
	.nresetout(), .cacr_out(), .vbr_out(), .dbg_pc(dbg_pc),
	.debug_fault(), .debug_halted(), .debug_status(), .debug_status2()
);

// ---- RAM: 1 MB, mirrored
reg [7:0] ram [0:(1<<20)-1];
function automatic [31:0] rd32(input [31:0] a);
	rd32 = {ram[{a[19:2], 2'd0}], ram[{a[19:2], 2'd1}], ram[{a[19:2], 2'd2}], ram[{a[19:2], 2'd3}]};
endfunction
task automatic wr32(input [31:0] a, input [31:0] d);
	ram[{a[19:2], 2'd0}] = d[31:24]; ram[{a[19:2], 2'd1}] = d[23:16];
	ram[{a[19:2], 2'd2}] = d[15:8];  ram[{a[19:2], 2'd3}] = d[7:0];
endtask

int unsigned bcnt = 0;
reg          bbusy = 0;
int unsigned n_irq = 0, n_fl = 0, n_fld = 0, n_dma = 0, n_trap = 0;

always @(posedge clk) begin
	bus_ack <= 1'b0;
	if (!nreset) bbusy <= 1'b0;
	else if (bbusy) begin
		if (bcnt <= 1) begin
			bbusy   <= 1'b0;
			bus_ack <= 1'b1;
			if (bus_write) begin
				case (bus_size)
					2'd0: ram[bus_addr[19:0]] = bus_wdata[7:0];
					2'd1: begin ram[{bus_addr[19:1], 1'b0}] = bus_wdata[15:8]; ram[{bus_addr[19:1], 1'b1}] = bus_wdata[7:0]; end
					default: wr32(bus_addr, bus_wdata);
				endcase
				if (bus_addr[31:24] == 8'h02) begin
					if (bus_addr[3:0] == 4'h0) n_trap <= bus_wdata;
					if (bus_addr[3:0] == 4'h4) ipl <= 3'b111;      // the handler's ack
					if (bus_addr[3:0] == 4'h8) begin
						$display("FAIL cyc %0d: exception handler %08h, stacked PC %08h", cyc, bus_wdata,
						         rd32(32'h0407F000 - 32'd0));
						$finish;
					end
				end
			end
			else case (bus_size)
				2'd0: bus_rdata <= {24'd0, ram[bus_addr[19:0]]};
				2'd1: bus_rdata <= {16'd0, ram[{bus_addr[19:1], 1'b0}], ram[{bus_addr[19:1], 1'b1}]};
				default: bus_rdata <= rd32(bus_addr);
			endcase
		end
		else bcnt <= bcnt - 1;
	end
	else if (bus_req && !bus_ack) begin
		bbusy <= 1'b1;
		// I/O ($02xxxxxx): 20-40 clocks, as tc_machine's S_IO with a device
		bcnt  <= (bus_addr[31:24] == 8'h02) ? 20 + ($urandom % 21) : 1 + ($urandom % lat_max);
	end
end

// ---- tc_machine's side of the flush: ask, write a dirty line back, then
// a DMA byte write into the DMA buffer when the line is one of its
reg          fl_wait = 0;
int unsigned fl_next = 200;
reg  [31:4]  fl_cur;
reg          dma_pend = 0;
// lines flushed: the table, the functions' data, the stack, the code,
// a DMA buffer
function automatic [31:4] pick_line();
	int unsigned r;
	r = $urandom % 11;
	case (r)
		0: pick_line = 28'h0401000 + ($urandom % 4);           // table
		1: pick_line = 28'h0401800 + ($urandom % 8);           // functions' data
		2: pick_line = 28'h0401810;                            // the IRQ's data
		3: pick_line = 28'h0407EF0 + ($urandom % 16);          // stack
		4: pick_line = 28'h0400040 + ($urandom % 16);          // code
		5: pick_line = 28'h0401000 + 28'h40 * (1 + $urandom % 5) + ($urandom % 4); // the table's sets
		6, 7: pick_line = 28'h0401406;                         // the 'uthread' line ($66)
		8: pick_line = 28'h0404000 + ($urandom % 64);          // page tables
		9: pick_line = ($urandom % 2) ? 28'h0404400 : 28'h0404420;           // root / pointer tables
		default: pick_line = 28'h0403000 + ($urandom % 64);    // DMA buffer
	endcase
endfunction

always @(posedge clk) begin
	fl_req <= 1'b0;
	if (nreset) begin
		if (fl_done) begin
			if (!fl_wait) begin $display("FAIL cyc %0d: fl_done without a request", cyc); $finish; end
			fl_wait <= 1'b0;
			n_fl <= n_fl + 1;
			if (fl_dirty) begin
				n_fld <= n_fld + 1;
				wr32({fl_cur, 4'h0}, fl_line[127:96]);
				wr32({fl_cur, 4'h4}, fl_line[95:64]);
				wr32({fl_cur, 4'h8}, fl_line[63:32]);
				wr32({fl_cur, 4'hC}, fl_line[31:0]);
			end
			dma_pend <= (fl_cur[31:16] == 16'h0403);
		end
		else if (dma_pend && !sb_pending) begin
			// the DMA beat: a byte into the buffer line
			ram[{fl_cur[19:4], 4'($urandom % 16)}] = 8'($urandom);
			dma_pend <= 1'b0;
			n_dma <= n_dma + 1;
		end
		else if (!fl_wait && !dma_pend && dir_go) begin
			// directed: a flush of a DMA-buffer line K core clocks after
			// the kernel's clr.l $66(a0) enters AG
			dir_ack <= dir_req;
			fl_cur  = 28'h0403000 + ($urandom % 64);
			fl_addr <= fl_cur;
			fl_req  <= 1'b1;
			fl_wait <= 1'b1;
		end
		else if (!fl_wait && !dma_pend && fl_every != 0 && cyc >= fl_next) begin
			fl_cur  = pick_line();
			fl_addr <= fl_cur;
			fl_req  <= 1'b1;
			fl_wait <= 1'b1;
			fl_next <= cyc + 1 + ($urandom % (2 * fl_every));
		end
	end
end

// ---- directed flush: +clrpc=<hex> +dirk=K
reg [31:0]   clr_pc = 0;
int          dir_k = -1;
int unsigned dir_cnt = 0;
// (on clk_cpu, the core's own clock, K counts core clocks; the request
// crosses to the clk-side flush requester as a counter pair)
reg          dir_arm = 0;
reg    [7:0] dir_req = 0, dir_ack = 0;
wire         dir_go = (dir_req != dir_ack);
initial begin void'($value$plusargs("clrpc=%h", clr_pc)); void'($value$plusargs("dirk=%d", dir_k)); end
always @(posedge clk_cpu) begin
	if (nreset && dir_k >= 0) begin
		if (!dir_arm && dut.cpu.be.ag_v && dut.cpu.be.ag_u.pc == clr_pc && dut.cpu.be.adv_ag) begin
			dir_arm <= 1'b1; dir_cnt <= 0;
		end
		else if (dir_arm) begin
			dir_cnt <= dir_cnt + 1;
			if (dir_cnt == dir_k) begin dir_req <= dir_req + 8'd1; dir_arm <= 1'b0; end
		end
	end
end

// ---- level-4 interrupts
int unsigned irq_next = 5000;
always @(posedge clk)
	if (nreset && irq_every != 0 && ipl == 3'b111 && cyc >= irq_next) begin
		ipl <= 3'b011;
		n_irq <= n_irq + 1;
		irq_next <= cyc + 1 + ($urandom % (2 * irq_every));
	end

// ---- +trace=FROM,N: the bus transactions and retired PCs
int unsigned tr_from = 0, tr_n = 0;
initial begin void'($value$plusargs("trfrom=%d", tr_from)); void'($value$plusargs("trn=%d", tr_n)); end
always @(posedge clk) if (nreset && tr_n != 0 && cyc >= tr_from && cyc < tr_from + tr_n) begin
	if (bus_ack) $display("%0d BUS %s %08h sz%0d %08h%s", cyc, bus_write ? "W" : "R", bus_addr, bus_size,
	                      bus_write ? bus_wdata : rd32(bus_addr), bus_instr ? " I" : "");
	if (dut.cpu.dbg_retire) $display("%0d RET %08h", cyc, dbg_pc);
	if (fl_req) $display("%0d FLREQ %07h", cyc, fl_addr);
	if (fl_done) $display("%0d FLDONE dirty=%0d %032h", cyc, fl_dirty, fl_line);
end

// ---- coverage
int unsigned c_ihit = 0, c_snref = 0, c_src0 = 0, c_src1 = 0, c_src2 = 0, c_kill = 0, c_drop = 0, c_icall = 0, c_stcap = 0;
always @(posedge clk_cpu) if (nreset) begin
	if (dut.cpu.be.sn_ihit) c_ihit <= c_ihit + 1;
	if (dut.cpu.be.adv_ag && dut.cpu.be.ag_snref) c_snref <= c_snref + 1;
	if (dut.cpu.dmu.sn_look && dut.cpu.dmu.sn_hit) begin
		if (dut.cpu.dmu.sn_src == 0) c_src0 <= c_src0 + 1;
		if (dut.cpu.dmu.sn_src == 1) c_src1 <= c_src1 + 1;
		if (dut.cpu.dmu.sn_src == 2) c_src2 <= c_src2 + 1;
	end
	if (dut.cpu.dmu.kill_now && dut.cpu.dmu.e_st != 0) c_kill <= c_kill + 1;
	if (dut.cpu.dmu.b_drop) c_drop <= c_drop + 1;
	// AG reloads a base from EX's last write although a load leaving DC2
	// supplied it (cap_b): the base goes back to the older writer's value
	if (dut.cpu.be.ag_v && dut.cpu.be.ag_u.base_v && dut.cpu.be.stale_b && dut.cpu.be.cap_b) begin
		c_stcap <= c_stcap + 1;
		if (c_stcap < 5) $display("HAZARD cyc %0d: AG pc %08h base reloaded from EX (%08h) over the DC2 capture (%08h)",
		                          cyc, dut.cpu.be.ag_u.pc, dut.cpu.be.exq_val, dut.cpu.be.agb_q);
	end
	if (dut.cpu.snoop.ic_req && dut.cpu.snoop.ic_all) c_icall <= c_icall + 1;
end
final $display("COVER ihit %0d snref %0d src way/pv/queued %0d/%0d/%0d kill-in-job %0d drop %0d ic_all-clk %0d stale-over-capture %0d",
               c_ihit, c_snref, c_src0, c_src1, c_src2, c_kill, c_drop, c_icall, c_stcap);

// ---- checks
int unsigned last_ret = 0;
reg [31:0]   last_pc = 0;
always @(posedge clk_cpu) if (nreset && dut.cpu.dbg_retire) begin
	// (every core clock: the core retires on clk_cpu)
	last_ret <= cyc;
	last_pc  <= dbg_pc;
	if (dbg_pc[31:8] == 24'h040100) begin
		$display("FAIL cyc %0d: retired PC %08h in the table (previous %08h); trap %0d flushes %0d dirty %0d irqs %0d",
		         cyc, dbg_pc, last_pc, n_trap, n_fl, n_fld, n_irq);
		$finish;
	end
end
always @(posedge clk) if (nreset) begin
	cyc <= cyc + 1;
	if (cyc - last_ret > 20000 && cyc > 20000) begin
		$display("FAIL cyc %0d: no retirement since %0d (PC %08h)", cyc, last_ret, last_pc);
		$display("  dmu e_st %0d e_ret %0d sn_ph %0d e_job %0d e_kill %0d bo_cancel %0d bo_ingnt %0d e_breq %0d tw_va %08h tw_da %08h",
		         dut.cpu.dmu.e_st, dut.cpu.dmu.e_ret, dut.cpu.dmu.sn_ph, dut.cpu.dmu.e_job, dut.cpu.dmu.e_kill,
		         dut.cpu.dmu.bo_cancel, dut.cpu.dmu.bo_ingnt, dut.cpu.dmu.e_breq, dut.cpu.dmu.tw_va, dut.cpu.dmu.tw_da);
		$display("  snoop st %0d dc_req %0d; m2 v %0d m4 v %0d; nst %0d cst %0d bg_n %0d",
		         dut.cpu.snoop.st, dut.cpu.snoop.dc_req, dut.cpu.dmu.m2.r.v, dut.cpu.dmu.m4.r.v,
		         dut.nst, dut.cst, dut.bg_n);
		$finish;
	end
	if (cyc >= cycles) begin
		$display("PASS cycles %0d traps %0d flushes %0d dirty %0d dma %0d irqs %0d",
		         cyc, n_trap, n_fl, n_fld, n_dma, n_irq);
		$finish;
	end
end

initial begin
	string f;
	void'($value$plusargs("seed=%d", seed));
	void'($value$plusargs("cycles=%d", cycles));
	void'($value$plusargs("flush=%d", fl_every));
	void'($value$plusargs("irq=%d", irq_every));
	void'($value$plusargs("lat=%d", lat_max));
	void'($urandom(seed));
	for (int i = 0; i < (1 << 20); i++) ram[i] = 8'h4A;   // (ILLEGAL is $4AFC)
	if (!$value$plusargs("prog=%s", f)) f = "prog.hex";
	$readmemh(f, ram, 0, 'h4FFFF);
	repeat (10) @(posedge clk);
	nreset = 1;
end

endmodule
