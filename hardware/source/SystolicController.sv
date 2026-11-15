`timescale 1ns / 1ps

// One tile, with synchronous one-cycle buffer reads. Both buffers start at 0.
// Lane staggering belongs in the datapath: lane 0 bypasses the delay chain,
// lane n has n registers. Advance delays whenever array_en is high.
// Deferred timing concern (2026-11-14): k_latched - 1 and drain_cycles - 1
// may add combinational delay to comparison/control paths and affect timing
// closure. Impact is unverified; evaluate synthesis/implementation timing
// reports later. Leave these expressions unchanged until that evaluation.
module SystolicController (
    input  logic clk, rst,
    input  logic start,
    input  logic [13:0] k_words,
    input  logic [3:0] active_rows, active_cols,
    input  logic out_ready,
    output logic start_ready, busy, config_error,
    output logic buffer_rd_en,
    output logic [13:0] buffer_addr,
    output logic array_rst, array_en,
    output logic feed_valid, capture_en, out_valid
);
    typedef enum logic [2:0] {
        IDLE, INIT, PRIME, FEED, DRAIN, CAPTURE, DONE
    } state_t;
    state_t state;
    logic [13:0] k_latched, feed_count;
    logic [4:0] drain_cycles, drain_count;
    logic config_ok;

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
        end else begin
            // Registers hold their values unless assigned in the active state.
            case (state)
                IDLE: begin
                    // Data operations
                    config_error <= start && !config_ok;
                    if (start && config_ok) begin
                        k_latched <= k_words;
                        drain_cycles <= {1'b0, active_rows} + {1'b0, active_cols} - 5'd2;
                    end
                    // Transition
                    if (start && config_ok) state <= INIT;
                end
                INIT: begin
                    // Data operations
                    config_error <= 0;
                    feed_count <= 0;
                    drain_count <= 0;

                    // Transition
                    state <= PRIME;
                end

                PRIME: begin
                    config_error <= 0;
                    state <= FEED;
                end

                FEED: begin
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
                    // Data operations
                    config_error <= 0;
                    if (drain_count < drain_cycles - 1'b1)
                        drain_count <= drain_count + 1'b1;

                    // Transition
                    if (drain_count == drain_cycles - 1'b1)
                        state <= CAPTURE;
                end

                CAPTURE: begin
                    config_error <= 0;
                    state <= DONE;
                end

                DONE: begin
                    config_error <= 0;
                    if (out_ready) state <= IDLE;
                end

                default: begin
                    config_error <= 0;
                    state <= IDLE;
                end
            endcase
        end
    end

    // Combinational output decoding; enum names must be compared with state.
    always_comb begin
        start_ready = !rst && (state == IDLE);
        busy = !start_ready;
        array_en = !rst && ((state == FEED) || (state == DRAIN));
        feed_valid = !rst && (state == FEED);
        capture_en = !rst && (state == CAPTURE);
        out_valid = !rst && (state == DONE);

        // Also reset on an unused state encoding, preserving default recovery.
        array_rst = rst || (state == INIT) ||
                    !((state == IDLE) || (state == PRIME) ||
                      (state == FEED) || (state == DRAIN) ||
                      (state == CAPTURE) || (state == DONE));

        // PRIME requests word 0; FEED requests the next word, except at the end.
        buffer_rd_en = !rst && ((state == PRIME) ||
                       ((state == FEED) && (feed_count != k_latched - 1'b1)));
        buffer_addr = (buffer_rd_en && (state == FEED)) ?
                      feed_count + 1'b1 : 14'd0;
        // feed_valid=0 selects zeros BEFORE the lane delays during DRAIN.
    end
endmodule
