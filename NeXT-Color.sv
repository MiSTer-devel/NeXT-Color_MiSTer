//============================================================================
//
//  NeXT-Color -- NeXTstation Turbo Color (33 MHz 68040, TMC + PC chip set,
//  Bt463, 2 MB VRAM at $0C000000, 1120x832 x 16 bpp) for MiSTer.
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//  Clocks (structure from MacQuadra800_MiSTer, MacQuadra800.sv):
//    clk_sys  25.000 MHz  CPU bus, devices (real Turbo bus: 33 MHz; CLK_HZ
//                         keeps the devices' real-time rates)
//    clk_ram  75.000 MHz  SDRAM controller, exactly 3 x clk_sys (same PLL)
//    clk_cpu  50.000 MHz  AP68040 core, 2 x clk_sys (same PLL; its bus runs
//                         at clk_sys, rtl/next_ap68040.sv).  Sets the PLL:
//                         ~95% full with the DSP, 57 MHz does not close.
//    clk_vid 100.000 MHz  pixel clock, own PLL (rtl/pll_vid.v)
//
//  Memory (docs/DECISIONS.md):
//    main RAM   SDRAM, 4 banks at $04000000 + n*$02000000
//    boot ROM   M10K (rtl/tc_rom.sv), loaded from games/NeXT-Color/boot.rom
//    VRAM       DDR3 (2 MB)
//
//  Machine: rtl/tc_machine.sv; memories + scan-out: rtl/tc_memsys.sv.
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used yet /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;

assign VGA_SL = 0;
assign VGA_F1 = 0;
assign VGA_SCALER  = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

// sound out: the machine's sound box (tc_kms), signed 16-bit stereo, clk_sys
wire [15:0] audio_l, audio_r;
assign AUDIO_S = 1;
assign AUDIO_L = audio_l;
assign AUDIO_R = audio_r;
assign AUDIO_MIX = 0;

assign LED_POWER = 0;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

`include "build_id.v"
localparam CONF_STR = {
	"NeXT-Color;;",
	"-;",
	// MiSTer OSD standard (danifunker/hp9000-715_MiSTer docs/osd-standard.md).
	// Settings other than the media, Input and the P1 buttons take effect at
	// the next reset (cfg below).  Rows keep their status bits, so saved
	// settings stay valid.
	//
	// SC slots: Main remembers the mounted image in config/NeXT-Color.s<n>
	// and re-mounts it at core start, so the ROM can boot from the disk.
	// Slot n = SCSI target n; slot 3 is the CD-ROM (Main's NEXT_CDROM_SLOT,
	// which also carries the target-response windows, rtl/tc_scsi.sv).
	"SC0,HDAVHDIMG,Pri. disk (ID 0);",
	"SC1,HDAVHDIMG,Disk (ID 1);",
	"SC3,ISOCUEBINCHD,CD-ROM (ID 3);",
	// slot 4: the 2.88 MB floppy drive (rtl/next_floppy.sv; 720K, 1.44M and
	// 2.88M images, the geometry follows the size).  Same slot and
	// extensions as the mono NeXT core.
	"SC4,IMGIMAFLPVFDFD ,Floppy;",
	// ioctl index 1, not remembered (boot0.rom is index 0, below)
	"F1,ROMBIN,Load ROM;",
	"-;",
	// The first entry is the default.  32 MB fits every SDRAM module; a
	// larger choice is capped at the module's size (mem_rank below).  "v,1"
	// drops settings saved with the old order (64 MB, Prompt, Normal first).
	"O[4:3],Memory,32MB,64MB,128MB,16MB;",
	// Network interface: latched (cfg), passed to Main's next_enet daemon as
	// NET_MODE (rtl/next_enet_bridge.sv).  None unplugs the cable
	// (rtl/tc_enet.sv).  No wlan0: Main's bridge has none.  Bits 54:52 are
	// the old Ethernet switch and Main's mono-core status mode: never reuse.
	// Older saved settings read 0 = eth0.
	"O[57:55],Network interface,eth0,None,eth1,macvlan,tap0;",
	"-;",
	"P1,Machine;",
	"P2,Video;",
	"P3,Input;",
	"P5,Advanced;",
	"-;",
	"h0-,Changes pending;",
	"R[0],Apply and reset;",

	// buttons (status pulses while held): power key (as F10), NMI (ROM
	// monitor, as F11)
	"P1T[10],Power key;",
	"P1T[11],NMI (monitor);",

	// V-Integer first (the default): 1:1 1120x832 on a 1080p display.
	"P2O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"P2O[125:123],Scale,V-Integer,Normal,Narrower HV-Integer,Wider HV-Integer;",

	// Input acts at once (not latched)
	"P3O[9],Swap Alt/Win keys,No,Yes;",

	"P5O[8:6],Boot device,SCSI disk,Prompt,Network,Floppy;",
	"P5O[5],Self test,On,Off;",

	"v,1;",
	"V,v",`BUILD_DATE
};

wire   [1:0] buttons;
wire [127:0] status;
wire         cfg_pending;      // a latched setting waits for Apply and reset
wire  [10:0] ps2_key;
wire  [24:0] ps2_mouse;
wire  [32:0] timestamp;
wire  [15:0] sdram_sz;         // Main's SDRAM module size (UIO_SET_MEMSZ)

wire        ioctl_download;
wire [15:0] ioctl_index;
wire        ioctl_wr;
wire [26:0] ioctl_addr;
wire  [7:0] ioctl_dout;

// SD slots (NeXT_MiSTer NeXT.sv): WIDE=0 because tc_scsi keeps next_scsi's
// 8-bit sd_buff port; VDNUM 4 = slots 0..3 (slot 2 has no OSD entry, so
// target 2 always times out, as in the mono core), slot 4 = the floppy
// (VDNUM 5).  tc_scsi talks to one
// target at a time: its request goes to slot sd_unit and only that slot's
// acknowledge comes back.
wire  [4:0] img_mounted_v, sd_ack_v;
wire        img_readonly;
wire [63:0] img_size;
wire  [2:0] sd_unit;
wire [31:0] sd_lba;
wire        sd_rd, sd_wr, sd_busy;
wire [13:0] sd_buff_addr;
wire  [7:0] sd_buff_dout, sd_buff_din;
wire        sd_buff_wr;
wire  [3:0] scsi_onehot = 4'd1 << sd_unit[1:0];
wire        sd_ack      = (sd_unit < 3'd4) ? sd_ack_v[sd_unit[1:0]] : 1'b0;
// the floppy's own request on slot 4 (tc_machine / next_floppy)
wire [31:0] fsd_lba;
wire        fsd_rd, fsd_wr;
wire  [7:0] fsd_buff_din;

hps_io #(.CONF_STR(CONF_STR), .WIDE(0), .VDNUM(5)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(),

	.buttons(buttons),
	.status(status),
	.status_menumask({15'd0, cfg_pending}),

	.ps2_key(ps2_key),
	.ps2_mouse(ps2_mouse),
	.TIMESTAMP(timestamp),
	.sdram_sz(sdram_sz),

	.ioctl_download(ioctl_download),
	.ioctl_index(ioctl_index),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(1'b0),

	.img_mounted(img_mounted_v),
	.img_readonly(img_readonly),
	.img_size(img_size),
	// sd_lba / sd_blk_cnt / sd_buff_din are unpacked [VDNUM] = [0:VDNUM-1]:
	// the FIRST pattern element is slot 0 (sd_rd/sd_wr are packed, MSB first)
	.sd_lba('{sd_lba, sd_lba, sd_lba, sd_lba, fsd_lba}),
	.sd_rd({fsd_rd, {4{sd_rd}} & scsi_onehot}),
	.sd_wr({fsd_wr, {4{sd_wr}} & scsi_onehot}),
	.sd_ack(sd_ack_v),
	.sd_blk_cnt('{6'd0, 6'd0, 6'd0, 6'd0, 6'd0}),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din('{sd_buff_din, sd_buff_din, sd_buff_din, sd_buff_din, fsd_buff_din}),
	.sd_buff_wr(sd_buff_wr)
);

assign LED_DISK = {1'b0, sd_busy | sd_ack_v[4]};

///////////////////////   CLOCKS   ///////////////////////////////

localparam CLK_SYS_HZ = 25000000;   // rtl/pll/pll_0002.v outclk_0

wire clk_sys, clk_ram, clk_cpu, pll_locked;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_ram),
	.outclk_2(clk_cpu),
	.locked(pll_locked)
);

wire clk_vid, pllv_locked;
pll_vid pllv
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_vid),
	.locked(pllv_locked)
);

///////////////////////   BOOT ROM   /////////////////////////////

// boot0.rom (or boot.rom) is ioctl index 0, loaded by the Main at core start
// from games/NeXT-Color/; the OSD "Load ROM" entry is index 1, with the
// file-extension number in bits [15:6] (.BIN = $41).  Main also sends
// boot1/2/3.rom at start as $40/$80/$C0: those are not the boot ROM (a
// boot1.rom copied from the mono NeXT core is a 68030 ROM and left the
// screen black), so index 0 must be exactly 0.
wire rom_index = (ioctl_index == 16'd0) || (ioctl_index[5:0] == 6'd1);
reg  rom_loaded = 0;
reg  rom_dl_d   = 0;
reg  [7:0] rom_even = 0;      // the even byte of the halfword being loaded
always @(posedge clk_sys) begin
	rom_dl_d <= ioctl_download && rom_index;
	if (rom_dl_d && !(ioctl_download && rom_index)) rom_loaded <= 1;
	if (ioctl_wr && !ioctl_addr[0]) rom_even <= ioctl_dout;
end


///////////////////////   RESET   ////////////////////////////////

// The KMS magic reset ($C6 $1000A825, hardware-summary 6.2) resets the
// machine but not the NVRAM image; the OSD/power-up reset rebuilds it.
wire        reset_req;
reg   [7:0] kms_reset_cnt = 0;
always @(posedge clk_sys) begin
	if (reset_req) kms_reset_cnt <= 8'hFF;
	else if (kms_reset_cnt != 0) kms_reset_cnt <= kms_reset_cnt - 1'd1;
end

// Registered, as the mono core learned (NeXT_MiSTer RESUME-20260925: the
// reset nets fan out to thousands of flops; a register lets Quartus put
// them on a global).
reg config_reset = 1, reset = 1;
always @(posedge clk_sys) begin
	config_reset <= RESET | status[0] | buttons[1] | (ioctl_download && rom_index) |
	                ~rom_loaded | ~pll_locked;
	reset        <= config_reset | (kms_reset_cnt != 0);
end

// The settings the machine runs with, latched in configuration reset (Apply
// and reset, the board button, core start, ROM load) so the ROM never sees
// one change.  The KMS magic reset keeps them, as it keeps the NVRAM.
// cfg_pending ("Changes pending", menumask bit 0): a latched field differs.
reg [125:0] cfg = 126'd0;
always @(posedge clk_sys) if (config_reset) cfg <= status[125:0];
assign cfg_pending = {status[8:3], status[57:55], status[125:121]} !=
                     {cfg[8:3],    cfg[57:55],    cfg[125:121]};

// Network interface: OSD order eth0, None, eth1, macvlan, tap0 -> Main's
// NB_MODE_ 1, 0, 2, 3, 4 (support/next/next_enet.cpp).
reg [2:0] net_mode;
always @(*) case (cfg[57:55])
	3'd0:    net_mode = 3'd1;   // eth0 (shared, promiscuous + the MAC filter)
	3'd2:    net_mode = 3'd2;   // eth1
	3'd3:    net_mode = 3'd3;   // macvlan
	3'd4:    net_mode = 3'd4;   // tap0
	default: net_mode = 3'd0;   // None
endcase
wire net_connected = (net_mode != 3'd0);

// Memory, capped at the SDRAM module (more makes NeXTSTEP panic).  Ranks:
// 0 = 16 MB, 1 = 32, 2 = 64, 3 = 128; OSD order 32, 64, 128, 16 MB is
// rank - 1.  sdram_sz[15] = module known, [1:0] 1/2/3 = 32/64/128 MB
// (sys/hps_io.sv); an unknown module is not capped.
wire [1:0] mem_want = status[4:3] + 2'd1;
wire [1:0] mem_max  = !sdram_sz[15]          ? 2'd3 :
                      (sdram_sz[1:0] == 2'd0) ? 2'd1 : sdram_sz[1:0];
wire [1:0] mem_rank = (mem_want > mem_max) ? mem_max : mem_want;

// Machine configuration, sampled while the machine is in reset.
reg  [1:0] ram_cfg  = 2'd0;
reg        pot_on   = 1'b1;
reg [95:0] boot_cmd = 96'd0;
always @(posedge clk_sys) if (config_reset) begin
	// rank 1, 2, 3, 0 (32, 64, 128, 16 MB) -> ram_cfg 3, 0, 1, 2 (0 = 64 MB,
	// 1 = 128 MB, 2 = 16 MB, 3 = 32 MB, rtl/tc_mccs1850.sv)
	ram_cfg <= mem_rank - 2'd2;
	pot_on  <= ~status[5];
	case (status[8:6])                      // OSD order: SCSI disk, Prompt, Network, Floppy
	3'd0:    boot_cmd <= {"sd", 80'd0};
	3'd2:    boot_cmd <= {"en", 80'd0};
	3'd3:    boot_cmd <= {"fd", 80'd0};
	default: boot_cmd <= 96'd0;             // empty: the ROM stops at NeXT>
	endcase
end

// The P1 Machine buttons: a press is a rising edge of the T bit.
reg  [11:10] osd_btn_d = 2'b00;
always @(posedge clk_sys) osd_btn_d <= status[11:10];
wire osd_power = status[10] & ~osd_btn_d[10];
wire osd_nmi   = status[11] & ~osd_btn_d[11];

// Input: Swap Alt/Win keys (status[9], at once).  Win = NeXT Command, Alt =
// Alternate (rtl/tc_kms.sv).  ps2_key [8] = extended, [7:0] = set-2 code.
function automatic [8:0] alt_win(input [8:0] k);
	case (k)
		9'h011: alt_win = 9'h11F;   // left Alt -> left GUI
		9'h11F: alt_win = 9'h011;
		9'h111: alt_win = 9'h127;   // right Alt -> right GUI
		9'h127: alt_win = 9'h111;
		default: alt_win = k;
	endcase
endfunction
wire [10:0] kbd_key = status[9] ? {ps2_key[10:9], alt_win(ps2_key[8:0])} : ps2_key;

// video-domain reset: two-flop synchronizer of the PLL lock
reg vrst_meta = 1, vrst = 1;
always @(posedge clk_vid) begin
	vrst_meta <= ~pllv_locked;
	vrst      <= vrst_meta;
end

///////////////////////   MACHINE   //////////////////////////////

wire        mem_req, mem_write;
wire [26:2] mem_addr;
wire  [3:0] mem_be;
wire [31:0] mem_wdata;
wire  [1:0] mem_memsel;
wire [31:0] mem_rdata;
wire        mem_ack;
wire        mem_wp_valid;
wire [26:2] mem_wp_addr;
wire  [3:0] mem_wp_be;
wire [31:0] mem_wp_data;
wire        mem_wq_room;
wire        mem_line_valid;
wire [26:4] mem_line_tag;
wire [127:0] mem_line_data;
wire        mem_line_pending;
wire [26:4] mem_line_pending_tag;

wire [31:0] tmc_hreg, tmc_vreg;
wire        video_enable;
wire   [2:0] pal_we;
wire   [3:0] pal_n;
wire   [7:0] pal_d;
wire        vbl_pulse;
wire        led;

tc_machine #(.CLK_HZ(CLK_SYS_HZ)) machine
(
	.clk(clk_sys),
	.clk_cpu(clk_cpu),
	.nreset(~reset),
	.ce(1'b1),
	.config_reset(config_reset),
	.ram_cfg(ram_cfg),

	.mem_req(mem_req),
	.mem_write(mem_write),
	.mem_addr(mem_addr),
	.mem_be(mem_be),
	.mem_wdata(mem_wdata),
	.mem_memsel(mem_memsel),
	.mem_rdata(mem_rdata),
	.mem_ack(mem_ack),
	.mem_wp_valid(mem_wp_valid),
	.mem_wp_addr(mem_wp_addr),
	.mem_wp_be(mem_wp_be),
	.mem_wp_data(mem_wp_data),
	.mem_wq_room(mem_wq_room),
	.mem_line_valid(mem_line_valid),
	.mem_line_tag(mem_line_tag),
	.mem_line_data(mem_line_data),
	.mem_line_pending(mem_line_pending),
	.mem_line_pending_tag(mem_line_pending_tag),

	.tmc_hreg(tmc_hreg),
	.tmc_vreg(tmc_vreg),
	.video_enable(video_enable),
	.pal_we(pal_we),
	.pal_n(pal_n),
	.pal_d(pal_d),
	.vbl_pulse(vbl_pulse),

	.ps2_key(kbd_key),
	.ps2_mouse(ps2_mouse),
	.osd_power(osd_power),
	.osd_nmi(osd_nmi),
	.timestamp(timestamp),
	.pot_on(pot_on),
	.boot_cmd(boot_cmd),

	.img_mounted({2'b00, img_mounted_v[3:0]}),
	.img_readonly(img_readonly),
	.img_size(img_size),
	.sd_unit(sd_unit),
	.sd_lba(sd_lba),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr),
	.sd_busy(sd_busy),
	.fimg_mounted(img_mounted_v[4]),
	.fsd_lba(fsd_lba),
	.fsd_rd(fsd_rd),
	.fsd_wr(fsd_wr),
	.fsd_ack(sd_ack_v[4]),
	.fsd_buff_din(fsd_buff_din),
	.enet_connected(net_connected),
	.enet_mode(net_mode),
	.enet_m_req(enet_m_req),
	.enet_m_we(enet_m_we),
	.enet_m_addr(enet_m_addr),
	.enet_m_wdata(enet_m_wdata),
	.enet_m_rdata(enet_m_rdata),
	.enet_m_ack(enet_m_ack),

	.led(led),
	.reset_req(reset_req),
	.audio_l(audio_l), .audio_r(audio_r),

	.dbg_berr(),
	.dbg_berr_addr(),
	.debug_status(),
	.debug_status2(),
	.debug_fault(),
	.debug_halted(),
	.dbg_intstat(),
	.dbg_ipl()
);

///////////////////////   MEMORY + VIDEO   ///////////////////////

wire [7:0] vga_r, vga_g, vga_b;
wire       vga_hs, vga_vs, vga_de;

assign DDRAM_CLK = clk_ram;

// RESET is sys/'s reset_out: Main's core reset, which also drives the
// f2sdram_safe_terminator in front of the DDRAM port.  Every reset after the
// first one (Main pulses it on each restart; a Main switch through a main=
// line in MiSTer.ini restarts it twice) puts the terminator in its
// "terminating" stage for the whole pulse: it lets transactions already in
// flight finish but swallows new ones while still passing waitrequest, so a
// read started then is accepted and never answered.  tc_vram's scan-out
// fetches from configuration on, reset or not, so it was left waiting
// forever and the CPU's VRAM beats with it: a black screen with no POST.
// ddr_hold stops every DDRAM master here from starting anything during the
// pulse and drops their waits.  The terminator syncs RESET with two flops on
// this clock and leaves "terminating" one clock after the second falls, so
// ddr_hold rises off one flop (a cycle before the terminator starts) and
// falls three clocks after RESET (two after the terminator has stopped).
reg       ddr_hold = 1'b1;
reg [2:0] ddr_hold_d = 3'b111;
always @(posedge clk_ram) begin
	ddr_hold_d <= {ddr_hold_d[1:0], RESET};
	ddr_hold   <= RESET | (|ddr_hold_d);
end

// tc_memsys (tc_vram) and the Ethernet bridge share the DDRAM port:
// rtl/tc_enet_ddr.sv, the VRAM traffic first.
wire        va_busy, va_dout_ready, va_rd, va_we;
wire  [7:0] va_burstcnt, va_be;
wire [28:0] va_addr;
wire [63:0] va_dout, va_din;
wire        enet_m_req, enet_m_we, enet_m_ack;
wire [28:0] enet_m_addr;
wire [63:0] enet_m_wdata, enet_m_rdata;

tc_enet_ddr enet_ddr
(
	.clk_sys(clk_sys), .clk_ram(clk_ram), .ddr_hold(ddr_hold),
	.s_req(enet_m_req), .s_we(enet_m_we), .s_addr(enet_m_addr), .s_wdata(enet_m_wdata),
	.s_rdata(enet_m_rdata), .s_ack(enet_m_ack),
	.a_busy(va_busy), .a_burstcnt(va_burstcnt), .a_addr(va_addr), .a_dout(va_dout),
	.a_dout_ready(va_dout_ready), .a_rd(va_rd), .a_din(va_din), .a_be(va_be), .a_we(va_we),
	.DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
	.DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY), .DDRAM_RD(DDRAM_RD),
	.DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE)
);

tc_memsys #(.RAM_HZ(3 * CLK_SYS_HZ)) memsys
(
	.clk_sys(clk_sys),
	.clk_ram(clk_ram),
	.clk_vid(clk_vid),
	.reset(reset),
	.reset_vid(vrst),
	.ddr_hold(ddr_hold),
	.sdram_init(~pll_locked),

	.mem_req(mem_req),
	.mem_write(mem_write),
	.mem_addr(mem_addr),
	.mem_be(mem_be),
	.mem_wdata(mem_wdata),
	.mem_memsel(mem_memsel),
	.mem_rdata(mem_rdata),
	.mem_ack(mem_ack),
	.mem_wp_valid(mem_wp_valid),
	.mem_wp_addr(mem_wp_addr),
	.mem_wp_be(mem_wp_be),
	.mem_wp_data(mem_wp_data),
	.mem_wq_room(mem_wq_room),
	.mem_line_valid(mem_line_valid),
	.mem_line_tag(mem_line_tag),
	.mem_line_data(mem_line_data),
	.mem_line_pending(mem_line_pending),
	.mem_line_pending_tag(mem_line_pending_tag),

	// boot.rom is ioctl index 0 (the Main loads games/NeXT-Color/boot.rom at
	// core start), the OSD "Load ROM" entry is index 1.  Byte-wide
	// ioctl (WIDE=0): the even byte is held and written with the odd one,
	// big-endian (file byte 0 = bits 15:8 of the first halfword).
	.rom_we(ioctl_download && rom_index && ioctl_wr && ioctl_addr[0] && ioctl_addr[26:17] == 0),
	.rom_waddr(ioctl_addr[16:1]),
	.rom_wdata({rom_even, ioctl_dout}),

	.hreg(tmc_hreg),
	.vreg(tmc_vreg),
	.video_enable(video_enable),
	.pal_we(pal_we),
	.pal_n(pal_n),
	.pal_d(pal_d),
	.vbl_pulse(vbl_pulse),
	.vga_r(vga_r),
	.vga_g(vga_g),
	.vga_b(vga_b),
	.vga_hs(vga_hs),
	.vga_vs(vga_vs),
	.vga_de(vga_de),

	.SDRAM_DQ(SDRAM_DQ),
	.SDRAM_A(SDRAM_A),
	.SDRAM_DQML(SDRAM_DQML),
	.SDRAM_DQMH(SDRAM_DQMH),
	.SDRAM_BA(SDRAM_BA),
	.SDRAM_nCS(SDRAM_nCS),
	.SDRAM_nWE(SDRAM_nWE),
	.SDRAM_nRAS(SDRAM_nRAS),
	.SDRAM_nCAS(SDRAM_nCAS),
	.SDRAM_CKE(SDRAM_CKE),
	.SDRAM_CLK(SDRAM_CLK),

	.DDRAM_BUSY(va_busy),
	.DDRAM_BURSTCNT(va_burstcnt),
	.DDRAM_ADDR(va_addr),
	.DDRAM_DOUT(va_dout),
	.DDRAM_DOUT_READY(va_dout_ready),
	.DDRAM_RD(va_rd),
	.DDRAM_DIN(va_din),
	.DDRAM_BE(va_be),
	.DDRAM_WE(va_we)
);

assign CLK_VIDEO = clk_vid;
assign CE_PIXEL  = 1'b1;
assign VGA_R  = vga_r;
assign VGA_G  = vga_g;
assign VGA_B  = vga_b;
assign VGA_HS = ~vga_hs;
assign VGA_VS = ~vga_vs;

// Aspect ratio and scaling (sys/video_freak.sv).  "Original" is 1120:832 =
// 35:26, square pixels (the mono core's lesson: a 4:3 declaration squeezes
// 1120 columns into 1109).  "Normal" scale fills the output height with the
// right aspect: 1454x1080 on 1080p, 969x720 on 720p.
// Both latched (cfg).
wire [1:0] ar = cfg[122:121];
// OSD order V-Integer, Normal, ... -> video_freak's 1, 0, 2, 3
wire [2:0] scale = (cfg[125:123] == 3'd0) ? 3'd1 :
                   (cfg[125:123] == 3'd1) ? 3'd0 : cfg[125:123];
video_freak video_freak
(
	.CLK_VIDEO(clk_vid),
	.CE_PIXEL(1'b1),
	.VGA_VS(~vga_vs),
	.HDMI_WIDTH(HDMI_WIDTH),
	.HDMI_HEIGHT(HDMI_HEIGHT),
	.VGA_DE(VGA_DE),
	.VIDEO_ARX(VIDEO_ARX),
	.VIDEO_ARY(VIDEO_ARY),
	.VGA_DE_IN(vga_de),
	.ARX((!ar) ? 12'd35 : (ar - 1'd1)),
	.ARY((!ar) ? 12'd26 : 12'd0),
	.CROP_SIZE(12'd0),
	.CROP_OFF(5'd0),
	.SCALE(scale)
);

assign LED_USER = led;

endmodule
