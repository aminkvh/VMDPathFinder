#!/bin/sh
# Martini 2 and 3 radius files: every bead of a martinized protein resolves
# to its force-field radius through HOLE's first-match rules, the files stay
# under HOLE's 100-rule limit, and the ion fallback splice cannot override a
# Martini ion.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
TCL="$ROOT/vmdpathfinder/vmdpathfinder.tcl"
RAD="$ROOT/vmdpathfinder/rad"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  PASS  $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; }
echo "martini-rad"
command -v tclsh >/dev/null 2>&1 || { echo "SKIP: no tclsh"; exit 0; }
[ -f "$RAD/martini3.rad" ] && [ -f "$RAD/martini2.rad" ] || { bad "rad files missing"; exit 1; }
OUT=$(tclsh <<TCLEOF 2>&1
namespace eval ::VMDPathFinder { variable ION_RADIUS_FALLBACK {{{NA SOD SODIUM} 0.95} {{CL CLA CHLORIDE} 1.81}} }
namespace eval hole {}
$(awk '/^proc hole::read_rad_file /,/^}/' "$TCL")
$(awk '/^proc hole::element_radius /,/^}/' "$TCL")
$(awk '/^proc hole::radius_for /,/^}/' "$TCL")
$(awk '/^proc ::VMDPathFinder::_ion_radius_fallback_lines /,/^}/' "$TCL")
$(awk '/^proc ::VMDPathFinder::_write_ion_fallback_radius_file /,/^}/' "$TCL")
foreach {ver expect} {martini3 {ALA SC1 1.70 ALA BB 2.05 PHE SC1 2.05 W W 2.35 NA NA 1.77 ZZZ ZZZ 2.35} martini2 {ALA SC1 2.35 PHE SC1 2.15 TRP SC2 2.15 W W 2.35 NA+ NA+ 2.35 ZZZ ZZZ 2.35}} {
    set rules [hole::read_rad_file $RAD/\$ver.rad]
    puts "NRULES \$ver [llength \$rules]"
    foreach {rn an v} \$expect {
        puts "SIZE \$ver \$rn \$an [hole::radius_for \$rules \$an \$rn] expect \$v"
    }
    set fh [open $HERE/fixtures/\${ver}_kcsa_pairs.txt]
    set miss {}; set n 0
    while {[gets \$fh line] >= 0} {
        if {[string match "#*" \$line] || [string trim \$line] eq ""} continue
        lassign \$line an rn want
        incr n
        set got [hole::radius_for \$rules \$an \$rn]
        if {\$got != \$want} { lappend miss "\$an/\$rn=\$got(\$want)" }
    }
    close \$fh
    puts "COVER \$ver \$n beads, wrong: [llength \$miss] \$miss"
}
# ion fallback splice: NA keeps the Martini radius
set dest [file join [pwd] martini3_ionfb.rad]
::VMDPathFinder::_write_ion_fallback_radius_file $RAD/martini3.rad \$dest
set rules [hole::read_rad_file \$dest]
puts "IONFB NA [hole::radius_for \$rules NA NA] SOD [hole::radius_for \$rules SOD SOD]"
file delete \$dest
TCLEOF
)
line() { printf '%s\n' "$OUT" | grep "^$1" | head -1; }
for v in martini3 martini2; do
    n=$(printf '%s\n' "$OUT" | grep "^NRULES $v" | awk '{print $3}')
    [ "${n:-0}" -gt 20 ] && [ "$n" -le 100 ] && ok "$v.rad parses ($n rules, under HOLE's 100)" || bad "$v.rad: $n rules"
    for l in $(printf '%s\n' "$OUT" | grep "^SIZE $v" | tr ' ' '_'); do
        set -- $(echo "$l" | tr '_' ' ')
        [ "$5" = "$7" ] && ok "$v $3 $4 = $7" || bad "$v $3 $4 = $5 (expected $7)"
    done
    c=$(printf '%s\n' "$OUT" | grep "^COVER $v")
    case "$c" in *"wrong: 0 "*|*"wrong: 0") ok "$v: every KcsA bead gets its force-field radius (${c#COVER $v })" ;; *) bad "$v coverage: $c" ;; esac
done
[ "$(line IONFB)" = "IONFB NA 1.77 SOD 0.95" ] && ok "the ion fallback keeps Martini NA and still adds SOD" || bad "ionfb: $(line IONFB)"
echo "  -> $pass passed, $fail failed"
[ "$fail" -eq 0 ]
