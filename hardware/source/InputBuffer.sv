

module InputBuffer(
    input logic clk, wr_en, rd_en,
    input logic [13:0] addr,
    input logic [63:0] data_in,

    output logic signed [7:0] data_out[0:7]
);

// 9,216 words x 8 bytes = 73,728 bytes (72 KiB).
// The controller must keep addr in the range 0 through 9,215.
logic [63:0] memory [0:9215];

always_ff@(posedge clk) begin
    // Lane 0 is the least-significant byte. Disabled reads hold outputs.
    // A simultaneous read/write returns the old word at this address.
    if (rd_en) begin
        for (int i = 0; i < 8; i++)
            data_out[i] <= memory[addr][8*i +: 8];
    end
    if (wr_en)
        memory[addr] <= data_in;
end

endmodule
