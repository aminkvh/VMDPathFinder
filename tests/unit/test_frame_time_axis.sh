#!/bin/sh
# Time per frame: empty, zero, junk or negative keeps frame numbers (and the
# validator never admits a minus sign); a positive value times the frame
# INDEX (frame 30 at 0.1 ns per frame is 3.0 ns, whatever the analysed
# stride), the axis title carries the unit, ticks carry no "F" prefix, and
# the permeation rate gets the same interval in nanoseconds.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
TCL="$ROOT/vmdpathfinder/vmdpathfinder.tcl"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  PASS  $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; }
echo "frame-time-axis"
command -v tclsh >/dev/null 2>&1 || { echo "SKIP: no tclsh"; exit 0; }
[ -f "$TCL" ] || { echo "SKIP: no plugin source"; exit 0; }

OUT=$(tclsh <<TCLEOF 2>&1
namespace eval ::VMDPathFinder { variable state; array set state {frame_time {} frame_time_unit ns} }
$(awk '/^proc ::VMDPathFinder::_is_finite /,/^}/' "$TCL")
$(awk '/^proc ::VMDPathFinder::_frame_time_dt /,/^}/' "$TCL")
$(awk '/^proc ::VMDPathFinder::_frame_time_unit /,/^}/' "$TCL")
$(awk '/^proc ::VMDPathFinder::_frame_time_unit_label /,/^}/' "$TCL")
$(awk '/^proc ::VMDPathFinder::_frame_axis_label /,/^}/' "$TCL")
$(awk '/^proc ::VMDPathFinder::_frame_to_time /,/^}/' "$TCL")
$(awk '/^proc ::VMDPathFinder::_frame_tick_text /,/^}/' "$TCL")
$(awk '/^proc ::VMDPathFinder::_frame_time_ns /,/^}/' "$TCL")
$(awk '/^proc ::VMDPathFinder::_frame_time_validate /,/^}/' "$TCL")
$(awk '/^proc ::VMDPathFinder::_csv_time_header /,/^}/' "$TCL")
$(awk '/^proc ::VMDPathFinder::_csv_time_cell /,/^}/' "$TCL")
namespace eval ::VMDPathFinder {
    puts "EMPTY [_frame_axis_label] [_frame_tick_text 30] [_frame_time_ns] [_csv_time_header]"
    set state(frame_time) 0
    puts "ZERO [_frame_axis_label] [_frame_tick_text 30]"
    set state(frame_time) -0.5
    puts "NEG [_frame_axis_label] [_frame_tick_text 30]"
    set state(frame_time) abc
    puts "JUNK [_frame_axis_label] [_frame_tick_text 30]"
    puts "VALID [_frame_time_validate 0.25] [_frame_time_validate -1] [_frame_time_validate 1e3] [_frame_time_validate {}] [_frame_time_validate 12.]"
    set state(frame_time) 0.1
    puts "NS [_frame_axis_label] [_frame_tick_text 30] [_frame_to_time 30] [_frame_time_ns] [_csv_time_header] [_csv_time_cell 30]"
    set state(frame_time_unit) ps
    puts "PS [_frame_axis_label] [_frame_tick_text 30] [_frame_time_ns]"
    set state(frame_time_unit) us
    puts "US [_frame_axis_label] [_frame_time_ns]"
    set state(frame_time) 2
    puts "FMT [_frame_tick_text 3] [_frame_tick_text 7] [_frame_tick_text 60]"
    set state(frame_time_unit) parsec
    puts "BADUNIT [_frame_time_unit]"
}
TCLEOF
)
line() { printf '%s\n' "$OUT" | grep "^$1 " | head -1; }
[ "$(line EMPTY)" = "EMPTY Frame 30  " ] && ok "empty field: frame numbers, no F prefix, no rate interval, no csv column" || bad "empty: $(line EMPTY)"
[ "$(line ZERO)" = "ZERO Frame 30" ] && ok "zero keeps frames" || bad "zero: $(line ZERO)"
[ "$(line NEG)" = "NEG Frame 30" ] && ok "a negative value keeps frames" || bad "neg: $(line NEG)"
[ "$(line JUNK)" = "JUNK Frame 30" ] && ok "junk keeps frames" || bad "junk: $(line JUNK)"
[ "$(line VALID)" = "VALID 1 0 0 1 1" ] && ok "the validator admits digits and a point only" || bad "valid: $(line VALID)"
[ "$(line NS)" = "NS Time (ns) 3.00 3.0 0.1 ,time_ns ,3" ] && ok "0.1 ns per frame: frame 30 reads 3.00 ns, rate interval 0.1 ns, csv column" || bad "ns: $(line NS)"
[ "$(line PS)" = "PS Time (ps) 3.00 0.0001" ] && ok "switching the unit relabels without rescaling; rate interval converts" || bad "ps: $(line PS)"
printf '%s\n' "$(line US)" | grep -q "^US Time (.s) 100.0$" && ok "microseconds label and conversion" || bad "us: $(line US)"
[ "$(line FMT)" = "FMT 6.00 14.0 120" ] && ok "tick decimals follow the magnitude" || bad "fmt: $(line FMT)"
[ "$(line BADUNIT)" = "BADUNIT ns" ] && ok "an unknown unit falls back to ns" || bad "badunit: $(line BADUNIT)"
echo "  -> $pass passed, $fail failed"
[ "$fail" -eq 0 ]
