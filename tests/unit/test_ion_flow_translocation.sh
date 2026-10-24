#!/bin/sh
# Translocation = in one end of the crossing window, out the other (the definition that
# reproduces the Mironenko et al. KcsA counter, 51 / 0). Plus the gear's window fields.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
TCL="$ROOT/vmdpathfinder/vmdpathfinder.tcl"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  PASS  $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; }
echo "ion-flow-translocation"
command -v tclsh >/dev/null 2>&1 || { echo "SKIP: no tclsh"; exit 0; }
[ -f "$TCL" ] || { echo "SKIP: no plugin source"; exit 0; }
OUT=$(tclsh <<TCLEOF 2>&1
namespace eval ::VMDPathFinder {}
$(awk '/^proc ::VMDPathFinder::_ion_flow_visit_dir /,/^}/' "$TCL")
$(awk '/^proc ::VMDPathFinder::_ion_flow_window_from_fields /,/^}/' "$TCL")
$(awk '/^proc ::VMDPathFinder::_ion_flow_plane_label /,/^}/' "$TCL")
namespace eval ::VMDPathFinder {
    variable state
    set state(ion_flow_window) {}
    puts "PL0 [_ion_flow_plane_label]"
    set state(ion_flow_window) {8 51.8 60.7 56.3}
    puts "PL1 [_ion_flow_plane_label]"
    puts "DIR [_ion_flow_visit_dir below above] [_ion_flow_visit_dir above below] [_ion_flow_visit_dir below below] [_ion_flow_visit_dir below inside] [_ion_flow_visit_dir {} above]"
    puts "W1 [_ion_flow_window_from_fields set 3 -6 8 1]"
    puts "W2 [_ion_flow_window_from_fields set 3 8 -6 {}]"
    puts "W3 \[[_ion_flow_window_from_fields auto 3 -6 8 1]\]"
    puts "W4 \[[_ion_flow_window_from_fields set 0 -6 8 1]\] \[[_ion_flow_window_from_fields set 3 x 8 1]\] \[[_ion_flow_window_from_fields set 3 5 5 1]\]"
}
TCLEOF
)
line() { printf '%s\n' "$OUT" | grep "^$1 " | head -1; }
[ "$(line DIR)" = "DIR up down recross incomplete incomplete" ] && ok "in at one end, out the other; same end = returned; sideways or unseen = unresolved" || bad "dir: $(line DIR) $OUT"
[ "$(line W1)" = "W1 3 -6 8 1" ] && ok "window fields with a plane" || bad "w1: $(line W1)"
[ "$(line W2)" = "W2 3 -6 8" ] && ok "reversed ends are swapped; blank plane = narrowest point" || bad "w2: $(line W2)"
[ "$(line W3)" = "W3 []" ] && ok "Auto clears the window" || bad "w3: $(line W3)"
[ "$(line W4)" = "W4 [] [] []" ] && ok "zero radius, non-numeric or equal ends are rejected" || bad "w4: $(line W4)"
[ "$(line PL0)" = "PL0 constriction" ] && ok "Auto: the plane is the constriction" || bad "pl0: $(line PL0) $OUT"
[ "$(line PL1)" = "PL1 crossing plane" ] && ok "a set window labels its plane as the crossing plane" || bad "pl1: $(line PL1)"
echo "  -> $pass passed, $fail failed"
[ "$fail" -eq 0 ]
