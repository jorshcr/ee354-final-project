`timescale 1ns / 1ps

module ConvEngineTop_tb;
    logic clk = 0, rst = 1;
    logic input_wr_en = 0, weight_wr_en = 0;
    logic [13:0] load_addr = 0;
    logic [63:0] load_data = 0;
    logic start = 0, out_ready = 0;
    logic [13:0] k_words = 0;
    logic [3:0] active_rows = 0, active_cols = 0;
    wire start_ready, busy, config_error, out_valid;
    wire signed [7:0] results [0:7][0:7];
    logic signed [7:0] matrix_a [0:7][0:26];
    logic signed [7:0] matrix_b [0:26][0:7];
    integer expected [0:7][0:7];

    logic bias_wr_en=0, shift_wr_en=0, activation_en=0;
    logic [2:0] bias_addr=0;
    logic signed [31:0] bias_data=0;
    logic [3:0] shift_data=0;
    integer test_bias [0:7];
    ConvEngineTop dut (.*);
    always #5 clk = ~clk;

    task automatic load_word(
        input bit is_weight,
        input logic [13:0] address,
        input logic [63:0] data
    );
        @(negedge clk);
        if (start_ready !== 1'b1 || start || rst)
            $fatal(1, "Attempted load while engine unavailable");
        load_addr = address;
        load_data = data;
        input_wr_en = !is_weight;
        weight_wr_en = is_weight;
        @(negedge clk);
        input_wr_en = 0;
        weight_wr_en = 0;
    endtask

    // Small matrix tests: A is rows x depth, B is depth x cols.
    task automatic load_tile(
        input int rows, cols, depth,
        input logic signed [7:0] a [0:7][0:26],
        input logic signed [7:0] b [0:26][0:7]
    );
        logic [63:0] a_word, b_word;
        if (rows < 1 || rows > 8 || cols < 1 || cols > 8 ||
            depth < 1 || depth > 27)
            $fatal(1, "Invalid tile dimensions");
        for (int k = 0; k < depth; k++) begin
            a_word = '0;
            b_word = '0;
            for (int lane = 0; lane < 8; lane++) begin
                if (lane < rows) a_word[8*lane +: 8] = a[lane][k];
                if (lane < cols) b_word[8*lane +: 8] = b[k][lane];
            end
            load_word(0, k, a_word);
            load_word(1, k, b_word);
        end
    endtask

    task automatic check_results;
        for (int r = 0; r < 8; r++)
            for (int c = 0; c < 8; c++)
                if (results[r][c] !== expected[r][c])
                    $fatal(1, "Result [%0d][%0d]: expected %0d, got %0d",
                           r, c, expected[r][c], results[r][c]);
    endtask

    task automatic prepare_case(input int id, output int rows, cols, depth);
        for (int r = 0; r < 8; r++)
            for (int k = 0; k < 27; k++) begin
                matrix_a[r][k] = 0;
                matrix_b[k][r] = 0;
            end
        case (id)
            1: begin
                rows=1; cols=1; depth=1;
                matrix_a[0][0]=-128; matrix_b[0][0]=-128;
            end
            2: begin
                rows=1; cols=8; depth=1;
                matrix_a[0][0]=3;
                for (int c=0; c<8; c++) matrix_b[0][c]=c-4;
            end
            3: begin
                rows=8; cols=1; depth=1;
                for (int r=0; r<8; r++) matrix_a[r][0]=r-4;
                matrix_b[0][0]=-2;
            end
            4: begin
                rows=1; cols=8; depth=8;
                for (int k=0; k<8; k++) begin
                    matrix_a[0][k]=1; matrix_b[k][k]=1;
                end
            end
            5: begin
                rows=8; cols=1; depth=8;
                for (int k=0; k<8; k++) begin
                    matrix_a[k][k]=1; matrix_b[k][0]=k+1;
                end
            end
            6: begin
                rows=2; cols=2; depth=2;
                matrix_a[0][0]=1; matrix_a[0][1]=2;
                matrix_a[1][0]=3; matrix_a[1][1]=4;
                matrix_b[0][0]=5; matrix_b[0][1]=6;
                matrix_b[1][0]=7; matrix_b[1][1]=8;
            end
            7: begin
                rows=3; cols=2; depth=4;
                for (int r=0; r<rows; r++)
                    for (int k=0; k<depth; k++)
                        matrix_a[r][k]=(r*depth+k)%9+1;
                for (int k=0; k<depth; k++)
                    for (int c=0; c<cols; c++)
                        matrix_b[k][c]=(k*cols+c+4)%9+1;
            end
            8: begin
                rows=8; cols=8; depth=8;
                for (int r=0; r<rows; r++)
                    for (int k=0; k<depth; k++)
                        matrix_a[r][k]=((r+k)%2==0) ? -128 : 127;
                for (int k=0; k<depth; k++)
                    for (int c=0; c<cols; c++)
                        matrix_b[k][c]=((k+c)%3==0) ? 127 :
                                      (((k+c)%3==1) ? -128 : 0);
            end
            9, 10: begin
                rows=(id==9) ? 8 : 1; cols=3; depth=27;
                for (int r=0; r<rows; r++)
                    for (int k=0; k<depth; k++) matrix_a[r][k]=1;
                for (int k=0; k<depth; k++) begin
                    matrix_b[k][0]=1; matrix_b[k][1]=-1;
                end
            end
            default: $fatal(1, "Unknown case");
        endcase
    endtask

    function automatic integer quantize(input longint signed value,
                                        input bit activate, input int shift);
        longint signed magnitude, numerator, denominator, whole, remainder;
        magnitude=(value<0) ? -value : value;
        numerator=magnitude*((activate && value<0) ? 104858 : 1048576);
        denominator=64'd1 << (20+shift);
        whole=numerator/denominator; remainder=numerator%denominator;
        if (2*remainder>denominator || (2*remainder==denominator && whole%2==1)) whole++;
        if (value<0) whole=-whole;
        if (whole>127) whole=127;
        if (whole< -128) whole=-128;
        return whole;
    endfunction

    task automatic run_case(input int id, input bit use_post_config);
        int rows, cols, depth, av, bv, cycles;
        prepare_case(id, rows, cols, depth);
        for (int c=0;c<8;c++) begin
            @(negedge clk);
            bias_wr_en=1; bias_addr=c;
            test_bias[c]=use_post_config ? (c-3)*19 : 0;
            bias_data=test_bias[c];
        end
        @(negedge clk);
        bias_wr_en=0; shift_wr_en=1;
        shift_data=use_post_config ? 2 : 0;
        activation_en=use_post_config;
        @(negedge clk);
        shift_wr_en=0;
        // Independent reference from logical matrices, before word packing.
        for (int r=0; r<8; r++)
            for (int c=0; c<8; c++) begin
                expected[r][c]=0;
                if (r<rows && c<cols)
                    for (int k=0; k<depth; k++) begin
                        av=matrix_a[r][k]; bv=matrix_b[k][c];
                        expected[r][c]+=av*bv;
                    end
            end
        for (int r=0;r<rows;r++)
            for (int c=0;c<cols;c++)
                expected[r][c]=quantize(expected[r][c]+test_bias[c],activation_en,shift_data);
        load_tile(rows, cols, depth, matrix_a, matrix_b);
        @(negedge clk);
        k_words=depth; active_rows=rows; active_cols=cols; start=1;
        @(negedge clk);
        start=0;
        // Configuration must be latched/gated while a tile is processing.
        activation_en=~activation_en;
        bias_wr_en=1; bias_addr=0; bias_data=999;
        shift_wr_en=1; shift_data=15;
        if (busy !== 1'b1 || config_error !== 1'b0)
            $fatal(1, "Case %0d: start rejected", id);
        cycles=0;
        while (out_valid !== 1'b1) begin
            @(negedge clk);
            cycles++;
            if (config_error !== 1'b0 || cycles>depth+rows+cols+10)
                $fatal(1, "Case %0d: error or timeout", id);
        end
        bias_wr_en=0; shift_wr_en=0;
        check_results();
        $display("Case %0d: %0dx%0d output, K=%0d", id, rows, cols, depth);
        for (int r=0; r<rows; r++) begin
            $write("[ ");
            for (int c=0; c<cols; c++) $write("%0d ",results[r][c]);
            $write("]\n");
        end
        repeat (3) begin
            @(negedge clk);
            if (out_valid !== 1'b1 || busy !== 1'b1)
                $fatal(1, "Output handshake did not hold");
            check_results();
        end
        out_ready=1;
        @(negedge clk);
        out_ready=0;
        if (start_ready !== 1'b1 || busy !== 1'b0 || out_valid !== 1'b0)
            $fatal(1, "Engine did not return to idle");
        $display("PASS case %0d: all 64 outputs and handshake checked", id);
    endtask

    initial begin
        repeat (2) @(negedge clk);
        rst=0;
        for (int id=1; id<=10; id++) run_case(id,0);
        for (int id=1; id<=10; id++) run_case(id,1);
        $display("PASS: all 20 postprocessed tiles, no external reset between tiles");
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "Top-level test timed out");
    end
endmodule
