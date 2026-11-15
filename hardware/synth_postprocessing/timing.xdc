create_clock -name clk -period 10.000 [get_ports clk]
# Isolate synchronous arithmetic; reset assertion/deassertion is not characterized here.
set_false_path -from [get_ports rst]
# Assumed external launch/capture budget, not board pin timing.
set data_inputs [get_ports -filter {DIRECTION == IN && NAME != clk && NAME != rst}]
set_input_delay -clock clk -max 2.000 $data_inputs
set_input_delay -clock clk -min 0.000 $data_inputs
set_output_delay -clock clk -max 2.000 [all_outputs]
set_output_delay -clock clk -min 0.000 [all_outputs]

