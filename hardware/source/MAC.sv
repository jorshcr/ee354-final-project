// Multiply Accumulate Unit, for use in systolic array convolution engine
// Takes and multiplies two signed INT8 inputs then passes inputs through
// Last updated: 11/12/26, Josh

`timescale 1ns / 1ps

module MAC (

input logic clk, rst, clear, en,
input logic signed [7:0] inA,
input logic signed [7:0] inB,
output logic [7:0] passA, passB,

output logic signed [31:0] acc
);

wire signed [15:0] product;
assign product = inA * inB;

always_ff @(posedge clk, posedge rst) begin
    // Reset will affect all data out
    if (rst) begin
        acc <= 0;
        passA <= 0;
        passB <= 0;
    end
    // Clear will only reset Accumulator
    else if (clear) begin 
        acc <= 0;
    end

    else if (en) begin
        acc <= acc + { {16{product[15]}}, product[15:0]};
        passA <= inA;
        passB <= inB;
    end

end
endmodule
