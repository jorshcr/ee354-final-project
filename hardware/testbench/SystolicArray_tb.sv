`timescale 1ns / 1ps

// A is M x K, B is K x N, and C = A*B is M x N.
// Change these parameters and the matrix initialization below to try a case.
module SystolicArray_tb #(
  parameter integer M = 2,
  parameter integer K = 2,
  parameter integer N = 2,
  parameter bit SHOW_EACH_CYCLE = 1
);
  localparam integer RUN_CYCLES = K + M + N - 2;
  logic clk = 0;
  logic rst, clear, en;
  logic signed [7:0] matrix_a [0:M-1][0:K-1];
  logic signed [7:0] matrix_b [0:K-1][0:N-1];
  logic signed [7:0] a_inputs [0:7];
  logic signed [7:0] b_inputs [0:7];
  wire signed [31:0] acc [0:7][0:7];
  integer expected [0:7][0:7];
  integer a_value, b_value, failures;

  SystolicArray sysarray (
    .clk(clk), .rst(rst), .clear(clear), .en(en),
    .inputA(a_inputs), .inputB(b_inputs), .arrayAcc(acc)
  );
  always #5 clk = ~clk;

  task automatic display_output;
    for (int r = 0; r < M; r++) begin
      $write("[ ");
      for (int c = 0; c < N; c++)
        $write("%0d ", acc[r][c]);
      $write("]\n");
    end
    $write("\n");
  endtask

  // Wait 1 ps past each rising edge so nonblocking register updates settle.
  always @(posedge clk) begin
    #1ps;
    if (SHOW_EACH_CYCLE) display_output();
  end

  initial begin
    if (M < 1 || M > 8 || K < 1 || K > 8 || N < 1 || N > 8)
      $fatal(1, "M, K, and N must each be between 1 and 8");
    // Two independent examples for every configured shape.
    for (int example = 0; example < 2; example++) begin
      $display("Example %0d", example + 1);
      rst = 1; clear = 0; en = 0;
      for (int lane = 0; lane < 8; lane++) begin
        a_inputs[lane] = 0;
        b_inputs[lane] = 0;
      end

      // EDIT HERE: positive values first, then signed INT8 boundary values.
      for (int r = 0; r < M; r++)
        for (int k = 0; k < K; k++)
          if (example == 0)
            matrix_a[r][k] = ((r * K + k) % 9) + 1;
          else
            matrix_a[r][k] = ((r + k) % 2 == 0) ? -128 : 127;
      for (int k = 0; k < K; k++)
        for (int c = 0; c < N; c++)
          if (example == 0)
            matrix_b[k][c] = ((k * N + c + 4) % 9) + 1;
          else
            matrix_b[k][c] = ((k + c) % 3 == 0) ? 127 :
                             (((k + c) % 3 == 1) ? -128 : 0);

      // Preserve the original teaching example for the default 2x2 case.
      // Remove this block if supplying your own 2x2 values above.
      if (example == 0 && M == 2 && K == 2 && N == 2) begin
        matrix_a[0][0] = 1; matrix_a[0][1] = 2;
        matrix_a[1][0] = 3; matrix_a[1][1] = 4;
        matrix_b[0][0] = 5; matrix_b[0][1] = 6;
        matrix_b[1][0] = 7; matrix_b[1][1] = 8;
      end

      // Independent matrix-multiplication reference, including unused lanes.
      for (int r = 0; r < 8; r++) begin
        for (int c = 0; c < 8; c++) begin
          expected[r][c] = 0;
          if (r < M && c < N) begin
            for (int k = 0; k < K; k++) begin
              a_value = matrix_a[r][k];
              b_value = matrix_b[k][c];
              expected[r][c] += a_value * b_value;
            end
          end
        end
      end

      // Delay row r's A stream by r cycles and column c's B stream by c.
      // Out-of-range slots and unused lanes receive zero, including drain cycles.
      for (int cycle = 0; cycle < RUN_CYCLES; cycle++) begin
        @(negedge clk);
        rst = 0; en = 1;
        for (int lane = 0; lane < 8; lane++) begin
          a_inputs[lane] = 0;
          b_inputs[lane] = 0;
          if (lane < M && cycle >= lane && cycle - lane < K)
            a_inputs[lane] = matrix_a[lane][cycle - lane];
          if (lane < N && cycle >= lane && cycle - lane < K)
            b_inputs[lane] = matrix_b[cycle - lane][lane];
        end
      end

      @(posedge clk);
      @(negedge clk);
      en = 0;
      failures = 0;
      for (int r = 0; r < 8; r++) begin
        for (int c = 0; c < 8; c++) begin
          if (acc[r][c] !== expected[r][c]) begin
            $display("FAIL [%0d][%0d]: expected %0d, got %0d",
                     r, c, expected[r][c], acc[r][c]);
            failures++;
          end
        end
      end
      if (failures != 0) $fatal(1, "%0d incorrect accumulators", failures);
      if (!SHOW_EACH_CYCLE) display_output();
      $display("PASS: (%0dx%0d) * (%0dx%0d), %0d processing cycles; all 64 accumulators checked",
               M, K, K, N, RUN_CYCLES);
    end // examples
    $display("PASS: both examples completed");
    $finish;
  end
endmodule
