# FINAL NUMERICAL RESULTS - VMDPathFinder 1.0.1 freeze, Nelder-Mead search + marching-cubes mesher

**Refresh 2026-09-13 (commit `0fbab73`, tag v1.0.2 + 5):** the three Tier-2 stages
(`endtoend`, `scaling`, `tunnel-clustering-real`) and `figures` were re-run after the job
pools changed - one OpenMP thread per worker, worker shells reused, `nproc` and the
coordinate identity cached. Only those stages run the plugin's pools; every Tier-1 row
below (reference tools, standalone engines, identity gates) is from the 2026-09-12 run
and its code is unchanged. The reference rows re-timed 5-7% faster this run (idle
machine), so ratios, not seconds, are the comparison.

Generated: 2026-09-07T01:14:34Z
Benchmarked commit: `061f7d75dafd9c4bbd3126b6ff1176844359eb49` (branch main; working tree CLEAN at run time
except these regenerated result files). The commits after it, up to `71d9ae9` where this
document was written, change only the CPOINT/CVECT stick dialog and documentation - no measured path.
On 2026-09-07 the project was renamed (commit `9ed96e9`): labels and paths in these result files
read `vmdpathfinder`/`VMDPathFinder` where the run wrote `vmdhole`/`VMDHole`. That edit is textual;
no measured value changed, and `SHA256_MANIFEST.txt` was re-hashed for it on 2026-09-10.
Protocol: `paper/benchmarks/reproduce.sh`, the repository's own harness,
3 timing repetitions per point, medians reported. No benchmark script parameter
or dataset changed for this run; the harness gained three plugin rows
(`vmdpathfinder_nm`, `vmdpathfinder_csg`, `vmdpathfinder_nm_csg`) so the plugin's own search engine
and mesher are timed beside the accelerated HOLE rows.

## Environment

See `env_manifest.txt` (regenerated this run) for the full record. Summary:
AMD Ryzen 7 7700X (8c/16t), 128 GB RAM, Linux 7.0.0-28-generic,
gcc/gfortran 13.3.0, Python 3.12.3, Tcl 8.6.14, VMD 2.0.1a1 (`vmd2`),
OMP_NUM_THREADS unset. Binary SHA-256s for every engine invoked are in each
CSV's own provenance header; the `env` stage verifies the stock build links
no OpenMP.

## Commands executed (in order)

1. `bash reproduce.sh --tier1 --tier2 --data vmdpathfinder` - env, regress, gate-surface, identity-profile, identity-sos, identity-accel and poreanalyser passed with the quiet-machine gate active; the gate then timed out at load ~2.6 (>0.5 for 10 min: the desktop's own file-sync daemon at ~2.3 cores, browser and a live VMD session, none of them benchmark processes) and the run stopped, per protocol
2. `bash reproduce.sh --tier1 --tier2 --data vmdpathfinder --allow-noisy --skip <the 7 stages above>` - the timed stages and `figures`, recorded in every CSV header as allow_noisy: 1 with the load at start
3. `bash reproduce.sh --allow-noisy --stage endtoend --stage figures --data vmdpathfinder` - the end-to-end stage again after a harness fix: VMD drops empty `-args` entries, so the optional arguments now travel as `-`. Before the fix the trailing keep-PDB flag arrived in the job-count slot, which means the `vmdpathfinder_accel_pdb` row of the 2026-09-03 freeze (6.48 s) timed a SERIAL 1-job run with the packed record, not a keep-PDB run; this run measures what the row says.
4. `bash reproduce.sh --allow-noisy --stage chap` - CHAP replication (its inputs are the checked-in CHAP 0.9.1 example-02 outputs)
5. 2026-09-13: `bash reproduce.sh --stage endtoend --stage scaling --stage tunnel-clustering-real --stage figures --data vmdpathfinder` on an idle machine (load < 0.5, no `--allow-noisy`), after the job-pool changes in `0fbab73`

Correctness gate BEFORE benchmarking: `vmdpathfinder/tests/run_tests.sh` = ALL 23
GROUPS PASSED and `tests/unit/run_unit_tests.sh` = 14 passed on `71d9ae9`; the tier-1 `regress` stage
repeated the main suite under VMDPATHFINDER_RELEASE=1: ALL 23 TEST GROUPS PASSED (`regression.log`).

## Identity / numerical-parity gates (all PASS)

| gate | result | source |
|---|---|---|
| HOLE vs VMDPathFinder profile identity | PASS (4 frames) | `profile_identity.csv` |
| Pure-Tcl fallback vs HOLE (all 3 pore methods) | PASS | `regression.log` (groups hole_tcl_fallback, _pore_methods, _e2e) |
| Packed-coordinate vs standard-PDB hand-off | PASS | `accel_parity.log` |
| Connolly/capsule/surface output identity | PASS | `gate_surface.log` + `identity-sos` (verify.sh A/B/D/E) |
| 1BL8 pipeline: .sph md5 + triangle counts identical across stock/accel_1t/accel_nt | PASS | `pipeline_1bl8.csv` |
| Ellipse fit C-vs-Tcl parity | PASS | `regression.log` (ellipse-parity group) |
| Nelder-Mead search, Connolly port, marching-cubes mesher, lobe classifier vs their references | PASS | `regression.log` (nm_engine, conn_lobes_engine, mesh_csg_engine groups) |
| Figure S2 self-agreement with CSVs | PASS (FIG_RESULT PASS) | `figures` stage output, `fig_performance_provenance.txt` |

## End-to-end, 50-frame trajectory (Tier 2) - `endtoend.csv`

Baselines: bare HOLE = the stock `hole` binary scripted directly (serial, and
a 15-way `xargs -P15` control); mdahole2 = the MDAnalysis HOLE wrapper;
VMDPathFinder = this plugin, 15 jobs, stock or accelerated binaries. The three new
rows keep the accelerated binaries and switch the plugin's own engines on:
`vmdpathfinder_nm` = Nelder-Mead search instead of HOLE's Monte Carlo (calc);
`vmdpathfinder_csg` = marching-cubes mesher on HOLE's search (surface);
`vmdpathfinder_nm_csg` = both (surface).

| deliverable | tool | median s | repetitions (s) |
|---|---|---|---|
| calc | bare_hole_serial | 5.8632 | 5.8641, 5.8422, 5.8632 |
| calc | bare_hole_parallel | 0.6898 | 0.6769, 0.6914, 0.6898 |
| calc | mdahole2 | 87.6012 | 88.1991, 87.4695, 87.6012 |
| calc | vmdpathfinder_stock | 1.2233 | 1.2459, 1.2157, 1.2233 |
| calc | vmdpathfinder_accel | 0.8382 | 0.8382, 0.8447, 0.8323 |
| calc | vmdpathfinder_accel_pdb | 1.2169 | 1.2413, 1.2136, 1.2169 |
| calc | vmdpathfinder_nm | 0.8728 | 0.8796, 0.8727, 0.8728 |
| surface | bare_hole_serial | 40.7361 | 40.5792, 40.8553, 40.7361 |
| surface | bare_hole_parallel | 4.5521 | 4.5337, 4.5521, 4.6534 |
| surface | mdahole2 | 123.5350 | 122.4749, 123.5350, 126.9547 |
| surface | vmdpathfinder_stock | 5.8884 | 5.8376, 5.8884, 5.9578 |
| surface | vmdpathfinder_accel | 2.0506 | 2.0595, 2.0506, 2.0132 |
| surface | vmdpathfinder_accel_pdb | 2.4354 | 2.4484, 2.4150, 2.4354 |
| surface | vmdpathfinder_csg | 1.2705 | 1.3065, 1.2632, 1.2705 |
| surface | vmdpathfinder_nm_csg | 1.2957 | 1.2997, 1.2912, 1.2957 |

**Derived ratios (full precision -> rounding):**

- calc vs mdahole2 (accelerated HOLE search): 104.5111 -> **104.5x**
- calc vs mdahole2 (Nelder-Mead search): 100.3680 -> **100.4x**
- calc, Nelder-Mead vs accelerated HOLE search: 0.9604 -> **0.96x**
- calc vs bare serial HOLE: 6.9950 -> **6.99x**
- calc vs xargs control: 0.8230 -> **0.82x**
- surface vs mdahole2 (accelerated sph_process + sos_triangle): 60.2433 -> **60.2x**
- surface vs mdahole2 (marching cubes): 97.2334 -> **97.2x**
- surface vs mdahole2 (Nelder-Mead + marching cubes): 95.3423 -> **95.3x**
- surface, marching cubes vs sos_triangle on the same HOLE search: 1.6140 -> **1.61x**
- surface, Nelder-Mead + marching cubes vs accelerated HOLE path: 1.5826 -> **1.58x**
- surface vs bare serial: 19.8655 -> **19.9x**
- surface vs bare serial (marching cubes): 32.0630 -> **32.1x**
- surface vs xargs control: 2.2199 -> **2.22x**
- surface accel vs plugin's own stock: 2.8715 -> **2.87x**

## Worker-count sweep (Tier 2) - `scaling.csv`

| jobs | median s | speedup vs 1 job |
|---|---|---|
| 1 | 5.4984 | 1.0000 |
| 2 | 2.9800 | 1.8451 |
| 3 | 2.1587 | 2.5471 |
| 4 | 1.7531 | 3.1364 |
| 5 | 1.4248 | 3.8591 |
| 6 | 1.2727 | 4.3203 |
| 7 | 1.1700 | 4.6995 |
| 8 | 1.0549 | 5.2122 |
| 9 | 0.9832 | 5.5924 |
| 10 | 0.9345 | 5.8838 |
| 11 | 0.9073 | 6.0602 |
| 12 | 0.8974 | 6.1270 |
| 13 | 0.8718 | 6.3070 |
| 14 | 0.8593 | 6.3987 |
| 15 | 0.8446 | 6.5101 |

15-worker headline: **0.8446 s**, **6.51x**.

## Triangulation-density sweep (9HNR frame 0) - `sos_scaling.csv`

| dotden | triangles | upstream ms | fast ms | speedup | identical |
|---|---|---|---|---|---|
| 10 | 2810 | 100.0 | 29.6 | 3.4 | yes |
| 15 | 6390 | 444.7 | 50.0 | 8.9 | yes |
| 20 | 11280 | 1315.0 | 77.0 | 17.1 | yes |
| 25 | 17354 | 3042.5 | 109.9 | 27.7 | yes |
| 30 | 24570 | 6056.5 | 150.4 | 40.3 | yes |
| 35 | 33388 | 11107.8 | 198.1 | 56.1 | yes |
| 40 | 43707 | 18874.1 | 257.0 | 73.4 | yes |

Range: **3.4x (density 10) to 73.4x (density 40)**, output identical at every point.

## MOLE 2 tunnel validation + timing - `tunnel_vs_mole2.csv`, `tunnel_vs_mole2_auto_origin.csv`

| structure | tetra MOLE2 | tetra VMDPathFinder | tunnels (both) | MOLE2 s | VMDPathFinder s | speedup |
|---|---|---|---|---|---|---|
| 1BL8 | 18394 | 18380 | 4/4 | 0.3449 | 0.0252 | 13.69x |
| 1MXT_noHET | 45044 | 45031 | 5/5 | 0.5485 | 0.0593 | 9.26x |
| 1ERI | 15163 | 15163 | 1/1 | 0.2987 | 0.0196 | 15.25x |
| 1BL8_auto | 18394 | 18380 | 8/8 | 0.3891 | 0.0286 | 13.60x |
| 1MXT_auto | 45044 | 45031 | 13/13 | 0.6507 | 0.0731 | 8.90x |

Timing range: **8.90-15.25x**; tunnel counts agree on every structure: yes.

## CAVER comparison - `tunnel_vs_caver_timing.csv`, `tunnel_tcl_vs_compiled.csv`, `tunnel_clustering_real_pool.csv`

| threshold | VMDPathFinder s | CAVER stage-only s | CAVER full s | stage-only ratio | full ratio |
|---|---|---|---|---|---|
| 2.0 | 0.014005 | 0.147579 | 0.262494 | 10.54x | 18.74x |
| 4.0 | 0.010709 | 0.146122 | 0.261677 | 13.64x | 24.43x |

Stage-only band **10.5-13.6x**; complete-command band **18.7-24.4x**.

Compiled vs Tcl tunnel engine (search): 1BL8 173.4x; 1MXT_noHET 231.4x - `tunnel_tcl_vs_compiled.csv`.
Cross-frame clustering on the real 50-frame pool (1837 pathways), the kernel now answered by the resident mesher process:
compiled 0.594 s vs Tcl 16.44 s = **27.7x** (2026-09-13 refresh; 0.774 s / 18.02 s = 23.3x on 2026-09-12),
cluster multisets identical (yes).

## CHAP replication - `chap_correlation.csv` (CHAP 0.9.1, example-02, 11 frames)

| series | metric | value |
|---|---|---|
| min_radius_per_frame | pearson_r | 0.998341 |
| min_radius_per_frame | spearman_r | 1 |
| min_radius_per_frame | rmsd | 0.0112461 |
| min_radius_per_frame | mean_ours | 2.06829 |
| min_radius_per_frame | mean_chap | 2.06834 |
| min_radius_per_frame | frames | none |
| registration | sigma | -1 |
| registration | delta | -3 |
| registration | radius_pearson_r | 0.985819 |
| radius | pearson_r | 0.985819 |
| radius | spearman_r | 0.980819 |
| radius | rmsd | 0.140375 |
| density | pearson_r | 0.952111 |
| density | spearman_r | 0.944332 |
| density | rmsd | 0.146735 |
| energy | pearson_r | 0.96833 |
| energy | spearman_r | 0.953239 |
| energy | rmsd | 0.226769 |
| density2 | pearson_r | 0.923326 |
| density2 | spearman_r | 0.889271 |
| density2 | rmsd | 0.197276 |
| energy2 | pearson_r | 0.955671 |
| energy2 | spearman_r | 0.902834 |
| energy2 | rmsd | 1.35709 |

Headlines: min-radius **r = 0.998**, RMSD **0.0112 A**;
registered profiles: radius **r = 0.986**, water density **r = 0.952**,
free energy **r = 0.968**.

## Per-stage pipeline (1BL8) - `pipeline_1bl8.csv`

| method | build | total s |
|---|---|---|
| circular | stock | 0.7746 |
| circular | accel_1t | 0.1463 |
| circular | accel_nt | 0.1475 |
| connolly | stock | 2.5582 |
| connolly | accel_1t | 0.6876 |
| connolly | accel_nt | 0.3364 |

circular total **5.25x**; connolly total **7.60x** (connolly at dotden 8 -
stock sos_triangle overflows above dotden ~12; always carry this caveat).

## Comparison with the 2026-09-03 freeze (commit 07790cc)

| headline | 2026-09-03 | 2026-09-12 | 2026-09-13 refresh |
|---|---|---|---|
| calc vs mdahole2 (accelerated HOLE search) | 99.1 | 93.40 | 104.51 |
| surfaces vs mdahole2 (accelerated HOLE path) | 54.8 | 49.92 | 60.24 |
| surfaces vs mdahole2 (marching cubes) | - | 64.09 | 97.23 |
| marching cubes vs sos_triangle, 15-worker pool | - | 1.28 | 1.61 |
| 15-worker speedup | 6.96 | 6.39 | 6.51 |
| triangulation, density 40 | 72.0 | 73.40 | (Tier 1, not re-run) |
| MOLE 2 fold, 1BL8 | 14.28 | 13.69 | (Tier 1, not re-run) |
| CAVER stage-only, 2.0 A | 10.54 | 10.54 | (Tier 1, not re-run) |
| cross-frame clustering compiled vs Tcl | 26.5 | 23.27 | 27.70 |
| CHAP min-radius r | 0.998 | 1.00 | (Tier 1, not re-run) |

The reference tools (mdahole2, bare HOLE, MOLE 2, CAVER, CHAP) and the stock
build are unchanged; movements in those rows are run-to-run spread. New this
run: the `vmdpathfinder_nm`, `vmdpathfinder_csg` and `vmdpathfinder_nm_csg` rows above and their
bars in Figure S2.

## Figure S2

`results/fig_performance.png/.pdf/.eps` regenerated by the `figures` stage
from these exact CSVs; the stage's own agreement check passed (`FIG_RESULT
PASS`, see `fig_performance_provenance.txt`). `docs/images/
performance_summary.png` is a copy of the PNG.

## Nelder-Mead search and marching-cubes mesher: step timings vs pool throughput

The 15-worker pool pins every job to one OpenMP thread and adds per-frame fixed
costs (coordinate write, worker hand-off, job script, parse), so it cannot show a
search engine that costs 88-120 ms a frame. Step timings on one GABA-A frame
(`protein or glycan`, 27,660 atoms, the benchmark's own system, medians of 3;
commands in the session notes, not in `reproduce.sh`):

| step | HOLE / sos_triangle | plugin engine, 1 thread | plugin engine, 8 threads |
|---|---|---|---|
| pore search (circular) | 0.120 s (Monte Carlo) | 0.083 s (1.45x) | 0.036 s (3.3x) |
| surface | 0.089 s (sph_process + sos_triangle, serial) | 0.060 s (1.5x) | 0.022 s (4.0x) |

Profiles agree to Monte Carlo noise: identical minimum radius (1.770 A), rms 0.059 A
over 519 slices. In the pool (`endtoend.csv`, 15 workers): marching cubes
1.61x the accelerated `sph_process` + `sos_triangle` path; Nelder-Mead
0.96x the accelerated HOLE search (no change - HOLE is not the pool's
bottleneck); both engines 1.58x. Single-frame latency (run + surface, one job, all
cores): Monte Carlo + sos_triangle 380 ms, Nelder-Mead + marching cubes 271 ms.
Not in Figure S2.
