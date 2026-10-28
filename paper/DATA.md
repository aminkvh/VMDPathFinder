# Getting the trajectory data

Trajectories are **not** in this repository. They are large, they are published
elsewhere with their own DOIs, and a public code repository is the wrong place
to redistribute them. Download what you need and drop it into the directory
named below — every script here looks for it there.

Nothing on this page is required to *use* the plugin. It is only needed to
reproduce the validation and benchmark results.

---

## DhaA — validation against CAVER's own published results

**Zenodo: [10.5281/zenodo.7234700](https://doi.org/10.5281/zenodo.7234700)** —
*"Divide-and-conquer approach to study protein tunnels in long molecular
dynamics simulations"*.

This record is used because it carries **both halves**: the trajectory and
CAVER 3's own results computed on those exact frames. The reference is therefore
measured on the same data, not reconstructed from a paper.

Download the record and place two of its directories here:

```
paper/case_studies/
  01_inputs/                 <- from the Zenodo record
    trajectory.nc                10,000 frames, 4,649 atoms
    structure.parm7              Amber topology
    to_pdb.cppin                 cpptraj input, frames -> PDB
    rename.py                    splits the PDBs into eight parts
  04_full_trajectory/        <- from the same record
    caver_config.txt             CAVER 3's exact configuration
    out/                         CAVER 3's own results on these frames
```

> Note: CAVER's own download page offers the same simulation, but its only
> host (`decibel.fi.muni.cz`) refuses connections. The Zenodo record is the
> working source.

## Small single-structure inputs (auto-fetched)

Every PDB the case studies and benchmarks use is public, small, and has one
stable download URL - unlike the trajectory below, so these are **not**
checked in, and **not** manually placed either: run

```
sh paper/benchmarks/fetch_structures.sh
```

once, and it downloads each from RCSB into the paths every script already
expects (already-present files are left alone, so it is safe to re-run any
time). It also derives `fixtures/tunnel_vs_mole2/1MXT_noHET.pdb` from 1MXT.pdb
(ATOM records only, no HETATM, primary/blank altloc). `reproduce.sh` and
`bench_tunnel_vs_mole2.sh` both call it automatically; nothing else needs to.

| Structure | Used by |
|---|---|
| 1GRM | Case 1 (gramicidin A tutorial) |
| 9HNR | Case 2 (hydrophobic gating) |
| 1BL8 | Case 3, and the MOLE 2 reference/timing benchmarks |
| 1ERI | MOLE 2 reference/timing benchmarks |
| 1MXT | Case 5 (1MXT_mole2), and the MOLE 2 reference/timing benchmarks |

**Note on 1BL8**: RCSB's current file carries four HETATM records (three K+
ions and one water) that an earlier archived copy of this repository's fixture
did not. The protein's own ATOM coordinates are unchanged. If a benchmark
number depends on the pore being ion-free, pass a stripped copy instead of
relying on the auto-fetch.

### Real upstream MOLE 2 (optional, for the head-to-head timing benchmark)

`paper/benchmarks/real_mole_build/` expects a real, working `mole2.exe` built
from MOLE's own source under mono - a vendored third-party binary is not
checked in. `bench_tunnel_vs_mole2.sh` refuses cleanly if it is missing; see
`real_mole_build/README.md` for the full build recipe (it already worked once,
with every step recorded, including the three source patches needed for a
modern mono).

## Case 4 — the flagship MD trajectory

`paper/case_studies/case4_trajectory_flagship/` expects a membrane-protein
trajectory with a visible pore change over time:

```
case4_trajectory_flagship/
  sim_1.dcd
  step5_assembly.hmr.psf
```

Any CHARMM-GUI-style membrane system with the pore axis along z will do; see
that directory's own README for what the case is meant to show. Substitute your
own — nothing downstream depends on this being one specific system.

## What works without any of this

- The plugin itself, entirely.
- The tutorial — [gramicidin A](case1_gramicidin_1GRM/) ships in the repository.
- Cases 2, 3 and 5 — one `fetch_structures.sh` run gets their PDB inputs.
- Most of the test groups (`vmdpathfinder/tests/run_tests.sh`).

The groups that skip need locally built HOLE binaries
(`native/stock_build/`, `vmdpathfinder/hole_tcl/reference_bin/`), not trajectory data.
Build them with `sh native/build-vmdpathfinder-optimized.sh`.

## If a script cannot find the data

It says so and stops. `paper/benchmarks/reproduce.sh` is staged and fails
loudly on missing inputs rather than quietly producing a smaller number — a
benchmark that silently runs on less data is worse than one that refuses.

---

## The replication deposit

Everything that produced `benchmarks/results/*.csv` but is not itself a
reported number lives in one archive with one DOI:

**Zenodo: https://doi.org/10.5281/zenodo.22088514** (all versions; version 1.1.0 holds
`VMDPathFinder-replication-kit-1.1.0.tar.gz`, built from release v1.1.0)

Contents: the complete `paper/benchmarks/` harness (reproduce.sh, every
bench_* stage, comparison fixtures including the frozen 50-frame tunnel pool
and the CAVER/PoreAnalyser inputs), the case studies (inputs, outputs,
renders), the raw provenance logs behind each CSV, the rendered figures, the
`native/` benchmark corpus and unmodified-upstream reference copy, and the
ion-flow post-analysis helper. Unpack the archive over a repository checkout
and every path lands where the scripts expect it.

### The Tier-2 trajectory (GABA-A, 50 frames)

The trajectory behind the end-to-end and scaling benchmarks and the Nav case
study has its own versioned deposit:
**https://doi.org/10.5281/zenodo.20705736** (v3). `reproduce.sh --tier2`
takes its directory via `--data`; the harness names this DOI in its own
error message when the files are absent.

The CSVs the paper quotes stay IN the repository — a reviewer diffing the
numbers needs those, not fifty raw `out.dat` dumps.
