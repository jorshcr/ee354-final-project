`timescale 1ns / 1ps

module MAC_tb;
  logic clk = 0;
  logic rst, clear, en;
  logic signed [7:0] inA, inB;
  logic signed [7:0] passA, passB;
  logic signed [31:0] acc;
  integer expected_b, expected_product;

  MAC dut (
    .clk(clk), .rst(rst), .clear(clear), .en(en),
    .inA(inA), .inB(inB), .passA(passA), .passB(passB),
    .acc(acc)
  );

  always #5 clk = !clk;

  initial begin
    rst = 1;
    clear = 0;
    en = 0;
    inA = 0;
    inB = 0;
    @(negedge clk);
    rst = 0;

    for (int i = -128; i <= 128; i++) begin
      // Clear for one rising edge to test each product independently.
      clear = 1;
      en = 0;
      @(negedge clk);
      if (acc !== 32'sd0)
        $fatal(1, "Clear failed: acc=%0d", acc);
      clear = 0;
      en = 1;
      inA = 128; // 8'h80 represents -128 in signed INT8.
      inB = i;   // Requested +128 also wraps to -128.
      expected_b = (i == 128) ? -128 : i;
      expected_product = -128 * expected_b;

      // Observe after the rising edge and its nonblocking updates.
      @(negedge clk);
      en = 0;
      if (inA !== -8'sd128 || $signed(inB) != expected_b)
        $fatal(1, "Unexpected INT8 conversion at requested B=%0d", i);
      if (acc !== expected_product)
        $fatal(1, "B request=%0d, actual A=%0d B=%0d: expected %0d, got %0d",
               i, inA, inB, expected_product, acc);
      $display("B request=%0d, actual A=%0d B=%0d, product=%0d", i, inA, inB, acc);
    end

    $display("PASS: all 257 requests checked; signed INT8 +128 wraps to -128.");
    $finish;
  end
endmodule
