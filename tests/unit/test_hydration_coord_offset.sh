#!/bin/sh
# Hydration bins are stored relative to their binning origin; the tab, the CSV
# export and the Over Time heatmap show them in HOLE's coord frame (the plain
# projection onto the axis), the frame the Pore Profile and Ion & Water tabs
# already use. coord_offset carries the shift; profiles saved without it fall
# back to the stored axis when the origin was static, else to 0.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
TCL="$ROOT/vmdpathfinder/vmdpathfinder.tcl"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  PASS  $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; }
echo "hydration-coord-offset"
command -v tclsh >/dev/null 2>&1 || { echo "SKIP: no tclsh"; exit 0; }
[ -f "$TCL" ] || { echo "SKIP: no plugin source"; exit 0; }

OUT=$(tclsh <<TCLEOF 2>&1
namespace eval ::VMDPathFinder { variable hydration_data {} }
$(awk '/^proc ::VMDPathFinder::_hydration_coord_offset /,/^}/' "$TCL")
$(awk '/^proc ::VMDPathFinder::_hydration_display_coords /,/^}/' "$TCL")
namespace eval ::VMDPathFinder {
    set hydration_data [dict create coords {-1.5 -0.5 0.5} coord_offset 44.97 axis_mode pca axis {}]
    puts "STORED [format %.2f [_hydration_coord_offset]] [_hydration_display_coords]"
    # axis {mx my mz ux uy uz}: origin (10 20 30) on the z axis -> 30
    set hydration_data [dict create coords {-1.5 -0.5 0.5} axis_mode cpoint axis {10 20 30 0 0 1}]
    puts "CPOINT [format %.2f [_hydration_coord_offset]] [_hydration_display_coords]"
    set hydration_data [dict create coords {-1.5 -0.5 0.5} axis_mode pca axis {10 20 30 0 0 1}]
    puts "PCA [format %.2f [_hydration_coord_offset]] [_hydration_display_coords]"
    set hydration_data {}
    puts "EMPTY [format %.2f [_hydration_coord_offset]] [llength [_hydration_display_coords]]"
}
TCLEOF
)
line() { printf '%s\n' "$OUT" | grep "^$1 " | head -1; }
[ "$(line STORED)" = "STORED 44.97 43.47 44.47 45.47" ] && ok "a stored coord_offset shifts the displayed coords" || bad "stored: $(line STORED)"
[ "$(line CPOINT)" = "CPOINT 30.00 28.5 29.5 30.5" ] && ok "no field, static origin: offset from the stored axis" || bad "cpoint: $(line CPOINT)"
[ "$(line PCA)" = "PCA 0.00 -1.5 -0.5 0.5" ] && ok "no field, per-frame origin: coords unchanged" || bad "pca: $(line PCA)"
[ "$(line EMPTY)" = "EMPTY 0.00 0" ] && ok "no hydration data: offset 0, no coords" || bad "empty: $(line EMPTY)"
echo "  -> $pass passed, $fail failed"
[ "$fail" -eq 0 ]
