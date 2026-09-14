#!/bin/sh
# Ellipse rows carry centroid-relative PCA coords; the Mean Profile and Over
# Time relabel them into HOLE's coord (c.u) so the tube sits on the pore.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
TCL="$ROOT/vmdpathfinder/vmdpathfinder.tcl"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  PASS  $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; }
echo "ellipse-rows-hole-coord"
command -v tclsh >/dev/null 2>&1 || { echo "SKIP: no tclsh"; exit 0; }
[ -f "$TCL" ] || { echo "SKIP: no plugin source"; exit 0; }
OUT=$(tclsh <<TCLEOF 2>&1
namespace eval ::VMDPathFinder {
    variable results [dict create 0 [dict create run_dir /nowhere]]
    proc _hole_coord_dir {rd centers} { return {0 0 1} }
}
$(awk '/^proc ::VMDPathFinder::_asym_assemble /,/^}/' "$TCL")
$(awk '/^proc ::VMDPathFinder::_asym_rows_hole_coords /,/^}/' "$TCL")
namespace eval ::VMDPathFinder {
    set centers {{1 2 40} {1 2 45} {1 2 50}}
    set radii {2 1 3}
    set u {0 0 1 1 2 45}
    lassign [_asym_assemble {{1 2 0} {1 1.5 0} {2 3 0}} \$centers \$radii \$u 36] rows kept
    puts "RAW [lsort -real [lmap r \$rows {lindex \$r 0}]]"
    puts "HOLE [_asym_rows_hole_coords 0 [list \$centers \$radii \$u \$rows]]"
    set rows2 [lrange \$rows 0 1]
    puts "UNALIGNED [_asym_rows_hole_coords 0 [list \$centers \$radii \$u \$rows2]]"
}
TCLEOF
)
line() { printf '%s\n' "$OUT" | grep "^$1 " | head -1; }
[ "$(line RAW)" = "RAW -5 0 5" ] && ok "assembled rows are centroid-relative" || bad "raw: $(line RAW)"
[ "$(line HOLE)" = "HOLE 40 45 50" ] && ok "relabelled rows carry HOLE's coord" || bad "hole: $(line HOLE)"
[ "$(line UNALIGNED)" = "UNALIGNED -5 0" ] && ok "an unaligned entry keeps its own coords" || bad "unaligned: $(line UNALIGNED)"
echo "  -> $pass passed, $fail failed"
[ "$fail" -eq 0 ]
