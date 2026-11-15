`timescale 1ns / 1ps

module ConvEngineTop (
    input logic clk, rst,

    // Buffer loading
    input logic input_wr_en, weight_wr_en,
    input logic [13:0] load_addr,
    input logic [63:0] load_data,

    // Tile configuration
    input logic start,
    input logic [13:0] k_words,
    input logic [3:0] active_rows, active_cols,

    input logic bias_wr_en,
    input logic [2:0] bias_addr,
    input logic signed [31:0] bias_data,
    input logic shift_wr_en,
    input logic [3:0] shift_data,
    input logic activation_en,

    // Output handshake
    input logic out_ready,
    output logic start_ready, busy, config_error, out_valid,
    output logic signed [7:0] results [0:7][0:7]
);

    wire signed [7:0] input_data [0:7];
    wire signed [7:0] weight_data [0:7];
    wire signed [31:0] array_acc [0:7][0:7];
    wire signed [7:0] array_a [0:7], array_b [0:7];
    wire buffer_rd_en, array_rst, array_en, feed_valid;
    wire [13:0] buffer_addr, memory_addr;
    wire load_enable, config_enable;
    wire [7:0] post_in_valid, post_out_valid;
    wire [2:0] post_in_row [0:7], post_out_row [0:7];
    wire post_in_bank, post_in_last, post_out_bank, post_out_last;
    wire signed [31:0] post_acc [0:7];
    wire signed [7:0] post_data [0:7];
    logic activation_latched;
    wire accept_tile = start && start_ready &&
                       k_words >= 1 && k_words <= 9216 &&
                       active_rows >= 1 && active_rows <= 8 &&
                       active_cols >= 1 && active_cols <= 8;
    assign config_enable = start_ready && !start;


    assign load_enable = start_ready && !start && (load_addr < 14'd9216); // High when array is IDLE and not starting, only safe time to load into buffers
    assign memory_addr = start_ready ? load_addr : buffer_addr;
    // write address if IDLE, use read addr if computing

    SystolicController #(.ENABLE_POST(1)) controller (
        .clk(clk), .rst(rst), .start(start),
        // One result bank; controller admits no new tile until acknowledgment.
        .post_bank_available(1'b1), .tile_bank(1'b0),
        .post_out_valid(post_out_valid), .post_out_last(post_out_last), .post_out_bank(post_out_bank),
        .post_in_valid(post_in_valid), .post_in_row(post_in_row),
        .post_in_bank(post_in_bank), .post_in_last(post_in_last),
        .k_words(k_words), .active_rows(active_rows), .active_cols(active_cols),
        .out_ready(out_ready), .start_ready(start_ready), .busy(busy),
        .config_error(config_error), .out_valid(out_valid),
        .buffer_rd_en(buffer_rd_en), .buffer_addr(buffer_addr),
        .array_rst(array_rst), .array_en(array_en),
        .feed_valid(feed_valid), .capture_en()
    );

    InputBuffer input_buffer (
        .clk(clk),
        .wr_en(input_wr_en && load_enable),
        .rd_en(buffer_rd_en),
        .addr(memory_addr),
        .data_in(load_data),
        .data_out(input_data)
    );

    InputBuffer weight_buffer (
        .clk(clk),
        .wr_en(weight_wr_en && load_enable),
        .rd_en(buffer_rd_en),
        .addr(memory_addr),
        .data_in(load_data),
        .data_out(weight_data)
    );

    // Load unused lanes as zero; inject zeros into the lane delays during drain.
    // Feed_Valid = 1 if we are in FEED
    for (genvar lane = 0; lane < 8; lane++) begin
        assign array_a[lane] = feed_valid ? input_data[lane] : 8'sd0;
        assign array_b[lane] = feed_valid ? weight_data[lane] : 8'sd0;
    end

    SystolicArray systolic_array (
        .clk(clk),
        .rst(array_rst),
        .en(array_en),
        .clear(1'b0),
        .inputA(array_a),
        .inputB(array_b),
        .arrayAcc(array_acc)
    );

    for (genvar c = 0; c < 8; c++) begin
        assign post_acc[c] = post_in_valid[c] ? array_acc[post_in_row[c]][c] : 32'sd0;
    end

    PostProcessing post_processor (
        .clk(clk), .rst(rst),
        .bias_wr_en(bias_wr_en && config_enable), .bias_addr(bias_addr), .bias_data(bias_data),
        .shift_wr_en(shift_wr_en && config_enable), .shift_data(shift_data),
        .in_valid(post_in_valid), .activation_en(activation_latched), .acc_in(post_acc),
        .in_row(post_in_row), .in_bank(post_in_bank), .in_last(post_in_last),
        .out_valid(post_out_valid), .biased_out(), .quantized_out(post_data),
        .out_row(post_out_row), .out_bank(post_out_bank), .out_last(post_out_last)
    );

    always_ff @(posedge clk or posedge rst) begin
        if (rst) activation_latched <= 0;
        else if (accept_tile) activation_latched <= activation_en;
    end

    // Assemble streamed lanes into one tile; hold until receiver acknowledgment.
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            for (int r = 0; r < 8; r++)
                for (int c = 0; c < 8; c++)
                    results[r][c] <= 0;
        end else if (accept_tile) begin
            for (int r = 0; r < 8; r++)
                for (int c = 0; c < 8; c++) results[r][c] <= 0;
        end else begin
            for (int c = 0; c < 8; c++)
                if (post_out_valid[c] && !post_out_bank)
                    results[post_out_row[c]][c] <= post_data[c];
        end
    end

endmodule
