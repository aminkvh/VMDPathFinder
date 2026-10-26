#!/bin/sh
# Region passages: the ordered four-region rule of Mironenko et al.'s counter, and the
# per-region selection text (ends and optional radial limit).
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
TCL="$ROOT/vmdpathfinder/vmdpathfinder.tcl"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  PASS  $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; }
echo "ion-flow-region"
command -v tclsh >/dev/null 2>&1 || { echo "SKIP: no tclsh"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "SKIP: no python3"; exit 0; }
[ -f "$TCL" ] || { echo "SKIP: no plugin source"; exit 0; }
# reference: the authors' track_permeations state machine, verbatim logic, on random walks
REF=$(python3 -I - <<'PY'
import random
random.seed(7)
def ref(seq):
    s0, s1, up, dn = 0, 5, 0, 0
    for i in seq:
        if i == s0 + 1: s0 += 1
        elif s0 == 4 and i == 1: s0 = 1
        elif i == s0 - 1: s0 -= 1
        elif s0 == 1 and i == 4: s0 = 0
        if i == s1 - 1: s1 -= 1
        elif s1 == 1 and i == 4: s1 = 4
        elif i == s1 + 1: s1 += 1
        elif s1 == 4 and i == 1: s1 = 5
        if s0 == 4: s0 = 0; up += 1
        if s1 == 1: s1 = 5; dn += 1
    return up, dn
for _ in range(300):
    seq = [random.randint(1, 4) for _ in range(random.randint(1, 40))]
    print(" ".join(map(str, seq)) + "|%d %d" % ref(seq))
PY
)
OUT=$(printf '%s\n' "$REF" | tclsh 3<&0 <<TCLEOF 2>&1
namespace eval ::VMDPathFinder {}
$(awk '/^proc ::VMDPathFinder::_ion_flow_region_walk /,/^}/' "$TCL")
$(awk '/^proc ::VMDPathFinder::_ion_flow_region_seltext /,/^}/' "$TCL")
namespace eval ::VMDPathFinder {
    set bad 0; set n 0
    set fh [open /dev/fd/3]
    while {[gets \$fh line] >= 0} {
        lassign [split \$line |] seq want
        if {[_ion_flow_region_walk \$seq] ne \$want} { incr bad; puts "MISMATCH \$seq got [_ion_flow_region_walk \$seq] want \$want" }
        incr n
    }
    puts "RW \$n \$bad"
    puts "W1 [_ion_flow_region_walk {1 2 3 4}] [_ion_flow_region_walk {4 3 2 1}] [_ion_flow_region_walk {1 2 3 4 1 2 3 4}] [_ion_flow_region_walk {1 2 1 2 3 2 3 4}]"
    puts "S1 [_ion_flow_region_seltext 2 {0 0 1} 1 2 3 {0 0 0} {}]"
    puts "S4 [_ion_flow_region_seltext 4 {0 0 1} 1 2 3 {0 0 0} 5]"
}
TCLEOF
)
line() { printf '%s\n' "$OUT" | grep "^$1 " | head -1; }
[ "$(line RW)" = "RW 300 0" ] && ok "state machine matches the authors' counter on 300 random region sequences" || bad "rw: $(line RW) $(printf '%s\n' "$OUT" | head -5)"
[ "$(line W1)" = "W1 1 0 0 1 2 0 1 0" ] && ok "up, down, two cycles, backtracking walk" || bad "w1: $(line W1)"
[ "$(line S1)" = "S1 (x*0+y*0+z*1) >= 1 and (x*0+y*0+z*1) < 2" ] && ok "region 2 text, no radial limit" || bad "s1: $(line S1)"
case "$(line S4)" in
  "S4 (x*0+y*0+z*1) >= 3 or (("*" > 25) and (x*0+y*0+z*1) >= 2)") ok "region 4 with R: off-axis above the midpoint counts as above" ;;
  *) bad "s4: $(line S4)" ;;
esac
echo "  -> $pass passed, $fail failed"
[ "$fail" -eq 0 ]
