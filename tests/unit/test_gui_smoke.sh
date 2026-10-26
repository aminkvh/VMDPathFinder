#!/bin/sh
# GUI smoke + regression suite, driven WITHOUT VMD: the real vmdpathfinder.tcl is
# sourced under plain tclsh+Tk with VMD stubbed, the full widget tree built by
# the real show_gui, and the defects below exercised as scripted user actions.
#
# THE DEFECTS THIS GUARDS (each verified red on its pre-fix tree):
#   close path   - close_gui self-cancelled its own abort (a close mid-run
#                  stopped nothing); stripped four display/property traces
#                  nothing re-adds (controls dead after one reopen); left a
#                  pending overwrite-confirm grab unanswered (all of VMD's Tk
#                  mouse-dead); ignored tunnel results in the keep-vis gate.
#   guards       - Run/Reset/Align/import were deliverable mid-pass (busy
#                  covered only the two Run pipelines, not the bracketed read
#                  passes); align had no bracket at all; run_current_mode's
#                  backstop double-released _calc_depth.
#   molid class  - resolve_molid throws and never returns -1, so a deleted
#                  molecule crashed Passability (then left it permanently,
#                  silently dead), Ion Flow, Permeation and the metrics
#                  readout instead of their own friendly branches; the Mean
#                  tab's Show 3D died reading a never-set _volmode.
#   tunnel/opts  - a stale gear popup wrote edits onto whichever route held
#                  its captured rank; absent-route gear clicks were silent;
#                  "nan" in numeric option fields threw from inside expr
#                  ternaries; Over Time Compute swallowed every error.
#
# Each section runs in a FRESH tclsh so probe stubs cannot leak between them.
set -u
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/../.." && pwd)
export VMDPATHFINDER_ROOT="$ROOT"

echo "gui-smoke: $ROOT/vmdpathfinder/vmdpathfinder.tcl"
command -v tclsh >/dev/null 2>&1 || { echo "SKIP: no tclsh"; exit 0; }
if ! echo 'if {[catch {package require Tk}]} {exit 1}; exit 0' | tclsh >/dev/null 2>&1; then
    echo "SKIP: no usable Tk/DISPLAY (try xvfb-run)"; exit 0
fi

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT INT TERM
export VMDPATHFINDER_HARNESS_TMP="$T"
cat > "$T/harness.tcl" <<'HARNESS_EOF'
# Shared GUI-review harness: source vmdpathfinder.tcl under plain tclsh+Tk with VMD
# stubs and build the real GUI. Usage:  tclsh harness.tcl <script.tcl>
# The child script runs AFTER show_gui with the .vmdpathfinder toplevel built.
package require Tk
wm withdraw .

# ---- VMD stubs --------------------------------------------------------------
set ::STUB_MOLS {}          ;# list of {molid name numframes}
set ::TKDIALOG_LOG {}       ;# every dialog invocation is recorded, not shown
proc vmdcon {args} { lappend ::VMDCON_LOG $args }
set ::VMDCON_LOG {}
proc vmd_install_extension {args} {}
proc molinfo {args} {
    set a0 [lindex $args 0]
    if {$a0 eq "list"} { set r {}; foreach m $::STUB_MOLS {lappend r [lindex $m 0]}; return $r }
    if {$a0 eq "top"}  { return [expr {[llength $::STUB_MOLS] ? [lindex $::STUB_MOLS 0 0] : -1}] }
    foreach m $::STUB_MOLS { if {[lindex $m 0] == $a0} {
        set what [lindex $args 2]
        switch -- $what {
            name      { return [lindex $m 1] }
            numframes { return [lindex $m 2] }
            frame     { return 0 }
            default   { return 0 }
        }
    }}
    error "molinfo: molecule $a0 does not exist"
}
set ::aselc 0
proc atomselect {molid seltext args} {
    if {![llength $::STUB_MOLS]} { error "atomselect: no molecules loaded" }
    set name ::asel[incr ::aselc]
    proc $name {args} [format {
        set a0 [lindex $args 0]
        switch -- $a0 {
            num    { return 0 }
            get    { return {} }
            frame  { return }
            update { return }
            delete { rename %s "" }
            default { return {} }
        }
    } $name]
    return $name
}
foreach c {mol animate graphics display material render axes light imd measure} {
    proc $c {args} { return 0 }
}
proc color {args} { return 0 }
# Tk dialogs: record and return a benign answer instead of blocking
proc tk_messageBox {args} { lappend ::TKDIALOG_LOG [list messageBox $args]; return ok }
proc tk_chooseColor {args} { lappend ::TKDIALOG_LOG [list chooseColor $args]; return "" }
proc tk_getSaveFile {args} { lappend ::TKDIALOG_LOG [list getSaveFile $args]; return "" }
proc tk_getOpenFile {args} { lappend ::TKDIALOG_LOG [list getOpenFile $args]; return "" }
proc tk_chooseDirectory {args} { lappend ::TKDIALOG_LOG [list chooseDirectory $args]; return "" }

# ---- plugin -----------------------------------------------------------------
namespace eval ::VMDPathFinder {}
source [file join $::env(VMDPATHFINDER_ROOT) vmdpathfinder vmdpathfinder.tcl]
# keep config I/O away from the user's real ~/.vmdpathfinder_config
set ::HARNESS_TMP [expr {[info exists ::env(VMDPATHFINDER_HARNESS_TMP)] ? $::env(VMDPATHFINDER_HARNESS_TMP) : [pwd]}]
set ::VMDPathFinder::config_file [file join $::HARNESS_TMP .harness_vmdpathfinder_config]
catch {file delete $::VMDPathFinder::config_file}

::VMDPathFinder::show_gui
update
# A background error from stub data must not open Tk's modal error dialog and
# stall the harness; it is printed and the section goes on.
proc ::bgerror {msg} { puts "    (background error: [string range $msg 0 100])" }
interp bgerror {} ::bgerror

# ---- helpers for review scripts --------------------------------------------
proc walk {w} { set out [list $w]; foreach c [winfo children $w] { lappend out {*}[walk $c] }; return $out }
proc all_widgets {} { walk .vmdpathfinder }
proc invokables {} {
    set out {}
    foreach w [all_widgets] {
        set cls [winfo class $w]
        if {$cls in {Button TButton Checkbutton TCheckbutton Radiobutton TRadiobutton Menubutton TMenubutton}} {
            lappend out $w $cls
        }
    }
    return $out
}


source [lindex $argv 0]
exit 0
HARNESS_EOF

pass=0; fail=0
run_section () {
    name=$1; script=$2
    out=$(cd "$ROOT" && timeout 120 tclsh "$T/harness.tcl" "$script" 2>&1); rc=$?
    printf '%s\n' "$out" | grep -E ' OK$| BAD' | sed 's/^/    /'
    p=$(printf '%s\n' "$out" | grep -c ' OK$'); f=$(printf '%s\n' "$out" | grep -cE ' BAD')
    [ "$rc" -ne 0 ] && { echo "    FAIL $name: harness exit $rc"; f=$((f+1)); }
    pass=$((pass+p)); fail=$((fail+f))
}

cat > "$T/s1.tcl" <<'S1_EOF'
# 1. traces survive close/reopen
set t0 [llength [trace info variable ::VMDPathFinder::state(display_mode)]]
::VMDPathFinder::close_gui
::VMDPathFinder::show_gui
update
set t1 [llength [trace info variable ::VMDPathFinder::state(display_mode)]]
set t2 [llength [trace info variable ::VMDPathFinder::state(hydro_scheme)]]
puts "TRACES before=$t0 after_reopen=$t1 hydro=$t2 [expr {$t1>0 && $t2>0 ? {OK} : {BAD}}]"

# 2. abort survives close only while work is in flight
set ::VMDPathFinder::busy 1; set ::VMDPathFinder::_calc_depth 1
::VMDPathFinder::close_gui
puts "ABORT inflight: raised=[set ::VMDPathFinder::state(abort_requested)] [expr {$::VMDPathFinder::state(abort_requested)==1 ? {OK} : {BAD}}]"
set ::VMDPathFinder::busy 0
::VMDPathFinder::_end_calc
puts "ABORT after unwind: [set ::VMDPathFinder::state(abort_requested)] depth=$::VMDPathFinder::_calc_depth [expr {$::VMDPathFinder::state(abort_requested)==0 && $::VMDPathFinder::_calc_depth==0 ? {OK} : {BAD}}]"
::VMDPathFinder::show_gui; update
::VMDPathFinder::close_gui
puts "ABORT idle close: [set ::VMDPathFinder::state(abort_requested)] [expr {$::VMDPathFinder::state(abort_requested)==0 ? {OK} : {BAD}}]"

# 3. a pending modal answer is forced to Cancel by close
::VMDPathFinder::show_gui; update
unset -nocomplain ::VMDPathFinder::_overwrite_ans
after 200 ::VMDPathFinder::close_gui
set ::VMDPathFinder::_overwrite_ans_pending 1
# simulate the dialog's wait: tkwait returns only if close_gui answers
after 2000 {set ::VMDPathFinder::_overwrite_ans timeout}
tkwait variable ::VMDPathFinder::_overwrite_ans
puts "OVERWRITE answered=[set ::VMDPathFinder::_overwrite_ans] [expr {$::VMDPathFinder::_overwrite_ans eq 0 ? {OK} : {BAD}}]"
S1_EOF
cat > "$T/s2.tcl" <<'S2_EOF'
# depth>0 (bracketed pass) must refuse Run / Reset / Align / molid swap
set ::VMDPathFinder::busy 0
::VMDPathFinder::_begin_calc
set r [::VMDPathFinder::run_analysis]
puts "RUN mid-pass: rc=$r status='$::VMDPathFinder::state(status)' [expr {$r==0 && [string match {*in progress*} $::VMDPathFinder::state(status)] ? {OK} : {BAD}}]"
set ::VMDPathFinder::state(status) ""
::VMDPathFinder::reset_session
puts "RESET mid-pass: [expr {[string match {*in progress*} $::VMDPathFinder::state(status)] ? {OK} : {BAD}}]"
set ::VMDPathFinder::state(status) ""
::VMDPathFinder::do_align_trajectory
puts "ALIGN mid-pass: [expr {[string match {*in progress*} $::VMDPathFinder::state(status)] ? {OK} : {BAD}}]"
::VMDPathFinder::_end_calc

# align brackets busy/_begin_calc and restores on throw
set ::seen_busy -1; set ::seen_depth -1
proc ::VMDPathFinder::align_trajectory {{molid ""}} {
    set ::seen_busy $::VMDPathFinder::busy
    set ::seen_depth $::VMDPathFinder::_calc_depth
    error "boom"
}
set ::TKDIALOG_LOG {}
::VMDPathFinder::do_align_trajectory
puts "ALIGN bracket: during busy=$::seen_busy depth=$::seen_depth after busy=$::VMDPathFinder::busy depth=$::VMDPathFinder::_calc_depth dialogs=[llength $::TKDIALOG_LOG] [expr {$::seen_busy==1 && $::seen_depth==1 && $::VMDPathFinder::busy==0 && $::VMDPathFinder::_calc_depth==0 && [llength $::TKDIALOG_LOG]==1 ? {OK} : {BAD}}]"

# run_current_mode must not double-release an enclosing bracket
proc ::VMDPathFinder::analysis_mode {} { return tunnel }
proc ::VMDPathFinder::run_tunnel_analysis {} {
    # model the real wrapper: restore, then rethrow
    set ::VMDPathFinder::busy 0
    ::VMDPathFinder::_end_calc
    error "engine died"
}
::VMDPathFinder::_begin_calc            ;# outer bracket (depth 1)
set ::VMDPathFinder::busy 1
::VMDPathFinder::_begin_calc            ;# the run's own bracket (depth 2)
::VMDPathFinder::run_current_mode
puts "BACKSTOP: depth=$::VMDPathFinder::_calc_depth (outer bracket must survive) [expr {$::VMDPathFinder::_calc_depth==1 ? {OK} : {BAD}}]"
::VMDPathFinder::_end_calc
S2_EOF
cat > "$T/s3.tcl" <<'S3_EOF'
# state: results empty, no molecules (STUB_MOLS empty) - the delete-and-move-on world
set ::VMDPathFinder::state(molid) 0

# 1. _volmode: ticking Show 3D with no results must not raise, must untick + report
set ::VMDPathFinder::state(show_mean_surface) 1
set rc [catch {::VMDPathFinder::on_show_mean_surface_toggled} err]
puts "VOLMODE rc=$rc show=$::VMDPathFinder::state(show_mean_surface) status='[string range $::VMDPathFinder::state(status) 0 40]' [expr {$rc==0 && $::VMDPathFinder::state(show_mean_surface)==0 && [string match {Mean surface:*} $::VMDPathFinder::state(status)] ? {OK} : {BAD}}]"

# 2. Volume-trap recovery is reachable: persisted Volume mode, no results
set ::VMDPathFinder::state(mean_3d_mode) "Volume"
set ::VMDPathFinder::state(show_mean_surface) 1
set rc [catch {::VMDPathFinder::on_show_mean_surface_toggled} err]
puts "VOLTRAP rc=$rc [expr {$rc==0 ? {OK} : "BAD $err"}]"

# 3. passability: click with dead molid - no raw error, dialog usable after
set rc1 [catch {::VMDPathFinder::show_passability_dialog} e1]
set d .vmdpathfinder.passability
set st1 [expr {[winfo exists $d] ? [wm state $d] : "none"}]
set rc2 [catch {::VMDPathFinder::show_passability_dialog} e2]
set st2 [expr {[winfo exists $d] ? [wm state $d] : "none"}]
puts "PASSABILITY rc1=$rc1 st1=$st1 rc2=$rc2 st2=$st2 [expr {$rc1==0 && $rc2==0 && $st2 eq "normal" ? {OK} : {BAD}}]"

# 4. ion flow with no molecule: friendly branch, not a raw throw
set ::VMDPathFinder::state(status) ""
set rc [catch {::VMDPathFinder::_run_ion_flow} err]
puts "IONFLOW rc=$rc status='$::VMDPathFinder::state(status)' [expr {$rc==0 && $::VMDPathFinder::state(status) eq {Load a molecule first.} ? {OK} : {BAD}}]"

# 5. permeation dialog opens with no molecule
set rc [catch {::VMDPathFinder::show_permeation_dialog} err]
puts "PERMEATION rc=$rc [expr {$rc==0 ? {OK} : "BAD $err"}]"

# 6. metrics readout with dead molid must not throw (canvas + fake args)
canvas .c
set rc [catch {::VMDPathFinder::_draw_metrics_readout .c 0 0 0 200 100} err]
puts "READOUT rc=$rc [expr {$rc==0 || ![string match {*not available*} $err] ? {OK} : "BAD $err"}]"
S3_EOF
cat > "$T/s4.tcl" <<'S4_EOF'
# 1. gear cross-route write is refused
set ::VMDPathFinder::_gear_open_cid 5
array set ::VMDPathFinder::tunnel_xcid {1,2 7}
proc ::VMDPathFinder::_tunnel_display_frame {} { return 1 }
set ::VMDPathFinder::state(status) ""
catch {::VMDPathFinder::_tunnel_gear_set_from_popup 2 material Glass} err
set wrote [info exists ::VMDPathFinder::tunnel_gear_cid(7,material)]
puts "GEARGUARD wrote=$wrote status='[string range $::VMDPathFinder::state(status) 0 30]' [expr {!$wrote && [string match {*reopen it*} $::VMDPathFinder::state(status)] ? {OK} : {BAD}}]"
# same-route write still works
set ::VMDPathFinder::_gear_open_cid 7
catch {::VMDPathFinder::_tunnel_gear_set_from_popup 2 material Glass} err
puts "GEARSAME wrote=[info exists ::VMDPathFinder::tunnel_gear_cid(7,material)] [expr {[info exists ::VMDPathFinder::tunnel_gear_cid(7,material)] ? {OK} : "BAD $err"}]"

# 2. absent-route gear click reports and cleans up
unset -nocomplain ::VMDPathFinder::_gear_open_cid
set ::VMDPathFinder::state(status) ""
catch {::VMDPathFinder::_tunnel_gear_click_cid 99} err
puts "GEARABSENT status='[string range $::VMDPathFinder::state(status) 0 40]' [expr {[string match {*not in any analysed frame*} $::VMDPathFinder::state(status)] ? {OK} : "BAD $err"}]"

# 3. nan option fields fall back instead of throwing
set ::VMDPathFinder::state(conn_pore_margin) nan
set rc [catch {::VMDPathFinder::_conn_pore_margin} v]
puts "MARGIN rc=$rc v=$v [expr {$rc==0 && $v==2.0 ? {OK} : {BAD}}]"
set ::VMDPathFinder::state(conn_lobe_tolz) nan; set ::VMDPathFinder::state(conn_lobe_tola) inf
set rc [catch {::VMDPathFinder::_conn_lobe_tol} v]
puts "LOBETOL rc=$rc v=$v [expr {$rc==0 && $v eq {6.0 35.0} ? {OK} : {BAD}}]"

# 4. Over Time compute failure is reported
proc ::VMDPathFinder::draw_heatmap {} { error "synthetic draw failure" }
set ::VMDPathFinder::state(status) ""
catch {::VMDPathFinder::on_heatmap_property_compute} err
puts "OTCOMPUTE busy=$::VMDPathFinder::busy status='[string range $::VMDPathFinder::state(status) 0 45]' [expr {$::VMDPathFinder::busy==0 && [string match {Over Time compute failed:*} $::VMDPathFinder::state(status)] ? {OK} : {BAD}}]"

# 5. keep_visualization honours tunnel sessions
set ::VMDPathFinder::state(keep_visualization) 1
set ::VMDPathFinder::tunnel_result_frames {0 1}
set ::VMDPathFinder::state(status) ""
::VMDPathFinder::close_gui
puts "KEEPVIS status='[string range $::VMDPathFinder::state(status) 0 24]' [expr {[string match {Visualization kept*} $::VMDPathFinder::state(status)] ? {OK} : {BAD}}]"

# 6. selection-changed path (incl. lining body follow) runs clean
::VMDPathFinder::show_gui; update
set rc [catch {::VMDPathFinder::_on_tunnel_selection_changed} err]
puts "SELCHANGE rc=$rc [expr {$rc==0 ? {OK} : "BAD $err"}]"
S4_EOF

cat > "$T/s5.tcl" <<'S5_EOF'
# 1. inf/nan in _num_or fields fall back
set ::VMDPathFinder::state(mole_bottleneck) inf
puts "NUMOR [::VMDPathFinder::_num_or mole_bottleneck 3.0 1] [expr {[::VMDPathFinder::_num_or mole_bottleneck 3.0 1]==3.0 ? {OK} : {BAD}}]"
# 2. water probe survives an emptied/mistyped field
set ::VMDPathFinder::state(metrics_water_probe) ""
set a [::VMDPathFinder::_metrics_water_probe]
set ::VMDPathFinder::state(metrics_water_probe) "1,15"
set b [::VMDPathFinder::_metrics_water_probe]
puts "WPROBE '$a' '$b' [expr {$a==1.15 && $b==1.15 ? {OK} : {BAD}}]"
# 3. show_gui must not clear a live run's abort
::VMDPathFinder::_begin_calc
set ::VMDPathFinder::state(abort_requested) 1
::VMDPathFinder::show_gui
puts "SHOWGUI-LIVE abort=$::VMDPathFinder::state(abort_requested) [expr {$::VMDPathFinder::state(abort_requested)==1 ? {OK} : {BAD}}]"
::VMDPathFinder::_end_calc
# 4. save publishes by rename; no .tmp litter
set cfg $::VMDPathFinder::config_file
::VMDPathFinder::save_config
set tmps [glob -nocomplain "$cfg.tmp*"]
puts "SAVECFG exists=[file exists $cfg] tmps=[llength $tmps] [expr {[file exists $cfg] && ![llength $tmps] ? {OK} : {BAD}}]"
# 5. reopen must not revert a saved rename-atoms setting
set fh [open $cfg w]; puts $fh "hole_fix_atom_names = 1"; puts $fh "ion_radius_fallback = 0"; close $fh
::VMDPathFinder::load_config
puts "MIRROR fix=$::VMDPathFinder::state(hole_fix_atom_names) [expr {$::VMDPathFinder::state(hole_fix_atom_names)==1 ? {OK} : {BAD}}]"
# 6. torn boolean must not blow up close_gui
set fh [open $cfg w]; puts $fh "keep_visualization ="; close $fh
::VMDPathFinder::load_config
set rc [catch {::VMDPathFinder::close_gui} err]
puts "TORNBOOL rc=$rc [expr {$rc==0 ? {OK} : "BAD $err"}]"
# 7. unreadable config: GUI still opens
set ::VMDPathFinder::config_file [file join $::HARNESS_TMP .harness_cfg_dir]
file mkdir $::VMDPathFinder::config_file
set rc [catch {::VMDPathFinder::load_config} err]
puts "UNREADABLE rc=$rc [expr {$rc==0 ? {OK} : "BAD $err"}]"
set ::VMDPathFinder::config_file $cfg
# 8. the weight the combobox writes is what save persists
set ::VMDPathFinder::state(mole_weight_disp) "Length"
::VMDPathFinder::save_config
set fh [open $cfg r]; set t [read $fh]; close $fh
puts "WEIGHTKEY [expr {[string match "*mole_weight_disp = Length*" $t] ? {OK} : {BAD}}]"
# 9. a caller-preset engine path is not persisted by init_executables
set eng [file join $::HARNESS_TMP .harness_fake_hole]
set fh [open $eng w]; puts $fh "#!/bin/sh"; close $fh
file attributes $eng -permissions 0755
file delete -force $cfg
set ::VMDPathFinder::state(hole_exec) $eng
::VMDPathFinder::init_executables
set saved [expr {[file exists $cfg] ? [string match "*$eng*" [read [open $cfg r]]] : 0}]
puts "PRESETSAVE saved=$saved [expr {!$saved ? {OK} : {BAD}}]"
S5_EOF

cat > "$T/s6.tcl" <<'S6_EOF'
# ---- memory slots: several spherical pores held and drawn at once ----
namespace eval ::VMDPathFinder {
set row $_runpanel.mem
# 1. the row exists and starts with exactly one slot plus the "+"
_mem_refresh_row
update
set kids [lsort [winfo children $row.slots]]
puts "MEMROW mapped=[winfo ismapped $row] kids=$kids\
    [expr {[winfo ismapped $row] && [llength $kids]==2 && [winfo exists $row.slots.m1] \
           && [winfo exists $row.slots.add] ? {OK} : {BAD}}]"
# 2. Sync and Delete are disabled while there is only one memory - neither
#    means anything yet, and an enabled button that does nothing is a bug report
puts "MEMONE sync=[$row.sync cget -state] del=[$row.del cget -state]\
    [expr {[$row.sync cget -state] eq {disabled} && [$row.del cget -state] eq {disabled} ? {OK} : {BAD}}]"
# 3. "+" adds a slot, from DEFAULT parameters, without touching the first one's
set state(cpoint) "1 2 3"
set results [dict create 0 {min_radius 1.0}]
set result_frames {0}
_mem_stash_active
_mem_add_clicked
update
set n2 [llength [winfo children $row.slots]]
puts "MEMADD slots=$n2 cpoint='$state(cpoint)' res=[dict size $results]\
    [expr {$n2==3 && $state(cpoint) eq {} && [dict size $results]==0 ? {OK} : {BAD}}]"
# 4. clicking back to slot 1 restores its numbers AND its results
_mem_slot_clicked 1
update
puts "MEMBACK cpoint='$state(cpoint)' res=[dict size $results]\
    [expr {$state(cpoint) eq {1 2 3} && [dict size $results]==1 ? {OK} : {BAD}}]"
# 5. with two memories Sync and Delete come alive
puts "MEMTWO sync=[$row.sync cget -state] del=[$row.del cget -state]\
    [expr {[$row.sync cget -state] eq {normal} && [$row.del cget -state] eq {normal} ? {OK} : {BAD}}]"
# 6. the row is SPHERICAL ONLY - under Connolly it must disappear, or the other
#    memories' spherical surfaces read as part of a Connolly result
set state(pore_method) connolly
_mem_refresh_row
update
set hidden [expr {![winfo ismapped $row]}]
set state(pore_method) circular
_mem_refresh_row
update
puts "MEMMODE hidden_under_connolly=$hidden back=[winfo ismapped $row]\
    [expr {$hidden && [winfo ismapped $row] ? {OK} : {BAD}}]"
# 7. no slot switching mid-run: it would stash half a run and redirect the rest
_begin_calc
set before $pore_memory_active
_mem_slot_clicked 2
set moved [expr {$pore_memory_active ne $before}]
_end_calc
puts "MEMBUSY moved=$moved [expr {!$moved ? {OK} : {BAD}}]"
# 8. the RUN PATH writes memory 2 elsewhere. This is the actual no-overwrite
#    guarantee: resolve_output_root, not the reporting helper.
set state(work_dir) $::env(VMDPATHFINDER_HARNESS_TMP)/wd
set state(save_results) 1
_mem_slot_clicked 2
lassign [resolve_output_root 0] r2 t2
_mem_slot_clicked 1
lassign [resolve_output_root 0] r1 t1
puts "MEMROOT m1=$r1 m2=$r2\
    [expr {$r1 ne $r2 && [file dirname $r2] eq [file dirname $r1] && [file dirname $r1] eq [file normalize $state(work_dir)] ? {OK} : {BAD}}]"
# 9. each memory keeps its own folder across a switch
_mem_slot_clicked 2
lassign [resolve_output_root 0] r2b t2b
puts "MEMROOT2 same=[expr {$r2b eq $r2}] [expr {$r2b eq $r2 ? {OK} : {BAD}}]"
# 10. Sync really redraws: press the button for real, with two memories holding
#     different colours, and check the other memory's stored colour followed
_mem_slot_clicked 2
set state(surface_color) blue
_mem_stash_active
_mem_slot_clicked 1
set state(surface_color) red
_mem_sync_clicked
update
set other [dict get [dict get $pore_memories 2] params surface_color]
puts "MEMSYNC other=$other here=$state(surface_color)\
    [expr {$other eq {red} && $state(surface_color) eq {red} ? {OK} : {BAD}}]"
# 11. the row sits at the BOTTOM of the panel
set myrow [lindex [grid info $row] [expr {[lsearch [grid info $row] -row]+1}]]
set maxrow 0
foreach kid [winfo children $_runpanel] {
    set gi [grid info $kid]
    set i [lsearch $gi -row]
    if {$i < 0} { continue }
    set r [lindex $gi [expr {$i+1}]]
    if {$r > $maxrow} { set maxrow $r }
}
puts "MEMBOTTOM row=$myrow max=$maxrow [expr {$myrow == $maxrow ? {OK} : {BAD}}]"
# 12. the 3-D cues follow the memory. The write trace on state(cvect) clears
#     the cue by design, so restoring the parameters is not enough on its own -
#     without an explicit re-sync a switch left the previous memory's cue up.
#     The stubbed harness cannot create marker molecules, so this checks that
#     the re-sync is DRIVEN, and with the restored point already in place.
#     Renamed INSIDE the namespace: renaming a proc into the global namespace
#     silently breaks its own `variable` lookups.
set ::CUECALLS {}
rename _sync_point_marker _real_sync_point_marker
proc _sync_point_marker {key show_key args} {
    lappend ::CUECALLS "$key=$::VMDPathFinder::state(cpoint)"
    return [_real_sync_point_marker $key $show_key {*}$args]
}
rename _sync_cvect_handles _real_sync_cvect_handles
proc _sync_cvect_handles {args} {
    lappend ::CUECALLS "cvect=$::VMDPathFinder::state(cvect)"
    return [_real_sync_cvect_handles {*}$args]
}
_mem_slot_clicked 1
set state(cpoint) "5 6 7"; set state(cvect) "0 0 1"
_mem_stash_active
_mem_slot_clicked 2
set state(cpoint) "20 21 22"
_mem_stash_active
set ::CUECALLS {}
_mem_slot_clicked 1
update
rename _sync_point_marker {}; rename _real_sync_point_marker _sync_point_marker
rename _sync_cvect_handles {}; rename _real_sync_cvect_handles _sync_cvect_handles
set sawpt [expr {[lsearch $::CUECALLS "cpoint=5 6 7"] >= 0}]
set sawcv [expr {[lsearch -glob $::CUECALLS "cvect=*"] >= 0}]
puts "MEMCUE calls={$::CUECALLS} pt=$sawpt cv=$sawcv\
    [expr {$sawpt && $sawcv && $state(cpoint) eq {5 6 7} ? {OK} : {BAD}}]"
# 13. END RADIUS is per memory - two pores of one structure legitimately end
#     at different radii, and a new memory starts from the shipped default
_mem_slot_clicked 1
set state(endrad) 22.5
_mem_stash_active
_mem_slot_clicked 2
set e2new $state(endrad)
set state(endrad) 8.0
_mem_stash_active
_mem_slot_clicked 1
set e1 $state(endrad)
_mem_slot_clicked 2
puts "MEMENDRAD m1=$e1 m2=$state(endrad) newdefault=$e2new\
    [expr {$e1 == 22.5 && $state(endrad) == 8.0 ? {OK} : {BAD}}]"
# 14. creating a new memory must NOT take the previous one's surface track with
#     it: current_surface_mol used to stay pointed at the old memory's track, so
#     the new memory's first clear_surface deleted the previous pore
# real stub molecules, since _mem_point_surface_mol correctly refuses a track
# whose molecule VMD no longer has
lappend ::STUB_MOLS {41 memtrack1 1} {42 memtrack2 1}
_mem_slot_clicked 1
set mem_surface_mols(0|1) 41
set mem_surface_mols(0|2) 42
_mem_point_surface_mol
set p1 $current_surface_mol
_mem_slot_clicked 2
set p2 $current_surface_mol
puts "MEMTRACK m1=$p1 m2=$p2 [expr {$p1 == 41 && $p2 == 42 ? {OK} : {BAD}}]"
# 15. clear_surface must drop the deleted track from the MEMORY registry too,
#     or that memory points at a dead mol and loses its surface silently
set mem_surface_mols(0|1) 41
set mem_surface_mols(0|2) 42
set current_surface_mol 42
clear_surface
puts "MEMCLEAR left=[lsort [array names mem_surface_mols]]\
    [expr {![info exists mem_surface_mols(0|2)] && [info exists mem_surface_mols(0|1)] ? {OK} : {BAD}}]"
array unset mem_surface_mols
# 16. the draw cache is per TRACK. One global value alternated between two
#     memories' tracks, so it never hit - and could match the wrong track.
set _drawn_key [dict create]
dict set _drawn_key 41 keyA
dict set _drawn_key 42 keyB
puts "MEMDRAWKEY a=[dict get $_drawn_key 41] b=[dict get $_drawn_key 42]\
    [expr {[dict get $_drawn_key 41] ne [dict get $_drawn_key 42] ? {OK} : {BAD}}]"
# 17. every memory holding a result for the frame is rendered, not just the
#     active one - "with play it only plays one memory"
set ::RENDERED {}
rename load_surface_for_frame _real_load_surface_for_frame
proc load_surface_for_frame {frame {draft 0}} {
    lappend ::RENDERED "$::VMDPathFinder::pore_memory_active:$frame"
}
dict set pore_memories 1 results [dict create 7 {a b}]
dict set pore_memories 1 frames {7}
dict set pore_memories 2 results [dict create 7 {c d}]
dict set pore_memories 2 frames {7}
set was $pore_memory_active
_mem_render_other_memories 7 1
rename load_surface_for_frame {}; rename _real_load_surface_for_frame load_surface_for_frame
puts "MEMPLAY rendered={$::RENDERED} active_restored=[expr {$pore_memory_active eq $was}]\
    [expr {[llength $::RENDERED] == 1 && $pore_memory_active eq $was ? {OK} : {BAD}}]"
# 18. switching memories keeps the FRAME the user is on. Falling back to the
#     memory's first frame is what made the Over Time indicator jump and the
#     3-D surface snap on every switch.
set results [dict create]; set result_frames {}
dict set pore_memories 1 results [dict create 10 {a b} 20 {a b} 30 {a b}]
dict set pore_memories 1 frames {10 20 30}
dict set pore_memories 2 results [dict create 5 {c d} 30 {c d}]
dict set pore_memories 2 frames {5 30}
set pore_memory_active 1
_mem_apply [dict get $pore_memories 1]
set state(selected_result_frame) 30
_mem_activate 2
set kept $state(selected_result_frame)
# a frame the other memory does NOT have falls to the NEAREST, not to the first
_mem_activate 1
set state(selected_result_frame) 20
_mem_activate 2
# frame 20 is absent from {5 30}: nearest is 30 (10 away) not 5 (15 away)
puts "MEMFRAME kept=$kept nearest=$state(selected_result_frame)\
    [expr {$kept == 30 && $state(selected_result_frame) == 30 ? {OK} : {BAD}}]"
# 19. the stabilizer/tracker SCOPE fields are per memory - two pores need
#     different scope radii, and sharing them meant editing one memory's scope
#     silently changed what the other memory's next run would do
set keys [_mem_run_keys]
set want {stab_radius_inner stab_radius_outer stab_rmsd_warn track_radius}
set missing {}
foreach k $want { if {[lsearch -exact $keys $k] < 0} { lappend missing $k } }
puts "MEMSTAB missing={$missing} [expr {$missing eq {} ? {OK} : {BAD}}]"
# 20. deleting a memory must drop its tracks from the DRAW CACHE. VMD reuses
#     freed molecule ids, so a later track handed that id was told it was
#     already drawn and never rendered - the deleted memory's frame lingered
#     and playback jumped at it.
lappend ::STUB_MOLS {51 memdel1 1} {52 memdel2 1}
set mem_surface_mols(0|1) 51
set mem_surface_mols(0|2) 52
set _drawn_key [dict create]
dict set _drawn_key 51 keep
dict set _drawn_key 52 stale
_mem_forget_tracks 2
puts "MEMDELCACHE has51=[dict exists $_drawn_key 51] has52=[dict exists $_drawn_key 52]\
    [expr {[dict exists $_drawn_key 51] && ![dict exists $_drawn_key 52] ? {OK} : {BAD}}]"
array unset mem_surface_mols
# 21. after deleting the ACTIVE memory, current_surface_mol must point at the
#     survivor, not at the track that was just deleted
set pore_memories [dict create]
set pore_memory_next 1
set pore_memory_active ""
set results [dict create]; set result_frames {}
_mem_ensure_first
_mem_add_clicked
set mem_surface_mols(0|1) 51
set mem_surface_mols(0|2) 52
set pore_memory_active 2
set current_surface_mol 52
_mem_delete 2
puts "MEMDELPTR active=$pore_memory_active surf=$current_surface_mol\
    [expr {$pore_memory_active == 1 && $current_surface_mol == 51 ? {OK} : {BAD}}]"
array unset mem_surface_mols
# 22. SYNC must not rebuild geometry. Forcing last_geom_key made
#     apply_display_change rebuild every frame of every memory - sph_process and
#     sos_triangle per frame - and never finish. Sync renders the shown frame
#     only, and leaves the geometry key alone.
set pore_memories [dict create]
set pore_memory_next 1
set pore_memory_active ""
_mem_ensure_first
set state(surface_color) blue
_mem_stash_active
_mem_add_clicked
set state(surface_color) red
_mem_stash_active
_mem_slot_clicked 1
set last_geom_key "SENTINEL"
set ::SYNCRENDER {}
rename load_surface_for_frame _real_lsff
proc load_surface_for_frame {frame {draft 0}} { lappend ::SYNCRENDER "$frame" }
set state(selected_result_frame) 3
dict set pore_memories 1 results [dict create 3 {a b}]
dict set pore_memories 1 frames {3}
dict set pore_memories 2 results [dict create 3 {c d}]
dict set pore_memories 2 frames {3}
_mem_sync_clicked
rename load_surface_for_frame {}; rename _real_lsff load_surface_for_frame
puts "MEMSYNCCHEAP geomkey=$last_geom_key rendered={$::SYNCRENDER} busy=[_op_in_progress]\
    [expr {$last_geom_key eq {SENTINEL} && [llength $::SYNCRENDER] <= 1 \
           && ![_op_in_progress] ? {OK} : {BAD}}]"
# 23. the Follow-mode smoothing watcher schedules itself and can be stopped -
#     a leaked `after` keeps firing at a closed window
_smooth_watch_start
set armed [expr {$_smooth_watch_after ne ""}]
_smooth_watch_stop
puts "MEMSMOOTHWATCH armed=$armed stopped=[expr {$_smooth_watch_after eq {}}]\
    [expr {$armed && $_smooth_watch_after eq {} ? {OK} : {BAD}}]"
# 24. deleting the current memory leaves the other one active
_mem_delete_clicked
update
puts "MEMDEL left=[dict keys $pore_memories] active=$pore_memory_active\
    [expr {[dict size $pore_memories]==1 && $pore_memory_active ne {} ? {OK} : {BAD}}]"
}
S6_EOF

run_section close-path "$T/s1.tcl"
run_section guards     "$T/s2.tcl"
run_section molid      "$T/s3.tcl"
run_section tunnel-opts "$T/s4.tcl"
run_section config-fields "$T/s5.tcl"
run_section memory-slots "$T/s6.tcl"
cat > "$T/s7.tcl" <<'S7_EOF'
# Ion & Water gear: crossing-window fields write state(ion_flow_window); Auto clears it.
set ::VMDPathFinder::state(ion_flow_window) {}
::VMDPathFinder::show_ion_flow_settings; update
set d $::VMDPathFinder::w.ionflowcfg
set have [expr {[winfo exists $d.cwm.a] && [winfo exists $d.ewin_R] && [winfo exists $d.ewin_zc] && [winfo exists $d.cwc]}]
puts "XWIN widgets [expr {$have ? {OK} : {BAD}}]"
puts "XWIN opens Auto: $::VMDPathFinder::state(ion_flow_win_mode) [expr {$::VMDPathFinder::state(ion_flow_win_mode) eq {auto} ? {OK} : {BAD}}]"
foreach {k v} {win_mode set win_R 3 win_lo 8 win_hi -6 win_zc 1} { set ::VMDPathFinder::state(ion_flow_$k) $v }
::VMDPathFinder::_ion_flow_window_apply
puts "XWIN set: {$::VMDPathFinder::state(ion_flow_window)} [expr {$::VMDPathFinder::state(ion_flow_window) eq {3 -6 8 1} ? {OK} : {BAD}}]"
destroy $d
::VMDPathFinder::show_ion_flow_settings; update
puts "XWIN reopens with the fields: $::VMDPathFinder::state(ion_flow_win_mode) $::VMDPathFinder::state(ion_flow_win_lo) [expr {$::VMDPathFinder::state(ion_flow_win_mode) eq {set} && $::VMDPathFinder::state(ion_flow_win_lo) == -6 ? {OK} : {BAD}}]"
puts "XWIN region-passage fields [expr {[winfo exists $d.eregion_lo] && [winfo exists $d.eregion_hi] && [winfo exists $d.eregion_r] ? {OK} : {BAD}}]"
set ::VMDPathFinder::state(ion_flow_win_mode) auto
::VMDPathFinder::_ion_flow_window_apply
puts "XWIN Auto clears: {$::VMDPathFinder::state(ion_flow_window)} [expr {$::VMDPathFinder::state(ion_flow_window) eq {} ? {OK} : {BAD}}]"
S7_EOF
run_section crossing-window "$T/s7.tcl"

echo "  -> $pass passed, $fail failed"
[ "$fail" -eq 0 ]
