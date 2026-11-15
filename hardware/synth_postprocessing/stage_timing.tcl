set script_dir [file dirname [file normalize [info script]]]
open_checkpoint [file join $script_dir postprocessing_synth.dcp]
foreach {label expression} {
    bias {NAME =~ biased_out_reg*}
    magnitude {NAME =~ magnitude_*}
    multiply {NAME =~ product_*}
    scaling {NAME =~ integer_reg* || NAME =~ scaled_* || NAME =~ round_up*}
    rounding {NAME =~ quantized_out_reg* || NAME =~ out_*}
} {
    set endpoints [get_cells -hier -filter "IS_SEQUENTIAL == 1 && ($expression)"]
    report_timing -to $endpoints -delay_type max -max_paths 1 -file [file join $script_dir stage_${label}.rpt]
}
exit
