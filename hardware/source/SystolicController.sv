`timescale 1ns / 1ps

// Module for State Machine Control of Systolic array given k "words" or # of inputs / weights for a given filter and layer.
// Feed State: K clocks
// Drain : R + C - 2, where R/C are the active rows/cols being used for the tile

// One tile, with synchronous one-cycle buffer reads. Both buffers start at 0.
// Lane staggering belongs in the datapath: lane 0 bypasses the delay chain,
// lane n has n registers. Advance delays whenever array_en is high.

// Josh: Deferred timing concern (2026-11-14): k_latched - 1 and drain_cycles - 1
// may add combinational delay to comparison/control paths and affect timing
// closure. Impact is unverified; evaluate synthesis/implementation timing
// reports later. Leave these expressions unchanged until that evaluation.
module SystolicController #(parameter bit ENABLE_POST = 1) (
    input  logic clk, rst,
    input  logic start,
    
    // Tile calculation config
    input  logic [13:0] k_words,
    input  logic [3:0] active_rows, active_cols,
    
    // State machine output, outputs & signals
    input logic post_bank_available, tile_bank,
    input logic [7:0] post_out_valid,
    input logic post_out_last, post_out_bank,
    output logic [7:0] post_in_valid,
    output logic [2:0] post_in_row [0:7],
    output logic post_in_bank, post_in_last,

    input  logic out_ready, // receiver acknowledgment
    output logic start_ready, busy, config_error, // status
    output logic feed_valid, capture_en, out_valid,
    
    // Buffer (mem) and Systolic Array enables
    output logic buffer_rd_en,
    output logic [13:0] buffer_addr,
    output logic array_rst, array_en
);
    typedef enum logic [2:0] {
        IDLE, INIT, PRIME, FEED, DRAIN, CAPTURE, POST_WAIT, DONE
    } state_t;
    state_t state;
    logic [13:0] k_latched, feed_count;
    logic [4:0] drain_cycles, drain_count;
    logic config_ok;
    logic [3:0] rows_latched, cols_latched;
    logic bank_latched;
    wire bank_available = !ENABLE_POST || post_bank_available;
    wire post_finished = post_out_last && (|post_out_valid) &&
                         (post_out_bank == bank_latched);

    // gives error if provided parameters no workie
    assign config_ok = (k_words >= 1 && k_words <= 9216 &&
                        active_rows >= 1 && active_rows <= 8 &&
                        active_cols >= 1 && active_cols <= 8);

    // State, configuration, and counters update only at clock edges.
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= IDLE;
            k_latched <= 0;
            feed_count <= 0;
            drain_cycles <= 0;
            drain_count <= 0;
            config_error <= 0;
            rows_latched <= 0;
            cols_latched <= 0;
            bank_latched <= 0;
            post_in_valid <= 0;
            for (int c = 0; c < 8; c++) post_in_row[c] <= 0;
        end else begin
            // Registers hold their values unless assigned in the active state.
            case (state)
                IDLE: begin
                    post_in_valid <= 0;
                    for (int c = 0; c < 8; c++) post_in_row[c] <= 0;
                    // Data operations
                    config_error <= start && bank_available && !config_ok;
                    if (start && bank_available && config_ok) begin
                        k_latched <= k_words;
                        rows_latched <= active_rows;
                        cols_latched <= active_cols;
                        bank_latched <= tile_bank;
                        drain_cycles <= {1'b0, active_rows} + {1'b0, active_cols} - 5'd2;
                    end
                    // Transition
                    if (start && bank_available && config_ok) state <= INIT;
                end
                INIT: begin
                    post_in_valid <= 0;
                    for (int c = 0; c < 8; c++) post_in_row[c] <= 0;
                    // Data operations
                    config_error <= 0;
                    feed_count <= 0;
                    drain_count <= 0;

                    // Transition
                    state <= PRIME;
                end

                PRIME: begin
                    post_in_valid <= 0;
                    for (int c = 0; c < 8; c++) post_in_row[c] <= 0;
                    config_error <= 0;
                    state <= FEED;
                end

                FEED: begin
                    post_in_valid <= 0;
                    for (int c = 0; c < 8; c++) post_in_row[c] <= 0;
                    // Final FEED edge completes [0][0]; capture it next edge.
                    if (ENABLE_POST && feed_count == k_latched - 1'b1)
                        post_in_valid[0] <= 1;

                    // Data operations
                    config_error <= 0;
                    if (feed_count < k_latched - 1'b1)
                        feed_count <= feed_count + 1'b1;

                    // Transition
                    if (feed_count == k_latched - 1'b1) begin
                        if (drain_cycles == 0) state <= CAPTURE;
                        else state <= DRAIN;
                    end
                end

                DRAIN: begin
                    // This edge consumes diagonal j; register tags for j+1.
                    for (int c = 0; c < 8; c++) begin
                        post_in_valid[c] <= 0;
                        post_in_row[c] <= 0;
                        if (ENABLE_POST && (c < cols_latched) &&
                            ((drain_count + 5'd1) >= c) &&
                            ((drain_count + 5'd1 - c) < rows_latched)) begin
                            post_in_valid[c] <= 1;
                            post_in_row[c] <= drain_count + 5'd1 - c;
                        end
                    end

                    // Data operations
                    config_error <= 0;
                    if (drain_count < drain_cycles - 1'b1)
                        drain_count <= drain_count + 1'b1;

                    // Transition
                    if (drain_count == drain_cycles - 1'b1)
                        state <= CAPTURE;
                end

                CAPTURE: begin
                    post_in_valid <= 0;
                    for (int c = 0; c < 8; c++) post_in_row[c] <= 0;
                    config_error <= 0;
                    if (ENABLE_POST) state <= POST_WAIT;
                    else state <= DONE;
                end

                POST_WAIT: begin
                    post_in_valid <= 0;
                    for (int c = 0; c < 8; c++) post_in_row[c] <= 0;
                    config_error <= 0;
                    if (post_finished) state <= DONE;
                end

                DONE: begin
                    post_in_valid <= 0;
                    for (int c = 0; c < 8; c++) post_in_row[c] <= 0;
                    config_error <= 0;
                    if (out_ready) state <= IDLE;
                end

                default: begin
                    post_in_valid <= 0;
                    for (int c = 0; c < 8; c++) post_in_row[c] <= 0;
                    config_error <= 0;
                    state <= IDLE;
                end
            endcase
        end
    end

    // Combinational output decoding; enum names must be compared with state.
    always_comb begin
        start_ready = !rst && (state == IDLE) && bank_available;
        busy = rst || (state != IDLE);
        array_en = !rst && ((state == FEED) || (state == DRAIN));
        feed_valid = !rst && (state == FEED);
        capture_en = !rst && !ENABLE_POST && (state == CAPTURE);
        out_valid = !rst && (state == DONE);

        // Also reset on an unused state encoding, preserving default recovery.
        array_rst = rst || (state == INIT) ||
                    !((state == IDLE) || (state == PRIME) ||
                      (state == FEED) || (state == DRAIN) ||
                      (state == CAPTURE) || (state == POST_WAIT) || (state == DONE));

        post_in_bank = bank_latched;
        post_in_last = ENABLE_POST && !rst && (state == CAPTURE) && (|post_in_valid);

        // PRIME requests word 0; FEED requests the next word, except at the end.
        buffer_rd_en = !rst && ((state == PRIME) ||
                       ((state == FEED) && (feed_count != k_latched - 1'b1)));
        buffer_addr = (buffer_rd_en && (state == FEED)) ?
                      feed_count + 1'b1 : 14'd0;
        // feed_valid=0 selects zeros BEFORE the lane delays during DRAIN.
    end
endmodule
