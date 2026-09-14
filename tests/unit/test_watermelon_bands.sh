#!/bin/sh
# Watermelon radius bands: the 2D hex and the 3D colour slot agree band for
# band, edges are inclusive below and the top band is open above; and both
# engines colour a mesh by the radius of the sphere whose surface is nearest
# each triangle's centroid - checked triangle by triangle against an
# independent lookup, ties within the plot's print precision excepted.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
TCL="$ROOT/vmdpathfinder/vmdpathfinder.tcl"
F="$ROOT/vmdpathfinder/tests/fixtures/spherical_1GRM.sph"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  PASS  $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; }
echo "watermelon-bands"
command -v tclsh >/dev/null 2>&1 || { echo "SKIP: no tclsh"; exit 0; }
[ -f "$TCL" ] || { echo "SKIP: no plugin source"; exit 0; }

OUT=$(tclsh <<TCLEOF 2>&1
namespace eval ::VMDPathFinder {}
$(awk '/^proc ::VMDPathFinder::watermelon_levels /,/^}/' "$TCL")
$(awk '/^proc ::VMDPathFinder::watermelon_hex /,/^}/' "$TCL")
$(awk '/^proc ::VMDPathFinder::watermelon_vmd_color /,/^}/' "$TCL")
$(awk '/^proc ::VMDPathFinder::_watermelon_band_opts /,/^}/' "$TCL")
namespace eval ::VMDPathFinder {
    lassign [watermelon_levels] bounds hexes slots
    puts "SIZES [llength \$bounds] [llength \$hexes] [llength \$slots]"
    set agree 1
    foreach r {-1 0 0.5 1.25 1.2499 2.5 3.75 5 6.25 7.5 8.75 10 13.99 14 17.99 18 25} {
        set h [watermelon_hex \$r]; set c [watermelon_vmd_color \$r]
        if {[lsearch -exact \$hexes \$h] != [lsearch -exact \$slots \$c]} { set agree 0 }
    }
    puts "AGREE \$agree"
    puts "EDGE [watermelon_hex 1.2499] [watermelon_hex 1.25] [watermelon_hex 13.99] [watermelon_hex 18] [watermelon_hex 40] [watermelon_hex -3]"
    puts "OPTS [_watermelon_band_opts]"
}
TCLEOF
)
line() { printf '%s\n' "$OUT" | grep "^$1 " | head -1; }
[ "$(line SIZES)" = "SIZES 11 10 10" ] && ok "ten bands, eleven edges, ten colour slots" || bad "sizes: $(line SIZES)"
[ "$(line AGREE)" = "AGREE 1" ] && ok "hex and VMD slot pick the same band for every radius" || bad "agree: $(line AGREE)"
[ "$(line EDGE)" = "EDGE #000000 #b22222 #006400 #ffffff #ffffff #000000" ] && ok "edges inclusive below, top band open, negatives closed" || bad "edges: $(line EDGE)"
printf '%s\n' "$(line OPTS)" | grep -q -- "--bands 0,1.25,2.5,3.75,5,6.25,7.5,8.75,10,14,18 --band-names 1047,1048,1049,1050,1051,1052,1053,1054,1055,1056" \
    && ok "engine options carry the same edges and slots" || bad "opts: $(line OPTS)"

# ---- engine parity ----------------------------------------------------------
EXE=""
[ -x "$ROOT/native/sos_triangle_fast" ] && EXE="$ROOT/native/sos_triangle_fast"
if [ -z "$EXE" ] || [ ! -f "$F" ] || ! command -v python3 >/dev/null 2>&1; then
    echo "  SKIP  engine parity (needs native/sos_triangle_fast, the spherical fixture and python3)"
else
    TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
    B="0,1.25,2.5,3.75,5,6.25,7.5,8.75,10,14,18"; N="1047,1048,1049,1050,1051,1052,1053,1054,1055,1056"
    "$EXE" --mesh "$F" "$TMP/csg.vmd_plot" 0.5 --bands "$B" --band-names "$N" >/dev/null 2>&1
    "$EXE" --mesh "$F" "$TMP/base.vmd_plot" 0.5 --draw >/dev/null 2>&1
    "$EXE" --recolor "$TMP/base.vmd_plot" --hydro-sph "$F" --value-radius --bands "$B" --band-names "$N" > "$TMP/sos.vmd_plot" 2>/dev/null
    cat > "$TMP/check.py" <<'PY'
import sys, re, math
sph, plot = sys.argv[1], sys.argv[2]
edges=[0,1.25,2.5,3.75,5,6.25,7.5,8.75,10,14,18]; names=[str(1047+i) for i in range(10)]
S=[]
for l in open(sph):
    if not l.startswith(("ATOM","HETATM")): continue
    resid=int(l[22:26]); r=float(l[60:66])
    if resid in (-999,-888) or r>=999 or r<=0.005: continue
    S.append((float(l[30:38]),float(l[38:46]),float(l[46:54]),r))
def band(r):
    for i in range(10):
        if r<edges[i+1]: return names[i]
    return names[-1]
cur=None; n=0; bad=0
for l in open(plot):
    m=re.search(r'color (\S+)', l)
    if m and 'tri' not in l: cur=m.group(1); continue
    if 'trinorm' in l or 'triangle' in l:
        nums=[float(x) for x in re.findall(r'-?\d+\.\d+', l)]
        v=nums[0:3],nums[3:6],nums[6:9]; c=[(v[0][k]+v[1][k]+v[2][k])/3 for k in range(3)]
        ds=sorted(((math.sqrt((c[0]-x)**2+(c[1]-y)**2+(c[2]-z)**2)-r, r) for (x,y,z,r) in S))
        n+=1
        if band(ds[0][1])!=cur:
            alt=[d for d in ds if band(d[1])==cur]
            if not alt or alt[0][0]-ds[0][0] > 0.01: bad+=1
print(n, bad)
PY
    R1=$(python3 "$TMP/check.py" "$F" "$TMP/csg.vmd_plot"); R2=$(python3 "$TMP/check.py" "$F" "$TMP/sos.vmd_plot")
    set -- $R1; [ "${1:-0}" -gt 100 ] && [ "${2:-1}" -eq 0 ] && ok "mesher bands match the nearest-surface radius on $1 triangles" || bad "mesher: $R1"
    set -- $R2; [ "${1:-0}" -gt 100 ] && [ "${2:-1}" -eq 0 ] && ok "recolour bands match the nearest-surface radius on $1 triangles" || bad "recolour: $R2"
fi
echo "  -> $pass passed, $fail failed"
[ "$fail" -eq 0 ]
