`timescale 1ns / 1ps
module ConvEngineImages_tb;
    logic clk=0, rst=1, input_wr_en=0, weight_wr_en=0;
    logic [13:0] load_addr=0, k_words=27;
    logic [63:0] load_data=0;
    logic start=0, out_ready=0;
    logic [3:0] active_rows=8, active_cols=3;
    wire start_ready, busy, config_error, out_valid;
    wire signed [31:0] results [0:7][0:7];
    logic signed [7:0] pixels [0:242], weights [0:80];
    logic signed [31:0] expected [0:146];
    integer output_file;
    ConvEngineTop dut (.*);
    always #5 clk=~clk;

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
        int rows, pos, y, x, ky, kx, channel, clocks;
        $readmemh({"../testbench/data/image_tests/",name,".mem"},pixels);
        $readmemh({"../testbench/data/image_tests/",name,"_expected.mem"},expected);
        // Load filters once; reuse them across all seven tiles.
        for (int k=0; k<27; k++) begin
            word_data='0;
            for (int f=0; f<3; f++) word_data[8*f +: 8]=weights[f*27+k];
            load_word(1,k,word_data);
        end
        for (int base=0; base<49; base+=8) begin
            rows=(49-base<8) ? 49-base : 8;
            for (int k=0; k<27; k++) begin
                word_data='0;
                ky=k/9; kx=(k/3)%3; channel=k%3;
                for (int lane=0; lane<rows; lane++) begin
                    pos=base+lane; y=pos/7; x=pos%7;
                    word_data[8*lane +: 8]=pixels[((y+ky)*9+x+kx)*3+channel];
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
                    if (r<rows && c<3) begin
                        pos=base+r;
                        if (results[r][c] !== expected[pos*3+c])
                            $fatal(1,"%s pos=%0d filter=%0d expected=%0d actual=%0d",
                                   name,pos,c,expected[pos*3+c],results[r][c]);
                        $fdisplay(output_file,"%s,%0d,%0d,%0d,%0d",name,pos/7,pos%7,c,results[r][c]);
                    end else if (results[r][c] !== 32'sd0)
                        $fatal(1,"Unused output nonzero");
                end
            end
            out_ready=1;
            @(negedge clk);
            out_ready=0;
            if (start_ready !== 1'b1) $fatal(1,"Handshake failed");
        end
        $display("PASS %s: 147 outputs, 7 tiles, all three filters",name);
    endtask

    initial begin
        output_file=$fopen("image_outputs.csv","w");
        if (!output_file) $fatal(1,"Could not open output file");
        $fdisplay(output_file,"image,y,x,filter,value");
        $readmemh("../testbench/data/image_tests/weights.mem",weights);
        repeat (2) @(negedge clk);
        rst=0;
        run_image("heart");
        run_image("staircase");
        $fclose(output_file);
        $display("PASS: all 294 image outputs match direct convolution references");
        $finish;
    end
    initial begin
        #100000;
        $fatal(1,"Timeout");
    end
endmodule
