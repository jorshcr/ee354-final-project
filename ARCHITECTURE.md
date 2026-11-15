# Tiny YOLOv2 FPGA architecture

## Agreed direction
- Board: Digilent Nexys A7-100T (Artix-7), with external DDR2.
- Model: Tiny YOLOv2 inference, targeting INT8 weights and activations.
- Architecture: one reusable accelerator, configured and reused layer by layer. A dedicated engine per network layer is not planned.
- PC handles image preparation, model loading, prediction decoding, and non-maximum suppression (NMS).

## Proposed data path
```text
DDR2 -> BRAM input/weight tiles -> convolution MAC engine
     -> INT32 accumulation + bias -> hidden-layer Leaky ReLU
     -> requantize to INT8 -> optional max pooling -> DDR2
Repeat for each layer; final predictions return to PC.
```
The final prediction convolution is linear (no Leaky ReLU). Pooling stride and padding must match the model, including its stride-1 pooling layer.

## Starting implementation choices (to validate)
- Fold batch normalization into convolution weights and biases before quantization.
- Start with symmetric signed INT8 and per-layer scales; use INT32 biases/accumulators.
- Requantization uses an integer multiplier and shift with explicitly defined rounding and saturation.
- Calibrate activation ranges using representative images and check detection accuracy. Final-layer precision remains subject to accuracy validation.
- Use tiled transfers and on-chip data reuse. Add double buffering after correctness is established.
- Controller supplies layer dimensions, addresses, filter counts, quantization parameters, and pooling settings.
- Current implementation: an 8x8 output-stationary systolic array with one DSP48E1 per MAC; see the synthesis decision below.

## First milestone
Build a bit-exact quantized software reference, then match the first convolution in RTL using BRAM-resident data. Progress through activation/pooling, two layers, DDR2 integration, and the full network. Compare intermediate outputs against the reference. The RGB first layer has 27 products per output; later 3x3 layers have 9 times the input-channel count.

This note records the side-chat design direction; no model quantization or hardware implementation has been completed by that discussion.

## Deferred timing evaluation (2026-11-14)
- User concern: expressions such as `k_latched - 1` and `drain_cycles - 1` in `hardware/source/SystolicController.sv` may add unnecessary combinational delay to comparisons/control paths and affect timing closure.
- This is an unverified concern, not a measured timing failure. Evaluate the actual synthesized logic and implementation timing reports later.
- Leave the RTL unchanged for now. Do not optimize these expressions proactively; assess their actual timing impact before deciding on changes.

## MAC implementation decision and synthesis comparison (2026-11-14)

Selected one DSP48E1 per MAC for the 64-MAC array. The main `hardware/source/MAC.sv` now uses `(* use_dsp = "yes" *)`, the direct signed expression `acc <= acc + inA * inB`, and synchronous accumulator reset. Operand-forwarding registers retain asynchronous reset and pause on clear. Reset must span a rising clock edge to clear the accumulator. No extra compute pipeline stage was added.

Vivado 2024.1 out-of-context synthesis of `ConvEngineTop`, targeting `xc7a100tcsg324-1`. Counts below cover the whole engine, including both buffers and output registers. Timing was reported after synthesis with a 10 ns clock (100 MHz), not after placement/routing; the clock constraint was applied after `synth_design` in these comparison scripts.

| MAC mapping | LUTs | Flip-flops | DSP48E1 | BRAM36 | Estimated worst setup slack |
|---|---:|---:|---:|---:|---:|
| Original fabric multiply/accumulate | 6,261 | 5,268 | 0 | 64 | +0.485 ns |
| Separate DSP multiply and DSP accumulate | 364 | 3,220 | 128 | 64 | -0.870 ns |
| **Selected fused DSP multiply/accumulate** | **364** | **3,220** | **64** | **64** | **+2.010 ns** |
| DSP multiply, fabric accumulate | 2,410 | 5,268 | 64 | 64 | -0.532 ns |

The selected mapping improved estimated setup slack by **1.525 ns versus the original fabric design**, while reducing LUT usage and using 64 of 240 available DSPs. This assisted preliminary timing and motivated the choice; it does not establish routed timing closure or a measured maximum frequency. The controller subtraction expressions were not changed.

The fused and hybrid variants each passed all 10 integrated engine tile tests, including signed boundary data and consecutive tiles without external reset. This is functional RTL simulation, not exhaustive equivalence or post-route verification.

Preserved experiment scripts, source variants, checkpoints, and reports:
- Original: [utilization](hardware/synth_resource_check/utilization.rpt), [timing](hardware/synth_resource_check/timing_synthesis.rpt).
- Two-DSP: [utilization](hardware/synth_dsp_variant/utilization.rpt), [timing](hardware/synth_dsp_variant/timing_synthesis.rpt), [MAC](hardware/synth_dsp_variant/MAC.sv).
- Selected fused DSP: [utilization](hardware/synth_dsp_fused/utilization.rpt), [timing](hardware/synth_dsp_fused/timing_synthesis.rpt), [MAC](hardware/synth_dsp_fused/MAC.sv).
- DSP plus fabric: [utilization](hardware/synth_dsp_lut/utilization.rpt), [timing](hardware/synth_dsp_lut/timing_synthesis.rpt), [MAC](hardware/synth_dsp_lut/MAC.sv).

Reports are historical snapshots. Scripts reference shared source files, so rerunning them after subsequent RTL changes can produce different results.
