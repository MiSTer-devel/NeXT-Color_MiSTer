project_open NeXT-Color -revision NeXT-Color
create_timing_netlist -model slow
read_sdc
update_timing_netlist
set clk [get_clocks {pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}]
report_timing -setup -npaths 200 -detail summary -to_clock $clk -file hdmi_setup_summary.rpt
report_timing -setup -npaths 3 -detail full_path -to_clock $clk -file hdmi_setup_full.rpt
delete_timing_netlist
project_close
