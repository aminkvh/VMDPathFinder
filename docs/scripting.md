# Tcl and headless use

VMDPathFinder's pore workflow can be driven from the VMD Tk Console or from a script
passed to `vmd -dispdev text -e`. Pin the VMDPathFinder version used by a script,
because state names and result fields can change between releases.

## Loading the plugin

After `install.sh` the package is on VMD's search path once its directory is
appended to `auto_path`; a checkout can be sourced directly instead. Either
form loads without Tk, so it works under `-dispdev text`:

```tcl
lappend auto_path $env(HOME)/.vmd/plugins/vmdpathfinder
package require vmdpathfinder 1.0
# or: source /absolute/path/to/VMDPathFinder/vmdpathfinder/vmdpathfinder.tcl
::VMDPathFinder::init_executables
```

## Minimal pore script

```tcl
lappend auto_path $env(HOME)/.vmd/plugins/vmdpathfinder
package require vmdpathfinder 1.0
::VMDPathFinder::init_executables

set molid [mol new /data/channel.pdb]
mol addfile /data/channel.xtc molid $molid waitfor all

set ::VMDPathFinder::state(molid) $molid
set ::VMDPathFinder::state(selection) "protein"
set ::VMDPathFinder::state(frame_spec) "0:10:1000"
set ::VMDPathFinder::state(cpoint) "12.3 4.5 -6.7"
set ::VMDPathFinder::state(cvect) "0 0 1"
set ::VMDPathFinder::state(radius_file) "/opt/hole2/rad/simple.rad"
set ::VMDPathFinder::state(display_mode) "none"
set ::VMDPathFinder::state(work_dir) "/data/results/channel"
set ::VMDPathFinder::state(save_results) 1

if {![::VMDPathFinder::run_analysis]} {
    puts stderr "VMDPathFinder failed: $::VMDPathFinder::state(status)"
    exit 1
}

foreach frame $::VMDPathFinder::result_frames {
    set profile [dict get $::VMDPathFinder::results $frame profile]
    puts "$frame,[dict get $profile min_radius]"
}
exit 0
```

Run it with:

```sh
vmd -dispdev text -e analyse.tcl
```

`run_analysis` returns `1` when the run completes and `0` for a cancelled or
failed run. Hard validation errors can also be raised as Tcl errors before
execution; production scripts should wrap the call in `catch` and return a
nonzero process status.

## Set native executable paths

`init_executables` reads saved configuration. Paths can also be set explicitly:

```tcl
set ::VMDPathFinder::state(hole_exec) "/opt/vmdpathfinder/bin/hole"
set ::VMDPathFinder::state(sph_process_exec) "/opt/vmdpathfinder/bin/sph_process"
set ::VMDPathFinder::state(sos_triangle_exec) "/opt/vmdpathfinder/bin/sos_triangle"
```

An empty path permits an embedded fallback where supported. This is useful for
portability but can be much slower.

## Channel axis without coordinates

`cpoint` and `cvect` accept a literal `x y z`, an atom selection (its centre
of geometry, re-evaluated per frame), or nothing:

- A blank field is resolved once per run by HOLE's own CGUESS (the same rule
  as leaving the GUI field empty).
- `suggest_cvect 1` runs the GUI's **Guess** button: membrane normal, then
  channel symmetry axis, then inertia long axis; it writes `state(cvect)` and
  returns which method was used.

The value a run actually used is in its parameter file (`run_*.txt`) and from
`_run_axis_manifest cpoint` / `cvect`, marked `(guessed)` when it was not
supplied.

```tcl
set ::VMDPathFinder::state(cpoint) ""
set ::VMDPathFinder::state(cvect)  ""
puts "axis from: [::VMDPathFinder::suggest_cvect 1]"
::VMDPathFinder::run_analysis
puts "used [::VMDPathFinder::_run_axis_manifest cpoint] / [::VMDPathFinder::_run_axis_manifest cvect]"
```

## Many structures in one job

Load each structure, point `state(molid)` at it, run, read, delete. The state
block is shared, so set every field you rely on inside the loop; a blank axis
is re-guessed for each structure.

```tcl
set fh [open /data/results/summary.csv w]
puts $fh "structure,cpoint,cvect,min_radius_A"
foreach pdb [glob /data/structures/*.pdb] {
    set molid [mol new $pdb waitfor all]
    set ::VMDPathFinder::state(molid) $molid
    set ::VMDPathFinder::state(selection) "protein"
    set ::VMDPathFinder::state(frame_spec) "now"
    set ::VMDPathFinder::state(cpoint) ""
    set ::VMDPathFinder::state(cvect) ""
    set ::VMDPathFinder::state(display_mode) "none"
    set ::VMDPathFinder::state(work_dir) "/data/results/[file rootname [file tail $pdb]]"
    set ::VMDPathFinder::state(save_results) 1
    ::VMDPathFinder::suggest_cvect 1
    if {[catch {::VMDPathFinder::run_analysis} ok] || !$ok} {
        puts stderr "$pdb: $::VMDPathFinder::state(status)"
        mol delete $molid
        continue
    }
    set f [lindex $::VMDPathFinder::result_frames 0]
    puts $fh "[file tail $pdb],[::VMDPathFinder::_run_axis_manifest cpoint],[::VMDPathFinder::_run_axis_manifest cvect],[dict get $::VMDPathFinder::results $f profile min_radius]"
    mol delete $molid
}
close $fh
```

For trajectories, replace `mol new` with `mol new` + `mol addfile ... waitfor all`
and set `frame_spec` to a range.

## Frame specification

`state(frame_spec)` accepts the same syntax as the GUI: `now`, `all`, a frame
number, `start:end`, or `start:stride:end`.

## Read results without dialogs

GUI export procedures open file-selection dialogs and should not be called in
text mode. Read result dictionaries or metric helpers directly and write output
in the calling script:

```tcl
foreach frame $::VMDPathFinder::result_frames {
    set metrics [::VMDPathFinder::metrics_for_frame $frame]
    if {$metrics eq ""} { continue }
    puts "$frame,[dict get $metrics min_radius],[dict get $metrics volume]"
}
```

Record the VMDPathFinder version with scripted output.

## Using the results outside VMD

There is no direct MDAnalysis bridge. With **Save results** on, each frame
directory holds HOLE's sphere file (`hole_out.sph`, PDB-like `ATOM` records
with the sphere radius in the last two columns) and the profile
(`hole_profile.tsv`: `coord`, `radius`, …). Both are plain text; `pandas`
reads the TSV and the CSV exports directly, and the `.sph` file is the same
format MDAnalysis's `hole2` module writes for its own runs.

## Headless limitations

Do not call `vmdpathfinder_tk`, `show_gui`, dialog procedures, or GUI export commands
under `-dispdev text`. Load coordinates before calling the analysis and ensure
that output paths are absolute and writable. Console logs contain engine paths,
warnings, failed frames, and the saved result root; capture them with the batch
job.

Tunnel analysis can also be configured through `state(tunnel_...)` and
`run_tunnel_analysis`, but the state keys are more extensive. Use the values in
the [parameter reference](parameters.md#tunnel-search), generate a run once in
the GUI, and pin that VMDPathFinder version before automating a tunnel pipeline.
