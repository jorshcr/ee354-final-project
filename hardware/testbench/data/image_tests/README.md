# Integrated image convolution tests

Run `prepare.py` to generate deterministic fixtures and direct integer convolution references.
Run `ConvEngineImages_tb` in hardware/sim; it writes image_outputs.csv from captured DUT results.
Run `plot_results.py` after a successful simulation to render those actual RTL outputs.

Both inputs are 9x9 RGB, with one active channel valued 8 per pixel.
The heart matches ../heart_9x9/README.md.
The staircase uses red where row+column < 6, green where 6 <= row+column < 12,
and blue otherwise (zero-based indices).

Filters: 3x3 RGB box sum, vertical edge [-1,0,1] repeated across rows/channels,
and center red-minus-blue. Stride 1, no padding, bias, activation, or requantization.
Each image produces 7x7x3 raw INT32 values over seven tiles; the last tile has one row.
Weights are loaded once per image and retained across its tiles. The controller resets
the array and its internal lane delays before each tile. The TB does not pre-skew inputs.

Every pixel has channel sum 8, so box outputs are 72 and vertical-edge outputs are 0.
These fixtures test color routing but do not exercise a nonzero vertical-edge response.
2026-11-14: all 294 active outputs and unused tile outputs passed in Vivado simulation.
