`timescale 1ns / 1ps
// Selected single-DSP MAC; synthesis comparison recorded in ARCHITECTURE.md.
// Forwarding retains the original asynchronous reset and clear-stall behavior.
(* use_dsp = "yes" *)
module MAC (
    input logic clk, rst, clear, en,
    input logic signed [7:0] inA, inB,
    output logic [7:0] passA, passB,
    output logic signed [31:0] acc
);

    // Reset must span a rising clock edge; no extra compute latency is added.
    always_ff @(posedge clk) begin
        if (rst || clear) acc <= 0;
        else if (en) acc <= acc + inA * inB;
    end
    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            passA <= 0;
            passB <= 0;
        end else if (en && !clear) begin
            passA <= inA;
            passB <= inB;
        end
    end
endmodule


