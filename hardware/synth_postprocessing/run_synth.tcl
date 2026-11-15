set script_dir [file dirname [file normalize [info script]]]
set_param general.maxThreads 4
read_verilog -sv [list [file join $script_dir ../source/PostProcessing.sv]]
read_xdc [list [file join $script_dir timing.xdc]]
synth_design -top PostProcessing -part xc7a100tcsg324-1 -mode out_of_context
report_utilization -file [file join $script_dir utilization.rpt]
report_timing_summary -delay_type max -max_paths 10 -file [file join $script_dir timing_summary.rpt]
report_timing -from [all_registers -clock clk] -to [all_registers -clock clk] -delay_type max -max_paths 10 -path_type full_clock_expanded -file [file join $script_dir register_paths.rpt]
check_timing -verbose -file [file join $script_dir check_timing.rpt]
write_checkpoint -force [file join $script_dir postprocessing_synth.dcp]
puts "POSTPROCESSING_SYNTHESIS_COMPLETE"
exit
