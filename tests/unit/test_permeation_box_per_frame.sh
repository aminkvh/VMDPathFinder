#!/bin/sh
# count_permeation must unwrap each step with THAT frame's box. `molinfo get
# {a b c}` without `frame` returns the current frame's box, which counted
# 325/353 instead of 347/376 on Treptow's Kv1.2-2.1 AMBER trajectory.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
TCL="$ROOT/vmdpathfinder/vmdpathfinder.tcl"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  PASS  $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; }
echo "permeation-box-per-frame"
command -v tclsh >/dev/null 2>&1 || { echo "SKIP: no tclsh"; exit 0; }
[ -f "$TCL" ] || { echo "SKIP: no plugin source"; exit 0; }
OUT=$(tclsh <<TCLEOF 2>&1
namespace eval ::VMDPathFinder { proc _warn_if_triclinic {m} {} }
# one ion; true z -20, -25, -20; box Lz 100, 40, 100; current frame = last
set ::Z {-20.0 15.0 -20.0}
set ::L {100.0 40.0 100.0}
set ::cur 0
proc molinfo {m get what args} {
    if {\$what eq "numframes"} { return 3 }
    set f 2
    if {[llength \$args] == 2 && [lindex \$args 0] eq "frame"} { set f [lindex \$args 1] }
    return [list 50.0 50.0 [lindex \$::L \$f]]
}
proc atomselect {m sel} { return ::fsel }
proc ::fsel {cmd args} {
    switch -- \$cmd {
        num { return 1 }
        frame { set ::cur [lindex \$args 0] }
        get { if {[lindex \$args 0] eq "z"} { return [list [lindex \$::Z \$::cur]] }; return [list [list 0.0 0.0 [lindex \$::Z \$::cur]]] }
        default { return }
    }
}
proc measure {args} { return {0.0 0.0 0.0} }
$(awk '/^proc ::VMDPathFinder::_perm_unreliable /,/^}/' "$TCL")
$(awk '/^proc ::VMDPathFinder::count_permeation /,/^}/' "$TCL")
set r [::VMDPathFinder::count_permeation 0 ion z -5 5]
puts "COUNT [dict get \$r up] [dict get \$r down]"
TCLEOF
)
line() { printf '%s\n' "$OUT" | grep "^$1 " | head -1; }
[ "$(line COUNT)" = "COUNT 0 0" ] && ok "each step unwrapped with its own frame's box" || bad "count: $(line COUNT) $OUT"
echo "  -> $pass passed, $fail failed"
[ "$fail" -eq 0 ]
