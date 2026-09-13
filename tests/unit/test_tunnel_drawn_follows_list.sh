#!/bin/sh
# The tunnel 3D view draws exactly the routes the panel lists. With clustering
# on and the Seen floor active, a cluster below the floor is hidden from the
# list AND not drawn; "Show all" or selecting it brings it back in both.
# Reported on DhaA: one row listed, several routes drawn, and unticking the
# row changed nothing - the other routes belonged to hidden clusters.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
TCL="$ROOT/vmdpathfinder/vmdpathfinder.tcl"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  PASS  $1"; }
bad() { fail=$((fail+1)); echo "  FAIL  $1"; }
echo "tunnel-drawn-follows-list"
command -v tclsh >/dev/null 2>&1 || { echo "SKIP: no tclsh"; exit 0; }
[ -f "$TCL" ] || { echo "SKIP: no plugin source"; exit 0; }

OUT=$(tclsh <<TCLEOF 2>&1
namespace eval ::VMDPathFinder {
    variable state; variable tunnel_xcid
    array set state {tunnel_cluster_on 1 tunnel_seen_floor 40 tunnel_list_show_all 0 tunnel_selected_cid ""}
    # three clusters: 1 seen 60%, 2 seen 20%, 3 seen 10%
    proc _tunnel_cluster_rows {} {
        return [list [dict create cid 1 seen 60.0] [dict create cid 2 seen 20.0] [dict create cid 3 seen 10.0]]
    }
    # frame 8 carries one route per cluster (ranks 1,2,3) and an untracked rank 4
    array set tunnel_xcid {8,1 1 8,2 2 8,3 3}
}
$(awk '/^proc ::VMDPathFinder::_is_finite /,/^}/' "$TCL")
$(awk '/^proc ::VMDPathFinder::_num_or /,/^}/' "$TCL")
$(awk '/^proc ::VMDPathFinder::_tunnel_visible_cids/,/^}/' "$TCL")
$(awk '/^proc ::VMDPathFinder::_tunnel_hidden_by_list/,/^}/' "$TCL")
namespace eval ::VMDPathFinder {
    proc drawn {} {
        set l [_tunnel_visible_cids]; set out {}
        foreach i {1 2 3 4} { if {![_tunnel_hidden_by_list 8 \$i \$l]} { lappend out \$i } }
        return \$out
    }
    puts "FLOOR [lsort -integer [dict keys [_tunnel_visible_cids]]] DRAWN [drawn]"
    set state(tunnel_selected_cid) 3
    puts "SELECTED [lsort -integer [dict keys [_tunnel_visible_cids]]] DRAWN [drawn]"
    set state(tunnel_selected_cid) ""
    set state(tunnel_list_show_all) 1
    puts "SHOWALL [lsort -integer [dict keys [_tunnel_visible_cids]]] DRAWN [drawn]"
    set state(tunnel_list_show_all) 0
    set state(tunnel_seen_floor) 0
    puts "NOFLOOR [lsort -integer [dict keys [_tunnel_visible_cids]]] DRAWN [drawn]"
    set state(tunnel_seen_floor) 40
    set state(tunnel_cluster_on) 0
    puts "NOCLUSTER DRAWN [drawn]"
}
TCLEOF
)
line() { printf '%s\n' "$OUT" | grep "^$1 " | head -1; }
[ "$(line FLOOR)" = "FLOOR 1 DRAWN 1" ] && ok "below the floor: only the listed cluster is drawn" || bad "floor: $(line FLOOR)"
[ "$(line SELECTED)" = "SELECTED 1 3 DRAWN 1 3" ] && ok "selecting a hidden cluster lists and draws it" || bad "selected: $(line SELECTED)"
[ "$(line SHOWALL)" = "SHOWALL 1 2 3 DRAWN 1 2 3 4" ] && ok "Show all lists every cluster and draws every route" || bad "showall: $(line SHOWALL)"
[ "$(line NOFLOOR)" = "NOFLOOR 1 2 3 DRAWN 1 2 3" ] && ok "no floor: every cluster, untracked still hidden" || bad "nofloor: $(line NOFLOOR)"
[ "$(line NOCLUSTER)" = "NOCLUSTER DRAWN 1 2 3 4" ] && ok "clustering off: the list rule does not apply" || bad "nocluster: $(line NOCLUSTER)"
echo "  -> $pass passed, $fail failed"
[ "$fail" -eq 0 ]
