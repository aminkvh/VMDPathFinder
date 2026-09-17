# Installation

## Requirements

- VMD with Tcl/Tk support for the graphical interface
- A supported VMDPathFinder release for your operating system
- For a local binary rebuild: a POSIX shell, `make`, Python 3, Git, and C and
  Fortran compilers with OpenMP and legacy-Fortran support (on Windows,
  MSYS2/MinGW-w64 provides all of these; there is no other Windows-specific
  step)

VMDPathFinder can run without external executables, but the Tcl fallbacks are much
slower and are discouraged for trajectories and production work.

## 1. Install the plugin

Download and extract a release, or clone the repository. Keep the `vmdpathfinder`
directory intact. Add its parent directory to VMD's Tcl search path in `.vmdrc`:

```tcl
lappend auto_path /absolute/path/to/VMDPathFinder
package require vmdpathfinder 1.0
```

Restart VMD and open **Extensions → Analysis → VMDPathFinder**.

## 2. Install the VMDPathFinder binaries (highly recommended)

### Rebuild locally at `-O2` (recommended)

A local rebuild uses your compiler and platform and builds the complete VMDPathFinder
binary set: accelerated HOLE, Connolly, Capsule, `sph_process`, surface
processing, and tunnel search. From the repository, run:

```sh
./native/build-vmdpathfinder-optimized.sh
```

With no argument, the script clones the pinned HOLE 2 source revision and
builds into `native/build/`. To use an existing source checkout or another
output directory:

```sh
./native/build-vmdpathfinder-optimized.sh /path/to/hole2/src /path/to/output
```

The default build uses `-O2` without `-march=native`. Do not distribute a build
made with `-march=native`; it is CPU-specific and may change floating-point
rounding.

The downloaded [HOLE 2 source](https://github.com/osmart/hole2) is Apache-2.0
licensed. Its license and attribution files are included with VMDPathFinder.

### Use the release binaries

Each supported-platform bundle is built at `-O0` and matched to a VMDPathFinder
release. The current bundle provides the surface helper
`sos_triangle_fast` and the `mole_tunnel_engine`. Select these files directly
in **File → Settings**. Use a local rebuild for the complete accelerated HOLE,
Connolly, Capsule, and `sph_process` set. Keep every binary matched to the
plugin release and verify published checksums when available.

### Existing stock HOLE 2 (supported, not recommended)

An unmodified HOLE 2 installation can provide `hole`, `sph_process`,
`sos_triangle`, and a radius file. It lacks the VMDPathFinder acceleration patches,
can be substantially slower, and its surface converter can fail on large,
high-density Connolly surfaces. Use the VMDPathFinder release binaries or a local
`-O2` rebuild for routine work.

### Tcl fallbacks (compatibility only)

Leaving an executable path empty permits an embedded fallback where one is
available. This is useful when no compatible binary can run, but it is
substantially slower and does not implement every native feature. Do not use it
as the normal trajectory workflow.

## 3. Configure and confirm acceleration

Open **File → Settings** and select:

| Field | File |
|---|---|
| Surface mesher | Marching cubes (default) or `sos_triangle` |
| HOLE exe | `hole` |
| `sph_process` | `sph_process` |
| `sos_triangle` | `sos_triangle` from a local rebuild, or release `sos_triangle_fast`. The marching-cubes mesher, the Nelder-Mead search and the Connolly classifier are built into it |
| MOLE tunnel engine | `mole_tunnel_engine` |
| Radius file | an appropriate HOLE `.rad` file; **Preset** lists the shipped ones, including `martini2.rad` and `martini3.rad` |

VMDPathFinder checks the selected files in this window. The HOLE, `sph_process`, and
`sos_triangle` rows show green **accelerated** indicators when the VMDPathFinder
features are recognized; stock binaries show **not accelerated**. The tunnel
engine row reports **detected** or **not detected**. Hover over an indicator for
details, then save the settings for future sessions.

## 4. Verify the installation

Load `vmdpathfinder/1GRM.pdb`, set **Selection** to `all`, and follow the
[quick start](quickstart.md). The VMD console identifies the executable or
fallback used by each stage.

## Upgrade

Replace the complete `vmdpathfinder` directory; do not mix files from different
releases. Replace or rebuild the matching binaries, then reopen **File →
Settings** and confirm their acceleration status. Existing user defaults remain
in `~/.vmdpathfinder_config`.
