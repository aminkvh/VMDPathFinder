#!/bin/sh
# Transport reliability gates. frac_wrap counted every step after an ion's
# first box crossing as a wrap (0.90 on a trajectory with 0.3 A in-pore
# steps); the Ion & Water crossings had no frame-spacing check at all.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
TCL="$ROOT/vmdpathfinder/vmdpathfinder.tcl"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  PASS  $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; }
echo "transport-reliability"
command -v tclsh >/dev/null 2>&1 || { echo "SKIP: no tclsh"; exit 0; }
[ -f "$TCL" ] || { echo "SKIP: no plugin source"; exit 0; }
OUT=$(tclsh <<TCLEOF 2>&1
namespace eval ::VMDPathFinder { proc _warn_if_triclinic {m} {} }
# one ion crossing the +z box face once (true z 48 -> 52, box 100), then 1 A steps
set ::Z {46.0 48.0 -48.0 -47.0 -46.0 -45.0 -44.0 -43.0 -42.0 -41.0}
set ::cur 0
proc molinfo {m get what args} {
    if {\$what eq "numframes"} { return [llength \$::Z] }
    return {100.0 100.0 100.0}
}
proc atomselect {m sel} { return ::fsel }
proc ::fsel {cmd args} {
    switch -- \$cmd {
        num { return 1 }
        frame { set ::cur [lindex \$args 0] }
        get { return [list [lindex \$::Z \$::cur]] }
        default { return }
    }
}
proc measure {args} { return {0.0 0.0 0.0} }
$(awk '/^proc ::VMDPathFinder::_perm_unreliable /,/^}/' "$TCL")
$(awk '/^proc ::VMDPathFinder::count_permeation /,/^}/' "$TCL")
$(awk '/^proc ::VMDPathFinder::_ion_flow_resolution /,/^}/' "$TCL")
namespace eval ::VMDPathFinder {
    set r [count_permeation 0 ion z -5 5]
    puts "WRAP [format %.3f [dict get \$r frac_wrap]] [dict get \$r unreliable]"
    puts "GATE [_perm_unreliable 0.0 20.0 55.0] [_perm_unreliable 0.0 10.0 55.0] [_perm_unreliable 0.5 1.0 55.0]"
    puts "RES1 [_ion_flow_resolution {{12.0 0} {13.0 1} {14.0 2}} {{0 5.0} {1 2.2} {2 6.0}}]"
    puts "RES2 [_ion_flow_resolution {{0.3 0} {0.3 1} {0.4 0}} {{0 0.45} {1 2.0}}]"
    puts "RES3 [_ion_flow_resolution {} {{0 2.0}}]"
    puts "RES4 [_ion_flow_resolution {{1.2 5} {1.1 5} {0.3 0}} {{0 0.6} {5 5.0}}]"
}
TCLEOF
)
line() { printf '%s\n' "$OUT" | grep "^$1 " | head -1; }
[ "$(line WRAP)" = "WRAP 0.111 0" ] && ok "one box crossing is one wrap event, not a wrap on every later step" || bad "wrap: $(line WRAP) $OUT"
[ "$(line GATE)" = "GATE 1 0 1" ] && ok "unreliable when the median step exceeds a quarter of half the box" || bad "gate: $(line GATE)"
[ "$(line RES1)" = "RES1 13.0 2.4 1" ] && ok "steps several times the local radius are unresolved" || bad "res1: $(line RES1)"
[ "$(line RES2)" = "RES2 0.3 0.3 0" ] && ok "sub-angstrom radius floors at 1 A" || bad "res2: $(line RES2)"
[ "$(line RES3)" = "RES3 {} {} 0" ] && ok "no in-pore steps: no verdict" || bad "res3: $(line RES3)"
[ "$(line RES4)" = "RES4 1.1 0.24 0" ] && ok "fast steps in a wide cavity are not flagged" || bad "res4: $(line RES4)"
echo "  -> $pass passed, $fail failed"
[ "$fail" -eq 0 ]
