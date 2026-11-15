`timescale 1ns / 1ps

// Lane c always represents filter column c. Inputs are selected completed MACs.
// No backpressure: reserve an output tile bank before issuing any inputs.
module PostProcessing (
    input logic clk, rst,
    
    // Filter Bias and Layer Shifts 
    input logic bias_wr_en,
    input logic [2:0] bias_addr,
    input logic signed [31:0] bias_data,
    input logic shift_wr_en,
    input logic [3:0] shift_data,

    // MAC inputs
    input logic [7:0] in_valid,
    input logic activation_en,
    input logic signed [31:0] acc_in [0:7],
    input logic [2:0] in_row [0:7],
    input logic in_bank, in_last,
    
    // Post Processing outputs
    output logic [7:0] out_valid,
    output logic signed [32:0] biased_out [0:7],
    output logic signed [7:0] quantized_out [0:7],
    output logic [2:0] out_row [0:7],
    output logic out_bank, out_last
);
    // Stored from inputs
    logic signed [31:0] biases [0:7];
    logic [3:0] requant_shift, shift_reg;
    
    // Internal flags and such
    logic activation_en_reg;
    logic [7:0] bias_valid;
    logic [2:0] row_reg [0:7];
    logic bank_reg, last_reg;

    logic [7:0] magnitude_valid, product_valid, scaled_valid;
    logic [32:0] magnitude_reg [0:7], integer_reg [0:7];
    logic [53:0] product_reg [0:7];
    logic [7:0] magnitude_negative, magnitude_leaky, product_negative, scaled_negative;
    logic [7:0] round_up;
    logic [3:0] magnitude_shift, product_shift;
    logic [2:0] magnitude_row [0:7], product_row [0:7], scaled_row [0:7];
    logic magnitude_bank, magnitude_last, product_bank, product_last, scaled_bank, scaled_last;

    // Q20 coefficients: identity=1048576, leaky slope=104858/1048576 ~= 0.100000381.
    // Full product is retained; scaling and activation receive one final rounding.
    wire [53:0] fixed_product [0:7];
    for (genvar c=0; c<8; c++) begin : fixed_lanes
        (* use_dsp = "yes" *) wire [53:0] product;
        assign product = magnitude_reg[c] * (magnitude_leaky[c] ? 21'd104858 : 21'd1048576);
        assign fixed_product[c] = product;
    end

    // Configuration writes affect inputs accepted on subsequent clock edges.
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            requant_shift <= 0;
            for (int c = 0; c < 8; c++) biases[c] <= 0;
        end else begin
            if (shift_wr_en) requant_shift <= shift_data;
            if (bias_wr_en) biases[bias_addr] <= bias_data;
        end
    end

    // Stage 1: one completed MAC per filter, with its destination row.
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            bias_valid <= 0;
            activation_en_reg <= 0;
            shift_reg <= 0;
            bank_reg <= 0;
            last_reg <= 0;
            for (int c = 0; c < 8; c++) begin
                biased_out[c] <= 0;
                row_reg[c] <= 0;
            end
        end else begin
            bias_valid <= in_valid;
            last_reg <= in_last && (|in_valid);
            if (|in_valid) begin
                activation_en_reg <= activation_en;
                shift_reg <= requant_shift;
                bank_reg <= in_bank;
            end
            for (int c = 0; c < 8; c++) begin
                if (in_valid[c]) begin
                    biased_out[c] <= $signed({acc_in[c][31], acc_in[c]}) +
                                     $signed({biases[c][31], biases[c]});
                    row_reg[c] <= in_row[c];
                end
            end
        end
    end

    // Stage 2: magnitude and coefficient selection, before any truncation.
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            magnitude_valid <= 0; magnitude_negative <= 0; magnitude_leaky <= 0;
            magnitude_shift <= 0; magnitude_bank <= 0; magnitude_last <= 0;
            for (int c=0;c<8;c++) begin magnitude_reg[c] <= 0; magnitude_row[c] <= 0; end
        end else begin
            magnitude_valid <= bias_valid; magnitude_last <= last_reg;
            if (|bias_valid) begin magnitude_shift <= shift_reg; magnitude_bank <= bank_reg; end
            for (int c=0;c<8;c++) if (bias_valid[c]) begin
                magnitude_reg[c] <= biased_out[c][32] ? -biased_out[c] : biased_out[c];
                magnitude_negative[c] <= biased_out[c][32];
                magnitude_leaky[c] <= biased_out[c][32] && activation_en_reg;
                magnitude_row[c] <= row_reg[c];
            end
        end
    end

    // Stage 3: fixed-point multiplication (DSP hint; synthesis may use fabric).
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            product_valid <= 0; product_negative <= 0; product_shift <= 0;
            product_bank <= 0; product_last <= 0;
            for (int c=0;c<8;c++) begin product_reg[c] <= 0; product_row[c] <= 0; end
        end else begin
            product_valid <= magnitude_valid; product_last <= magnitude_last;
            if (|magnitude_valid) begin product_shift <= magnitude_shift; product_bank <= magnitude_bank; end
            for (int c=0;c<8;c++) if (magnitude_valid[c]) begin
                product_reg[c] <= fixed_product[c];
                product_negative[c] <= magnitude_negative[c]; product_row[c] <= magnitude_row[c];
            end
        end
    end

    // Stage 4: combined shift (20 fractional bits + layer shift), guard/sticky.
    always_ff @(posedge clk or posedge rst) begin : scaling
        logic [5:0] shift_amount;
        logic [53:0] whole;
        logic guard_bit, sticky_bit;
        if (rst) begin
            scaled_valid <= 0; scaled_negative <= 0; round_up <= 0;
            scaled_bank <= 0; scaled_last <= 0;
            for (int c=0;c<8;c++) begin integer_reg[c] <= 0; scaled_row[c] <= 0; end
        end else begin
            scaled_valid <= product_valid; scaled_last <= product_last;
            if (|product_valid) scaled_bank <= product_bank;
            for (int c=0;c<8;c++) if (product_valid[c]) begin
                shift_amount = 6'd20 + {2'b0, product_shift};
                whole = product_reg[c] >> shift_amount;
                guard_bit = product_reg[c][shift_amount-1'b1];
                sticky_bit = |(product_reg[c] & ((54'd1 << (shift_amount-1'b1))-54'd1));
                integer_reg[c] <= whole[32:0];
                round_up[c] <= guard_bit && (sticky_bit || whole[0]);
                scaled_negative[c] <= product_negative[c]; scaled_row[c] <= product_row[c];
            end
        end
    end

    // Stage 5: nearest-even rounding and signed INT8 saturation.
    always_ff @(posedge clk or posedge rst) begin : rounding
        logic [32:0] rounded;
        if (rst) begin
            out_valid <= 0; out_bank <= 0; out_last <= 0;
            for (int c=0;c<8;c++) begin quantized_out[c] <= 0; out_row[c] <= 0; end
        end else begin
            out_valid <= scaled_valid; out_last <= scaled_last;
            if (|scaled_valid) out_bank <= scaled_bank;
            for (int c=0;c<8;c++) if (scaled_valid[c]) begin
                rounded = integer_reg[c] + round_up[c];
                if (scaled_negative[c])
                    quantized_out[c] <= (rounded >= 33'd128) ? 8'sh80 : -$signed(rounded[7:0]);
                else
                    quantized_out[c] <= (rounded > 33'd127) ? 8'sd127 : $signed(rounded[7:0]);
                out_row[c] <= scaled_row[c];
            end
        end
    end
endmodule

