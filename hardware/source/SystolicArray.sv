// Systolic Array, an array of MACs
// 8x8 array, where A amt of columns, B amt of rows
// AxB array
// 00 01 02 ...
// 10 11 12 ...
// 20 21 22 ...
// .. .. ..
// Last updated: 11/12/26, Josh
`timescale 1ns / 1ps

module SystolicArray (
    input clk, rst, en, clear,

    input logic signed [7:0] inputA [0:7],
    input logic signed [7:0] inputB [0:7],

    output logic signed [31:0] arrayAcc [0:7][0:7]
);

wire signed [7:0] aLink [0:7][0:8]; // connecting wires across rows
wire signed [7:0] bLink [0:8][0:7]; // connecting down columns

genvar i, row, col;
generate 
    // input connections
    for (i = 0; i < 8; i = i + 1) begin
        assign aLink[i][0] = inputA[i];
        assign bLink[0][i] = inputB[i];
    end

    // MACs creation
    for (row = 0; row < 8; row = row + 1) begin 
        for (col = 0; col < 8; col = col + 1) begin
            MAC mac (
            .clk(clk), .rst(rst), .en(en), .clear(clear),
            .inA(aLink[row][col]), .inB(bLink[row][col]), 
            .passA(aLink[row][col+1]), .passB(bLink[row+1][col]),
            .acc(arrayAcc[row][col])
            );

        end 
    end
endgenerate 
endmodule