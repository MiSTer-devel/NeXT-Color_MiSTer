derive_pll_clocks
derive_clock_uncertainty

# core specific constraints

# ----------------------------------------------------------------------------
# Pixel-clock domain (rtl/pll_vid.v, 100 MHz) -- asynchronous to everything.
# ----------------------------------------------------------------------------
# sys_top.sdc groups only the main core PLL, so a second PLL would land in no
# group and every framework path touching CLK_VIDEO would be timed against
# unrelated domains (MacQuadra800.sdc and MacLC.sdc learned this).  The
# clk_sys <-> clk_vid crossings are 2FF synchronizers (*_meta) and the
# quasi-static TMC timing registers (tc_vtiming re-samples them).
set_clock_groups -asynchronous -group [get_clocks {emu|pllv|*|divclk}]

set_false_path -to [get_keepers {*_meta*}]

# ----------------------------------------------------------------------------
# The AP68040 on clk_cpu (50 MHz, 2 x clk_sys, same PLL, aligned edges).
# rtl/next_ap68040.sv runs the core's bus, its transfer FSM, the store buffer
# and the snoop presenter on clk_cpu under bclk_en, which is high only in the
# clk_cpu cycles that end on a clk_sys edge.  Every register that talks to
# clk_sys logic (tc_machine) therefore launches and captures only on clk_sys
# edges: the paths between the two clocks are a full clk_sys period, two
# clk_cpu cycles.  The exception is the bclk_en phase detector, whose
# clk_sys -> clk_cpu paths are single-cycle by design.
# derive_pll_clocks names the clocks by PLL counter, so find them by period.
# ----------------------------------------------------------------------------
set ntc_cpu_clk ""
set ntc_sys_clk ""
foreach_in_collection c [get_clocks {emu|pll|*divclk}] {
	set p [get_clock_info -period $c]
	if {abs($p - 17.544) < 0.05} { set ntc_cpu_clk [get_clock_info -name $c] }
	if {abs($p - 35.088) < 0.05} { set ntc_sys_clk [get_clock_info -name $c] }
}
if {$ntc_cpu_clk ne "" && $ntc_sys_clk ne ""} {
	set_multicycle_path -from [get_clocks $ntc_cpu_clk] -to [get_clocks $ntc_sys_clk] -setup -start 2
	set_multicycle_path -from [get_clocks $ntc_cpu_clk] -to [get_clocks $ntc_sys_clk] -hold  -start 1
	set_multicycle_path -from [get_clocks $ntc_sys_clk] -to [get_clocks $ntc_cpu_clk] -setup -end 2
	set_multicycle_path -from [get_clocks $ntc_sys_clk] -to [get_clocks $ntc_cpu_clk] -hold  -end 1
	# the phase detector: clk_sys's toggle seen on the very next clk_cpu edge
	set_multicycle_path -from [get_registers {*|cpu|g_bclk.ph_sys}] -to [get_clocks $ntc_cpu_clk] -setup -end 1
	set_multicycle_path -from [get_registers {*|cpu|g_bclk.ph_sys}] -to [get_clocks $ntc_cpu_clk] -hold  -end 0
} else {
	post_message -type critical_warning "NeXT-Color.sdc: clk_cpu/clk_sys not found; CPU2X paths are not constrained as multicycle"
}
