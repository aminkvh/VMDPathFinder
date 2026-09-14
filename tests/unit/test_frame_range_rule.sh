#!/bin/sh
# A frame RANGE ("all", "N:M", "N:S:M") defines the result set; single frames
# and "now" add to it. And the Ion & Water scan covers the analysed span only.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
TCL="$ROOT/vmdpathfinder/vmdpathfinder.tcl"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  PASS  $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; }
echo "frame-range-rule"
command -v tclsh >/dev/null 2>&1 || { echo "SKIP: no tclsh"; exit 0; }
[ -f "$TCL" ] || { echo "SKIP: no plugin source"; exit 0; }
OUT=$(tclsh <<TCLEOF 2>&1
namespace eval ::VMDPathFinder {
    variable result_frames {3 4 5}; variable tunnel_result_frames {}
    proc analysis_mode {} { return hole }
}
proc molinfo {m get what} { return 12 }
$(awk '/^proc ::VMDPathFinder::_frame_spec_is_range /,/^}/' "$TCL")
$(awk '/^proc ::VMDPathFinder::_ion_flow_frame_span /,/^}/' "$TCL")
namespace eval ::VMDPathFinder {
    puts "RANGE [_frame_spec_is_range all] [_frame_spec_is_range 1:11] [_frame_spec_is_range 0:10:100] [_frame_spec_is_range now] [_frame_spec_is_range 5] [_frame_spec_is_range 3,7]"
    puts "SPAN [_ion_flow_frame_span 0]"
    set result_frames {}
    puts "SPAN-EMPTY [_ion_flow_frame_span 0]"
    set result_frames {10 20 30}
    puts "SPAN-CLIP [_ion_flow_frame_span 0]"
}
TCLEOF
)
line() { printf '%s\n' "$OUT" | grep "^$1 " | head -1; }
[ "$(line RANGE)" = "RANGE 1 1 1 0 0 0" ] && ok "all and N:M forms are ranges; now, N and N,M are not" || bad "range: $(line RANGE)"
[ "$(line SPAN)" = "SPAN 3 5" ] && ok "the scan spans the analysed frames" || bad "span: $(line SPAN)"
[ "$(line SPAN-EMPTY)" = "SPAN-EMPTY 0 11" ] && ok "no analysis: the whole trajectory" || bad "span-empty: $(line SPAN-EMPTY)"
[ "$(line SPAN-CLIP)" = "SPAN-CLIP 10 11" ] && ok "the span is clipped to the loaded frames" || bad "span-clip: $(line SPAN-CLIP)"
echo "  -> $pass passed, $fail failed"
[ "$fail" -eq 0 ]
