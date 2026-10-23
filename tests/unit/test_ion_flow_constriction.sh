#!/bin/sh
# The constriction plane every crossing is counted against is the trajectory's
# mean narrowest point, not the reference frame's own: one frame whose minimum
# sat 12 A away moved the CHAP example's count from 28/17 to 61/54.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
TCL="$ROOT/vmdpathfinder/vmdpathfinder.tcl"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  PASS  $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; }
echo "ion-flow-constriction"
command -v tclsh >/dev/null 2>&1 || { echo "SKIP: no tclsh"; exit 0; }
[ -f "$TCL" ] || { echo "SKIP: no plugin source"; exit 0; }
OUT=$(tclsh <<TCLEOF 2>&1
namespace eval ::VMDPathFinder {}
$(awk '/^proc ::VMDPathFinder::_ion_flow_mean_constriction /,/^}/' "$TCL")
namespace eval ::VMDPathFinder {
    # {bin sum count frames}: bin 80 is narrow in ONE frame of 10, bin 100 in all.
    set bins {{80 1.0 2 1} {90 40.0 20 10} {100 20.0 20 10} {110 60.0 20 10}}
    puts "Z [_ion_flow_mean_constriction \$bins 10 0.5]"
    puts "ORDER [_ion_flow_mean_constriction [lreverse \$bins] 10 0.5]"
    puts "NONE [_ion_flow_mean_constriction {{80 1.0 2 1}} 10 0.5]"
    puts "EMPTY [_ion_flow_mean_constriction {} 10 0.5]"
}
TCLEOF
)
line() { printf '%s\n' "$OUT" | grep "^$1 " | head -1; }
[ "$(line Z)" = "Z 50.0" ] && ok "narrowest bin of the mean, not one frame's dip" || bad "z: $(line Z) $OUT"
[ "$(line ORDER)" = "ORDER 50.0" ] && ok "independent of bin order" || bad "order: $(line ORDER)"
[ "$(line NONE)" = "NONE " ] && ok "no bin seen in half the frames: no answer" || bad "none: $(line NONE)"
[ "$(line EMPTY)" = "EMPTY " ] && ok "no bins: no answer" || bad "empty: $(line EMPTY)"
echo "  -> $pass passed, $fail failed"
[ "$fail" -eq 0 ]
