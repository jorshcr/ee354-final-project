`timescale 1ns / 1ps
module ConvEngineStreet_tb;
    logic clk=0, rst=1, input_wr_en=0, weight_wr_en=0;
    logic [13:0] load_addr=0, k_words=27;
    logic [63:0] load_data=0;
    logic start=0, out_ready=0;
    logic [3:0] active_rows=8, active_cols=8;
    wire start_ready, busy, config_error, out_valid;
    wire signed [7:0] results [0:7][0:7];
    logic signed [7:0] pixels [0:196607], weights [0:215];
    logic signed [31:0] expected [0:524287];
    logic bias_wr_en=0, shift_wr_en=0, activation_en=1;
    logic [2:0] bias_addr=0;
    logic signed [31:0] bias_data=0;
    logic [3:0] shift_data=7;
    integer output_file;
    integer timing_file, metrics_file;
    longint total_cycles=0, reset_cycles=0, init_cycles=0;
    longint input_writes=0, weight_writes=0, read_cycles=0;
    longint feed_cycles=0, drain_cycles=0, capture_cycles=0;
    longint idle_cycles=0, done_cycles=0, comparisons=0, accepted=0;
    longint start_cycle=0;
    bit previous_valid=0;
    ConvEngineTop dut (.*);
    always #5 clk=~clk;

    // Sample the controls consumed at each rising edge, then observe new valid.
    always @(posedge clk) begin
        total_cycles++;
        if (rst) reset_cycles++;
        else begin
            if (start_ready) idle_cycles++;
            if (dut.array_rst) init_cycles++;
            if (input_wr_en && dut.load_enable) input_writes++;
            if (weight_wr_en && dut.load_enable) weight_writes++;
            if (dut.buffer_rd_en) read_cycles++;
            if (dut.array_en && dut.feed_valid) feed_cycles++;
            if (dut.array_en && !dut.feed_valid) drain_cycles++;
            if (dut.post_in_last && (|dut.post_in_valid)) capture_cycles++;
            if (out_valid) done_cycles++;
            if (start && start_ready) begin
                start_cycle=total_cycles;
                accepted++;
            end
        end
        #1ps;
        if (out_valid && !previous_valid) begin
            $fdisplay(timing_file,"%0d,%0d,%0d,%0d",accepted-1,start_cycle,
                      total_cycles,total_cycles-start_cycle);
            if (total_cycles-start_cycle != 49)
                $fatal(1,"Unexpected accepted-start to output-valid latency");
        end
        previous_valid=out_valid;
    end

    // Q20 leaky coefficient, shift 7, nearest-even rounding, INT8 saturation.
    function automatic integer quantize(input longint signed value);
        longint unsigned magnitude, product, quotient, remainder, denominator;
        longint signed rounded;
        magnitude = value < 0 ? -value : value;
        product = magnitude * (value < 0 ? 64'd104858 : 64'd1048576);
        denominator = 64'd1 << 27;
        quotient = product / denominator;
        remainder = product % denominator;
        if (remainder > denominator/2 ||
            (remainder == denominator/2 && (quotient & 1))) quotient++;
        rounded = value < 0 ? -$signed(quotient) : $signed(quotient);
        if (rounded > 127) return 127;
        if (rounded < -128) return -128;
        return int'(rounded);
    endfunction

    task automatic load_word(input bit weight_select, input int address,
                             input logic [63:0] data);
        @(negedge clk);
        if (start_ready !== 1'b1) $fatal(1,"Not ready to load");
        load_addr=address; load_data=data;
        input_wr_en=!weight_select; weight_wr_en=weight_select;
        @(negedge clk);
        input_wr_en=0; weight_wr_en=0;
    endtask

    task automatic run_image(input string name);
        logic [63:0] word_data;
        int rows, pos, y, x, ky, kx, channel, clocks, iy, ix;
        $readmemh("../testbench/data/street_256/pixels.mem",pixels);
        $readmemh("../testbench/data/street_256/expected.mem",expected);
        // Load filters once; reuse them across all 8192 tiles.
        for (int k=0; k<27; k++) begin
            word_data='0;
            for (int f=0; f<8; f++) word_data[8*f +: 8]=weights[f*27+k];
            load_word(1,k,word_data);
        end
        for (int base=0; base<65536; base+=8) begin
            rows=8;
            for (int k=0; k<27; k++) begin
                word_data='0;
                ky=k/9; kx=(k/3)%3; channel=k%3;
                for (int lane=0; lane<rows; lane++) begin
                    pos=base+lane; y=pos/256; x=pos%256;
                    iy=y+ky-1; ix=x+kx-1;
                    if (iy>=0 && iy<256 && ix>=0 && ix<256)
                        word_data[8*lane +: 8]=pixels[(iy*256+ix)*3+channel];
                end
                load_word(0,k,word_data);
            end
            @(negedge clk);
            active_rows=rows; start=1;
            @(negedge clk);
            start=0; clocks=0;
            while (out_valid !== 1'b1) begin
                @(negedge clk);
                clocks++;
                if (clocks>60 || config_error !== 1'b0) $fatal(1,"Run failed");
            end
            for (int r=0; r<8; r++) begin
                for (int c=0; c<8; c++) begin
                    if (r<rows && c<8) begin
                        pos=base+r;
                        if (results[r][c] !== quantize(expected[pos*8+c]))
                            $fatal(1,"%s pos=%0d filter=%0d expected=%0d actual=%0d",
                                   name,pos,c,quantize(expected[pos*8+c]),results[r][c]);
                        comparisons++;
                        $fdisplay(output_file,"%s,%0d,%0d,%0d,%0d",name,pos/256,pos%256,c,results[r][c]);
                    end else if (results[r][c] !== 8'sd0)
                        $fatal(1,"Unused output nonzero");
                end
            end
            out_ready=1;
            @(negedge clk);
            out_ready=0;
            if (start_ready !== 1'b1) $fatal(1,"Handshake failed");
            if ((base/8+1)%1024==0) $display("Checked %0d / 8192 tiles",base/8+1);
        end
        $display("PASS %s: 524288 outputs, 8192 tiles, all eight filters",name);
    endtask

    initial begin
        timing_file=$fopen("street_post_tile_timing.csv","w");
        metrics_file=$fopen("street_post_metrics.csv","w");
        if (!timing_file || !metrics_file) $fatal(1,"Cannot open metrics files");
        $fdisplay(timing_file,"tile,start_edge,valid_edge,latency_cycles");
        output_file=$fopen("street_post_outputs.csv","w");
        if (!output_file) $fatal(1,"Could not open output file");
        $fdisplay(output_file,"image,y,x,filter,value");
        $readmemh("../testbench/data/street_256/weights.mem",weights);
        repeat (2) @(negedge clk);
        rst=0;
        for (int c=0; c<8; c++) begin
            @(negedge clk);
            bias_wr_en=1; bias_addr=c; bias_data=0;
        end
        @(negedge clk);
        bias_wr_en=0; shift_wr_en=1;
        @(negedge clk);
        shift_wr_en=0;
        run_image("street");

        $fclose(output_file);
        $fclose(timing_file);
        if (comparisons != 524288 || accepted != 8192 ||
            feed_cycles != 8192*27 || drain_cycles != 8192*14 ||
            input_writes != 8192*27 || weight_writes != 27 ||
            capture_cycles != 8192 || read_cycles != 8192*27)
            $fatal(1,"Performance counter totals incorrect");
        $fdisplay(metrics_file,"metric,value");
        $fdisplay(metrics_file,"total_cycles,%0d",total_cycles);
        $fdisplay(metrics_file,"global_reset_cycles,%0d",reset_cycles);
        $fdisplay(metrics_file,"idle_cycles,%0d",idle_cycles);
        $fdisplay(metrics_file,"init_cycles,%0d",init_cycles);
        $fdisplay(metrics_file,"input_write_words,%0d",input_writes);
        $fdisplay(metrics_file,"weight_write_words,%0d",weight_writes);
        $fdisplay(metrics_file,"read_cycles_per_buffer,%0d",read_cycles);
        $fdisplay(metrics_file,"feed_cycles,%0d",feed_cycles);
        $fdisplay(metrics_file,"drain_cycles,%0d",drain_cycles);
        $fdisplay(metrics_file,"post_last_input_cycles,%0d",capture_cycles);
        $fdisplay(metrics_file,"done_cycles,%0d",done_cycles);
        $fdisplay(metrics_file,"accepted_tiles,%0d",accepted);
        $fdisplay(metrics_file,"exact_int8_comparisons,%0d",comparisons);
        $fdisplay(metrics_file,"clock_period_ns,10");
        $fdisplay(metrics_file,"simulation_end_ns,%0d",$time);
        $fclose(metrics_file);
        $display("PASS: all 524288 image outputs match postprocessed convolution references");
        $finish;
    end
    initial begin
        #20000000;
        $fatal(1,"Timeout");
    end
endmodule

