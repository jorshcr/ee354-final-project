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
    // Boundary skew only: A row i and B column i each have i delays.
    // Present the same k index on all input lanes; no external skew needed.
    for (i = 0; i < 8; i = i + 1) begin : input_delays
        if (i == 0) begin : direct_input
            assign aLink[i][0] = inputA[i];
            assign bLink[0][i] = inputB[i];
        end else begin : delayed_input
            logic signed [7:0] aDelay [0:i-1];
            logic signed [7:0] bDelay [0:i-1];

            always_ff @(posedge clk or posedge rst) begin
                if (rst) begin
                    for (int stage = 0; stage < i; stage++) begin
                        aDelay[stage] <= 0;
                        bDelay[stage] <= 0;
                    end
                end
                else if (clear) begin
                    // hold vals and clear acc
                end
                else if (en) begin
                    // Match the MAC forwarding enable, including clear stalls.
                    aDelay[0] <= inputA[i];
                    bDelay[0] <= inputB[i];
                    for (int stage = 1; stage < i; stage++) begin
                        aDelay[stage] <= aDelay[stage-1];
                        bDelay[stage] <= bDelay[stage-1];
                    end
                end
            end

            assign aLink[i][0] = aDelay[i-1];
            assign bLink[0][i] = bDelay[i-1];
        end
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
