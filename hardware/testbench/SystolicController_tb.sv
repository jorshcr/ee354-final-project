`timescale 1ns / 1ps
module SystolicController_tb;
    logic clk = 0, rst = 1, start = 0, out_ready = 0;
    logic [13:0] k_words = 0;
    logic [3:0] active_rows = 0, active_cols = 0;
    wire start_ready, busy, config_error, buffer_rd_en;
    wire array_rst, array_en, feed_valid, capture_en, out_valid;
    wire [13:0] buffer_addr;
    integer reads, feeds, drains, captures, ticks;
    logic post_bank_available=0, tile_bank=0, post_out_last=0, post_out_bank=0;
    logic [7:0] post_out_valid=0;
    wire [7:0] post_in_valid;
    wire [2:0] post_in_row [0:7];
    wire post_in_bank, post_in_last;
    SystolicController #(.ENABLE_POST(0)) dut (.*);
    always #5 clk = ~clk;

    task automatic run_tile(input integer k, r, c);
        @(negedge clk);
        k_words = k; active_rows = r; active_cols = c; start = 1;
        @(negedge clk);
        start = 0;
        reads = 0; feeds = 0; drains = 0; captures = 0; ticks = 0;
        // Sample controls BEFORE each processing edge (as the datapath does).
        while (!out_valid) begin
            @(posedge clk);
            if (buffer_rd_en) begin
                if (buffer_addr !== reads[13:0])
                    $fatal(1, "Read address %0d, expected %0d", buffer_addr, reads);
                reads++;
            end
            if (array_en && feed_valid) feeds++;
            if (array_en && !feed_valid) drains++;
            if (capture_en) captures++;
            ticks++;
            if (ticks > k + 30) $fatal(1, "Controller timed out");
            @(negedge clk);
        end
        if (reads != k || feeds != k || drains != r+c-2 || captures != 1)
            $fatal(1, "Counts: reads=%0d feed=%0d drain=%0d capture=%0d",
                   reads, feeds, drains, captures);
        // Receiver stalls: controller must hold valid and stop all activity.
        repeat (3) begin
            @(negedge clk);
            if (!out_valid || !busy || array_en || buffer_rd_en || capture_en)
                $fatal(1, "DONE did not hold while receiver stalled");
        end
        out_ready = 1;
        @(negedge clk);
        out_ready = 0;
        if (!start_ready) $fatal(1, "Did not return to IDLE");
        $display("PASS K=%0d rows=%0d cols=%0d: feed=%0d drain=%0d", k,r,c,feeds,drains);
    endtask

    initial begin
        repeat (2) @(negedge clk);
        rst = 0;
        run_tile(16, 8, 8);
        run_tile(27, 8, 3);
        run_tile(27, 1, 3);
        run_tile(1, 1, 1);
        run_tile(9216, 8, 8);
        @(negedge clk);
        k_words = 0; start = 1;
        @(negedge clk);
        start = 0;
        if (!config_error || !start_ready || busy)
            $fatal(1, "Invalid configuration was not rejected");
        $display("PASS: invalid K rejected; all controller checks passed");
        $finish;
    end
endmodule
