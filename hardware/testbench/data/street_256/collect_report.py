from pathlib import Path
import csv,json,hashlib,shutil
import numpy as np
root=Path(__file__).resolve().parent
hardware=root.parents[2]; sim=hardware/'sim'
report=root/'measurement_run'; report.mkdir(exist_ok=True)
for name in ['street_metrics.csv','street_tile_timing.csv','street_wall_time.json','street_outputs.csv','xsim.log']:
 shutil.copy2(sim/name,report/name)
source_dir=report/'source_snapshot'; source_dir.mkdir(exist_ok=True)
paths=list((hardware/'source').glob('*.sv'))+[hardware/'testbench'/'ConvEngineStreet_tb.sv']
for p in paths: shutil.copy2(p,source_dir/p.name)
manifest={str(p.relative_to(hardware)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
for name in ['street_256.png','pixels.mem','weights.mem','expected.mem','prepare.py','plot_results.py']:
 p=root/name; manifest['fixture/'+name]=hashlib.sha256(p.read_bytes()).hexdigest()
(report/'sha256.json').write_text(json.dumps(manifest,indent=2))
m={r['metric']:int(r['value']) for r in csv.DictReader((report/'street_metrics.csv').open())}
t=np.loadtxt(report/'street_tile_timing.csv',delimiter=',',skiprows=1,dtype=np.int64)
assert t.shape==(8192,4) and np.all(t[:,3]==44)
assert np.all(np.diff(t[:,1])==101)
a=np.load(root/'rtl_outputs.npy'); e=np.load(root/'expected.npy'); diff=a.astype(np.int64)-e.astype(np.int64)
assert np.count_nonzero(diff)==0
names=['Box sum','Sobel X','Sobel Y','Laplacian','Red minus green','Green minus blue','Blue minus red','Center RGB sum']
with (report/'filter_statistics.csv').open('w',newline='') as f:
 writer=csv.writer(f); writer.writerow(['filter','name','count','mismatches','mae','rmse','max_abs_error','min','max','zero_count','negative_count','positive_count'])
 for i,name in enumerate(names):
  v=a[:,:,i]; d=diff[:,:,i]
  writer.writerow([i,name,v.size,int(np.count_nonzero(d)),float(np.abs(d).mean()),float(np.sqrt((d*d).mean())),int(np.abs(d).max()),int(v.min()),int(v.max()),int((v==0).sum()),int((v<0).sum()),int((v>0).sum())])
macs=256*256*8*27
seconds=m['simulation_end_ns']*1e-9
summary={'exact_matches':int(a.size),'mismatches':int(np.count_nonzero(diff)),'mae':float(np.abs(diff).mean()),'rmse':float(np.sqrt((diff*diff).mean())),'max_abs_error':int(np.abs(diff).max()),'dense_mac_count':macs,'end_to_end_gmac_s':macs/seconds/1e9,'array_enabled_utilization':27/41,'overall_dense_mac_slot_utilization':macs/(64*m['total_cycles']),'tile_latency_cycles':44,'tile_initiation_interval_cycles':101,'testbench_equivalent_images_s':1/seconds}
(report/'summary.json').write_text(json.dumps(summary,indent=2))
wall=json.loads((report/'street_wall_time.json').read_text())
text=f'''# Street-image convolution: RTL measurement report

Date: 2026-11-14. Simulator: AMD Vivado XSim 2024.1. Outcome: PASS.

## Experiment

Generated candidate B street scene, cropped from the saved candidate sheet at
(647, 8, 1238, 555), resized to 256x256 with Pillow Lanczos. Input conversion is
floor(pixel / 2), giving nonnegative signed INT8 values 0..127. The displayed RGB
image retains the original display brightness. This is synthetic imagery, not a
benchmark dataset or evidence of object-detection accuracy.

Eight hand-designed 3x3x3 INT8 filters: box sum, Sobel X, Sobel Y, Laplacian,
center R-G, center G-B, center B-R, center R+G+B. Stride 1, zero padding 1,
CNN cross-correlation (no kernel flip), zero bias, raw INT32 outputs.
No activation, normalization, requantization, pooling, or DDR traffic is modeled.

Output shape: 256x256x8. K=27. All 8192 tiles use eight patches and eight filters.
Filters are loaded once and retained across tiles. Global reset occurs only once;
array-local initialization occurs for every tile. Testbench extracts/pads patches
and writes packed words; patch-generation hardware is not part of this experiment.

## Correctness

All 524288 outputs were compared using SystemVerilog case inequality, which also
rejects unknown bits, against a separately generated direct integer-convolution
reference. Exported coordinates were checked for complete, unique coverage and
outputs independently rechecked in Python.

- Exact matches: 524288 / 524288 (100%).
- Mismatches: 0; maximum absolute error: 0; MAE: 0; RMSE: 0.
- Boundary outputs (one-pixel perimeter): {(256*256-254*254)*8}, all matched.
- Interior outputs: {254*254*8}, all matched.
- Per-filter counts, signed ranges, zeros, and errors: filter_statistics.csv.
- Arithmetic is safely bounded for these small weights; this does not test
  worst-case INT32 overflow or all signed-input combinations.

## Cycle measurements

Clock period is 10 ns (100 MHz stimulus). Controls are sampled before rising-edge
updates. Output-valid is observed 1 ps after the edge; latency counts edge intervals,
not this observation delay. Every tile's accepted-start and valid edge are recorded.

| Metric | Measured value |
|---|---:|
| Total rising edges | {m['total_cycles']} |
| Global reset edges | {m['global_reset_cycles']} |
| IDLE edges (includes buffer loading, gaps, accepted starts) | {m['idle_cycles']} |
| INIT edges | {m['init_cycles']} |
| PRIME edges (one per tile) | 8192 |
| FEED edges | {m['feed_cycles']} |
| DRAIN edges | {m['drain_cycles']} |
| CAPTURE edges | {m['capture_cycles']} |
| DONE/acknowledgment edges | {m['done_cycles']} |
| Per-tile accepted-start to valid, min/mean/max | 44 / 44 / 44 clocks |
| Per-tile FEED / DRAIN | 27 / 14 clocks |
| Interval between accepted starts, all 8191 intervals | 101 clocks |
| Total simulated time | 8.274480 ms |

The state-edge totals sum to total rising edges. Per tile: 1 INIT + 1 PRIME +
27 FEED + 14 DRAIN + 1 CAPTURE = 44 elapsed clocks from accepted start to valid.
The 101-clock tile interval includes 54 clocks in the conservative loading task
(two clocks per input word), 44 processing clocks, and 3 launch/acknowledgment/gap
clocks. This is the testbench schedule, not a minimum achievable interval.

## Data movement and derived throughput

- Input buffer writes: 221184 words = 1769472 bytes (1728 KiB).
- Weight buffer writes: 27 words = 216 bytes, reused for every tile.
- Read requests: 221184 per buffer; 3538944 combined logical bytes.
- Unique quantized image: 196608 bytes (192 KiB). Packed patch writes expand this
  to 9x bytes, including explicitly supplied padding zeros. This is not DDR traffic.
- Captured output payload: 2097152 bytes (2 MiB); the 64 output registers are read
  in parallel by the testbench. No serialized host/DDR output transfer is timed.
- Dense scheduled convolution MACs: {macs} (includes zero weights/padding).
- MACs per array-enabled clock: {macs/(8192*41):.4f}, out of 64 slots.
- Array-enabled dense utilization: {100*27/41:.2f}%.
- Overall dense utilization, including reset/loading/handshakes: {100*summary['overall_dense_mac_slot_utilization']:.2f}%.
- Schedule-equivalent throughput at the stipulated 100 MHz: {summary['end_to_end_gmac_s']:.4f} GMAC/s,
  or {2*summary['end_to_end_gmac_s']:.4f} GOP/s if one multiply plus one add counts as two operations.
- Equivalent repeated-image rate for this schedule: {1/seconds:.2f} images/s.
  This is not a measured FPGA frame rate or full-network inference rate.

## Simulator wall time

One run, no statistical repeatability study: simulation process including startup
{wall['simulation_process_seconds']:.3f} s; compile + elaborate + simulation
{wall['compile_elaborate_simulate_seconds']:.3f} s. XSim reports approximately 8 s
for its run-all command. These host execution times are separate from simulated
hardware time and exclude Python preparation/plotting.

## Limits and follow-up

Functional RTL simulation only: no synthesized clock frequency, WNS/TNS, post-route
critical paths, BRAM/DSP/LUT utilization, power, or physical-board measurements.
No claim of 100 MHz timing closure. The deferred subtraction/comparator timing
concern remains unchanged and unmeasured. Loading is not overlapped with compute.
One image and one filter bank establish this case's correctness, not exhaustive
verification, trained YOLO accuracy, or a full-network performance result.

## Reproduction and provenance

1. Run ../prepare.py from this report directory (or its absolute path).
2. Compile InputBuffer.sv, MAC.sv, SystolicArray.sv, SystolicController.sv,
   ConvEngineTop.sv and ConvEngineStreet_tb.sv with xvlog -sv.
3. From hardware/sim, elaborate ConvEngineStreet_tb with xelab -s street_test
   -timescale 1ns/1ps, then run xsim street_test -runall.
4. Run ../plot_results.py and ../collect_report.py.

Original source snapshot, SHA-256 hashes, actual outputs, per-tile timing,
aggregate counters, wall-time JSON and simulator log are saved beside this report.
Input generation scripts and numerical arrays are in the parent directory.
'''
(report/'REPORT.md').write_text(text,encoding='utf-8')
print(json.dumps(summary,indent=2))
