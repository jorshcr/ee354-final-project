# Heart convolution test fixture

Selected input: option E, a red heart on a blue background.
This folder records the agreed test; the integrated testbench is not implemented here.

## Image

9 x 9 RGB, signed INT8 channel values. Rows are top to bottom; columns left to right.
`R = (8, 0, 0)`, `B = (0, 0, 8)`. Channel order is R, G, B.

```text
BBBBBBBBB
BRRBBBRRB
RRRRBRRRR
RRRRRRRRR
BRRRRRRRB
BBRRRRRBB
BBBRRRBBB
BBBBRBBBB
BBBBBBBBB
```

## Filters (column order)

All filters are 3 x 3 x 3 signed INT8; bias is zero.

0. Box sum: every weight is +1 in all three channels. No averaging/division.
1. Vertical edge: the following spatial weights are repeated in each RGB channel:

   ```text
   -1  0  1
   -1  0  1
   -1  0  1
   ```

2. Red-minus-blue: center red weight +1, center blue weight -1; all other weights zero.

Use CNN cross-correlation (do not flip kernels), stride 1, no padding.
Compare raw signed INT32 sums; no activation, requantization, or pooling.

## Array mapping and buffering

- Output: 7 x 7 positions x 3 filters = 147 values.
- Flatten output positions in row-major order: position = y * 7 + x.
- Array rows represent eight successive output positions; columns represent filters.
- Seven tiles: six full eight-position tiles and one tile containing position 48.
- In the final tile only row 0 is active; zero-fill other patch lanes.
- Columns 0, 1, 2 contain the filters above; zero-fill columns 3 through 7.
- Each tile uses 27 input words and 27 weight words, each 64 bits wide.
- Traverse patch/filter coordinates with channel fastest: k = (ky * 3 + kx) * 3 + channel.
- Input word k holds the kth patch value for each of eight output positions.
- Weight word k holds the kth weight for each filter (unused lanes zero).
- Lane i occupies bits [8*i +: 8]; lane 0 is the least-significant byte.
- Reuse the same 27 weight words for all seven tiles.
- Delay input row r by r cycles and weight column c by c cycles.
- Clear before each tile; feed zeros through startup/drain cycles and capture after draining.

## Simple expected checks

Every pixel has RGB sum 8, so every box-sum output is 72 and every vertical-edge
output is 0. Red-minus-blue is +8 for a red center pixel and -8 for a blue center.
This image therefore does not exercise nonzero vertical-edge results; a later
fixture should vary total brightness for that check.
