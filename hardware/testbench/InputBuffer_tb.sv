`timescale 1ns / 1ps

module InputBuffer_tb;
    logic clk = 0, wr_en = 0, rd_en = 0;
    logic [13:0] addr = 0;
    logic [63:0] data_in = 0;
    wire signed [7:0] data_out [0:7];
    logic [63:0] reference_mem [0:9215];
    logic [63:0] expected_out;
    bit output_known = 0;
    integer checks = 0;
    InputBuffer dut (.*);
    always #5 clk = ~clk;

    // Different bytes exercise lane order, signed boundaries, and addresses.
    function automatic logic [63:0] pattern(input int address, seed);
        for (int lane = 0; lane < 8; lane++)
            pattern[8*lane +: 8] = (address * 37 + lane * 53 + seed);
    endfunction

    task automatic cycle(input bit write_en, read_en,
                         input int address, input logic [63:0] value);
        @(negedge clk);
        wr_en = write_en; rd_en = read_en;
        addr = address; data_in = value;
        // Reference reads precede writes: same-address collisions are read-first.
        if (read_en) begin
            expected_out = reference_mem[address];
            output_known = 1;
        end
        if (write_en) reference_mem[address] = value;
        @(posedge clk);
        #1;
        if (output_known) begin
            for (int lane = 0; lane < 8; lane++) begin
                if (data_out[lane] !== expected_out[8*lane +: 8])
                    $fatal(1, "addr=%0d lane=%0d write=%0b read=%0b expected=%h got=%h",
                           address, lane, write_en, read_en,
                           expected_out[8*lane +: 8], data_out[lane]);
                if (int'(data_out[lane]) != int'($signed(expected_out[8*lane +: 8])))
                    $fatal(1, "Signed interpretation failed at lane %0d", lane);
            end
            checks++;
        end
    endtask

    task automatic trial(input int k);
        for (int a = 0; a < k; a++)
            cycle(1, 0, a, pattern(a, k));
        for (int a = 0; a < k; a++)
            cycle(0, 1, a, '0);
        // Every collision must return the old word and store the new one.
        for (int a = 0; a < k; a++)
            cycle(1, 1, a, pattern(a, k + 127));
        for (int a = k-1; a >= 0; a--)
            cycle(0, 1, a, '0);
        cycle(0, 0, k-1, '1); // Disabled ports hold output and memory.
        cycle(0, 1, k-1, '0);
        $display("PASS InputBuffer K=%0d: writes, reads, collisions, hold, signed lanes", k);
    endtask

    initial begin
        trial(1);
        trial(8);
        trial(27);
        trial(257);
        trial(9216);
        $display("PASS InputBuffer: %0d checked cycles", checks);
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1, "InputBuffer test timed out");
    end
endmodule
