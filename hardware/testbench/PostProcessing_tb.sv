`timescale 1ns / 1ps
module PostProcessing_tb;
    logic clk=0, rst=1, bias_wr_en=0, shift_wr_en=0, activation_en=0;
    logic [2:0] bias_addr=0;
    logic signed [31:0] bias_data=0;
    logic [3:0] shift_data=0;
    logic [7:0] in_valid=0;
    logic signed [31:0] acc_in [0:7];
    logic [2:0] in_row [0:7];
    logic in_bank=0, in_last=0;
    wire [7:0] out_valid;
    wire signed [32:0] biased_out [0:7];
    wire signed [7:0] quantized_out [0:7];
    wire [2:0] out_row [0:7];
    wire out_bank, out_last;
    PostProcessing dut (.*);
    always #5 clk=~clk;

    function automatic integer reference_value(input longint signed v,
                                               input int shift, input bit act, input bit fixed_scale);
        real scaled, lower, fraction;
        longint signed rounded;
        scaled=real'(v)/(2.0**shift);
        if (act && v<0) scaled=fixed_scale ? scaled*(104858.0/1048576.0) : scaled/10.0;
        lower=$floor(scaled);
        fraction=scaled-lower;
        rounded=longint'(lower);
        if (fraction>0.5 || (fraction==0.5 && rounded%2!=0)) rounded++;
        if (rounded>127) return 127;
        if (rounded< -128) return -128;
        return integer'(rounded);
    endfunction

    integer differences=0, max_error=0, delta;
    integer pending_ideal[0:3][0:7], held_ideal[0:7];
    integer model_bias[0:7], model_shift=0;
    longint signed model_sum[0:7];
    integer pending_value[0:3][0:7], held_value[0:7];
    logic [2:0] pending_row[0:3][0:7], held_row[0:7];
    logic [7:0] pending_valid[0:3], expected_valid=0;
    bit pending_bank[0:3], held_bank=0, pending_last[0:3], expected_last=0;
    integer lane_checks=0, outputs=0, tiles=0, issued=0, issued_tiles=0;

    always @(posedge clk) begin
        if (rst) begin
            expected_valid=0; held_bank=0; expected_last=0; model_shift=0;
            for (int c=0;c<8;c++) begin
                model_bias[c]=0; model_sum[c]=0; held_ideal[c]=0; held_value[c]=0; held_row[c]=0;
            end
            for (int stage=0;stage<4;stage++) begin
                pending_valid[stage]=0; pending_bank[stage]=0; pending_last[stage]=0;
                for (int c=0;c<8;c++) begin pending_ideal[stage][c]=0; pending_value[stage][c]=0; pending_row[stage][c]=0; end
            end
        end else begin
            expected_valid=pending_valid[3]; expected_last=pending_last[3];
            if (|pending_valid[3]) held_bank=pending_bank[3];
            if (pending_last[3]) tiles++;
            for (int c=0;c<8;c++) begin
                if (pending_valid[3][c]) begin
                    held_ideal[c]=pending_ideal[3][c]; held_value[c]=pending_value[3][c]; held_row[c]=pending_row[3][c]; outputs++;
                end
            end
            for (int stage=3;stage>0;stage--) begin
                pending_valid[stage]=pending_valid[stage-1];
                pending_bank[stage]=pending_bank[stage-1]; pending_last[stage]=pending_last[stage-1];
                for (int c=0;c<8;c++) begin
                    pending_ideal[stage][c]=pending_ideal[stage-1][c];
                    pending_value[stage][c]=pending_value[stage-1][c];
                    pending_row[stage][c]=pending_row[stage-1][c];
                end
            end
            for (int c=0;c<8;c++) begin
                if (in_valid[c]) begin
                    model_sum[c]=longint'($signed(acc_in[c]))+longint'(model_bias[c]);
                    pending_value[0][c]=reference_value(model_sum[c],model_shift,activation_en,1);
                    pending_ideal[0][c]=reference_value(model_sum[c],model_shift,activation_en,0);
                    pending_row[0][c]=in_row[c]; issued++;
                end
            end
            pending_valid[0]=in_valid; pending_last[0]=in_last && (|in_valid);
            if (pending_last[0]) issued_tiles++;
            if (|in_valid) pending_bank[0]=in_bank;
            if (shift_wr_en) model_shift=shift_data;
            if (bias_wr_en) model_bias[bias_addr]=bias_data;
        end
        #1ps;
        if (out_valid !== expected_valid || out_last !== expected_last || out_bank !== held_bank)
            $fatal(1,"Valid/last/bank alignment mismatch");
        for (int c=0;c<8;c++) begin
            if (quantized_out[c] !== held_value[c][7:0] || out_row[c] !== held_row[c] ||
                biased_out[c] !== model_sum[c][32:0])
                $fatal(1,"Lane %0d mismatch: output %0d expected %0d",c,quantized_out[c],held_value[c]);
            if (expected_valid[c]) begin
                delta=integer'($signed(quantized_out[c]))-held_ideal[c];
                if (delta<0) delta=-delta;
                if (delta!=0) differences++;
                if (delta>max_error) max_error=delta;
            end
            lane_checks++;
        end
    end

    // Each cycle supplies the newly completed diagonal, independently of the FSM.
    task automatic diagonal_tile(input int rows, cols, shift, input bit act);
        longint signed denominator, value;
        int row, target;
        activation_en=act;
        for (int d=0;d<rows+cols-1;d++) begin
            in_valid=0; in_last=(d==rows+cols-2);
            for (int c=0;c<8;c++) begin
                row=d-c;
                if (c<cols && row>=0 && row<rows) begin
                    in_valid[c]=1; in_row[c]=row;
                    case ((row*8+c)%8)
                        0: target=0; 1: target=1; 2: target=2; 3: target=3;
                        4: target=126; 5: target=127; 6: target=128; 7: target=129;
                    endcase
                    denominator=64'd1<<shift;
                    if (act && row%2) denominator*=10;
                    value=target*denominator+denominator/2+((row+c)%3)-1;
                    if (row%2) value=-value;
                    acc_in[c]=value-(c-4);
                end
            end
            @(negedge clk);
        end
        in_bank=~in_bank;
    endtask

    initial begin
        for (int c=0;c<8;c++) begin acc_in[c]=0; in_row[c]=0; end
        repeat (2) @(negedge clk);
        rst=0;
        for (int c=0;c<8;c++) begin
            bias_wr_en=1; bias_addr=c; bias_data=c-4;
            @(negedge clk);
        end
        bias_wr_en=0;
        for (int shift=0;shift<16;shift++) begin
            in_valid=0; in_last=0; shift_wr_en=1; shift_data=shift;
            @(negedge clk);
            shift_wr_en=0;
            for (int act=0;act<2;act++)
                for (int rows=1;rows<=8;rows++)
                    for (int cols=1;cols<=8;cols++)
                        diagonal_tile(rows,cols,shift,act);
            in_valid=0; in_last=1; // Invalid last must not produce completion.
            repeat (5) @(negedge clk);
        end
        in_valid=0; in_last=0; shift_wr_en=1; shift_data=7;
        for (int c=0;c<8;c++) begin
            bias_wr_en=1; bias_addr=c;
            bias_data=(c%2) ? 32'sh80000000 : 32'sh7fffffff;
            acc_in[c]=bias_data; in_row[c]=c;
            @(negedge clk);
        end
        bias_wr_en=0; shift_wr_en=0;
        for (int act=0;act<2;act++) begin
            activation_en=act; in_valid=8'hff; in_last=1;
            @(negedge clk);
        end
        in_valid=0; in_last=0;
        repeat (5) @(negedge clk);
        if (outputs!=41488 || tiles!=2050 || outputs!=issued || tiles!=issued_tiles)
            $fatal(1,"Missing/extra results: outputs=%0d tiles=%0d",outputs,tiles);
        // Full-width randomized inputs, compared against the fixed-point reference.
        for (int n=0;n<2048;n++) begin
            in_valid=8'hff; in_last=1; in_bank=n%2; activation_en=n%2;
            shift_wr_en=1; shift_data=n%16;
            for (int c=0;c<8;c++) begin acc_in[c]=$random; in_row[c]=c; end
            @(negedge clk);
        end
        in_valid=0; in_last=0; shift_wr_en=0;
        repeat (5) @(negedge clk);
        if (outputs!=57872 || tiles!=4098 || outputs!=issued || tiles!=issued_tiles)
            $fatal(1,"Random stream missing/extra results");
        // Reset while a diagonal is in flight must flush data and metadata.
        in_valid=8'hff; in_last=1;
        @(negedge clk);
        rst=1; in_valid=0; in_last=0;
        @(negedge clk);
        rst=0;
        repeat (5) @(negedge clk);
        $display("PASS: %0d lane checks; 57872 results across 4098 tiles, fixed-point reference checks, all 1..8 shapes, shifts 0..15, both activation modes, bank/row/last alignment, bubbles, extremes, reset flush",lane_checks);
        $display("Exact /10 comparison: %0d / %0d outputs differ; max absolute INT8 error = %0d", differences,outputs,max_error);
        $finish;
    end
    initial begin #1000000; $fatal(1,"Timeout"); end
endmodule

