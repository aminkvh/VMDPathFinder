# Every control in the Tunnel panel must be REACHABLE, not merely created.
#
# Originally written after the panel was found clipped: it asked for ~800 px of
# height, the sidebar got ~470, and everything from Max similarity down sat
# below the bottom edge with no way to scroll to it. `winfo ismapped` is 1 for
# every one of those widgets, so neither a data-path test nor an existence
# check can see it - the test is therefore GEOMETRIC: either a control's box
# lies inside the visible viewport, or the viewport scrolls far enough to
# bring it in.
#
# The panel was later split into essential controls (this file's CONTROLS,
# checked geometrically as above) and advanced ones moved to a separate gear
# popup show_tunnel_advanced_settings (ADV_CONTROLS, checked by plain
# existence - a standalone toplevel is not squeezed into the sidebar's fixed
# budget, so it was never the geometric failure mode this file exists for).
#
# Run by test_gui_reachable.sh under `vmd2 -e`; needs a real X display.

set LOG [open $::env(GUI_TEST_LOG) w]
set SHOT [file dirname $::env(GUI_TEST_LOG)]
proc say {s} { global LOG; puts $LOG $s; flush $LOG }
proc ::VMDPathFinder::_all_children {w} {
    set out {}
    foreach c [winfo children $w] { lappend out $c {*}[::VMDPathFinder::_all_children $c] }
    return $out
}

set fails 0
proc report {label ok {detail ""}} {
    global fails
    if {!$ok} { incr fails }
    say [format "  %-52s %s" $label [expr {$ok ? "PASS" : "FAIL $detail"}]]
}

# One catch around the whole body: `vmd -e` abandons the rest of the file on the
# first error, so an uncaught failure here would leave an EMPTY log, which the
# wrapper reads as "the GUI never opened" and skips. Catching turns it into a
# reported failure.
if {[catch {
uplevel #0 [list source $::env(VMDPATHFINDER_TCL)]
::VMDPathFinder::show_gui
set w $::VMDPathFinder::w
update idletasks; update
$w.sidebar.nb select $w.sidebar.nb.tunnel
update idletasks; update
after 600 {set ::go 1}; vwait ::go

set P $w.sidebar.nb.tunnel

# Essential controls only - the ones build_tunnel_panel keeps inline after the
# essential/advanced split (2.1). Everything else (depth filters, auto-origin
# spacing, bottleneck tolerance, tunnel similarity, weight function, custom
# exits/paths, clustering) moved to show_tunnel_advanced_settings, checked
# separately below.
# mole_*_e live under their own $P.mp sub-frame (G5: isolates the 2-column
# param grid's own widths from the rest of the panel's wider rows, which were
# inflating its label-to-entry and column-to-column gaps).
set CONTROLS {
    sel_e align_b sp_e sp_box.com sp_box.cor mole_h.gear
    mp.mole_probe_e mp.mole_interior_e mp.mole_originradius_e mp.mole_minlen_e
    mp.mole_bottleneck_e mp.seen_e
}

set missing {}
foreach c $CONTROLS { if {![winfo exists $P.$c]} { lappend missing $c } }
report "all [llength $CONTROLS] essential Tunnel controls exist" [expr {[llength $missing] == 0}] \
       "(missing: $missing)"

# Geometric, not just existence-based: a control mapped but off the bottom
# edge of the sidebar is invisible, and `winfo exists` alone would not catch
# that. Built directly into the tab (only tunlist, below, still scrolls, since
# its height is genuinely unbounded); the window's own default height is
# sized (build_gui) to fit this panel's real content, so the reachability
# check below is against the window's own bottom edge, not a viewport's.
report "the Tunnel panel is NOT wrapped in a scrolling canvas" \
       [expr {![winfo exists $w.sidebar.nb.tunnel.c]}]

set wbottom [expr {[winfo rooty $w] + [winfo height $w]}]
set unreachable {}
foreach c $CONTROLS {
    if {![winfo exists $P.$c]} continue
    set bottom [expr {[winfo rooty $P.$c] + [winfo height $P.$c]}]
    if {$bottom > $wbottom} { lappend unreachable $c }
}
report "every essential control fits within the window" \
       [expr {[llength $unreachable] == 0}] "(off the end: $unreachable)"

set last mp.mole_bottleneck_e
set y1 [expr {[winfo rooty $P.$last] + [winfo height $P.$last]}]
report "'Bottleneck radius' is on screen" \
       [expr {[winfo ismapped $P.$last] && $y1 <= $wbottom}] \
       "(bottom $y1, window bottom $wbottom)"

# The advanced popup: everything that moved OUT of the essential panel above
# must still exist and be reachable there. Plain toplevel, no _scrollable -
# same convention as every other settings popup in this file (show_settings_
# dialog, show_mean_profile_settings, show_scale_cutoff_settings), none of
# which wrap in a scrolling canvas either; a standalone floating window sizes
# to its own content and is not squeezed into the sidebar's fixed budget the
# way the original bug this test protects against was.
::VMDPathFinder::show_tunnel_advanced_settings
update idletasks; update
set ADVD $w.tunnel_advanced_settings
set ADV_CONTROLS {
    mole_mindepth_e mole_mindeplen_e mole_cover_e mole_autocover_e
    mole_maxorigins_e mole_bottletol_e mole_maxsim_e
    fbl_c mw_c
    mole_exit_e mole_path_a_e mole_path_b_e exonly_c
    clus_e
    align_c xfe
    sbar_c hydro3d_c
}
set adv_missing {}
foreach c $ADV_CONTROLS { if {![winfo exists $ADVD.$c]} { lappend adv_missing $c } }
report "all [llength $ADV_CONTROLS] advanced Tunnel controls exist in the gear popup" \
       [expr {[llength $adv_missing] == 0}] "(missing: $adv_missing)"

# tunnel_seen_floor's code default (40, raised from 10) reaches every user because the
# key is deliberately absent from BOTH save_config's persistent_keys and load_config's
# skip_keys - it is simply never written, so an old ~/.vmdpathfinder_config can never pin it
# to the old value. This regresses to 10 (or worse, an unset entry widget) if either
# side of that changes.
report "tunnel_seen_floor's code default is 40 (not the old 10)" \
       [expr {[info exists ::VMDPathFinder::state(tunnel_seen_floor)] && $::VMDPathFinder::state(tunnel_seen_floor) == 40}] \
       "(got: [expr {[info exists ::VMDPathFinder::state(tunnel_seen_floor)] ? $::VMDPathFinder::state(tunnel_seen_floor) : {unset}}])"
report "the panel's Seen floor field (Interior row) is bound to state(tunnel_seen_floor)" \
       [expr {[winfo exists $P.mp.seen_e] && [$P.mp.seen_e cget -textvariable] eq "::VMDPathFinder::state(tunnel_seen_floor)"}]
report "...and it sits on the Interior row" \
       [expr {[dict get [grid info $P.mp.seen_e] -row] == [dict get [grid info $P.mp.mole_interior_e] -row]}]
report "the gear popup no longer carries a Seen floor field" [expr {![winfo exists $ADVD.sfe]}]
destroy $ADVD

# The HOLE panel must not have acquired a scrollbar it does not need.
report "the HOLE panel is unchanged (no canvas)" \
       [expr {![winfo exists $w.sidebar.nb.hole.c]}]

# With no results, the property coloring and the Lining window must degrade
# rather than throw. A failed or empty run is a normal state, not an error.
foreach {lbl script} {
    refresh_tunnel_tab   {::VMDPathFinder::refresh_tunnel_tab}
    property_range       {::VMDPathFinder::_tunnel_property_range 0 radius}
    property_spheres     {::VMDPathFinder::_tunnel_property_spheres 0 1 radius}
    show_tunnel_lining   {::VMDPathFinder::show_tunnel_lining}
} {
    set rc [catch {uplevel #0 $script} out]
    report "$lbl survives an empty result set" [expr {$rc == 0}] "($out)"
}

# Hydration and Ion Flow have NO data until Compute runs, so gating their whole
# exportbar on _tab_has_data hid the only control that could produce the data -
# permanently unreachable, in both modes. Checked as geometry-manager state, not
# ismapped, so it holds for a tab that is not currently selected.
::VMDPathFinder::_sync_exportbars_for_data
update idletasks
foreach {tab btn} {hydration go ionflow go} {
    set eb $w.plotframe.nb.$tab.exportbar
    if {![winfo exists $eb.$btn]} { continue }
    set _gi [grid info $eb]
    report "$tab Compute is still reachable with zero results" \
           [expr {$_gi ne "" && [winfo manager $eb.$btn] eq "pack"}] \
           "(bar grid info='$_gi' btn manager='[winfo manager $eb.$btn]')"
}
# The output half of those bars SHOULD be hidden with no data - that was the
# original crowding complaint, and it must not regress into showing everything.
report "Ion Flow's export/view controls stay hidden with no results" \
       [expr {[winfo manager $w.plotframe.nb.ionflow.exportbar.export] eq "" \
              && [winfo manager $w.plotframe.nb.ionflow.exportbar.vwm] eq ""}] \
       "(export='[winfo manager $w.plotframe.nb.ionflow.exportbar.export]' vwm='[winfo manager $w.plotframe.nb.ionflow.exportbar.vwm]')"

# Task 194: "no reason to show the 3D scale bar while Ellipse is on" - traced
# to show_selected_surface (the single choke point load_surface_for_frame/the
# scale-bar build goes through) missing the same surface_is_hidden guard
# frame_changed_settle already had. select_result_from_list, jump_to_selected_
# frame, and play_stopped all called it unguarded - clicking/double-clicking a
# frame in the results list, or letting playback stop, while Ellipse had
# solo'd the pore surface off would silently rebuild it (and its now-orphaned
# property scale bar) anyway. Fixed inside show_selected_surface itself so
# every caller is covered without each needing its own copy of the check.
# Synthetic mol (no real HOLE run needed) + a stubbed load_surface_for_frame:
# tests the guard mechanism directly rather than a full triangulation pipeline.
set _sv_csm2 $::VMDPathFinder::current_surface_mol
set _sv_srf2 $::VMDPathFinder::state(selected_result_frame)
set _fakemol2 [mol new]
mol rename $_fakemol2 "fake_surface_for_hidden_test"
set ::VMDPathFinder::current_surface_mol $_fakemol2
set ::VMDPathFinder::state(selected_result_frame) 0
set ::VMDPathFinder::_lsff_calls 0
rename ::VMDPathFinder::load_surface_for_frame ::VMDPathFinder::_orig_load_surface_for_frame
proc ::VMDPathFinder::load_surface_for_frame {args} { incr ::VMDPathFinder::_lsff_calls }
mol off $_fakemol2
report "surface_is_hidden correctly reports hidden for a mol off'd surface" \
       [::VMDPathFinder::surface_is_hidden] ""
::VMDPathFinder::show_selected_surface
report "show_selected_surface skips the rebuild while the surface is hidden (Ellipse solo'd)" \
       [expr {$::VMDPathFinder::_lsff_calls == 0}] "(calls=$::VMDPathFinder::_lsff_calls)"
mol on $_fakemol2
::VMDPathFinder::show_selected_surface
report "show_selected_surface still rebuilds normally once the surface is shown again" \
       [expr {$::VMDPathFinder::_lsff_calls == 1}] "(calls=$::VMDPathFinder::_lsff_calls)"
rename ::VMDPathFinder::load_surface_for_frame {}
rename ::VMDPathFinder::_orig_load_surface_for_frame ::VMDPathFinder::load_surface_for_frame
catch {mol delete $_fakemol2}
set ::VMDPathFinder::current_surface_mol $_sv_csm2
set ::VMDPathFinder::state(selected_result_frame) $_sv_srf2

# Task 198: "shows the control but triggers the calculation automatically" -
# show_bottleneck_residues called the O(frames x atoms) _bottleneck_residue_
# series unconditionally the moment the Residues... window opened, before the
# user had any chance to adjust the shell and click Compute. Fixed by reading
# _bottleneck_series_cached (cache-only, never computes) on open, and reserving
# the real compute for the Compute button (_recompute_bottleneck_residues).
# Stubbed _bottleneck_residue_series the same way load_surface_for_frame was
# stubbed above - a call counter proves WHICH path ran, not just that some
# text appeared.
set _sv_btm $::VMDPathFinder::state(trends_metric)
set ::VMDPathFinder::state(trends_metric) min_r
set ::VMDPathFinder::bottleneck_cache {}
set ::VMDPathFinder::_bres_calls 0
rename ::VMDPathFinder::_bottleneck_residue_series ::VMDPathFinder::_orig_bottleneck_residue_series
proc ::VMDPathFinder::_bottleneck_residue_series {metric} {
    incr ::VMDPathFinder::_bres_calls
    return [list [dict create] [dict create] 0]
}
::VMDPathFinder::show_bottleneck_residues
update idletasks; update
set _bd $w.bneckres
set _btxt [expr {[winfo exists $_bd.txt] ? [$_bd.txt get 1.0 end] : ""}]
report "Residues window does not compute on open" \
       [expr {$::VMDPathFinder::_bres_calls == 0}] "(calls=$::VMDPathFinder::_bres_calls)"
report "Residues window shows a not-computed placeholder on open, not stale/wrong data" \
       [expr {[string match "*Not computed yet*" $_btxt]}] "(text='[string range $_btxt 0 60]')"
::VMDPathFinder::_recompute_bottleneck_residues
update idletasks; update
report "Compute button in the Residues window actually triggers the real compute" \
       [expr {$::VMDPathFinder::_bres_calls == 1}] "(calls=$::VMDPathFinder::_bres_calls)"
catch {destroy $_bd}
rename ::VMDPathFinder::_bottleneck_residue_series {}
rename ::VMDPathFinder::_orig_bottleneck_residue_series ::VMDPathFinder::_bottleneck_residue_series
set ::VMDPathFinder::bottleneck_cache {}
set ::VMDPathFinder::state(trends_metric) $_sv_btm

# _end_calc (unlike run_analysis, _asym_batch_all, ...) never touches
# state(status) - it only manages the Abort-button depth counter - so
# _bottleneck_residue_series has to set its own completion message or the
# status bar is left reading "Computing bottleneck residues..." forever after
# a successful compute: the one place a user looks to tell "did that work"
# read as permanently stuck. Stubs the INNER _bottleneck_residue_trend (not
# _bottleneck_residue_series itself, unlike the block above) so the real
# status-setting code in _bottleneck_residue_series actually runs.
set ::VMDPathFinder::state(trends_metric) min_r
set ::VMDPathFinder::bottleneck_cache {}
set _sv_rf_stat $::VMDPathFinder::result_frames
set ::VMDPathFinder::result_frames {0}
# resolve_molid (called unconditionally inside _bottleneck_residue_series,
# ahead of the stub below) throws with no molecule loaded at all - a stand-in
# mol, same pattern as _fakemol2/_fakepore elsewhere in this file.
set _fakemol_stat [mol new]
rename ::VMDPathFinder::_bottleneck_residue_trend ::VMDPathFinder::_orig_bottleneck_residue_trend_stat
proc ::VMDPathFinder::_bottleneck_residue_trend {molid frames metric} {
    return [list [dict create 0 {A ALA1}] [dict create {A ALA1} 1] 1]
}
::VMDPathFinder::_bottleneck_residue_series min_r
report "bottleneck-residue compute leaves a real completion status, not a stuck 'Computing...'" \
       [expr {![string match "Computing bottleneck residues*" $::VMDPathFinder::state(status)]}] \
       "(status='$::VMDPathFinder::state(status)')"
# Sabotage-checked by hand: removing the status-setting block added to
# _bottleneck_residue_series (right before its _end_calc) turns this FAIL
# (status stays "Computing bottleneck residues over 1 frame(s)...") -
# confirmed, then restored.
rename ::VMDPathFinder::_bottleneck_residue_trend {}
rename ::VMDPathFinder::_orig_bottleneck_residue_trend_stat ::VMDPathFinder::_bottleneck_residue_trend
catch {mol delete $_fakemol_stat}
set ::VMDPathFinder::result_frames $_sv_rf_stat
set ::VMDPathFinder::bottleneck_cache {}
set ::VMDPathFinder::state(trends_metric) $_sv_btm

# ---- a run WITH results, which the checks above deliberately do not cover ----
# Everything so far exercises an empty result set. The paths a user actually
# looks at - the property combobox populated, the coloring on a real tunnel,
# the Lining window with rows in it - had never been rendered, only tested as
# data. Needs the engine binary and a structure; skips loudly without either.
set PDB $::env(GUI_TEST_PDB)
# Point the plugin at the DEV binary. Without this it resolves whatever is
# beside the DEPLOYED sos_triangle, so the phase would either skip or silently
# test a different build than the one under test.
if {[info exists ::env(GUI_TEST_ENGINE)] && [file executable $::env(GUI_TEST_ENGINE)]} {
    set ::VMDPathFinder::state(mole_engine_exec) $::env(GUI_TEST_ENGINE)
}
if {[file exists $PDB] && [file executable [::VMDPathFinder::tool_path mole_engine]]} {
    set mid [mol new $PDB waitfor all]
    # Output goes to a scratch dir, not next to the structure: with work_dir on
    # "auto" the run writes tunnel_output_<name> beside the PDB, and the PDB
    # here lives in the repo.
    set ::VMDPathFinder::state(work_dir) [file join [file dirname $::env(GUI_TEST_LOG)] guirun]
    file mkdir $::VMDPathFinder::state(work_dir)
    set ::VMDPathFinder::state(molid) $mid

    # Catches: CPOINT/tunnel-start marker not drawing for a VMD SELECTION form
    # of CPOINT (only a literal "x y z"), even with "Show CPOINT as a sphere"
    # checked. The write trace that drives this is only installed the first
    # time show_hole_params_settings opens (where the checkbox lives) - open
    # it here, the same way a real user has to. Switches mode tabs to get
    # there and MUST switch back to tunnel before returning - every check
    # below this point assumes tunnel mode is still active.
    $w.sidebar.nb select $w.sidebar.nb.hole
    update idletasks; update
    ::VMDPathFinder::show_hole_params_settings
    update idletasks; update
    catch {destroy $w.hole_params_settings}
    set ::VMDPathFinder::state(show_cpoint_marker) 1
    set ::VMDPathFinder::state(cpoint) "protein"
    update idletasks; update
    set _pm_ok 0
    set _pm_detail "no marker mol created"
    if {[info exists ::VMDPathFinder::point_marker_mols] && \
            [dict exists $::VMDPathFinder::point_marker_mols cpoint]} {
        set _pm_mid [dict get $::VMDPathFinder::point_marker_mols cpoint]
        set _pm_g [llength [graphics $_pm_mid list]]
        set _pm_ok [expr {$_pm_g > 0}]
        set _pm_detail "mol $_pm_mid has $_pm_g graphics primitive(s)"
    }
    report "CPOINT marker draws for a SELECTION, not just literal x,y,z" $_pm_ok "($_pm_detail)"

    # The marker must share the STRUCTURE'S view matrices. Every VMD molecule
    # carries its own, and a fresh `mol new` gets the identity ones - so the
    # sphere renders in a different coordinate frame (measured on 1GRM: the
    # structure at scale 0.0586 with a z offset, the marker at scale 1.0 with
    # none) and lands far outside the visible volume. That is exactly the
    # "I check the box and see nothing in the 3D viewer" report: a molecule
    # that exists, has real graphics primitives and displayed=1, but is not
    # where the camera is looking. Existence checks cannot see this - only
    # comparing the matrices can.
    set _pm_aligned 0
    set _pm_adetail "no marker mol"
    if {[info exists ::VMDPathFinder::point_marker_mols] && \
            [dict exists $::VMDPathFinder::point_marker_mols cpoint]} {
        set _pm_mid [dict get $::VMDPathFinder::point_marker_mols cpoint]
        set _keys {center_matrix rotate_matrix scale_matrix global_matrix}
        catch {
            set _mv [molinfo $_pm_mid get $_keys]
            set _sv [molinfo $mid get $_keys]
            set _pm_aligned [expr {$_mv eq $_sv}]
            set _pm_adetail "marker scale [lindex [lindex $_mv 2] 0 0] vs structure\
                             scale [lindex [lindex $_sv 2] 0 0]"
        }
    }
    report "the marker shares the structure's view matrices (or it renders off-screen)" \
           $_pm_aligned "($_pm_adetail)"

    # Closing the stick must clear EVERY cue it turned on, not just the one it
    # was first opened with. The dialog is shared and re-targeted in place (the
    # CPOINT, CVECT and tunnel-start buttons all call show_axis_stick_dialog on
    # the same toplevel), and it used to remember a single cue variable - so
    # opening on one point and then re-targeting to the other left the first
    # cue on, with its marker molecule still in the scene, after Close. A cue
    # the USER had already switched on must survive Close either way.
    set _cue_saved [list $::VMDPathFinder::state(show_cpoint_marker) \
                         $::VMDPathFinder::state(show_tunnel_start_marker)]
    set ::VMDPathFinder::state(show_cpoint_marker) 0
    set ::VMDPathFinder::state(show_tunnel_start_marker) 0
    set _sd $w.axisstick
    ::VMDPathFinder::show_axis_stick_dialog cpoint
    update idletasks; update
    ::VMDPathFinder::show_axis_stick_dialog tunnel_start
    update idletasks; update
    set _both_on [expr {$::VMDPathFinder::state(show_cpoint_marker)
                        && $::VMDPathFinder::state(show_tunnel_start_marker)}]
    ::VMDPathFinder::_axis_stick_close $_sd
    update idletasks; update
    set _left [list]
    foreach _k {show_cpoint_marker show_tunnel_start_marker} {
        if {$::VMDPathFinder::state($_k)} { lappend _left $_k }
    }
    foreach _k {cpoint tunnel_start} {
        if {[info exists ::VMDPathFinder::point_marker_mols] && \
                [dict exists $::VMDPathFinder::point_marker_mols $_k]} { lappend _left "mol:$_k" }
    }
    report "closing the re-targeted stick clears every cue it turned on" \
           [expr {$_both_on && [llength $_left] == 0}] \
           "(both cues on while open: $_both_on; left behind: $_left)"

    # CVECT's two points are drawn as handles while its stick page is open.
    # CVECT is a DIRECTION - compute_vector keeps the normalised (P2-P1) and
    # discards the positions, and the search axis is drawn at CPOINT - so the
    # pair the stick actually moves had nothing on screen at all. They are
    # drawn exactly while the stick can move them: not on another page, not
    # after Close.
    set ::VMDPathFinder::state(cpoint) "70 30 25"
    set ::VMDPathFinder::state(cvect) "0 0 1"
    set ::VMDPathFinder::vec_p1 ""
    set ::VMDPathFinder::vec_p2 ""
    ::VMDPathFinder::show_axis_stick_dialog cvect
    update idletasks; update
    proc _cv_handle_centres {} {
        if {![info exists ::VMDPathFinder::point_marker_mols]} { return {} }
        if {![dict exists $::VMDPathFinder::point_marker_mols cvect_pts]} { return {} }
        set m [dict get $::VMDPathFinder::point_marker_mols cvect_pts]
        set o {}
        foreach it [graphics $m list] {
            set inf [graphics $m info $it]
            if {[lindex $inf 0] eq "sphere"} { lappend o [lindex $inf 1] }
        }
        return $o
    }
    set _h0 [_cv_handle_centres]
    proc _cv_midpoint {} {
        set c [_cv_handle_centres]
        if {[llength $c] != 2} { return {} }
        set m {}
        foreach a [lindex $c 0] b [lindex $c 1] { lappend m [expr {($a+$b)/2.0}] }
        return $m
    }
    proc _cv_near {a b} {
        if {[llength $a] != [llength $b] || ![llength $a]} { return 0 }
        foreach x $a y $b { if {abs($x-$y) > 0.02} { return 0 } }
        return 1
    }
    report "the CVECT page draws a handle at each of its two points" \
           [expr {[llength $_h0] == 2}] "(centres: $_h0)"
    set _cp_xyz {}
    catch {set _cp_xyz [::VMDPathFinder::_resolve_point_input \
        $::VMDPathFinder::state(cpoint) $mid [molinfo $mid get frame]]}
    report "CPOINT is the midpoint of the drawn axis" \
           [_cv_near [_cv_midpoint] $_cp_xyz] "(mid [_cv_midpoint] vs CPOINT $_cp_xyz)"

    # The two points are INDEPENDENT objects; the axis is a third. Each handle
    # sits at its own point, moving one never moves the other, and the axis is
    # the line through CPOINT along their direction - CPOINT is what HOLE
    # searches out from, so the axis has to pass through it. Making the handles
    # the axis's own ends is what forced them to move together.
    proc _cv_on_line {p a b} {
        if {[llength $p] != 3 || [llength $a] != 3 || [llength $b] != 3} { return 0 }
        lassign $a ax ay az; lassign $b bx by bz; lassign $p px py pz
        set dx [expr {$bx-$ax}]; set dy [expr {$by-$ay}]; set dz [expr {$bz-$az}]
        set L [expr {sqrt($dx*$dx+$dy*$dy+$dz*$dz)}]
        if {$L < 1e-9} { return 0 }
        set ex [expr {$px-$ax}]; set ey [expr {$py-$ay}]; set ez [expr {$pz-$az}]
        set cx [expr {$ey*$dz-$ez*$dy}]; set cy [expr {$ez*$dx-$ex*$dz}]; set cz [expr {$ex*$dy-$ey*$dx}]
        return [expr {sqrt($cx*$cx+$cy*$cy+$cz*$cz)/$L < 0.05}]
    }
    proc _cv_axis {} {
        if {![dict exists $::VMDPathFinder::point_marker_mols cpoint]} { return {} }
        set m [dict get $::VMDPathFinder::point_marker_mols cpoint]
        set cyl {}; set cone {}
        foreach it [graphics $m list] {
            set i [graphics $m info $it]
            if {[lindex $i 0] eq "cylinder"} { set cyl $i }
            if {[lindex $i 0] eq "cone"}     { set cone $i }
        }
        if {$cyl eq "" || $cone eq ""} { return {} }
        return [list [lindex $cyl 1] [lindex $cone 2]]
    }
    set ::VMDPathFinder::vec_p1 "60 30 20"
    set ::VMDPathFinder::vec_p2 "80 30 30"
    ::VMDPathFinder::show_axis_stick_dialog cvect
    update idletasks; update
    set _cp_xyz {}
    catch {set _cp_xyz [::VMDPathFinder::_resolve_point_input \
        $::VMDPathFinder::state(cpoint) $mid [molinfo $mid get frame]]}
    set _hA [_cv_handle_centres]
    report "each handle sits at its own point" \
           [expr {[_cv_near [lindex $_hA 0] {60 30 20}] && [_cv_near [lindex $_hA 1] {80 30 30}]}] \
           "(handles $_hA)"
    report "the axis passes through CPOINT" \
           [_cv_on_line $_cp_xyz [lindex [_cv_axis] 0] [lindex [_cv_axis] 1]] \
           "(axis [_cv_axis] vs CPOINT $_cp_xyz)"
    # independence, both ways round
    set ::VMDPathFinder::state(axis_stick_vec_pt) p2
    ::VMDPathFinder::_axis_stick_nudge cvect right
    update idletasks; update
    set _hB [_cv_handle_centres]
    report "moving Point 2 leaves Point 1 exactly where it was" \
           [expr {[_cv_near [lindex $_hA 0] [lindex $_hB 0]]
                  && ![_cv_near [lindex $_hA 1] [lindex $_hB 1]]}] "($_hA -> $_hB)"
    set ::VMDPathFinder::state(axis_stick_vec_pt) p1
    ::VMDPathFinder::_axis_stick_nudge cvect up
    update idletasks; update
    set _hC [_cv_handle_centres]
    report "moving Point 1 leaves Point 2 exactly where it was" \
           [expr {[_cv_near [lindex $_hB 1] [lindex $_hC 1]]
                  && ![_cv_near [lindex $_hB 0] [lindex $_hC 0]]}] "($_hB -> $_hC)"
    report "the axis still passes through CPOINT after both moves" \
           [_cv_on_line $_cp_xyz [lindex [_cv_axis] 0] [lindex [_cv_axis] 1]] \
           "(axis [_cv_axis])"
    # the axis direction is the pair's direction, and CVECT agrees with it
    proc _cv_dir {a b} {
        lassign $a x1 y1 z1; lassign $b x2 y2 z2
        set dx [expr {$x2-$x1}]; set dy [expr {$y2-$y1}]; set dz [expr {$z2-$z1}]
        set L [expr {sqrt($dx*$dx+$dy*$dy+$dz*$dz)}]
        if {$L < 1e-9} { return {} }
        return [list [expr {$dx/$L}] [expr {$dy/$L}] [expr {$dz/$L}]]
    }
    report "the axis runs along Point 1 -> Point 2, and CVECT matches" \
           [expr {[_cv_near [_cv_dir [lindex $_hC 0] [lindex $_hC 1]] \
                            [_cv_dir [lindex [_cv_axis] 0] [lindex [_cv_axis] 1]]]
                  && [_cv_near [::VMDPathFinder::_normalize_dir $::VMDPathFinder::state(cvect)] \
                               [_cv_dir [lindex $_hC 0] [lindex $_hC 1]]]}] \
           "(CVECT $::VMDPathFinder::state(cvect))"
    # exactly one axis: the handles contribute no shaft of their own
    set _h_shaft 0
    if {[dict exists $::VMDPathFinder::point_marker_mols cvect_pts]} {
        set _hm [dict get $::VMDPathFinder::point_marker_mols cvect_pts]
        foreach _it [graphics $_hm list] {
            if {[lindex [graphics $_hm info $_it] 0] in {cone cylinder}} { incr _h_shaft }
        }
    }
    report "only one axis is drawn (the handles add no second shaft)" \
           [expr {$_h_shaft == 0}] "(handles mol drew $_h_shaft shaft parts)"

    # The Value readout duplicates the Point entry above it on this page, so it
    # reports what the entries cannot: length, and the unit direction.
    set _val ""
    catch {set _val [$_sd.sv.val_v cget -text]}
    report "the stick's Value shows CVECT's length and unit direction" \
           [expr {[string match "len *" $_val] && [string match "*dir *" $_val]}] "($_val)"

    # Exact re-resolves both definitions literally per frame, so with two x,y,z
    # constants it re-derives an identical vector every frame - a live control
    # that cannot do anything. Stabilize fits a local atom context and is
    # meaningful for a literal point, so only Exact is gated.
    set _ex_lit ""; set _st_lit ""
    catch {::VMDPathFinder::compute_vector $_sd.vec}
    catch {::VMDPathFinder::_cvect_sync_stab_controls $_sd.vec}
    update idletasks; update
    catch {set _ex_lit [$_sd.vec.sb.ex cget -state]}
    catch {set _st_lit [$_sd.vec.sb.cv cget -state]}
    set ::VMDPathFinder::vec_p2 "index 120"
    catch {::VMDPathFinder::compute_vector $_sd.vec}
    catch {::VMDPathFinder::_cvect_sync_stab_controls $_sd.vec}
    update idletasks; update
    set _ex_sel ""
    catch {set _ex_sel [$_sd.vec.sb.ex cget -state]}
    report "Exact is offered only when an endpoint is a selection" \
           [expr {$_ex_lit eq "disabled" && $_st_lit eq "normal" && $_ex_sel eq "normal"}] \
           "(two literals: Exact $_ex_lit / Stabilize $_st_lit; with a selection: Exact $_ex_sel)"
    set ::VMDPathFinder::vec_p1 ""
    set ::VMDPathFinder::vec_p2 ""

    # Leaving the page takes the handles off screen; Close leaves nothing behind.
    set ::VMDPathFinder::state(axis_stick_mode) cpoint
    ::VMDPathFinder::_axis_stick_sync_mode $_sd
    update idletasks; update
    report "leaving the CVECT page clears the handles" \
           [expr {[llength [_cv_handle_centres]] == 0}] ""
    ::VMDPathFinder::_axis_stick_close $_sd
    update idletasks; update
    set _stray {}
    foreach _mm [molinfo list] {
        if {[string match "VMDPathFinder*" [molinfo $_mm get name]]} { lappend _stray [molinfo $_mm get name] }
    }
    report "closing the stick leaves no marker molecule behind" \
           [expr {[llength $_stray] == 0}] "(left: $_stray)"

    # ...but a cue the user set themselves is not cleared by Close.
    set ::VMDPathFinder::state(show_cpoint_marker) 1
    update idletasks; update
    ::VMDPathFinder::show_axis_stick_dialog cpoint
    update idletasks; update
    ::VMDPathFinder::_axis_stick_close $_sd
    update idletasks; update
    report "...but a cue the user had already on stays on" \
           $::VMDPathFinder::state(show_cpoint_marker) \
           "(show_cpoint_marker=$::VMDPathFinder::state(show_cpoint_marker))"
    set ::VMDPathFinder::state(show_cpoint_marker) [lindex $_cue_saved 0]
    set ::VMDPathFinder::state(show_tunnel_start_marker) [lindex $_cue_saved 1]
    update idletasks; update

    # The CVECT arrow: a cue for the search AXIS, not just its start point.
    # Drawn into the same marker mol, so one "Show cues" checkbox governs both.
    set ::VMDPathFinder::state(cvect) "0 0 1"
    update idletasks; update
    set _cue_kinds {}
    set _cue_cols {}
    if {[dict exists $::VMDPathFinder::point_marker_mols cpoint]} {
        set _cm [dict get $::VMDPathFinder::point_marker_mols cpoint]
        foreach _it [graphics $_cm list] {
            set _inf [graphics $_cm info $_it]
            lappend _cue_kinds [lindex $_inf 0]
            if {[lindex $_inf 0] eq "color"} { lappend _cue_cols [lindex $_inf 1] }
        }
    }
    report "the CPOINT cue draws a CVECT arrow (cylinder+cone) once an axis is set" \
           [expr {"cone" in $_cue_kinds && "cylinder" in $_cue_kinds}] \
           "(primitives: $_cue_kinds)"

    # _resolve_cvect_now must PREFER the two-point definition over the stored
    # literal - that preference is the whole mechanism by which the arrow
    # follows a moving axis instead of freezing at frame 0's direction.
    set ::VMDPathFinder::state(cvect_def_p1) "resid 23 and name CA"
    set ::VMDPathFinder::state(cvect_def_p2) "resid 40 and name CA"
    set _cv_dyn [::VMDPathFinder::_resolve_cvect_now $mid 0]
    set ::VMDPathFinder::state(cvect_def_p1) ""
    set ::VMDPathFinder::state(cvect_def_p2) ""
    set _cv_lit [::VMDPathFinder::_resolve_cvect_now $mid 0]
    report "_resolve_cvect_now prefers the two-point definition over the literal" \
           [expr {[llength $_cv_dyn] == 3 && $_cv_dyn ne $_cv_lit}] \
           "(two-point='$_cv_dyn' literal='$_cv_lit')"

    # Both cues can be on screen at once, so they must be told apart by color.
    set ::VMDPathFinder::state(tunnel_start) "protein"
    set ::VMDPathFinder::state(show_tunnel_start_marker) 1
    update idletasks; update
    set _tun_col ""
    if {[dict exists $::VMDPathFinder::point_marker_mols tunnel_start]} {
        set _tm [dict get $::VMDPathFinder::point_marker_mols tunnel_start]
        foreach _it [graphics $_tm list] {
            set _inf [graphics $_tm info $_it]
            if {[lindex $_inf 0] eq "color"} { set _tun_col [lindex $_inf 1]; break }
        }
    }
    set _hole_col [lindex $_cue_cols 0]
    report "HOLE and Tunnel cues use different colors" \
           [expr {$_hole_col ne "" && $_tun_col ne "" && $_hole_col ne $_tun_col}] \
           "(HOLE=$_hole_col tunnel=$_tun_col)"
    set ::VMDPathFinder::state(show_tunnel_start_marker) 0
    set ::VMDPathFinder::state(tunnel_start) ""
    set ::VMDPathFinder::state(cvect) ""
    update idletasks; update

    # The cue must show the point the RUN would use at this frame, i.e. go
    # through frame_axis (Track > Stabilize > Static). Resolving state(cpoint)
    # directly ignored Track/Stabilize entirely, so the sphere sat still while
    # the search used a point that had moved - the cue was lying. Also covers
    # _ensure_axis_refs: _stab_init used to run only at run start, so before a
    # run there were no Track refs and frame_axis fell back to static.
    proc _cue_sphere {mm} {
        foreach it [graphics $mm list] {
            set inf [graphics $mm info $it]
            if {[lindex $inf 0] eq "sphere"} { return [lindex $inf 1] }
        }
        return ""
    }
    # Catches: the cue resolving state(cpoint) directly instead of routing
    # through frame_axis (Track > Stabilize > Static), which would leave
    # Track/Stabilize never moving the sphere. Proving the cue routes through
    # it needs no trajectory: swap in a sentinel and check the sphere lands
    # on it.
    set ::VMDPathFinder::state(cpoint) "0 0 0"
    set ::VMDPathFinder::state(show_cpoint_marker) 1
    update idletasks; update
    rename ::VMDPathFinder::frame_axis ::VMDPathFinder::_fa_real_for_test
    proc ::VMDPathFinder::frame_axis {molid frame} { return [list "11 22 33" "0 0 1"] }
    ::VMDPathFinder::_sync_point_marker cpoint show_cpoint_marker
    update idletasks; update
    set _cue_fa ""
    catch {
        set _cm [dict get $::VMDPathFinder::point_marker_mols cpoint]
        set _cue_fa [_cue_sphere $_cm]
    }
    rename ::VMDPathFinder::frame_axis {}
    rename ::VMDPathFinder::_fa_real_for_test ::VMDPathFinder::frame_axis
    set _fa_ok 0
    catch {
        lassign $_cue_fa _fx _fy _fz
        set _fa_ok [expr {abs($_fx-11)<0.01 && abs($_fy-22)<0.01 && abs($_fz-33)<0.01}]
    }
    report "the CPOINT cue resolves through frame_axis (so Track/Stabilize move it)" \
           $_fa_ok "(cue sphere='$_cue_fa', expected 11 22 33)"
    set ::VMDPathFinder::state(track_cpoint) 0
    catch {::VMDPathFinder::_on_track_cpoint_toggled}
    set ::VMDPathFinder::state(show_cpoint_marker) 0
    set ::VMDPathFinder::state(cpoint) ""
    update idletasks; update

    # Catches: a molecule loaded while the panel is ALREADY OPEN leaving
    # CPOINT blank (sync_top_defaults only runs at show_gui). Blank is not
    # cosmetic: write_control_file omits the cpoint card entirely, so HOLE
    # guesses the point itself and the marker has nothing to draw.
    set ::VMDPathFinder::state(cpoint) ""
    set _nmol_before [llength [molinfo list]]
    set _late [mol new $PDB waitfor all]
    update idletasks; update
    after 400 {set ::go_cp 1}; vwait ::go_cp
    set _cp_late [string trim $::VMDPathFinder::state(cpoint)]
    report "a molecule loaded while the panel is open still fills CPOINT" \
           [expr {$_cp_late ne ""}] "(cpoint='$_cp_late')"
    # Catches: filling 0,0,0 (the origin) instead of the real selection
    # centroid - an explicit wrong cpoint, worse than blank.
    set _cp_nonzero 0
    catch {
        lassign $_cp_late _cx _cy _cz
        set _cp_nonzero [expr {abs($_cx)+abs($_cy)+abs($_cz) > 1e-6}]
    }
    report "the auto-filled CPOINT is a real centroid, not the 0,0,0 fallback" \
           $_cp_nonzero "(cpoint='$_cp_late')"
    # mol new inside the marker code re-fires VMD's own molecule callback; without
    # a re-entrancy guard that recursed into a storm of 300+ marker molecules.
    set _nmol_after [llength [molinfo list]]
    set _grew [expr {$_nmol_after - $_nmol_before}]
    report "loading a molecule does not storm marker mols (re-entrancy guard)" \
           [expr {$_grew <= 3}] "(molecule count grew by $_grew)"
    catch {mol delete $_late}
    update idletasks; update

    set ::VMDPathFinder::state(show_cpoint_marker) 0
    set ::VMDPathFinder::state(cpoint) ""
    update idletasks; update
    $w.sidebar.nb select $w.sidebar.nb.tunnel
    update idletasks; update

    # "protein" for the default fixture; the het pass needs a selection that
    # keeps the heteroatoms, or there is nothing for the HET row to show.
    set ::VMDPathFinder::state(selection) \
        [expr {[info exists ::env(GUI_TEST_SEL)] && $::env(GUI_TEST_SEL) ne ""
               ? $::env(GUI_TEST_SEL) : "protein"}]
    set ::VMDPathFinder::state(frame_spec) "now"
    set ::VMDPathFinder::state(engine) "mole"
    # No modal overwrite prompt in an automated run - it would block forever.
    set ::VMDPathFinder::state(overwrite_results) 0
    # A point that is genuinely inside KcsA's pore: the midpoint of tunnel 1 in
    # MOLE's own committed 1BL8 profile. Picked from the reference rather than by
    # eye, because a start point in bulk finds nothing and the phase would then
    # be testing the empty path all over again.
    # Taken from the fixture's own committed MOLE profile, not by eye: a start
    # point in bulk finds nothing and the phase silently tests the empty path
    # again. 1BL8 midpoint by default; GUI_TEST_START overrides for the het
    # pass, whose structure this point is nowhere near.
    # "auto" means MOLE's own automatic origins; anything else is a literal
    # start point.
    set _st "73.853 26.536 26.594"
    if {[info exists ::env(GUI_TEST_START)] && $::env(GUI_TEST_START) ne ""} {
        set _st [expr {$::env(GUI_TEST_START) eq "auto" ? "" : $::env(GUI_TEST_START)}]
        if {$::env(GUI_TEST_START) eq "auto"} { set ::VMDPathFinder::state(tunnel_auto_origin) 1 }
    }
    set ::VMDPathFinder::state(tunnel_start) $_st
    ::VMDPathFinder::run_tunnel_analysis
    update idletasks; update
    after 500 {set ::go4 1}; vwait ::go4

    set frames $::VMDPathFinder::tunnel_result_frames
    set ntun 0
    if {[llength $frames]} { set ntun [llength $::VMDPathFinder::tunnel_results([lindex $frames 0])] }
    report "the run produced tunnels" [expr {$ntun > 0}] \
           "(got $ntun; status: $::VMDPathFinder::state(status))"

    # ITEM 4: the bottom frame list is HOLE-only content until refresh_
    # results_list gets a tunnel-mode branch - it read ONLY result_frames/
    # results, so a tunnel run/import left it empty (or showing a stale HOLE
    # run). refresh_results_list is already called at the end of
    # run_tunnel_analysis (above), so the list should already be populated.
    if {$ntun > 0} {
        set _lb $w.bottom.detail.list
        report "the bottom frame list populates with tunnel_result_frames after a tunnel run" \
               [expr {[$_lb size] == [llength $frames]}] \
               "(rows=[$_lb size] want=[llength $frames])"
        report "the frame-list header switches to tunnel-mode columns" \
               [expr {[string match "*Tuns*" [$w.bottom.detail.header cget -text]]}] \
               "(header='[$w.bottom.detail.header cget -text]')"

        # Clicking a row must resolve through tunnel_result_frames, not HOLE's
        # result_frames - poison the latter to an impossible sentinel so the
        # two can never coincide by accident of this fixture's own frame
        # numbers, and capture what goto_trajectory_frame is actually called
        # with rather than the post-clamp VMD state (a single-frame molecule
        # would clamp an out-of-range HOLE frame back to the SAME frame the
        # tunnel run used, silently passing a broken handler).
        rename ::VMDPathFinder::goto_trajectory_frame ::VMDPathFinder::goto_trajectory_frame_orig_t4
        set ::_gtf_arg_t4 ""
        proc ::VMDPathFinder::goto_trajectory_frame {frame {draft 0}} {
            set ::_gtf_arg_t4 $frame
            ::VMDPathFinder::goto_trajectory_frame_orig_t4 $frame $draft
        }
        set _sv_rf_t4 $::VMDPathFinder::result_frames
        set ::VMDPathFinder::result_frames {888888}
        $_lb selection clear 0 end
        $_lb selection set 0
        ::VMDPathFinder::select_result_from_list
        report "clicking a frame-list row jumps to tunnel_result_frames' frame, not HOLE's" \
               [expr {$::_gtf_arg_t4 eq [lindex $frames 0] && $::_gtf_arg_t4 ne 888888}] \
               "(landed=$::_gtf_arg_t4 want=[lindex $frames 0])"
        # Sabotage-checked by hand: reverting select_result_from_list's mode
        # split (always index result_frames) turns this FAIL - confirmed,
        # then restored.
        set ::VMDPathFinder::result_frames $_sv_rf_t4
        rename ::VMDPathFinder::goto_trajectory_frame {}
        rename ::VMDPathFinder::goto_trajectory_frame_orig_t4 ::VMDPathFinder::goto_trajectory_frame

        # A plain frame step must NOT pay refresh_results_list's cache-
        # invalidation cost (plot_data_version/binned_cache/heatmap caches) -
        # only the cheap listbox-selection sync frame_changed actually calls.
        set _pdv_before $::VMDPathFinder::plot_data_version
        ::VMDPathFinder::_tunnel_sync_results_list_selection [lindex $frames 0]
        report "the per-frame listbox sync selects the landed frame's own row" \
               [expr {[$_lb curselection] eq "0"}] "(curselection=[$_lb curselection])"
        report "the per-frame listbox sync does not invalidate the analysis caches" \
               [expr {$::VMDPathFinder::plot_data_version == $_pdv_before}] \
               "(before=$_pdv_before after=$::VMDPathFinder::plot_data_version)"
    }

    # Task 179 (reverted first pass, then re-fixed on user feedback): the
    # tunlist canvas must fill the panel's full available width, with the
    # scrollbar sitting at the PANEL's right edge - not shrink to hug the
    # last data column, which read as cramped/claustrophobic rather than
    # compact. A first attempt at this task shrank it to content instead;
    # this asserts the corrected direction.
    if {$ntun > 0} {
        set _tlc $P.tunlist.c
        set _avail [expr {[winfo width $P] - 8 - [winfo width $P.tunlist.sb] - 8}]
        set _cw [winfo width $_tlc]
        report "tunlist canvas fills the available panel width (scrollbar at the panel edge)" \
               [expr {$_cw == $_avail}] \
               "(avail=$_avail canvas=$_cw)"
    }

    # Mode-switch speed: refresh_tunnel_tab (destroys/rebuilds every row
    # widget - real X-server cost, in
    # vmdpathfinder) must be skipped unless _tunlist_built_frame disagrees with
    # the current landed frame; everything else that changes row content
    # already calls refresh_tunnel_tab directly at its own point of change.
    if {$ntun > 0} {
        $w.sidebar.nb select $w.sidebar.nb.hole
        update idletasks; update
        set _t0 [clock milliseconds]
        $w.sidebar.nb select $w.sidebar.nb.tunnel
        update idletasks; update
        set _t1 [clock milliseconds]
        set _switch_ms [expr {$_t1 - $_t0}]
        report "switching back into Tunnel mode is fast when nothing changed" \
               [expr {$_switch_ms < 200}] "(${_switch_ms}ms; was ~740ms before this fix)"

        set _P $w.sidebar.nb.tunnel
        # Row widgets are keyed by ROW INDEX (rk1, rv1_3, ...), not by tunnel
        # id, so they survive a frame change and are reconfigured rather than
        # recreated - creating one costs ~22 ms in VMD's Tk, which is what made
        # this list take seconds to update. The swatch's text still carries the
        # tunnel id, so the row->tunnel mapping stays checkable.
        set _rowf $_P.tunlist.c.inner
        report "tunnel list rows still reflect the real data after the fast-path switch" \
               [expr {[winfo exists $_rowf.rk1] \
                   && [string trim [$_rowf.rk1 cget -text]] ne ""}] \
               "(row 1 swatch='[expr {[winfo exists $_rowf.rk1] ? [$_rowf.rk1 cget -text] : {missing}}]')"

        # Correctness of the skip condition itself: force the tracker stale
        # (simulating a frame change that happened while HOLE was visible)
        # and confirm the full rebuild path still fires rather than silently
        # showing outdated rows. Keyed on _tunlist_built_sig, not
        # _tunlist_built_frame - the guard compares the whole row signature
        # (frame + sort + row set) so the within-frame clustering toggle can
        # skip too; the frame alone no longer decides.
        set ::VMDPathFinder::_tunlist_built_sig "__forced_stale_test__"
        set _t0 [clock milliseconds]
        ::VMDPathFinder::on_mode_tab_changed
        set _t1 [clock milliseconds]
        report "a genuinely stale tracker still forces a real rebuild" \
               [expr {$::VMDPathFinder::_tunlist_built_sig ne "__forced_stale_test__"}] \
               "(built_sig changed=[expr {$::VMDPathFinder::_tunlist_built_sig ne {__forced_stale_test__}}], took [expr {$_t1-$_t0}]ms)"
        # Not timed as part of on_mode_tab_changed above: that callback also
        # runs _on_tunnel_selection_changed, whose draw_* calls each have
        # their OWN legitimate `update idletasks` (needed for real canvas
        # geometry, unlike the bug below) - whichever one runs first pays for
        # any pending Tk geometry work queued by earlier test steps, so its
        # own wall-clock time depends on unrelated GUI/tab state, not on
        # refresh_tunnel_tab. Time the ACTUALLY-FIXED proc in isolation
        # instead: _sync_tunlist_width used to force `update idletasks` to
        # answer a winfo reqwidth query NOTHING read ($need was dead - see
        # that proc's own comment) - that single call, not the widget
        # destroy/rebuild itself (~10ms), was 650-800ms of every
        # refresh_tunnel_tab call, on a real X11 display.
        set _t0 [clock milliseconds]
        ::VMDPathFinder::refresh_tunnel_tab
        set _t1 [clock milliseconds]
        report "refresh_tunnel_tab is not the 650-800ms it used to be" \
               [expr {$_t1 - $_t0 < 300}] "(took [expr {$_t1-$_t0}]ms)"
    }

    # Task 169: prev/next (_tunnel_select_step) must never land on a tunnel
    # id outside _tunnel_candidates - that gap (a raw-index walk could reach
    # a non-representative id with no list row, never drawn) was confirmed
    # live on 1MXT with auto-detect origins: 6 raw tunnels, 4 cluster
    # representatives {1 2 4 6}, arrows able to reach ids 3/5 before the fix.
    # Generic here (works on any fixture/cluster state, not just 1MXT).
    if {$ntun > 0} {
        set _cfr [::VMDPathFinder::_tunnel_display_frame]
        set _cand [::VMDPathFinder::_tunnel_candidates $_cfr]
        set _seen {}
        for {set _k 0} {$_k < 2 * [llength $_cand] + 2} {incr _k} {
            lappend _seen $::VMDPathFinder::state(tunnel_selected_id)
            ::VMDPathFinder::_tunnel_select_step 1
        }
        set _offcand {}
        foreach _sid $_seen { if {[lsearch -exact $_cand $_sid] < 0} { lappend _offcand $_sid } }
        report "prev/next never selects a tunnel outside the visible/listed set" \
               [expr {[llength $_offcand] == 0}] \
               "(candidates=$_cand visited=[lsort -unique -integer $_seen] off-candidate=$_offcand)"

        # Task 205: unchecking every tunnel's show/hide box (3D-visibility
        # only) used to make the arrows go completely inert - _tunnel_select_
        # step filtered its candidate list by tunnel_shown, so an empty
        # "shown" set left nothing to page through, with no way to recover
        # except manually re-checking a row. tunnel_shown is scoped to 3D
        # display everywhere else in this file; selection-for-analysis must
        # not depend on it.
        set _sv_shown [array get ::VMDPathFinder::tunnel_shown]
        foreach _c $_cand { set ::VMDPathFinder::tunnel_shown($_c) 0 }
        set _sv_sel $::VMDPathFinder::state(tunnel_selected_id)
        ::VMDPathFinder::_tunnel_select_step 1
        report "prev/next still selects a tunnel when every row is unchecked/hidden" \
               [expr {$::VMDPathFinder::state(tunnel_selected_id) ne "" \
                   && [lsearch -exact $_cand $::VMDPathFinder::state(tunnel_selected_id)] >= 0}] \
               "(selected=$::VMDPathFinder::state(tunnel_selected_id) candidates=$_cand)"
        array unset ::VMDPathFinder::tunnel_shown
        array set ::VMDPathFinder::tunnel_shown $_sv_shown
        set ::VMDPathFinder::state(tunnel_selected_id) $_sv_sel

        # Cross-frame clustering is UNCONDITIONAL - it is what gives a tunnel
        # its trajectory identity, and a fixed per-frame rank is the same
        # physical route on only 27% of frame steps, so it deliberately has no
        # off switch (an earlier round added one; the user had it removed).
        # This fixture is single-frame ("now"), so run_tunnel_analysis's own
        # call never exercises the >=2-frame path - build a synthetic 2-frame
        # tunnel_results/tunnel_result_frames from the one real frame already
        # loaded so _tunnel_xframe_build has something real to pool.
        set _sv_trf $::VMDPathFinder::tunnel_result_frames
        set _sv_tr [array get ::VMDPathFinder::tunnel_results]
        # The checks below toggle rows of the SYNTHETIC cluster set; those ids
        # are cluster-keyed and survive the results restore, and on a fixture
        # whose real clusters reuse the same low ids (1ERI: clusters 1 and 2)
        # the leaked OFF entries hid every real tunnel for the rest of the run
        # - which is what silently emptied the true-3D render downstream.
        set _sv_shown_cid [array get ::VMDPathFinder::tunnel_shown_cid]
        set _sv_shown_def $::VMDPathFinder::state(tunnel_shown_default)
        set _sv_shown_all $::VMDPathFinder::state(tunnel_shown_all)
        set ::VMDPathFinder::tunnel_results(90001) $::VMDPathFinder::tunnel_results($_cfr)
        set ::VMDPathFinder::tunnel_results(90002) $::VMDPathFinder::tunnel_results($_cfr)
        set ::VMDPathFinder::tunnel_result_frames {90001 90002}

        ::VMDPathFinder::_tunnel_xframe_build
        report "cross-frame clustering builds real clusters unconditionally" \
               [expr {[llength $::VMDPathFinder::tunnel_xclusters] > 0}] \
               "(n_clusters=[llength $::VMDPathFinder::tunnel_xclusters])"
        report "no cross-frame clustering off switch is exposed in state" \
               [expr {![info exists ::VMDPathFinder::state(tunnel_xframe_cluster_on)]}] \
               "(exists=[info exists ::VMDPathFinder::state(tunnel_xframe_cluster_on)])"

        # MOVED (C1): the clustering checkbox now sits on the SAME ROW as
        # Bottleneck inside the MOLE parameter block, rather than as one of two
        # checkboxes stacked underneath it.
        report "the within-frame clustering checkbox is on the MOLE parameter row" \
               [expr {[winfo exists $P.mp.xclus_within]}] \
               "(exists=[winfo exists $P.mp.xclus_within])"
        report "it is wired to tunnel_cluster_on" \
               [expr {[$P.mp.xclus_within cget -variable] eq "::VMDPathFinder::state(tunnel_cluster_on)"}] \
               "(var=[$P.mp.xclus_within cget -variable])"
        report "...on the same grid row as the Bottleneck entry" \
               [expr {[lindex [grid info $P.mp.xclus_within] \
                          [expr {[lsearch [grid info $P.mp.xclus_within] -row]+1}]] \
                   == [lindex [grid info $P.mp.mole_bottleneck_e] \
                          [expr {[lsearch [grid info $P.mp.mole_bottleneck_e] -row]+1}]]}] \
               "(chk=[grid info $P.mp.xclus_within] bneck=[grid info $P.mp.mole_bottleneck_e])"
        report "the old stacked checkbox is gone" \
               [expr {![winfo exists $P.xclus_within]}] "(exists=[winfo exists $P.xclus_within])"
        report "the removed between-frames checkbox is really gone" \
               [expr {![winfo exists $P.xclus] && ![winfo exists $P.xclus.between]}] \
               "(xclus=[winfo exists $P.xclus])"

        # MOVED (C2/C4): "Show all" now lives BELOW the list it filters, on the
        # bottom control row in the order Lining, Show lining, Show all - and it
        # is not shown at all until a run has produced tracked routes, since
        # before that it is a control that cannot do anything.
        report "the \"Show all\" checkbox is on the bottom control row" \
               [expr {[winfo exists $P.tunctl.showall]}] \
               "(exists=[winfo exists $P.tunctl.showall])"
        report "it is wired to tunnel_list_show_all" \
               [expr {[winfo exists $P.tunctl.showall] \
                   && [$P.tunctl.showall cget -variable] eq "::VMDPathFinder::state(tunnel_list_show_all)"}] \
               "(var=[expr {[winfo exists $P.tunctl.showall] ? [$P.tunctl.showall cget -variable] : {missing}}])"
        report "the old above-the-list checkbox is gone" \
               [expr {![winfo exists $P.tunlist_showall]}] \
               "(exists=[winfo exists $P.tunlist_showall])"
        # Order on that row: Lining button, Show lining, Show all.
        set _tcorder {}
        foreach _sl [pack slaves $P.tunctl] { lappend _tcorder [lindex [split $_sl .] end] }
        report "bottom row order is Lining, Show lining, Show all" \
               [expr {[lsearch $_tcorder lining] < [lsearch $_tcorder tlin]
                      && ([lsearch $_tcorder showall] < 0
                          || [lsearch $_tcorder tlin] < [lsearch $_tcorder showall])}] \
               "(order=$_tcorder)"

        # refresh_tunnel_tab_if_stale must NOT rebuild when the landed frame
        # has not moved - a full refresh destroys and recreates every row
        # widget (~660 ms of X churn), and it was being called on every
        # settled frame scrub. Detected structurally: plant a marker widget
        # inside the row container, which a real rebuild destroys along with
        # every other child. Sabotage-checked: calling refresh_tunnel_tab
        # directly here fails the skip case and passes the rebuild case.
        set _rowf $P.tunlist.c.inner
        if {[winfo exists $_rowf]} {
            catch {destroy $_rowf.__probe}
            frame $_rowf.__probe
            ::VMDPathFinder::refresh_tunnel_tab_if_stale
            report "same-frame refresh skips the full row rebuild" \
                   [expr {[winfo exists $_rowf.__probe]}] \
                   "(probe survived=[winfo exists $_rowf.__probe])"
            # A stale signature must still re-run the row pass. It no longer
            # DESTROYS the widgets (they are reused - see _rw_widget), so the
            # probe surviving proves nothing either way; what matters is that
            # the rows show THIS build's real data. The list is the CROSS-
            # frame cluster set now (refresh_tunnel_tab/_tunnel_cluster_rows),
            # not a per-frame rank list - # is the cluster id, Bneck is the
            # MEAN over that cluster's own frames, not one frame's raw value.
            catch {destroy $_rowf.__probe}
            set ::VMDPathFinder::_tunlist_built_sig "__not_a_real_signature__"
            ::VMDPathFinder::refresh_tunnel_tab_if_stale
            set _fr_now [::VMDPathFinder::_tunnel_display_frame]
            set _rows_now [::VMDPathFinder::_tunnel_cluster_rows]
            set _content_ok 1
            set _rr 0
            foreach _row $_rows_now {
                incr _rr
                set _cid [dict get $_row cid]
                if {![winfo exists $_rowf.rk$_rr]} { set _content_ok 0; break }
                if {[string trim [$_rowf.rk$_rr cget -text]] ne "$_cid"} { set _content_ok 0 }
                if {[$_rowf.rv${_rr}_3 cget -text] ne [format %.3f [dict get $_row bneck]]} { set _content_ok 0 }
            }
            report "a stale signature repopulates every row with this build's cluster data" \
                   [expr {$_content_ok && $_rr > 0}] "(rows checked=$_rr ok=$_content_ok)"

            # refresh_tunnel_tab must build EVERY row, and must not throw.
            # Its normal callers wrap it in catch, so an exception raised inside
            # the row loop is swallowed and simply truncates the list - a bad
            # tooltip string once left exactly ONE tunnel listed and every
            # existing check still passed, because they only ever inspected row
            # 1. Call it uncaught, then count the rows actually built. No
            # cross-frame identity to inject any more (unlike the old rank-
            # keyed list) - clustering is unconditional even for this
            # fixture's single frame (run_tunnel_analysis/_tunnel_xframe_
            # build), so every row already has one.
            set _refresh_err ""
            if {[catch {::VMDPathFinder::refresh_tunnel_tab} _re]} { set _refresh_err $_re }
            report "refresh_tunnel_tab completes without error" \
                   [expr {$_refresh_err eq ""}] "($_refresh_err)"
            set _want_rows [llength [::VMDPathFinder::_tunnel_cluster_rows]]
            set _got_rows 0
            for {set _qq 1} {$_qq <= 200} {incr _qq} {
                if {![winfo exists $_rowf.rk$_qq]} break
                if {[winfo ismapped $_rowf.rk$_qq]} { incr _got_rows }
            }
            report "every tracked cluster gets a row (not just the first)" \
                   [expr {$_want_rows > 0 && $_got_rows == $_want_rows}] \
                   "(want=$_want_rows got=$_got_rows)"

            # Cross-frame identity must drive the auto palette and the 3D
        # show/hide checkbox, not the rank - "a tunnel in frame 1 which is red
        # ... keep it red". Rank 1 is the same physical route on only 27% of
        # frame steps, so a rank-keyed palette recolors almost every step.
        # The synthetic 2-frame pool above is still in place here.
        # Use the SYNTHETIC pooled frame, not _tunnel_display_frame: the live
        # display frame is the fixture's real single frame, which by design has
        # no cross-frame identity at all.
        set _cfr2 90001
        if {[info exists ::VMDPathFinder::tunnel_xcid($_cfr2,1)]} {
            set _cid1 $::VMDPathFinder::tunnel_xcid($_cfr2,1)
            report "auto palette index follows the cross-frame cluster, not the rank" \
                   [expr {[::VMDPathFinder::_tunnel_palette_index $_cfr2 1] == $_cid1-1}] \
                   "(idx=[::VMDPathFinder::_tunnel_palette_index $_cfr2 1] cid=$_cid1)"
            # Show/hide follows the CLUSTER, not the rank slot. The previous
            # version of this check called on_tunnel_visibility_changed, which
            # records against _tunnel_display_frame - the fixture's real
            # single frame, which has no cross-frame identity - so the cluster
            # memory was never written and the assertion passed purely on
            # tunnel_shown's rank-keyed persistence, i.e. on the very behaviour
            # it claims to guard against (it reported cid_mem=unset while
            # passing). Write the memory the handler would write, then assert
            # the property rank-keying cannot give: hiding the cluster hides
            # whatever DIFFERENT rank carries it in another frame.
            set ::VMDPathFinder::tunnel_shown_cid($_cid1) 0
            set _rk2 ""
            foreach _k [array names ::VMDPathFinder::tunnel_xcid 90002,*] {
                if {$::VMDPathFinder::tunnel_xcid($_k) == $_cid1} {
                    set _rk2 [lindex [split $_k ,] 1]; break
                }
            }
            if {$_rk2 ne ""} {
                set ::VMDPathFinder::tunnel_shown($_rk2) 1
                ::VMDPathFinder::_tunnel_sync_shown_from_cluster 90002 $_rk2
                report "hiding a cluster hides its own rank in another frame" \
                       [expr {$::VMDPathFinder::tunnel_shown($_rk2) == 0}] \
                       "(frame 90002 rank=$_rk2 cid=$_cid1 shown=$::VMDPathFinder::tunnel_shown($_rk2))"
            } else {
                report "hiding a cluster hides its own rank in another frame" 0 \
                       "(no rank in frame 90002 carries cluster $_cid1)"
            }
            # A cluster nobody has touched is SHOWN, even when the same rank
            # number was hidden earlier for a different cluster. Without this
            # rule, unchecking rank 1 once left rank 1 hidden in every later
            # frame - measured: one 3-frame cluster hid 8 tunnels across 6.
            set _other ""
            foreach _k [array names ::VMDPathFinder::tunnel_xcid 90002,*] {
                if {$::VMDPathFinder::tunnel_xcid($_k) != $_cid1} {
                    set _other [lindex [split $_k ,] 1]; break
                }
            }
            if {$_other ne ""} {
                catch {unset ::VMDPathFinder::tunnel_shown_cid($::VMDPathFinder::tunnel_xcid(90002,$_other))}
                set ::VMDPathFinder::tunnel_shown($_other) 0
                ::VMDPathFinder::_tunnel_sync_shown_from_cluster 90002 $_other
                report "an untouched cluster is shown, not inherited from the rank slot" \
                       [expr {$::VMDPathFinder::tunnel_shown($_other) == 1}] \
                       "(frame 90002 rank=$_other shown=$::VMDPathFinder::tunnel_shown($_other))"
            }
            # A cluster that was never LISTED (present only in frames the user
            # never curated from) must follow tunnel_shown_default, not default
            # to shown. Defaulting to shown was the "I left one tunnel checked,
            # stepped a frame, and saw 11" bug: the list only ever shows one
            # frame's routes, so unchecking can never speak for the rest.
            set _unlisted 99001
            set ::VMDPathFinder::tunnel_xcid(90002,$_unlisted) 99999
            catch {unset ::VMDPathFinder::tunnel_shown_cid(99999)}
            catch {unset ::VMDPathFinder::tunnel_shown($_unlisted)}
            set ::VMDPathFinder::state(tunnel_shown_default) 0
            ::VMDPathFinder::_tunnel_sync_shown_from_cluster 90002 $_unlisted
            report "an unlisted cluster follows tunnel_shown_default (curated subset)" \
                   [expr {$::VMDPathFinder::tunnel_shown($_unlisted) == 0}] \
                   "(shown=$::VMDPathFinder::tunnel_shown($_unlisted), default=0)"
            set ::VMDPathFinder::state(tunnel_shown_default) 1
            catch {unset ::VMDPathFinder::tunnel_shown($_unlisted)}
            ::VMDPathFinder::_tunnel_sync_shown_from_cluster 90002 $_unlisted
            report "...and shows again once the default is back to show-all" \
                   [expr {$::VMDPathFinder::tunnel_shown($_unlisted) == 1}] \
                   "(shown=$::VMDPathFinder::tunnel_shown($_unlisted), default=1)"
            catch {unset ::VMDPathFinder::tunnel_xcid(90002,$_unlisted)}
            catch {unset ::VMDPathFinder::tunnel_shown($_unlisted)}

            # Per-tunnel gear overrides are keyed by RANK and persist across
            # frames, so without the cluster mirror a color painted on rank 1
            # in one frame re-painted an unrelated rank 1 in the next AND the
            # painted route reverted to auto.
            set ::VMDPathFinder::tunnel_gear_cid($_cid1,colormode) red
            set ::VMDPathFinder::tunnel_gear_cid($_cid1,color) red
            if {$_rk2 ne ""} {
                catch {unset ::VMDPathFinder::tunnel_gear_colormode($_rk2)}
                ::VMDPathFinder::_tunnel_sync_gear_from_cluster 90002 $_rk2
                report "a gear color override follows the cluster into another frame" \
                       [expr {[info exists ::VMDPathFinder::tunnel_gear_colormode($_rk2)] \
                           && $::VMDPathFinder::tunnel_gear_colormode($_rk2) eq "red"}] \
                       "(frame 90002 rank $_rk2 colormode=[expr {[info exists ::VMDPathFinder::tunnel_gear_colormode($_rk2)] ? $::VMDPathFinder::tunnel_gear_colormode($_rk2) : {unset}}])"
            }
            if {$_other ne ""} {
                set ::VMDPathFinder::tunnel_gear_colormode($_other) red
                ::VMDPathFinder::_tunnel_sync_gear_from_cluster 90002 $_other
                report "a stale rank-keyed override is CLEARED for a different cluster" \
                       [expr {![info exists ::VMDPathFinder::tunnel_gear_colormode($_other)]}] \
                       "(rank $_other colormode=[expr {[info exists ::VMDPathFinder::tunnel_gear_colormode($_other)] ? $::VMDPathFinder::tunnel_gear_colormode($_other) : {unset}}])"
            }
            catch {unset ::VMDPathFinder::tunnel_gear_cid($_cid1,colormode)}
            catch {unset ::VMDPathFinder::tunnel_gear_cid($_cid1,color)}
            # Leave no override behind: the later "gear icon defaults to no
            # override" check reads the RANK-keyed arrays, which the sync above
            # deliberately writes.
            foreach _rr [list 1 $_rk2 $_other] {
                if {$_rr eq ""} continue
                foreach _ff {color material wire prop colormode} {
                    catch {unset ::VMDPathFinder::tunnel_gear_${_ff}($_rr)}
                }
            }

            catch {unset ::VMDPathFinder::tunnel_shown_cid($_cid1)}
            set ::VMDPathFinder::tunnel_shown(1) 1
        }
        # No cross-frame identity (single-frame run) must be byte-identical to
        # the old rank-keyed behaviour - this is the regression path.
        report "with no cluster, the palette index is still rank-1 (old behaviour)" \
               [expr {[::VMDPathFinder::_tunnel_palette_index "__no_such_frame__" 4] == 3}] \
               "(idx=[::VMDPathFinder::_tunnel_palette_index {__no_such_frame__} 4])"

        # Within-frame clustering must WORK when ticked after a run, not only
        # when the run itself was made with it already on. run_tunnel_analysis
        # built tunnel_clusters only when the flag was already set - and it
        # defaults to OFF - so on a normal run nothing existed and the checkbox
        # did nothing at all (_tunnel_list_rows falls straight through to the
        # unclustered branch when tunnel_clusters($frame) is missing).
        # Sabotage-checked: dropping the _tunnel_ensure_clusters call fails it.
        # A frame that is really IN tunnel_result_frames - at this point the
        # synthetic 2-frame pool above is still installed, so the live display
        # frame is not one of them and _tunnel_ensure_clusters would correctly
        # build for the pooled frames instead.
        set _efr [lindex $::VMDPathFinder::tunnel_result_frames 0]
        set _sv_con2 $::VMDPathFinder::state(tunnel_cluster_on)
        set _sv_th2 $::VMDPathFinder::state(tunnel_cluster)
        array unset ::VMDPathFinder::tunnel_clusters
        array set ::VMDPathFinder::tunnel_clusters {}
        unset -nocomplain ::VMDPathFinder::_tunnel_clusters_th
        report "(setup) no within-frame clusters exist yet" \
               [expr {![info exists ::VMDPathFinder::tunnel_clusters($_efr)]}] \
               "(exists=[info exists ::VMDPathFinder::tunnel_clusters($_efr)])"
        set ::VMDPathFinder::state(tunnel_cluster_on) 1
        ::VMDPathFinder::_tunnel_cluster_toggle_changed
        # The contract is now PER FRAME: ticking the box groups the list you are
        # LOOKING AT. It used to cluster every result frame, which measured
        # ~20 ms x every frame of the trajectory (216 s on a 10k run) for a
        # display-only grouping of frames nobody sees.
        set _dfr [::VMDPathFinder::_tunnel_display_frame]
        report "ticking Cluster within frame builds the DISPLAYED frame on demand" \
               [expr {[info exists ::VMDPathFinder::tunnel_clusters($_dfr)]}] \
               "(displayed=$_dfr exists=[info exists ::VMDPathFinder::tunnel_clusters($_dfr)])"
        # ...and does NOT walk the whole trajectory doing it.
        set _nother 0
        foreach _f $::VMDPathFinder::tunnel_result_frames {
            if {$_f ne $_dfr && [info exists ::VMDPathFinder::tunnel_clusters($_f)]} { incr _nother }
        }
        report "...without clustering every other frame up front" \
               [expr {$_nother == 0}] "(other frames clustered=$_nother)"
        # Any frame can still be grouped when it is actually needed.
        ::VMDPathFinder::_tunnel_ensure_clusters_for $_efr
        report "another frame is grouped when something asks for it" \
               [expr {[info exists ::VMDPathFinder::tunnel_clusters($_efr)]}] \
               "(exists=[info exists ::VMDPathFinder::tunnel_clusters($_efr)])"
        set ::VMDPathFinder::state(tunnel_cluster) [expr {$_sv_th2 + 2.0}]
        ::VMDPathFinder::_tunnel_ensure_clusters
        report "changing the clustering threshold rebuilds, not reuses, the groups" \
               [expr {$::VMDPathFinder::_tunnel_clusters_th == $_sv_th2 + 2.0}] \
               "(cached_th=$::VMDPathFinder::_tunnel_clusters_th want=[expr {$_sv_th2 + 2.0}])"
        set ::VMDPathFinder::state(tunnel_cluster) $_sv_th2
        ::VMDPathFinder::_tunnel_ensure_clusters
        set ::VMDPathFinder::state(tunnel_cluster_on) $_sv_con2
        ::VMDPathFinder::_tunnel_cluster_toggle_changed

        # The within-frame clustering checkbox no longer changes the tunnel
            # LIST's row set at all - the list is the CROSS-frame cluster set
            # now (refresh_tunnel_tab/_tunnel_cluster_rows), and tunnel_
            # cluster_on is a purely WITHIN-frame, display/3D-only grouping
            # (_tunnel_list_rows/_tunnel_candidates, still exercised above by
            # the prev/next and render checks) that _tunnel_list_signature
            # deliberately does not depend on any more. So toggling it must
            # ALWAYS skip the list rebuild now, unconditionally - there is no
            # "row count changed" case left to assert for THIS list.
            set _sv_con $::VMDPathFinder::state(tunnel_cluster_on)
            ::VMDPathFinder::refresh_tunnel_tab
            frame $_rowf.__probe2
            set ::VMDPathFinder::state(tunnel_cluster_on) [expr {!$_sv_con}]
            ::VMDPathFinder::_tunnel_cluster_toggle_changed
            report "toggling within-frame clustering does not change the tunnel list's row set" \
                   [expr {[winfo exists $_rowf.__probe2]}] \
                   "(probe survived=[winfo exists $_rowf.__probe2])"
            set ::VMDPathFinder::state(tunnel_cluster_on) $_sv_con
            catch {destroy $_rowf.__probe2}
            ::VMDPathFinder::refresh_tunnel_tab
        }

        array unset ::VMDPathFinder::tunnel_results 90001
        array unset ::VMDPathFinder::tunnel_results 90002
        set ::VMDPathFinder::tunnel_result_frames $_sv_trf
        array set ::VMDPathFinder::tunnel_results $_sv_tr
        array unset ::VMDPathFinder::tunnel_shown_cid
        array set ::VMDPathFinder::tunnel_shown_cid $_sv_shown_cid
        set ::VMDPathFinder::state(tunnel_shown_default) $_sv_shown_def
        set ::VMDPathFinder::state(tunnel_shown_all) $_sv_shown_all
        ::VMDPathFinder::_tunnel_xframe_build

        # NEW (redesign): presence used to be its own traffic-light column,
        # the only per-row cell that varied with the landed frame. It was
        # squeezing the gear column to 0px the moment it was added (measured:
        # the fixed columns' minsize summed to exactly the tunlist canvas's
        # own width, leaving the gear - the one column with weight/no minsize,
        # meant to absorb slack - literally nothing) - see refresh_tunnel_
        # tab's header-build comment. Merged into the Seen cell's own
        # foreground color instead, which only exists on a multi-frame
        # result (_cov_col); this fixture is single-frame (1BL8, "now"), so
        # there is genuinely no cell to recolor here - real green/red
        # coverage is exercised on the synthetic multi-frame pool below (E2b),
        # which is also the fixture that lets order and color be checked
        # independently. Here, just prove the update path is still safe with
        # no Seen column to touch, and that the old separate widget is really
        # gone (not silently orphaned, still consuming a column).
        ::VMDPathFinder::refresh_tunnel_tab
        set _rowsN [::VMDPathFinder::_tunnel_cluster_rows]
        # Asserted on the widget's NAME, not on a column index: the index moves
        # whenever a column is added (Vol did), and a positional assertion then
        # fails for a reason that has nothing to do with what it is checking.
        report "the old separate traffic-light widget is gone (merged into Seen)" \
               [expr {![winfo exists $P.tunlist.hdr.hlive] \
                   && [lindex [grid size $P.tunlist.c.inner] 0] \
                      <= [lindex [grid size $P.tunlist.hdr] 0]}] \
               "(hlive=[winfo exists $P.tunlist.hdr.hlive] body=[lindex [grid size $P.tunlist.c.inner] 0] hdr=[lindex [grid size $P.tunlist.hdr] 0])"
        set _tl_rc [catch {::VMDPathFinder::_tunnel_update_traffic_lights} _tl_err]
        report "_tunnel_update_traffic_lights is a safe no-op with no Seen column (single frame)" \
               [expr {$_tl_rc == 0}] "($_tl_err)"

        if {[llength $_rowsN]} {
            report "the row survives (not rebuilt) across that no-op update" \
                   [expr {[winfo exists $P.tunlist.c.inner.rk1] \
                       && [string trim [$P.tunlist.c.inner.rk1 cget -text]] eq [dict get [lindex $_rowsN 0] cid]}] \
                   "(rk1=[expr {[winfo exists $P.tunlist.c.inner.rk1] ? [$P.tunlist.c.inner.rk1 cget -text] : {missing}}])"
        }
    }

    # E2b: default list ORDER (green-first, then Seen%) and the 10% Seen
    # floor + "Show all" bypass. The 2-frame pool above gives every cluster
    # identical 100% Seen (both frames are literal copies of one real frame),
    # which cannot exercise either feature - need Seen values that actually
    # spread out, AND the landed frame missing some clusters (red) while
    # others stay present (green), at the SAME landing _tunnel_display_frame
    # really resolves to (molinfo's real frame), not a synthetic one passed
    # by hand - refresh_tunnel_tab calls _tunnel_display_frame internally, so
    # bypassing it (like the cid1/cid2 checks above do) would not exercise
    # the real code path this feature lives in.
    #
    # 5 wholly-SYNTHETIC tuples, not a subset of the real ones: an earlier
    # version derived presence from real-tuple INDEX, but this fixture's own
    # routes cluster together (near-duplicate geometry, same as any real
    # structure), so two indices with different engineered presence silently
    # merged into one cluster and inherited the UNION of both - "below=0 of
    # 4" even though the presence pattern by construction had a below-floor
    # index. Each fake tuple here is the real tuple 0's centreline shifted a
    # fixed distance along x (99+ A apart, far past any clustering threshold
    # used in this file), so five clusters are GUARANTEED, each carrying
    # exactly the presence pattern assigned below - no dependency on how this
    # fixture's real geometry happens to cluster:
    #   fake0: present at $_cfr, present  15/19 synthetic -> Seen 80% (green, high)
    #   fake1: present at $_cfr, present   3/19 synthetic -> Seen 20% (green, low)
    #   fake2: ABSENT at $_cfr, present   17/19 synthetic -> Seen 85% (red, HIGHER than fake0)
    #   fake3: ABSENT at $_cfr, present    1/19 synthetic -> Seen  5% (red, below floor)
    #   fake4: present at $_cfr, present   0/19 synthetic -> Seen  5% (green, below floor)
    # fake2 > fake0 in Seen is the point: a plain Seen-only sort would put
    # fake2 ahead of fake0, but the two-tier rule must not.
    if {$ntun >= 1} {
        set _cfr [::VMDPathFinder::_tunnel_display_frame]
        set _real_tuns $::VMDPathFinder::tunnel_results($_cfr)
        set _sv_trf4 $::VMDPathFinder::tunnel_result_frames
        set _sv_tr4 [array get ::VMDPathFinder::tunnel_results]
        set _sv_sel4 $::VMDPathFinder::state(tunnel_selected_cid)
        set _sv_floor4 $::VMDPathFinder::state(tunnel_seen_floor)
        set _sv_showall4 $::VMDPathFinder::state(tunnel_list_show_all)
        set _sv_sortcol4 [expr {[info exists ::VMDPathFinder::state(tunnel_sort_col)] ? $::VMDPathFinder::state(tunnel_sort_col) : ""}]
        set _sv_sortdir4 [expr {[info exists ::VMDPathFinder::state(tunnel_sort_dir)] ? $::VMDPathFinder::state(tunnel_sort_dir) : 1}]

        proc ::_ge2b_shift_tuple {tuple dx} {
            set pts [lindex $tuple 4]
            set out {}
            set i 0
            foreach v $pts {
                if {$i % 4 == 0} { lappend out [expr {$v + $dx}] } else { lappend out $v }
                incr i
            }
            return [lreplace $tuple 4 4 $out]
        }
        set _tmpl [lindex $_real_tuns 0]
        set _fakes {}
        foreach _dx {0.0 100.0 200.0 300.0 400.0} { lappend _fakes [::_ge2b_shift_tuple $_tmpl $_dx] }
        rename ::_ge2b_shift_tuple {}

        set _synth {}
        for {set _k 1} {$_k <= 19} {incr _k} { lappend _synth [expr {70000+$_k}] }
        set _pool_frames [linsert $_synth 0 $_cfr]
        array unset ::VMDPathFinder::tunnel_results
        array set ::VMDPathFinder::tunnel_results {}
        # {present_at_cfr n_synthetic_present} per fake tuple, in order.
        set _plan {
            {1 15} {1 3} {0 17} {0 1} {1 0}
        }
        set _cfr_tuns {}
        foreach _p $_plan _fk $_fakes {
            if {[lindex $_p 0]} { lappend _cfr_tuns $_fk }
        }
        set ::VMDPathFinder::tunnel_results($_cfr) $_cfr_tuns
        for {set _fi 0} {$_fi < 19} {incr _fi} {
            set _fr [lindex $_synth $_fi]
            set _sub {}
            foreach _p $_plan _fk $_fakes {
                if {$_fi < [lindex $_p 1]} { lappend _sub $_fk }
            }
            set ::VMDPathFinder::tunnel_results($_fr) $_sub
        }
        set ::VMDPathFinder::tunnel_result_frames $_pool_frames
        set ::VMDPathFinder::state(tunnel_seen_floor) 10
        set ::VMDPathFinder::state(tunnel_list_show_all) 0
        set ::VMDPathFinder::state(tunnel_sort_col) ""
        ::VMDPathFinder::_tunnel_xframe_build
        report "(setup) the engineered pool has exactly 5 non-merging clusters" \
               [expr {[llength $::VMDPathFinder::tunnel_xclusters] == 5}] \
               "(n=[llength $::VMDPathFinder::tunnel_xclusters])"
        set _allrows [::VMDPathFinder::_tunnel_cluster_rows]
        array set _seenof {}
        foreach _rr $_allrows { set _seenof([dict get $_rr cid]) [dict get $_rr seen] }
        # A leftover pin from earlier in this file (any prior cid) would
        # otherwise coincidentally collide with one of THIS fresh pool's 1..5
        # cids and exempt it from the floor, undercounting exactly the "one
        # extra row" this bit itself checks for further down. Clearing it
        # outright does not fix that - _tunnel_sync_selected_id's own
        # fallback (no pin) re-pins to _tunnel_cluster_rows's first entry,
        # which is CAVER-priority order and not guaranteed to be fake0 either.
        # Pin explicitly to fake0 (Seen 80%, already above the floor on its
        # own), so the exemption is a documented no-op for this count.
        set _fake0_cid ""
        set _fake2_cid ""
        foreach _rr $_allrows {
            if {abs([dict get $_rr seen] - 80.0) < 1e-6} { set _fake0_cid [dict get $_rr cid] }
            if {abs([dict get $_rr seen] - 85.0) < 1e-6} { set _fake2_cid [dict get $_rr cid] }
        }
        set ::VMDPathFinder::state(tunnel_selected_cid) $_fake0_cid

        ::VMDPathFinder::refresh_tunnel_tab
        set _P $w.sidebar.nb.tunnel
        set _rf $_P.tunlist.c.inner
        set _hf $_P.tunlist.hdr
        set _disp {}
        for {set _r 1} {[winfo exists $_rf.rk$_r] && [winfo ismapped $_rf.rk$_r]} {incr _r} {
            lappend _disp [string trim [$_rf.rk$_r cget -text]]
        }
        # The old two-tier rule (present-in-$_cfr first, THEN Seen%) is gone -
        # see refresh_tunnel_tab's own comment on why (it made the default
        # order depend on the landed frame, which was the reported "the list
        # moves during the first playback after a run"). Order is Seen%
        # descending only now, a mean over the whole trajectory like every
        # other column _tunnel_cluster_rows computes - genuinely frame-
        # independent, not just reordered to look that way.
        set _order_ok 1
        set _last_seen 1000.0
        foreach _cid $_disp {
            if {$_seenof($_cid) > $_last_seen + 1e-9} { set _order_ok 0 }
            set _last_seen $_seenof($_cid)
        }
        # fake2 (85%, ABSENT at $_cfr) must sort ABOVE fake0 (80%, present) -
        # exactly the case the old present-first tier existed to override, and
        # exactly what a plain Seen-only sort was always going to do to it.
        set _pos2 [lsearch -exact $_disp $_fake2_cid]
        set _pos0 [lsearch -exact $_disp $_fake0_cid]
        report "default order is Seen% descending only - presence no longer overrides it" \
               [expr {$_order_ok && $_pos2 >= 0 && $_pos0 >= 0 && $_pos2 < $_pos0}] \
               "(rows=$_disp order_ok=$_order_ok fake2(85%,absent)_pos=$_pos2 fake0(80%,present)_pos=$_pos0)"

        # Stronger than "reordered correctly": order must not consult presence
        # AT ALL any more. Forcing every cluster "absent" - which would have
        # inverted the whole first tier under the old rule - must change
        # NOTHING about the displayed order.
        rename ::VMDPathFinder::_tunnel_cluster_present ::VMDPathFinder::_tunnel_cluster_present_orig_e2b
        proc ::VMDPathFinder::_tunnel_cluster_present {cid frame} { return 0 }
        ::VMDPathFinder::refresh_tunnel_tab
        set _disp_allabsent {}
        for {set _r 1} {[winfo exists $_rf.rk$_r] && [winfo ismapped $_rf.rk$_r]} {incr _r} {
            lappend _disp_allabsent [string trim [$_rf.rk$_r cget -text]]
        }
        rename ::VMDPathFinder::_tunnel_cluster_present {}
        rename ::VMDPathFinder::_tunnel_cluster_present_orig_e2b ::VMDPathFinder::_tunnel_cluster_present
        ::VMDPathFinder::refresh_tunnel_tab
        report "row order does not depend on presence at all (forcing every cluster absent changes nothing)" \
               [expr {$_disp_allabsent eq $_disp}] \
               "(with-real-presence=$_disp all-absent=$_disp_allabsent)"
        # Sabotage-checked by hand: restoring the old composite key's
        # ($_present ? 0.0 : 1000.0) term in refresh_tunnel_tab turns both of
        # the two reports above FAIL, as it must - confirmed, then removed.

        # Presence itself still has to be SHOWN somewhere - merged into the
        # Seen cell's own foreground color now (green/red), not a separate
        # column. fake0/fake1 are present at $_cfr (green), fake2 is absent
        # (red); fake3/fake4 are floor-hidden by default so not checked here.
        set _seen_col ""
        catch {
            array set _e2bgi [grid info $_hf.hseen]
            set _seen_col $_e2bgi(-column)
        }
        set _color_ok [expr {$_seen_col ne ""}]
        set _color_detail ""
        if {$_seen_col ne ""} {
            for {set _r 1} {[winfo exists $_rf.rk$_r] && [winfo ismapped $_rf.rk$_r]} {incr _r} {
                set _rcid [string trim [$_rf.rk$_r cget -text]]
                set _want [expr {[::VMDPathFinder::_tunnel_cluster_present $_rcid $_cfr] ? "#2a9d3f" : "#c0392b"}]
                set _got [$_rf.rv${_r}_$_seen_col cget -foreground]
                append _color_detail " cid$_rcid:got=$_got/want=$_want"
                if {$_got ne $_want} { set _color_ok 0 }
            }
        }
        report "presence is carried by the Seen cell's own color, not a separate column" \
               $_color_ok "($_color_detail)"

        # ITEM 1 (regression): the gear column must actually be ON SCREEN,
        # not merely exist. This is the one check the single-frame 1BL8
        # fixture below cannot make: without a Seen column (single frame) the
        # fixed columns never summed past the tunlist canvas's own width, so
        # the gear was never squeezed there even before the fix - the
        # overflow only happens once Seen (and, before this fix, the
        # traffic-light column next to it) is showing, i.e. on a multi-frame
        # result like this synthetic pool. `winfo exists` alone is exactly
        # what let this regress unnoticed (task 172's own existence check,
        # above) - `ismapped` and a real pixel width are what actually prove
        # the user can see and click it.
        update idletasks
        set _gc_hdr_ok [expr {[winfo exists $_hf.hgear] && [winfo ismapped $_hf.hgear] \
            && [winfo width $_hf.hgear] > 0}]
        set _gc_row_ok [expr {[winfo exists $_rf.rg1] && [winfo ismapped $_rf.rg1] \
            && [winfo width $_rf.rg1] > 0}]
        report "the header's global gear icon is actually visible (not squeezed to 0px)" \
               $_gc_hdr_ok "(exists=[winfo exists $_hf.hgear] ismapped=[expr {[winfo exists $_hf.hgear] ? [winfo ismapped $_hf.hgear] : {n/a}}] width=[expr {[winfo exists $_hf.hgear] ? [winfo width $_hf.hgear] : {n/a}}])"
        report "a row's own gear icon is actually visible (not squeezed to 0px)" \
               $_gc_row_ok "(exists=[winfo exists $_rf.rg1] ismapped=[expr {[winfo exists $_rf.rg1] ? [winfo ismapped $_rf.rg1] : {n/a}}] width=[expr {[winfo exists $_rf.rg1] ? [winfo width $_rf.rg1] : {n/a}}])"
        # Sabotage-checked by hand: reintroducing the separate traffic-light
        # column (hf.hlive / rv${r}_8, one more fixed-width column ahead of
        # the gear) turns both reports above FAIL on this fixture's panel
        # width - confirmed, then removed again.

        # Sabotage-checked by hand: reverting refresh_tunnel_tab's else branch
        # to reuse _tunnel_cluster_rows's raw CAVER-priority order (comment
        # out the reorder, leave $rows untouched) turns this FAIL - confirmed,
        # then restored.
        set _floor_n 0
        foreach _rr $_allrows { if {[dict get $_rr seen] < 10.0} { incr _floor_n } }
        report "(setup) the engineered pool has routes below the 10% floor" \
               [expr {$_floor_n > 0}] "(below=$_floor_n of [llength $_allrows])"
        report "the 10% Seen floor hides exactly the below-floor routes by default" \
               [expr {[llength $_disp] == [llength $_allrows] - $_floor_n}] \
               "(displayed=[llength $_disp] want=[expr {[llength $_allrows]-$_floor_n}])"

        # The hidden count belongs in the tooltip, not the label. Asserted
        # here, where routes really are hidden.
        set _sa_w $::VMDPathFinder::_tunnelpanel.tunctl.showall
        set _sa_txt [$_sa_w cget -text]
        report "the \"Show all\" label stays \"Show all\" - no count in parentheses" \
               [expr {$_sa_txt eq "Show all"}] "(label=\"$_sa_txt\", hidden=$_floor_n)"
        set _sa_tip ""
        catch {set _sa_tip $::VMDPathFinder::_tooltip_text($_sa_w)}
        report "...and the hidden count is in its tooltip instead" \
               [expr {[string match "*$_floor_n*" $_sa_tip] && [string match "*hidden*" $_sa_tip]}] \
               "(tooltip=\"$_sa_tip\")"

        set ::VMDPathFinder::state(tunnel_list_show_all) 1
        ::VMDPathFinder::refresh_tunnel_tab
        set _sa_created $::VMDPathFinder::_rw_created
        set _disp2 {}
        for {set _r 1} {[winfo exists $_rf.rk$_r] && [winfo ismapped $_rf.rk$_r]} {incr _r} {
            lappend _disp2 [string trim [$_rf.rk$_r cget -text]]
        }
        report "\"Show all\" bypasses the floor - every tracked route gets a row" \
               [expr {[llength $_disp2] == [llength $_allrows]}] \
               "(displayed=[llength $_disp2] total=[llength $_allrows])"
        # Not an assertion on the count - "Show all" legitimately creates the
        # rows the floor was hiding, and a row widget costs ~22 ms in VMD's Tk
        # against ~0.05 ms on a virtual display, so no timing measured here
        # says anything about the real machine. Recorded so a future change to
        # how those rows come into being has a number to move.
        report "(measurement) \"Show all\" widget creations" 1 \
               "(created=$_sa_created for [llength $_allrows] row(s))"
        # Sabotage-checked by hand: removing the "|| !$_showall" branch (always
        # filtering) turns this FAIL - confirmed, then restored.

        set ::VMDPathFinder::state(tunnel_list_show_all) 0
        ::VMDPathFinder::refresh_tunnel_tab

        # Selection pin is exempt from the floor even when below it - a click
        # or Prev/Next must never lose its row just because Seen is low, or
        # the pin silently reads as "gone" from the one place the user looks.
        set _low_cid ""
        foreach _rr $_allrows { if {[dict get $_rr seen] < 10.0} { set _low_cid [dict get $_rr cid]; break } }
        if {$_low_cid ne ""} {
            set ::VMDPathFinder::state(tunnel_selected_cid) $_low_cid
            ::VMDPathFinder::refresh_tunnel_tab
            variable ::VMDPathFinder::_tunlist_rowof
            report "a selected route below the floor still gets a row" \
                   [expr {[info exists ::VMDPathFinder::_tunlist_rowof($_low_cid)]}] \
                   "(cid=$_low_cid)"
            # Sabotage-checked by hand: dropping the "|| [dict get $row cid] eq
            # $_selcid" exemption from the filter loop turns this FAIL -
            # confirmed, then restored.
        }

        # The < / > arrows must keep the blue row highlight. Needs this
        # fixture: with the 10% floor on, the displayed rows are a subset, and
        # a rank walk could land on a floor-hidden route with no row to color.
        set ::VMDPathFinder::state(tunnel_selected_cid) [dict get [lindex $_allrows 0] cid]
        ::VMDPathFinder::refresh_tunnel_tab
        set _hl_ok 1; set _hl_lost {}; set _hl_steps 0
        set _nsteps [expr {[llength $_allrows] + 2}]
        for {set _k 0} {$_k < $_nsteps} {incr _k} {
            ::VMDPathFinder::_tunnel_select_step 1
            update idletasks
            incr _hl_steps
            # Count row cells actually painted with the selection background.
            set _nhl 0
            foreach _c [winfo children $_rf] {
                if {![regexp {^r(?:c|v|g)(\d+)} [winfo name $_c]]} continue
                if {[$_c cget -background] eq "#cfe3ff"} { incr _nhl }
            }
            if {$_nhl == 0} {
                set _hl_ok 0
                lappend _hl_lost "step${_hl_steps}:cid=$::VMDPathFinder::state(tunnel_selected_cid)"
            }
        }
        report "the < / > arrows never lose the blue row highlight" \
               $_hl_ok "(steps=$_hl_steps lost-highlight-at=[join $_hl_lost {, }])"
        # ...and the route they land on is one the list is actually showing.
        set _step_off {}
        for {set _k 0} {$_k < $_nsteps} {incr _k} {
            ::VMDPathFinder::_tunnel_select_step 1
            if {![info exists ::VMDPathFinder::_tunlist_rowof($::VMDPathFinder::state(tunnel_selected_cid))]} {
                lappend _step_off $::VMDPathFinder::state(tunnel_selected_cid)
            }
        }
        report "...and never selects a route with no row in the list" \
               [expr {[llength $_step_off] == 0}] "(off-list=[join $_step_off {, }])"

        # The pin itself must never move on a plain traffic-light update (the
        # cheap per-drafted-frame path) - only a full refresh may re-derive it,
        # and even then only when the pin is genuinely gone from the cluster
        # set (not merely floor-hidden, which _tunnel_sync_selected_id never
        # sees - it reads the unfiltered _tunnel_cluster_rows).
        set ::VMDPathFinder::state(tunnel_selected_cid) [dict get [lindex $_allrows 0] cid]
        ::VMDPathFinder::refresh_tunnel_tab
        set _pin0 $::VMDPathFinder::state(tunnel_selected_cid)
        ::VMDPathFinder::_tunnel_update_traffic_lights
        report "a plain traffic-light update never moves the selection pin" \
               [expr {$::VMDPathFinder::state(tunnel_selected_cid) eq $_pin0}] \
               "(before=$_pin0 after=$::VMDPathFinder::state(tunnel_selected_cid))"
        # ...nor does it reorder or rebuild any row - same probe technique as
        # the cross-frame block above.
        catch {destroy $_rf.__probe3}
        frame $_rf.__probe3
        ::VMDPathFinder::_tunnel_update_traffic_lights
        report "a plain traffic-light update does not rebuild the row set" \
               [expr {[winfo exists $_rf.__probe3]}] \
               "(probe survived=[winfo exists $_rf.__probe3])"
        catch {destroy $_rf.__probe3}

        # A column sort must still override the default order. The frame no
        # longer appears in the list signature AT ALL any more, sorted or
        # not - unlike the old present-first default order, Seen%-descending
        # is exactly as frame-independent as the row SET already was (see
        # _tunnel_list_signature's own comment), so there is nothing left for
        # the frame to invalidate. That is what makes a settled frame step a
        # no-op for refresh_tunnel_tab_if_stale now (only _tunnel_update_
        # traffic_lights has anything to do on one) - see frame_changed_
        # settle's own comment.
        ::VMDPathFinder::_tunnel_sort_by seen
        set _sig_sorted [::VMDPathFinder::_tunnel_list_signature]
        set _sig_hc_sorted [::VMDPathFinder::_tunnel_header_content_signature]
        report "the list signature carries no frame while a column sort is active" \
               [expr {$_sig_sorted eq $_sig_hc_sorted}] "(list=$_sig_sorted hc=$_sig_hc_sorted)"
        ::VMDPathFinder::refresh_tunnel_tab
        set _disp3 {}
        for {set _r 1} {[winfo exists $_rf.rk$_r] && [winfo ismapped $_rf.rk$_r]} {incr _r} {
            lappend _disp3 [string trim [$_rf.rk$_r cget -text]]
        }
        # _tunnel_sort_by's first click on a new column sets sortdir=1, which
        # refresh_tunnel_tab's column-sort branch renders as "-increasing"
        # (the header's own ▲ glyph) - ascending, lowest Seen first.
        set _seensort_ok 1
        set _prev_seen -1000.0
        foreach _cid $_disp3 {
            if {$_seenof($_cid) < $_prev_seen - 1e-9} { set _seensort_ok 0 }
            set _prev_seen $_seenof($_cid)
        }
        report "clicking the Seen column header still sorts by it explicitly" \
               [expr {$_seensort_ok} ] "(rows=[llength $_disp3])"
        set ::VMDPathFinder::state(tunnel_sort_col) ""
        set ::VMDPathFinder::state(tunnel_sort_dir) 1
        set _sig_unsorted [::VMDPathFinder::_tunnel_list_signature]
        set _sig_hc_unsorted [::VMDPathFinder::_tunnel_header_content_signature]
        report "...and still carries no frame once no column sort is active either" \
               [expr {$_sig_unsorted eq $_sig_hc_unsorted}] "(list=$_sig_unsorted hc=$_sig_hc_unsorted)"
        # Sabotage-checked by hand: reinstating a trailing $frame element in
        # _tunnel_list_signature (the pre-fix shape) turns both reports above
        # FAIL - confirmed, then restored.

        # ITEM 2 (per-frame rebuild cost): _sync_tunlist_header_columns's own
        # `update idletasks` was measured as 110-160ms of a ~230-260ms settled
        # frame step at 394 rows - the deferred cost of the Tk grid geometry
        # manager relaying out the ~3150 gridded cells the row loop above just
        # touched, paid wherever the next call happens to force it current. A
        # reorder-only rebuild (default order, same content) has nothing that
        # changes any column's required width - _tunnel_header_content_
        # signature and _tunnel_list_signature are now the SAME computation
        # (the latter simply returns the former - see its own comment), kept
        # as two names because they document two different questions.
        set _sig_full [::VMDPathFinder::_tunnel_list_signature]
        set _sig_hc [::VMDPathFinder::_tunnel_header_content_signature]
        report "the header-content signature is identical to the list signature" \
               [expr {$_sig_full eq $_sig_hc}] "(full=$_sig_full hc=$_sig_hc)"

        # Counting real invocations rather than probing a minsize value: an
        # earlier version of this test set an impossible -minsize as a canary
        # directly on $hf, but _sync_tunlist_header_columns measures ITS OWN
        # bbox (grid bbox $hf ...) as part of computing the new width, so a
        # canary sitting on $hf feeds back into the very measurement meant to
        # detect whether it ran - a real resync just reads the poisoned bbox
        # back and re-sets the same huge value, a false PASS/FAIL either way.
        rename ::VMDPathFinder::_sync_tunlist_header_columns ::VMDPathFinder::_sync_tunlist_header_columns_orig_t
        set ::_hdrsync_calls 0
        proc ::VMDPathFinder::_sync_tunlist_header_columns {} {
            incr ::_hdrsync_calls
            ::VMDPathFinder::_sync_tunlist_header_columns_orig_t
        }
        ::VMDPathFinder::refresh_tunnel_tab
        set ::_hdrsync_calls 0
        ::VMDPathFinder::refresh_tunnel_tab
        report "an unchanged content signature skips the header-column resync" \
               [expr {$::_hdrsync_calls == 0}] "(calls=$::_hdrsync_calls)"
        # Sabotage-checked by hand: dropping the _tunlist_hdrcols_sig guard
        # (always calling _sync_tunlist_header_columns) turns this FAIL -
        # confirmed, then restored.

        set _sv_showall_hc $::VMDPathFinder::state(tunnel_list_show_all)
        set ::VMDPathFinder::state(tunnel_list_show_all) [expr {!$_sv_showall_hc}]
        set ::_hdrsync_calls 0
        ::VMDPathFinder::refresh_tunnel_tab
        report "a genuine content change (Show all) still resyncs header columns" \
               [expr {$::_hdrsync_calls == 1}] "(calls=$::_hdrsync_calls)"
        set ::VMDPathFinder::state(tunnel_list_show_all) $_sv_showall_hc
        rename ::VMDPathFinder::_sync_tunlist_header_columns {}
        rename ::VMDPathFinder::_sync_tunlist_header_columns_orig_t ::VMDPathFinder::_sync_tunlist_header_columns
        ::VMDPathFinder::refresh_tunnel_tab

        # The selected row's scroll-into-view is deferred to the next idle
        # pass (its own `update idletasks` was the other large deferred-
        # relayout cost, ~105-115ms once the header-column gate above stopped
        # paying it), so refresh_tunnel_tab must not call it directly - it
        # must show up as a pending `after idle` script. Checking `after
        # info` rather than a yview probe: this fixture's 5 rows are shorter
        # than the list's fixed viewport height, so _tunnel_scroll_to_selected
        # would return before ever touching yview regardless of whether it
        # ran synchronously or deferred - a yview probe would pass vacuously.
        set _before_aids [after info]
        ::VMDPathFinder::refresh_tunnel_tab
        set _found_idle 0
        foreach _aid [after info] {
            if {[lsearch -exact $_before_aids $_aid] >= 0} continue
            lassign [after info $_aid] _ascript _aevent
            if {$_aevent eq "idle" && [string match "*_tunnel_scroll_to_selected*" $_ascript]} {
                set _found_idle 1
            }
        }
        report "the post-rebuild scroll-to-selected is scheduled via after idle, not called directly" \
               $_found_idle "(pending=[after info])"
        # Sabotage-checked by hand: reverting the after-idle wrap to a direct
        # _tunnel_scroll_to_selected call turns this FAIL - confirmed, then
        # restored.
        update idletasks
        update

        # ITEM 3: gear/visibility handlers must not repaint the landed frame
        # with a fallback SEARCHED frame's geometry when the landed frame
        # itself was never searched - _tunnel_display_frame's fallback exists
        # so analysis panels always have something to show, but render_
        # tunnels_for_frame drawing that fallback's geometry paints it onto
        # whatever frame the 3D view is actually on, which is wrong for any
        # frame but the one it was meant for.
        rename ::VMDPathFinder::render_tunnels_for_frame ::VMDPathFinder::render_tunnels_for_frame_orig_t3
        set ::_rtf_calls 0
        proc ::VMDPathFinder::render_tunnels_for_frame {frame {draft 0}} {
            incr ::_rtf_calls
            ::VMDPathFinder::render_tunnels_for_frame_orig_t3 $frame $draft
        }
        set _sv_tr_t3 [array get ::VMDPathFinder::tunnel_results]
        set _sv_trf_t3 $::VMDPathFinder::tunnel_result_frames
        # $_cfr is the real landed VMD frame throughout this file. Leaving it
        # OUT of tunnel_results (with some other frame present instead) makes
        # it genuinely unsearched while _tunnel_display_frame still has a
        # fallback to draw - exactly the situation the guard has to catch.
        array unset ::VMDPathFinder::tunnel_results
        array set ::VMDPathFinder::tunnel_results [list 99999 $_real_tuns]
        set ::VMDPathFinder::tunnel_result_frames {99999}
        report "(setup) the landed frame is genuinely unsearched here" \
               [::VMDPathFinder::_tunnel_landed_is_unsearched] ""
        set ::_rtf_calls 0
        ::VMDPathFinder::_tunnel_global_gear_reset
        report "a gear reset does not render onto an unsearched landed frame" \
               [expr {$::_rtf_calls == 0}] "(calls=$::_rtf_calls)"
        # Sabotage-checked by hand: dropping the _tunnel_landed_is_unsearched
        # guard from _tunnel_global_gear_reset (and the other 7 sites) turns
        # this FAIL - confirmed, then restored.

        # Same call, on a frame that WAS searched - the guard must not become
        # a blanket "never render".
        array unset ::VMDPathFinder::tunnel_results
        array set ::VMDPathFinder::tunnel_results [list $_cfr $_real_tuns 99999 $_real_tuns]
        set ::VMDPathFinder::tunnel_result_frames [list $_cfr 99999]
        report "(setup) the landed frame is searched again here" \
               [expr {![::VMDPathFinder::_tunnel_landed_is_unsearched]}] ""
        set ::_rtf_calls 0
        ::VMDPathFinder::_tunnel_global_gear_reset
        report "a gear reset still renders normally on a searched landed frame" \
               [expr {$::_rtf_calls == 1}] "(calls=$::_rtf_calls)"

        array unset ::VMDPathFinder::tunnel_results
        array set ::VMDPathFinder::tunnel_results $_sv_tr_t3
        set ::VMDPathFinder::tunnel_result_frames $_sv_trf_t3
        rename ::VMDPathFinder::render_tunnels_for_frame {}
        rename ::VMDPathFinder::render_tunnels_for_frame_orig_t3 ::VMDPathFinder::render_tunnels_for_frame

        # Cheap, real cost numbers on this fixture (small, so not the 394-row
        # figure quoted in the task - that was measured separately on the
        # real 50-frame import; this just proves neither path regresses to
        # something pathological here).
        set _t0 [clock milliseconds]
        ::VMDPathFinder::_tunnel_update_traffic_lights
        set _t1 [clock milliseconds]
        set _t2 [clock milliseconds]
        ::VMDPathFinder::refresh_tunnel_tab
        set _t3 [clock milliseconds]
        say "  (perf) traffic-light-only [expr {$_t1-$_t0}] ms, full rebuild [expr {$_t3-$_t2}] ms, [llength $_allrows] cluster(s)"

        array unset ::VMDPathFinder::tunnel_results
        array set ::VMDPathFinder::tunnel_results $_sv_tr4
        set ::VMDPathFinder::tunnel_result_frames $_sv_trf4
        set ::VMDPathFinder::state(tunnel_selected_cid) $_sv_sel4
        set ::VMDPathFinder::state(tunnel_seen_floor) $_sv_floor4
        set ::VMDPathFinder::state(tunnel_list_show_all) $_sv_showall4
        set ::VMDPathFinder::state(tunnel_sort_col) $_sv_sortcol4
        set ::VMDPathFinder::state(tunnel_sort_dir) $_sv_sortdir4
        ::VMDPathFinder::_tunnel_xframe_build
        ::VMDPathFinder::refresh_tunnel_tab
    }

    # E2b2: the "calculating" cue must be ON THE CANVAS while the data pass
    # runs, and must survive the <=1px reschedule that returns without drawing.
    # Six reports of "I don't see it" all came from deleting it the instant the
    # radii came back - before the reschedule, before the property-fill pass.
    if {[winfo exists $w.plotframe.nb.mean.cv]} {
        set ::_mcv $w.plotframe.nb.mean.cv
        set ::_CUE_DURING -1
        # This block runs in TUNNEL mode, so the body calls the tunnel collector -
        # stub both, or the probe never fires and reports -1.
        rename ::VMDPathFinder::collect_binned_radii ::_real_cbr
        rename ::VMDPathFinder::_tunnel_collect_binned_radii ::_real_tcbr
        # The cue rides on whichever of canvas/placeholder is already mapped -
        # it must not re-grid either (that <Configure> storm is what left the
        # sibling tabs' placeholders naming the wrong engine).
        proc ::VMDPathFinder::_cue_visible {} {
            set ph .vmdpathfinder.plotframe.nb.mean.placeholder
            if {[llength [$::_mcv find withtag meancalc]]} { return 1 }
            if {[winfo exists $ph] && [string match "Calculating*" [$ph cget -text]]} { return 1 }
            return 0
        }
        proc ::VMDPathFinder::collect_binned_radii {args} {
            set ::_CUE_DURING [::VMDPathFinder::_cue_visible]
            return {}
        }
        proc ::VMDPathFinder::_tunnel_collect_binned_radii {args} {
            set ::_CUE_DURING [::VMDPathFinder::_cue_visible]
            return {}
        }
        catch {::VMDPathFinder::_draw_mean_profile_body}
        rename ::VMDPathFinder::collect_binned_radii {}
        rename ::VMDPathFinder::_tunnel_collect_binned_radii {}
        rename ::_real_cbr ::VMDPathFinder::collect_binned_radii
        rename ::_real_tcbr ::VMDPathFinder::_tunnel_collect_binned_radii
        report "the mean-profile cue is drawn BEFORE the radii pass" \
               [expr {$::_CUE_DURING == 1}] "(cue visible = $::_CUE_DURING)"
        # The reschedule path cannot be driven here (this canvas is real and
        # wide), so assert its ORDER instead: the delete has to come after the
        # 100 ms re-arm, or that round-trip leaves the tab blank again.
        set _b [info body ::VMDPathFinder::_draw_mean_profile_body]
        set _ir [string first "after 100 {::VMDPathFinder::draw_mean_profile}" $_b]
        set _id [string first "delete meancalc" [string range $_b $_ir end]]
        report "the cue outlives the 1px reschedule (delete comes after it)" \
               [expr {$_ir > 0 && $_id > 0}] "(rearm=$_ir delete-after=$_id)"
        catch {$::_mcv delete meancalc}
    }

    # E2c: Mean Profile's 3D IsoSurface, re-enabled for Tunnel mode
    # (build_and_show_tunnel_mean_surface averages real 3D centrelines,
    # unlike HOLE's revolved-curve version - see its own comment).
    if {$ntun > 0} {
        set meb $w.plotframe.nb.mean.exportbar
        report "the Mean Profile IsoSurface checkbox is enabled in Tunnel mode" \
               [expr {[winfo exists $meb.show3d] && [$meb.show3d cget -state] eq "normal"}] \
               "(state=[expr {[winfo exists $meb.show3d] ? [$meb.show3d cget -state] : {missing}}])"
        # Sabotage-checked by hand: reverting _sync_profile_exportbar_for_mode's
        # "-state normal" back to the old disabled-in-tunnel ternary turns this
        # FAIL, as it must.

        # Orientation fix, proven through the REAL _tunnel_mean_centerline (not
        # a hand-reimplementation of its math, which would not catch a
        # regression IN that function): member B = member A's own physical
        # points with the point ORDER reversed - as if MOLE's engine had
        # emitted this exact route start<->end swapped. Injected as a real
        # 2-frame synthetic pool (same technique the cross-frame block earlier
        # in this file uses), so _tunnel_xframe_build's own clustering (order-
        # invariant - confirmed live, real reversed-order members merge into
        # one cluster on the 50-frame pentamer fixture, see NOTES) and
        # _tunnel_mean_centerline's own flip both run for real.
        set _cfr5 [::VMDPathFinder::_tunnel_display_frame]
        set _tupA [::VMDPathFinder::_tunnel_tuple_for $_cfr5 1]
        set _ptsA [lindex $_tupA 4]
        set _nA [expr {[llength $_ptsA]/4}]
        set _sv_trf5 $::VMDPathFinder::tunnel_result_frames
        set _sv_tr5 [array get ::VMDPathFinder::tunnel_results]
        set _sv_sel5 [expr {[info exists ::VMDPathFinder::state(tunnel_selected_cid)] ? $::VMDPathFinder::state(tunnel_selected_cid) : ""}]
        set _sv_show5 [expr {[info exists ::VMDPathFinder::state(show_mean_surface)] ? $::VMDPathFinder::state(show_mean_surface) : 0}]
        set _cid5 ""
        if {$_nA >= 4} {
            set _ptsB {}
            for {set _i [expr {$_nA-1}]} {$_i >= 0} {incr _i -1} {
                set _b [expr {$_i*4}]
                lappend _ptsB [lindex $_ptsA $_b] [lindex $_ptsA [expr {$_b+1}]] \
                    [lindex $_ptsA [expr {$_b+2}]] [lindex $_ptsA [expr {$_b+3}]]
            }
            set _tupB [lreplace $_tupA 4 4 $_ptsB]
            set ::VMDPathFinder::tunnel_results(80001) [list $_tupA]
            set ::VMDPathFinder::tunnel_results(80002) [list $_tupB]
            set ::VMDPathFinder::tunnel_result_frames {80001 80002}
            ::VMDPathFinder::_tunnel_xframe_build
            set _cid5 [expr {[info exists ::VMDPathFinder::tunnel_xcid(80001,1)] ? $::VMDPathFinder::tunnel_xcid(80001,1) : ""}]
            report "a start<->end-reversed member clusters with the original (real engine)" \
                   [expr {$_cid5 ne "" && [info exists ::VMDPathFinder::tunnel_xcid(80002,1)] \
                       && $::VMDPathFinder::tunnel_xcid(80002,1) == $_cid5}] "(cid=$_cid5)"
            if {$_cid5 ne ""} {
                set _avg5 [::VMDPathFinder::_tunnel_mean_centerline $_cid5]
                set _serA [::VMDPathFinder::_tunnel_mean_member_series $_tupA]
                set _serB [::VMDPathFinder::_tunnel_mean_member_series $_tupB]
                lassign $_serA _sA _xA _yA _zA _rA
                lassign $_serB _sB _xB _yB _zB _rB
                set _mA {}
                for {set _i 0} {$_i < [llength $_xA]} {incr _i} {
                    lappend _mA [list [lindex $_sA $_i] [lindex $_xA $_i] [lindex $_yA $_i] \
                        [lindex $_zA $_i] [lindex $_rA $_i]]
                }
                set _mA [lsort -real -index 0 $_mA]
                # B's OWN flip-corrected range: walking B from its other end
                # (reverse=1) is EXACTLY what _tunnel_mean_centerline itself
                # does (dot<0 branch) before computing smins/smaxs, so this
                # reproduces its own lo/hi precisely instead of approximating it.
                set _sBflip5 [lindex [::VMDPathFinder::_tunnel_mean_member_series $_tupB 1] 0]
                set _sAmin [lindex $_sA 0]; set _sAmax [lindex $_sA end]
                if {$_sAmin > $_sAmax} { lassign [list $_sAmax $_sAmin] _sAmin _sAmax }
                set _sBmin [lindex $_sBflip5 0]; set _sBmax [lindex $_sBflip5 end]
                if {$_sBmin > $_sBmax} { lassign [list $_sBmax $_sBmin] _sBmin _sBmax }
                set _lo5 [lindex [lsort -real [list $_sAmin $_sBmin]] 0]
                set _hi5 [lindex [lsort -real [list $_sAmax $_sBmax]] end]
                if {$_avg5 ne "" && $_hi5 > $_lo5} {
                    lassign $_avg5 _pts5 _nmem5
                    set _npts5 [expr {[llength $_pts5]/4}]
                    set _maxdev 0.0; set _cnt5 0
                    for {set _i 0} {$_i < $_npts5} {incr _i} {
                        set _b [expr {$_i*4}]
                        set _ax [lindex $_pts5 $_b]; set _ay [lindex $_pts5 [expr {$_b+1}]]
                        set _az [lindex $_pts5 [expr {$_b+2}]]
                        # Only compare where A's own path actually has a value
                        # - a sample outside A's own [smin,smax] is
                        # legitimately B-only and not part of this check.
                        set _s5 [expr {$_lo5 + ($_hi5-$_lo5)*$_i/double($_npts5-1)}]
                        if {$_s5 < $_sAmin || $_s5 > $_sAmax} { continue }
                        set _truth [::VMDPathFinder::_tunnel_mean_interp $_mA $_s5]
                        if {$_truth eq ""} continue
                        lassign $_truth _tx _ty _tz
                        set _d [expr {sqrt(($_ax-$_tx)*($_ax-$_tx)+($_ay-$_ty)*($_ay-$_ty)+($_az-$_tz)*($_az-$_tz))}]
                        if {$_d > $_maxdev} { set _maxdev $_d }
                        incr _cnt5
                    }
                    # 0.5 A, not the ~0 A a byte-exact recomputation gives
                    # (verified separately, off this fixture): the SUT
                    # resamples on its OWN 100-point s-grid, not at A's
                    # native point spacing, so linear interpolation between
                    # two different samplings of a curving path leaves a real
                    # but small discretization gap (measured 0.10 A here) -
                    # unrelated to the flip itself. 0.5 A stays two orders of
                    # magnitude below the several-A divergence an unflipped
                    # average produces (confirmed by the sabotage check).
                    report "_tunnel_mean_centerline recovers a reversed member's own path (<0.5 A)" \
                           [expr {$_cnt5 > 0 && $_maxdev < 0.5}] "(max_dev=[format %.4f $_maxdev] over $_cnt5 samples)"
                    # Sabotage-checked by hand: disabling the "if {$dot < 0}"
                    # flip in _tunnel_mean_centerline turns this FAIL (the
                    # unflipped average folds the route onto itself instead of
                    # tracking A's own path - max_dev jumps from ~0.1 A to
                    # several A on this same fixture's own tunnel 1).
                } else {
                    report "_tunnel_mean_centerline recovers a reversed member's own path (<0.5 A)" 0 "(centerline was empty)"
                }
            }
        }

        # End-to-end build/toggle/mode-switch lifecycle, same synthetic pool.
        set ::VMDPathFinder::state(tunnel_selected_cid) $_cid5
        set ::VMDPathFinder::state(show_mean_surface) 1
        set _e2e_err ""
        if {$_cid5 eq "" || [catch {::VMDPathFinder::_tunnel_on_show_mean_surface_toggled} _e2e_err]} {
            report "tunnel mean surface builds end-to-end on a real 2-member cluster" 0 "(error: $_e2e_err)"
        } else {
            report "tunnel mean surface builds end-to-end on a real 2-member cluster" \
                   [expr {$::VMDPathFinder::tunnel_mean_surface_mol >= 0 \
                       && ![catch {molinfo $::VMDPathFinder::tunnel_mean_surface_mol get name}]}] \
                   "(mol=$::VMDPathFinder::tunnel_mean_surface_mol)"
            report "its mol name states MEAN, not a measured route" \
                   [expr {[string match "*MEAN*" [molinfo $::VMDPathFinder::tunnel_mean_surface_mol get name]]}] \
                   "(name=[molinfo $::VMDPathFinder::tunnel_mean_surface_mol get name])"
            # Unchecking must delete it, matching HOLE's own on_show_mean_
            # surface_toggled semantics - re-checking should rebuild, not
            # silently reuse a stale hidden mol.
            set _mm [set ::VMDPathFinder::tunnel_mean_surface_mol]
            set ::VMDPathFinder::state(show_mean_surface) 0
            ::VMDPathFinder::_tunnel_on_show_mean_surface_toggled
            report "unchecking deletes the tunnel mean surface mol" \
                   [expr {$::VMDPathFinder::tunnel_mean_surface_mol < 0 && [catch {molinfo $_mm get name}]}] \
                   "(mol=$::VMDPathFinder::tunnel_mean_surface_mol)"

            # Mode-switch hide/restore (the bug this session found and fixed:
            # _update_surface_vis_buttons was reading HOLE's OWN mean_surface_
            # mol regardless of mode, so show_mean_surface silently reset to 0
            # moments after being checked - sabotage-checked by hand:
            # reverting _update_surface_vis_buttons' mean-mol selection to the
            # unconditional $mean_surface_mol turns the FIRST report below
            # FAIL, since the checkbox self-unchecks before the toggle even
            # returns).
            set ::VMDPathFinder::state(show_mean_surface) 1
            ::VMDPathFinder::_tunnel_on_show_mean_surface_toggled
            catch {::VMDPathFinder::_update_surface_vis_buttons}
            report "the checkbox survives its own post-build vis-button reconcile" \
                   [expr {[info exists ::VMDPathFinder::state(show_mean_surface)] && $::VMDPathFinder::state(show_mean_surface)}] \
                   "(show_mean_surface=[expr {[info exists ::VMDPathFinder::state(show_mean_surface)] ? $::VMDPathFinder::state(show_mean_surface) : {unset}}])"
            set _mm2 [set ::VMDPathFinder::tunnel_mean_surface_mol]
            $w.sidebar.nb select $w.sidebar.nb.hole
            update idletasks
            ::VMDPathFinder::_sync_solo_surface_for_mode
            report "switching to HOLE mode hides the tunnel mean surface (not deletes it)" \
                   [expr {$_mm2 >= 0 && ![catch {molinfo $_mm2 get name}] && ![molinfo $_mm2 get displayed]}] \
                   "(mol=$_mm2 displayed=[expr {[catch {molinfo $_mm2 get displayed} _d5] ? {gone} : $_d5}])"
            $w.sidebar.nb select $w.sidebar.nb.tunnel
            update idletasks
            ::VMDPathFinder::_sync_solo_surface_for_mode
            report "switching back to Tunnel mode restores it" \
                   [expr {$_mm2 >= 0 && ![catch {molinfo $_mm2 get displayed} _d6] && $_d6}] \
                   "(displayed=[expr {[catch {molinfo $_mm2 get displayed} _d6] ? {gone} : $_d6}])"
            catch {mol delete $_mm2}
            set ::VMDPathFinder::tunnel_mean_surface_mol -1
        }
        array unset ::VMDPathFinder::tunnel_results 80001
        array unset ::VMDPathFinder::tunnel_results 80002
        set ::VMDPathFinder::tunnel_result_frames $_sv_trf5
        array set ::VMDPathFinder::tunnel_results $_sv_tr5
        set ::VMDPathFinder::state(tunnel_selected_cid) $_sv_sel5
        set ::VMDPathFinder::state(show_mean_surface) $_sv_show5
        ::VMDPathFinder::_tunnel_xframe_build
        ::VMDPathFinder::refresh_tunnel_tab
    }

    # E3: Over Time/Mean Profile/Histogram are now reused in tunnel mode too,
    # binned on distance from the SELECTED tunnel's start point along its own
    # centreline (the CAVER/MOLE/CHAP convention) rather than a shared channel
    # coordinate. This fixture is single-frame ("now"), so it cannot exercise
    # the >=2-frame rendered path, but it can check the tab set, the
    # start-anchored distance on real data, and that mode-aware placeholder text
    # doesn't leak between modes (a real bug found and fixed this session:
    # the HOLE-side empty branches never updated -text because it used to be
    # static, so a tunnel-mode placeholder stayed showing after switching
    # back to HOLE with no HOLE run).
    set _mts [::VMDPathFinder::_mode_tab_set tunnel]
    report "_mode_tab_set(tunnel) reuses Over Time/Mean Profile/Histogram" \
           [expr {"heatmap" in $_mts && "mean" in $_mts && "hist" in $_mts}] \
           "($_mts)"
    if {$ntun > 0} {
        set _tuple [::VMDPathFinder::_tunnel_tuple_for [lindex $frames 0] 1]
        lassign [::VMDPathFinder::_tunnel_signed_profile $_tuple] _sd _radii
        set _mono 1
        for {set _i 1} {$_i < [llength $_sd]} {incr _i} {
            if {[lindex $_sd $_i] < [lindex $_sd [expr {$_i-1}]]} { set _mono 0 }
        }
        report "_tunnel_signed_profile starts at 0 at the route's start and never runs backwards" \
               [expr {abs([lindex $_sd 0]) < 1e-9 && $_mono && [lindex $_sd end] > 0}] \
               "(first [lindex $_sd 0] last [lindex $_sd end])"
    }
    ::VMDPathFinder::draw_histogram_tab
    # <<NotebookTabChanged>> is queued (event generate's default -when tail),
    # not synchronous, so any pending sidebar mode-switch from earlier in this
    # file can still land on an unrelated `update` below - and on_mode_tab_changed
    # -> refresh_results_list recomputes _method_mismatch_summary from (empty)
    # result_frames unconditionally, wiping a poisoned value out from under this
    # check before it's ever read. Flush the queue with the tab select FIRST,
    # then poison, then call draw_mean_profile directly (no update in between -
    # canvas item creation is synchronous, it needs no event-loop turn to land).
    $w.plotframe.nb select $w.plotframe.nb.mean
    update idletasks; update
    # (draw_mean_profile's own realize-guard - the fix for the 1px-fallback
    # overflow - is not independently checkable here: by this point in the
    # fixture the canvas is already realized via the tab-select above, the
    # same as every other analysis canvas in this file. Verified instead by
    # exact pattern match with draw_histogram_tab's already-relied-upon copy
    # of this guard, and by a real-data screenshot showing no overflow.)
    #
    # Poisoned as if a HOLE run earlier in this session had mixed pore methods -
    # the exact stale-note scenario draw_mean_profile's tunnel-mode guard must
    # suppress (the badge/note are about HOLE's own result_frames, meaningless
    # for a tunnel's own branching centerline).
    set _sv_mms $::VMDPathFinder::_method_mismatch_summary
    set ::VMDPathFinder::_method_mismatch_summary "HOLE (5), CONNOLLY (2)"
    ::VMDPathFinder::draw_mean_profile
    set _n_mm_t [llength [$w.plotframe.nb.mean.cv find withtag mismatch_note]]
    set _n_as_t [llength [$w.plotframe.nb.mean.cv find withtag axis_straightness_note]]
    report "tunnel-mode Mean Profile does not paint HOLE's mismatch/straightness notes" \
           [expr {$_n_mm_t == 0 && $_n_as_t == 0}] \
           "(mismatch=$_n_mm_t straightness=$_n_as_t)"
    set ::VMDPathFinder::_method_mismatch_summary $_sv_mms

    # The Fill checkbox in tunnel mode: _tunnel_collect_binned_property must
    # actually resolve real MOLE property values, not silently degrade to the
    # monochrome fallback while the checkbox is otherwise wired (do_fill true,
    # nothing graded drawn). Checked directly against the data source - a pure
    # function of tunnel_result_frames/tunnel_selected_id, immune to the Tk
    # event-queue race the mismatch-note check above needed a rewrite to avoid.
    set _sv_tprop [expr {[info exists ::VMDPathFinder::state(tunnel_prop)] ? $::VMDPathFinder::state(tunnel_prop) : ""}]
    set ::VMDPathFinder::state(tunnel_prop) hydropathy
    set _pvals [::VMDPathFinder::_tunnel_collect_binned_property 80]
    set _pnonempty 0
    foreach _pv $_pvals { if {$_pv ne ""} { incr _pnonempty } }
    report "tunnel Mean Profile Fill resolves real property values, not the monochrome fallback" \
           [expr {[llength $_pvals] == 80 && $_pnonempty > 0}] \
           "(len=[llength $_pvals] nonempty=$_pnonempty)"
    set ::VMDPathFinder::state(tunnel_prop) $_sv_tprop

    ::VMDPathFinder::draw_heatmap
    update idletasks; update
    set _hist_ph [$w.plotframe.nb.hist.placeholder cget -text]
    set _mean_ph [$w.plotframe.nb.mean.placeholder cget -text]
    set _hm_ph   [$w.plotframe.nb.heatmap.placeholder cget -text]
    report "tunnel-mode placeholders name the tunnel search, not HOLE" \
           [expr {[string match "*tunnel search*" $_hist_ph] && \
                   [string match "*tunnel search*" $_mean_ph] && \
                   [string match "*tunnel search*" $_hm_ph]}] \
           "(hist: $_hist_ph | mean: $_mean_ph | heatmap: $_hm_ph)"
    $w.sidebar.nb select $w.sidebar.nb.hole
    update idletasks; update
    ::VMDPathFinder::draw_histogram_tab
    ::VMDPathFinder::draw_mean_profile
    ::VMDPathFinder::draw_heatmap
    update idletasks; update
    set _hist_ph2 [$w.plotframe.nb.hist.placeholder cget -text]
    set _mean_ph2 [$w.plotframe.nb.mean.placeholder cget -text]
    set _hm_ph2   [$w.plotframe.nb.heatmap.placeholder cget -text]
    report "switching back to HOLE mode restores HOLE-worded placeholders" \
           [expr {[string match "*Run HOLE*" $_hist_ph2] && \
                   [string match "*Run HOLE*" $_mean_ph2] && \
                   [string match "*Run HOLE*" $_hm_ph2]}] \
           "(hist: $_hist_ph2 | mean: $_mean_ph2 | heatmap: $_hm_ph2)"

    # Batch  section B: a mode round trip is a REDISPLAY, not a data
    # change, so it must not invalidate the analysis caches. The headless suite
    # asserts the refresh/redisplay split directly but cannot reach this path at
    # all (analysis_mode is pinned to "hole" with no Tk), so the round trip
    # itself is only checkable here. C2 rides along: only the tunnel branch used
    # to rebuild the bottom frame list, so coming back left it holding tunnel
    # rows - or nothing.
    set _sv_rf $::VMDPathFinder::result_frames
    set _sv_rs $::VMDPathFinder::results
    set ::VMDPathFinder::result_frames {0 1}
    set ::VMDPathFinder::results [dict create \
        0 [dict create run_id 1 profile [dict create valid 1 min_radius 1.25 points {}]] \
        1 [dict create run_id 1 profile [dict create valid 1 min_radius 1.40 points {}]]]
    ::VMDPathFinder::refresh_results_list
    set ::VMDPathFinder::_hm_computed_scheme "kd"
    dict set ::VMDPathFinder::hm_prop_cache probe 1
    set _sv_pdv $::VMDPathFinder::plot_data_version
    $w.sidebar.nb select $w.sidebar.nb.tunnel
    update idletasks; update
    $w.sidebar.nb select $w.sidebar.nb.hole
    update idletasks; update
    report "a HOLE->Tunnel->HOLE round trip keeps the data version" \
           [expr {$::VMDPathFinder::plot_data_version == $_sv_pdv}] \
           "(before=$_sv_pdv after=$::VMDPathFinder::plot_data_version)"
    report "...and keeps the Over Time compute gate (no 'click Compute' again)" \
           [expr {$::VMDPathFinder::_hm_computed_scheme eq "kd"}] \
           "(gate='$::VMDPathFinder::_hm_computed_scheme')"
    report "...and keeps the property-heatmap cache" \
           [expr {[dict size $::VMDPathFinder::hm_prop_cache] == 1}] \
           "(entries=[dict size $::VMDPathFinder::hm_prop_cache])"
    set _lb $w.bottom.detail.list
    report "...and pore mode still lists its own frames afterwards" \
           [expr {[$_lb index end] == 2}] \
           "(rows=[$_lb index end], expected 2)"
    report "...under the pore header, not the tunnel one" \
           [expr {![string match "*Bneck*" [$w.bottom.detail.header cget -text]]}] \
           "(header='[$w.bottom.detail.header cget -text]')"
    set ::VMDPathFinder::result_frames $_sv_rf
    set ::VMDPathFinder::results $_sv_rs
    ::VMDPathFinder::refresh_results_list

    # Task 160: switching the sidebar tab now hides the OTHER mode's surface
    # (not just leaves it up), and switching back restores it - a stand-in
    # pore-surface mol stands in for a real HOLE run (this harness never runs
    # one), which is enough to exercise _sync_solo_surface_for_mode's own
    # mol-visibility bookkeeping without needing real HOLE surface geometry.
    set _sv_csm $::VMDPathFinder::current_surface_mol
    set _sv_hws $::VMDPathFinder::_hole_surface_was_shown
    set _sv_tws $::VMDPathFinder::_tunnel_surface_was_shown
    set _fakepore [mol new]
    # `mol new` makes this 0-frame mol VMD's TOP molecule - restore the real
    # trajectory as top immediately (ensure_tunnel_surface_mol's own fix for
    # the identical trap: resolve_molid/playback both key off "top").
    catch {mol top $mid}
    set ::VMDPathFinder::current_surface_mol $_fakepore
    mol on $_fakepore
    set ::VMDPathFinder::_hole_surface_was_shown ""
    set ::VMDPathFinder::_tunnel_surface_was_shown 0
    $w.sidebar.nb select $w.sidebar.nb.tunnel
    update idletasks; update
    report "switching to Tunnel hides the HOLE-side surface" \
           [expr {![molinfo $_fakepore get displayed]}] \
           "(displayed=[molinfo $_fakepore get displayed])"
    report "...and remembers which one, to restore it later" \
           [expr {$::VMDPathFinder::_hole_surface_was_shown eq "pore"}] \
           "(remembered=$::VMDPathFinder::_hole_surface_was_shown)"
    $w.sidebar.nb select $w.sidebar.nb.hole
    update idletasks; update
    report "switching back to HOLE restores the surface that was showing" \
           [expr {[molinfo $_fakepore get displayed]}] \
           "(displayed=[molinfo $_fakepore get displayed])"
    catch {mol delete $_fakepore}
    set ::VMDPathFinder::current_surface_mol $_sv_csm
    set ::VMDPathFinder::_hole_surface_was_shown $_sv_hws
    set ::VMDPathFinder::_tunnel_surface_was_shown $_sv_tws

    # The pore-FACING rep (a sibling of the pore-LINING rep, both reachable
    # via the single "Show nearby: None/Lining/Facing" dropdown) was never
    # hidden on a Pore->Tunnel switch: _sync_solo_surface_for_mode's hide/
    # restore only ever called _show_pore_lining_rep, never a matching
    # _show_pore_facing_rep for the separate pore_facing_viz_rep_idx dict -
    # reported as "switching to tunnel mode does not disable the lining
    # visualization" (true whenever "Facing", not "Lining", was selected).
    # Same stand-in-rep pattern as the pore-surface check just above - no
    # real HOLE run needed, this is purely about rep visibility bookkeeping.
    mol representation Lines
    mol selection "protein"
    mol addrep $mid
    set _fake_facing_idx [expr {[molinfo $mid get numreps] - 1}]
    dict set ::VMDPathFinder::pore_facing_viz_rep_idx $mid $_fake_facing_idx
    set _sv_spf $::VMDPathFinder::state(show_pore_facing)
    set ::VMDPathFinder::state(show_pore_facing) 1
    mol showrep $mid $_fake_facing_idx 1
    $w.sidebar.nb select $w.sidebar.nb.tunnel
    update idletasks; update
    report "switching to Tunnel mode hides the pore-FACING rep too, not just lining" \
           [expr {[mol showrep $mid $_fake_facing_idx] == 0}] \
           "(showrep=[mol showrep $mid $_fake_facing_idx])"

    # A memory with no results of its own must not keep the previous one's
    # lining lit up: it stayed on screen until something else redrew it.
    $w.sidebar.nb select $w.sidebar.nb.hole
    update idletasks
    mol representation Lines
    mol selection "protein"
    mol addrep $mid
    set _fake_lin_idx [expr {[molinfo $mid get numreps] - 1}]
    dict set ::VMDPathFinder::pore_facing_rep_idx $mid $_fake_lin_idx
    mol showrep $mid $_fake_lin_idx 1
    set _sv_spl $::VMDPathFinder::state(show_pore_lining)
    set _sv_srf $::VMDPathFinder::state(selected_result_frame)
    set ::VMDPathFinder::state(show_pore_lining) 1
    set ::VMDPathFinder::state(selected_result_frame) ""
    catch {::VMDPathFinder::update_pore_lining_rep}
    report "a memory with no results of its own hides the lining" \
           [expr {[mol showrep $mid $_fake_lin_idx] == 0}] \
           "(showrep=[mol showrep $mid $_fake_lin_idx])"
    set ::VMDPathFinder::state(show_pore_lining) $_sv_spl
    set ::VMDPathFinder::state(selected_result_frame) $_sv_srf
    report "a memory switch refreshes the lining" \
        [expr {[string first {update_pore_lining_rep} \
            [info body ::VMDPathFinder::_mem_slot_clicked]] >= 0}] ""
    $w.sidebar.nb select $w.sidebar.nb.hole
    update idletasks; update
    report "switching back to HOLE mode restores the pore-FACING rep (checkbox still on)" \
           [expr {[mol showrep $mid $_fake_facing_idx] == 1}] \
           "(showrep=[mol showrep $mid $_fake_facing_idx])"
    # Sabotage-checked by hand: removing the two `_show_pore_facing_rep` call
    # sites from _sync_solo_surface_for_mode turns the FIRST report above FAIL
    # (showrep stays 1 in Tunnel mode) - confirmed, then restored.
    catch {mol delrep $_fake_facing_idx $mid}
    catch {dict unset ::VMDPathFinder::pore_facing_viz_rep_idx $mid}
    set ::VMDPathFinder::state(show_pore_facing) $_sv_spf

    # Permeation is HOLE-only: bulk-to-bulk crossings along the pore axis, which
    # a tunnel has no equivalent of. ion_flow_cache is stashed per mode
    # (_mode_analysis_swap), so re-seed it after each switch.
    set _sv_perm_ifc $::VMDPathFinder::ion_flow_cache
    set _pm_bar $w.plotframe.nb.ionflow.exportbar
    set _pm_fake [dict create nr 4 nz 4 zmin -5.0 zmax 5.0 r_cut 4.0 species "All" nions 1]
    $w.sidebar.nb select $w.sidebar.nb.hole
    update idletasks; update
    set ::VMDPathFinder::ion_flow_cache $_pm_fake
    ::VMDPathFinder::_ion_flow_sync_bar_vis
    update idletasks
    report "(setup) Permeation is on the Ion Flow bar in pore mode" \
           [expr {[winfo manager $_pm_bar.perm] ne ""}] \
           "(manager='[winfo manager $_pm_bar.perm]')"
    # An already-open dialog must go too, not merely stop being reachable.
    ::VMDPathFinder::show_permeation_dialog
    update idletasks
    set _pm_opened [winfo exists $w.permeation]
    $w.sidebar.nb select $w.sidebar.nb.tunnel
    update idletasks; update
    set ::VMDPathFinder::ion_flow_cache $_pm_fake
    ::VMDPathFinder::_ion_flow_sync_bar_vis
    update idletasks
    report "Permeation is NOT offered in tunnel mode" \
           [expr {[winfo manager $_pm_bar.perm] eq ""}] \
           "(manager='[winfo manager $_pm_bar.perm]')"
    report "...and a Permeation dialog left open is closed by the switch" \
           [expr {$_pm_opened && ![winfo exists $w.permeation]}] \
           "(opened-in-pore-mode=$_pm_opened still-open=[winfo exists $w.permeation])"
    ::VMDPathFinder::show_permeation_dialog
    update idletasks
    report "...and calling show_permeation_dialog directly in tunnel mode is refused" \
           [expr {![winfo exists $w.permeation]}] \
           "(exists=[winfo exists $w.permeation] status='$::VMDPathFinder::state(status)')"
    catch {destroy $w.permeation}
    # Drop the per-mode stash too, not just the live variable - the fake cache
    # is otherwise restored under whichever mode it was set in.
    catch {dict unset ::VMDPathFinder::_mode_stash hole}
    catch {dict unset ::VMDPathFinder::_mode_stash tunnel}
    set ::VMDPathFinder::ion_flow_cache $_sv_perm_ifc
    ::VMDPathFinder::_ion_flow_sync_bar_vis

    $w.sidebar.nb select $w.sidebar.nb.tunnel
    update idletasks; update

    if {$ntun > 0} {
        set fr [lindex $frames 0]
        # Task 172: the old always-visible property combobox was replaced by
        # a global gear icon (last column of the tunlist header) opening a
        # popup with Representation + Material + Color. Task 176 then added
        # per-tunnel property (reversing the "no per-tunnel option" decision
        # documented here originally), and this round unified Color to mirror
        # HOLE's own state(surface_color): flat colors and "Property" as
        # sibling options of ONE control, with a second Property row that
        # only appears once Color is Property (update_color_row_visibility's
        # pattern, mirrored here as _sync_tunnel_global_gear_prop_row).
        # Header widgets moved OUT of the scrolled inner frame into
        # $P.tunlist.hdr when the header was frozen, so they no longer scroll
        # away with the rows.
        report "tunlist header's global gear icon exists" \
               [winfo exists $P.tunlist.hdr.hgear] ""
        report "the tunnel list header is frozen (outside the scrolled canvas)" \
               [expr {[winfo exists $P.tunlist.hdr.h1] \
                   && ![winfo exists $P.tunlist.c.inner.h1]}] \
               "(hdr.h1=[winfo exists $P.tunlist.hdr.h1] inner.h1=[winfo exists $P.tunlist.c.inner.h1])"
        # _center_toplevel now centers on the main VMDPathFinder window, not the
        # mouse pointer (which put dialogs wherever the pointer last was,
        # and could push a title bar off-screen near an edge) - verify the
        # popup lands within the main window's own footprint, not just
        # somewhere on the whole screen.
        set _mx [winfo rootx $w]; set _my [winfo rooty $w]
        set _mw [winfo width  $w]; set _mh [winfo height $w]
        ::VMDPathFinder::show_tunnel_global_gear_settings
        update idletasks; update
        set GGD $w.tunnel_global_gear
        report "gear popup centers on the main window, not the pointer" \
               [expr {[winfo rootx $GGD] >= $_mx - 5 && [winfo rootx $GGD] <= $_mx + $_mw + 5 \
                   && [winfo rooty $GGD] >= $_my - 5 && [winfo rooty $GGD] <= $_my + $_mh + 5}] \
               "(popup=([winfo rootx $GGD],[winfo rooty $GGD]) main_window=($_mx,$_my,${_mw}x$_mh))"
        report "global gear popup opens with representation + material + color + property controls" \
               [expr {[winfo exists $GGD.rep] && [winfo exists $GGD.mat] \
                   && [winfo exists $GGD.sc] && [winfo exists $GGD.pm]}] \
               "(exists under $GGD)"

        # Every dialog must be WITHDRAWN the moment it is created, before its
        # widgets are built: otherwise any builder that pumps an idle pass lets
        # the WM map it at its default spot (usually the pointer), so it
        # appears there and then jumps when _center_toplevel positions it -
        # the reported "opens at the pointer then moves". The withdraw is only
        # safe if something always undoes it, so assert BOTH: created hidden,
        # and ultimately mapped.
        foreach {_dn _dcmd _dpath} {
            hole_params  ::VMDPathFinder::show_hole_params_settings  .vmdpathfinder.hole_params_settings
            settings     ::VMDPathFinder::show_settings_dialog       .vmdpathfinder.settings
            scale_cutoff ::VMDPathFinder::show_scale_cutoff_settings .vmdpathfinder.scale_settings
            about        ::VMDPathFinder::show_about_dialog          .vmdpathfinder.about
        } {
            catch {destroy $_dpath}
            update idletasks
            if {[catch {eval $_dcmd}]} { continue }
            update idletasks; update
            report "dialog '$_dn' ends up visible (withdraw is always undone)" \
                   [expr {[winfo exists $_dpath] && [winfo ismapped $_dpath]}] \
                   "(exists=[winfo exists $_dpath] mapped=[expr {[winfo exists $_dpath] ? [winfo ismapped $_dpath] : {n/a}}])"
            catch {destroy $_dpath}
            update idletasks
        }

        # The leucine override corrects a bug in CHAP's own table, so it only
        # means anything inside CHAP mode; outside it the corrected value is
        # always used and the checkbox must not be on screen at all.
        catch {destroy $w.hydrocfg}
        set _chap_was $::VMDPathFinder::state(chap_mode)
        set ::VMDPathFinder::state(chap_mode) 0
        ::VMDPathFinder::show_hydration_settings
        update idletasks; update
        set _HD $w.hydrocfg
        if {[winfo exists $_HD.leufix]} {
            report "leucine override hidden while CHAP mode is off" \
                   [expr {![winfo ismapped $_HD.leufix]}] \
                   "(mapped=[winfo ismapped $_HD.leufix])"
            set ::VMDPathFinder::state(chap_mode) 1
            ::VMDPathFinder::_sync_hydration_chap_lock
            update idletasks; update
            report "leucine override appears when CHAP mode is on" \
                   [winfo ismapped $_HD.leufix] \
                   "(mapped=[winfo ismapped $_HD.leufix])"
            set ::VMDPathFinder::state(chap_mode) 0
            ::VMDPathFinder::_sync_hydration_chap_lock
            update idletasks; update
            report "leucine override hides again when CHAP mode goes off" \
                   [expr {![winfo ismapped $_HD.leufix]}] \
                   "(mapped=[winfo ismapped $_HD.leufix])"
        } else {
            report "leucine override checkbox exists in the hydration dialog" 0 "(missing)"
        }
        set ::VMDPathFinder::state(chap_mode) $_chap_was
        catch {destroy $w.hydrocfg}
        update idletasks

        # A window the user has MOVED must reopen where they left it. Centring
        # every time discards a deliberate placement, which reads as the
        # dialog relocating itself. Uses scale_settings so it cannot disturb
        # the gear popup's own centring assertion above. Sabotage-checked:
        # dropping the _toplevel_pos restore makes this come back centred.
        catch {destroy $w.scale_settings}
        ::VMDPathFinder::show_scale_cutoff_settings
        update idletasks; update
        set _SD $w.scale_settings
        if {[winfo exists $_SD]} {
            wm geometry $_SD "+120+140"
            update idletasks; update
            destroy $_SD
            update idletasks
            ::VMDPathFinder::show_scale_cutoff_settings
            update idletasks; update
            set _g2 [wm geometry $w.scale_settings]
            report "a moved dialog reopens where the user left it, not re-centred" \
                   [expr {[regexp {\+120\+140$} $_g2]}] "(geometry=$_g2)"
            catch {destroy $w.scale_settings}
        }
        # Task 207: Property now sits on Color's OWN row, immediately to its
        # left (columns 0-1, Color in 2-3), shown only while Color is
        # Property - not a separate full-width banner row any more, so the
        # popup's HEIGHT stays constant when it toggles (Color's row exists
        # either way); only the row's left half gains/loses content.
        set _sv_ggcolor $::VMDPathFinder::state(tunnel_display_color)
        ::VMDPathFinder::_tunnel_global_gear_color_set auto
        update idletasks; update
        report "global gear's Property control is hidden while Color is not Property" \
               [expr {![winfo ismapped $GGD.pm]}] \
               "(ismapped=[winfo ismapped $GGD.pm])"
        set _h_noprop [lindex [wm minsize $GGD] 1]
        ::VMDPathFinder::_tunnel_global_gear_color_set property
        update idletasks; update
        report "global gear's Property control appears once Color is set to Property" \
               [expr {[winfo ismapped $GGD.pm]}] \
               "(ismapped=[winfo ismapped $GGD.pm])"
        set _h_prop [lindex [wm minsize $GGD] 1]
        # Property is a ROW of its own now, so the REQUESTED height genuinely
        # differs between the two states. What must not change is the window
        # the user sees, and that is guaranteed by the minsize the dialog pins
        # while every conditional control is still gridded - so that is what is
        # asserted, rather than a requested size that was only equal because
        # Property used to share Color's row.
        report "global gear popup cannot shrink when Property toggles" \
               [expr {$_h_prop == $_h_noprop && $_h_prop > 0}] \
               "(pinned height without property=$_h_noprop with property=$_h_prop)"
        # Task 207 + D3: the two data-driven modes lead, not the 30-odd fixed
        # colors - Auto rank color first, then Property. The Color control is a
        # scrolling combobox now, not a menu, so this reads its -values list
        # rather than menu entry labels.
        report "Rank is the FIRST entry in the global Color menu" \
               [expr {[$GGD.sc.m entrycget 0 -label] eq "Rank"}] \
               "(first='[$GGD.sc.m entrycget 0 -label]')"
        report "Property is the SECOND entry in the global Color menu" \
               [expr {[$GGD.sc.m entrycget 1 -label] eq "Property"}] \
               "(second='[$GGD.sc.m entrycget 1 -label]')"
        report "global Color menu fits on screen (columns, not one tall strip)" \
               [expr {[winfo reqheight $GGD.sc.m] < 300}] \
               "(menu reqheight=[winfo reqheight $GGD.sc.m]px)"
        # Task 208: Default sits directly in front of (same row, left of)
        # Close - not its own row above it.
        report "global gear's Default button exists and sits before Close on the same row" \
               [expr {[winfo exists $GGD.footer.reset] && [winfo exists $GGD.footer.close] \
                   && [winfo rootx $GGD.footer.reset] < [winfo rootx $GGD.footer.close] \
                   && [winfo rooty $GGD.footer.reset] == [winfo rooty $GGD.footer.close]}] \
               "(reset=([winfo rootx $GGD.footer.reset],[winfo rooty $GGD.footer.reset])\
 close=([winfo rootx $GGD.footer.close],[winfo rooty $GGD.footer.close]))"
        set ::VMDPathFinder::state(tunnel_display_color) $_sv_ggcolor
        destroy $GGD
        set _sv_ggprop $::VMDPathFinder::state(tunnel_prop)
        ::VMDPathFinder::_tunnel_global_gear_set prop hydropathy
        report "global gear's property picker sets state(tunnel_prop) for real" \
               [expr {$::VMDPathFinder::state(tunnel_prop) eq "hydropathy"}] \
               "(tunnel_prop=$::VMDPathFinder::state(tunnel_prop))"
        ::VMDPathFinder::_tunnel_global_gear_set prop $_sv_ggprop

        # Task 174: an un-overridden tunnel's material used to silently fall
        # back to state(surface_material) - HOLE mode's OWN material picker,
        # unrelated to tunnel mode - the same coupling bug already fixed for
        # wireframe (state(tunnel_display_mode)) in task 172 but missed for
        # material. Set HOLE's material to something a tunnel would never be
        # expected to inherit and confirm it doesn't leak through.
        if {$ntun > 0} {
            set _sv_holemat $::VMDPathFinder::state(surface_material)
            set _sv_tunmat $::VMDPathFinder::state(tunnel_display_material)
            set ::VMDPathFinder::state(surface_material) Steel
            ::VMDPathFinder::_tunnel_global_gear_set material Ghost
            report "global gear's material picker sets state(tunnel_display_material) for real" \
                   [expr {$::VMDPathFinder::state(tunnel_display_material) eq "Ghost"}] \
                   "(tunnel_display_material=$::VMDPathFinder::state(tunnel_display_material))"
            report "unoverridden tunnel material stays decoupled from HOLE's surface_material" \
                   [expr {$::VMDPathFinder::state(surface_material) eq "Steel" \
                       && $::VMDPathFinder::state(tunnel_display_material) ne $::VMDPathFinder::state(surface_material)}] \
                   "(surface_material=$::VMDPathFinder::state(surface_material) tunnel_display_material=$::VMDPathFinder::state(tunnel_display_material))"
            set _rc [catch {::VMDPathFinder::render_tunnels_for_frame [lindex $frames 0]} _rcerr]
            report "rendering with the global material override does not error" \
                   [expr {!$_rc}] "(rc=$_rc err=$_rcerr)"
            set ::VMDPathFinder::state(surface_material) $_sv_holemat
            ::VMDPathFinder::_tunnel_global_gear_set material $_sv_tunmat
        }

        # 3D scale bar: same single global bar HOLE mode/Mean Profile share,
        # driven by the SELECTED tunnel's effective colormode+property (task
        # 176's unified Color control - colormode must be "property", not
        # just a real property token, or nothing is actually property-colored).
        set _sv_tprop $::VMDPathFinder::state(tunnel_prop)
        set _sv_tcolor $::VMDPathFinder::state(tunnel_display_color)
        set _sv_sbar $::VMDPathFinder::state(show_hydro_scalebar)
        set ::VMDPathFinder::state(tunnel_prop) hydropathy
        set ::VMDPathFinder::state(tunnel_display_color) property
        set ::VMDPathFinder::state(show_hydro_scalebar) 1
        ::VMDPathFinder::render_tunnels_for_frame $fr
        update idletasks; update
        report "tunnel scale bar mol created" \
               [expr {$::VMDPathFinder::hydro_scalebar_mol >= 0}] \
               "(mol=$::VMDPathFinder::hydro_scalebar_mol)"
        report "tunnel scale bar scheme matches the selected property" \
               [expr {$::VMDPathFinder::hydro_scalebar_scheme eq "hydropathy"}] \
               "(scheme=$::VMDPathFinder::hydro_scalebar_scheme)"
        set ::VMDPathFinder::state(tunnel_display_color) auto
        ::VMDPathFinder::render_tunnels_for_frame $fr
        update idletasks; update
        report "tunnel scale bar removed when Color is not Property" \
               [expr {$::VMDPathFinder::hydro_scalebar_mol < 0}] \
               "(mol=$::VMDPathFinder::hydro_scalebar_mol)"

        # The bar is a LEGEND: with no surface on screen there is nothing for
        # it to explain, and it used to appear anyway because every gate tested
        # the color MODE (a setting that survives the surface being switched
        # off) rather than what is displayed. Computing a property in Over
        # Time - a 2D plot - popped it into the 3D viewer.
        set _sb_hidden {}
        foreach _m [list $::VMDPathFinder::current_surface_mol $::VMDPathFinder::mean_surface_mol \
                         $::VMDPathFinder::tunnel_mean_surface_mol] {
            if {$_m ne "" && $_m >= 0 && ![catch {molinfo $_m get displayed} _md]} {
                lappend _sb_hidden [list $_m $_md]
                catch {mol off $_m}
            }
        }
        if {![catch {::VMDPathFinder::resolve_molid} _sbrm] \
                && [info exists ::VMDPathFinder::tunnel_surface_mols($_sbrm)]} {
            set _m $::VMDPathFinder::tunnel_surface_mols($_sbrm)
            if {$_m >= 0 && ![catch {molinfo $_m get displayed} _md]} {
                lappend _sb_hidden [list $_m $_md]
                catch {mol off $_m}
            }
        }
        set ::VMDPathFinder::state(tunnel_display_color) property
        set ::VMDPathFinder::state(show_hydro_scalebar) 1
        catch {::VMDPathFinder::draw_hydro_scalebar "tunnel" hydropathy}
        update idletasks
        report "the 3D scale bar stays away when no surface is displayed" \
               [expr {$::VMDPathFinder::hydro_scalebar_mol < 0}] \
               "(mol=$::VMDPathFinder::hydro_scalebar_mol hidden=[llength $_sb_hidden])"
        foreach _hm $_sb_hidden {
            lassign $_hm _m _md
            if {$_md} { catch {mol on $_m} }
        }
        set ::VMDPathFinder::state(tunnel_prop) $_sv_tprop
        set ::VMDPathFinder::state(tunnel_display_color) $_sv_tcolor
        set ::VMDPathFinder::state(show_hydro_scalebar) $_sv_sbar

        # True 3D accurate coloring: one row per (layer, lining
        # residue), positioned at the residue's real atom-selection COM, not
        # the axial centerline. Gated on the compiled binary's hydro3d
        # feature (same gate render_tunnels_for_frame itself uses) - an
        # older sos_triangle without it is a legitimate build, not a bug, so
        # that case reports a pass rather than a failure.
        if {[::VMDPathFinder::sos_triangle_has_feature hydro3d]} {
            set _sel_id [expr {[info exists ::VMDPathFinder::state(tunnel_selected_id)] \
                ? $::VMDPathFinder::state(tunnel_selected_id) : 1}]
            if {$_sel_id eq ""} { set _sel_id 1 }
            set _rfile [file join [file dirname $::env(GUI_TEST_LOG)] hydro3d_sidecar_test.txt]
            set _rc [catch {::VMDPathFinder::write_tunnel_hydro3d_residue_sidecar \
                [::VMDPathFinder::resolve_molid] $fr [list $_sel_id] $_rfile hydropathy} _n]
            report "tunnel hydro3d sidecar writes real residue rows" \
                   [expr {!$_rc && $_n > 0}] "(rc=$_rc n=$_n)"
            catch {file delete $_rfile}

            set _sv_h3d $::VMDPathFinder::state(tunnel_hydro3d_accurate)
            set _sv_h3dcolor $::VMDPathFinder::state(tunnel_display_color)
            set ::VMDPathFinder::state(tunnel_prop) hydropathy
            # render_tunnels_for_frame's property-coloring branch (the ONLY
            # branch that can write a _3d_v1.plot cache file) requires the
            # effective colormode to be "property", not merely a real prop
            # token in state(tunnel_prop) - see the Color/Property unification
            # earlier this session (render gate changed from `$prop ne
            # "none"` to `$cmode eq "property" && $prop ne "none"`). Without
            # this the whole block below is silently unreachable and both
            # checks fail no matter what tunnel_hydro3d_accurate is set to.
            set ::VMDPathFinder::state(tunnel_display_color) property
            set ::VMDPathFinder::state(tunnel_hydro3d_accurate) 1
            ::VMDPathFinder::render_tunnels_for_frame $fr
            update idletasks; update
            set _fd [file join $::VMDPathFinder::tunnel_root [format "tunnel_%05d" $fr]]
            set _cplot3d [file join $_fd [format "tunnel_%02d_hydropathy_3d_v1.plot" $_sel_id]]
            report "tunnel true-3D coloring writes its own cache file" \
                   [file exists $_cplot3d] "($_cplot3d)"

            set ::VMDPathFinder::state(tunnel_hydro3d_accurate) 0
            ::VMDPathFinder::render_tunnels_for_frame $fr
            update idletasks; update
            set _cplot2d [file join $_fd [format "tunnel_%02d_hydropathy_v2.plot" $_sel_id]]
            report "turning true-3D back off falls back to the axial cache file" \
                   [file exists $_cplot2d] "($_cplot2d)"

            # Task 170: the checkbox must actually change the COLORS, not
            # just write a differently-named file. Compare the parsed color
            # token streams of the two cached plots for the SAME tunnel/
            # frame/property - if they are byte-for-byte the same sequence,
            # "Accurate 3D" is wired to nothing.
            set _c3d {}
            set _c2d {}
            foreach _e [expr {[file exists $_cplot3d] ? [::VMDPathFinder::plot_cache_entries $_cplot3d] : {}}] {
                if {[lindex $_e 0] eq "c"} { lappend _c3d [lindex $_e 1] }
            }
            foreach _e [expr {[file exists $_cplot2d] ? [::VMDPathFinder::plot_cache_entries $_cplot2d] : {}}] {
                if {[lindex $_e 0] eq "c"} { lappend _c2d [lindex $_e 1] }
            }
            report "Accurate 3D actually changes the rendered colors (not just the cache filename)" \
                   [expr {$_c3d ne $_c2d}] \
                   "(3d color tokens=[llength $_c3d], 2d color tokens=[llength $_c2d], identical=[expr {$_c3d eq $_c2d}])"

            set ::VMDPathFinder::state(tunnel_hydro3d_accurate) $_sv_h3d
            set ::VMDPathFinder::state(tunnel_display_color) $_sv_h3dcolor
            set ::VMDPathFinder::state(tunnel_prop) $_sv_tprop
        } else {
            report "tunnel hydro3d sidecar writes real residue rows" 1 \
                   "(skipped: this sos_triangle build has no hydro3d feature)"
        }

        # Task 159: per-tunnel gear (representation/material/color).
        set _gid [expr {[llength $::VMDPathFinder::tunnel_results($fr)] > 0 ? 1 : ""}]
        # Row widgets are keyed by ROW INDEX now (see _rw_widget), and the
        # list itself is the CROSS-frame cluster set (refresh_tunnel_tab) -
        # the swatch text is the CLUSTER id (tunnel_xcid($fr,$_gid)), not the
        # rank $_gid resolves to in this frame. Resolved by scanning the
        # swatch texts for that cid rather than assuming id==row, so this
        # keeps working under sorting.
        set _gcid [expr {$_gid ne "" && [info exists ::VMDPathFinder::tunnel_xcid($fr,$_gid)] \
            ? $::VMDPathFinder::tunnel_xcid($fr,$_gid) : $_gid}]
        set _grow ""
        for {set _rr 1} {$_rr <= 200} {incr _rr} {
            if {![winfo exists $P.tunlist.c.inner.rk$_rr]} break
            if {[string trim [$P.tunlist.c.inner.rk$_rr cget -text]] eq "$_gcid"} { set _grow $_rr; break }
        }
        if {$_grow eq ""} { set _grow 1 }
        if {$_gid ne ""} {
            report "row's gear icon exists and defaults to no override" \
                   [expr {[winfo exists $P.tunlist.c.inner.rg$_grow] \
                       && [$P.tunlist.c.inner.rg$_grow cget -text] eq "⚙"}] \
                   "(text=[expr {[winfo exists $P.tunlist.c.inner.rg$_grow] ? [$P.tunlist.c.inner.rg$_grow cget -text] : {missing}}])"

            ::VMDPathFinder::show_tunnel_gear_settings $_gid
            update idletasks; update
            set GD $w.tunnel_gear
            report "gear popup opens with representation/material/property/color controls" \
                   [expr {[winfo exists $GD.rep] && [winfo exists $GD.mat] \
                       && [winfo exists $GD.pm] && [winfo exists $GD.sc]}] \
                   "(exists under $GD)"
            report "per-tunnel gear popup has no Reset to defaults button (task 193)" \
                   [expr {![winfo exists $GD.reset]}] "(exists=[winfo exists $GD.reset])"
            report "Property is the FIRST entry in the per-tunnel Color menu (task 207)" \
                   [expr {[$GD.sc.m entrycget 0 -label] eq "Property"}] \
                   "(first='[$GD.sc.m entrycget 0 -label]')"
            report "per-tunnel Color menu fits on screen (columns, not one tall strip)" \
                   [expr {[winfo reqheight $GD.sc.m] < 300}] \
                   "(menu reqheight=[winfo reqheight $GD.sc.m]px)"
            destroy $GD

            ::VMDPathFinder::_tunnel_gear_set $_gid wire 1
            set _isdef [::VMDPathFinder::_tunnel_gear_is_default $_gid]
            set _gtxt [$P.tunlist.c.inner.rg$_grow cget -text]
            report "setting wireframe marks the row as overridden" \
                   [expr {!$_isdef && $_gtxt eq "⚙*"}] \
                   "(is_default=$_isdef text=$_gtxt)"

            set _rc [catch {::VMDPathFinder::render_tunnels_for_frame $fr} _rcerr]
            report "rendering with a per-tunnel override does not error" \
                   [expr {!$_rc}] "(rc=$_rc err=$_rcerr)"

            ::VMDPathFinder::_tunnel_gear_reset $_gid
            set _isdef [::VMDPathFinder::_tunnel_gear_is_default $_gid]
            set _gtxt [$P.tunlist.c.inner.rg$_grow cget -text]
            report "reset clears the override and the row's marker" \
                   [expr {$_isdef && $_gtxt eq "⚙"}] "(is_default=$_isdef text=$_gtxt)"

            # Task 176: per-tunnel property override, reversing task 172's
            # global-only decision now that the user wants it exposed per row.
            set _sv_gprop $::VMDPathFinder::state(tunnel_prop)
            set ::VMDPathFinder::state(tunnel_prop) charge
            ::VMDPathFinder::_tunnel_gear_set $_gid prop hydropathy
            report "per-tunnel property override takes effect for that tunnel" \
                   [expr {[::VMDPathFinder::_tunnel_effective_prop $_gid] eq "hydropathy"}] \
                   "(effective=[::VMDPathFinder::_tunnel_effective_prop $_gid])"
            report "per-tunnel property override does not change the global picker" \
                   [expr {$::VMDPathFinder::state(tunnel_prop) eq "charge"}] \
                   "(state(tunnel_prop)=$::VMDPathFinder::state(tunnel_prop))"
            set _rc [catch {::VMDPathFinder::render_tunnels_for_frame $fr} _rcerr]
            report "rendering with a per-tunnel property override does not error" \
                   [expr {!$_rc}] "(rc=$_rc err=$_rcerr)"
            ::VMDPathFinder::_tunnel_gear_reset $_gid
            report "resetting the property override falls back to the global picker" \
                   [expr {[::VMDPathFinder::_tunnel_effective_prop $_gid] eq "charge"}] \
                   "(effective=[::VMDPathFinder::_tunnel_effective_prop $_gid])"
            set ::VMDPathFinder::state(tunnel_prop) $_sv_gprop

            # Unified Color control (mirrors HOLE's state(surface_color)):
            # ONE choice per tunnel between auto/a flat color/property, not
            # two independently-toggled fields. The semantic fix this gave -
            # a tunnel's OWN flat color now beats a GLOBAL property choice,
            # where it used to silently lose to it.
            set _sv_gprop2 $::VMDPathFinder::state(tunnel_prop)
            set _sv_gcolor2 $::VMDPathFinder::state(tunnel_display_color)
            set ::VMDPathFinder::state(tunnel_prop) hydropathy
            set ::VMDPathFinder::state(tunnel_display_color) property
            report "with no per-tunnel override, effective colormode follows the global Color" \
                   [expr {[::VMDPathFinder::_tunnel_effective_colormode $_gid] eq "property"}] \
                   "(effective=[::VMDPathFinder::_tunnel_effective_colormode $_gid])"
            ::VMDPathFinder::_tunnel_gear_color_set $_gid magenta
            report "a per-tunnel flat color wins over the global property choice" \
                   [expr {[::VMDPathFinder::_tunnel_effective_colormode $_gid] eq "magenta"}] \
                   "(effective=[::VMDPathFinder::_tunnel_effective_colormode $_gid], global=$::VMDPathFinder::state(tunnel_display_color))"
            ::VMDPathFinder::show_tunnel_gear_settings $_gid
            update idletasks; update
            set GD2 $w.tunnel_gear
            report "Property row is hidden for a tunnel whose color is a flat override" \
                   [expr {![winfo ismapped $GD2.pm]}] \
                   "(ismapped=[winfo ismapped $GD2.pm])"
            destroy $GD2
            ::VMDPathFinder::_tunnel_gear_color_set $_gid property
            report "picking Property per-tunnel takes effect immediately" \
                   [expr {[::VMDPathFinder::_tunnel_effective_colormode $_gid] eq "property"}] \
                   "(effective=[::VMDPathFinder::_tunnel_effective_colormode $_gid])"
            set _rc [catch {::VMDPathFinder::render_tunnels_for_frame $fr} _rcerr]
            report "rendering with a per-tunnel colormode override does not error" \
                   [expr {!$_rc}] "(rc=$_rc err=$_rcerr)"
            ::VMDPathFinder::_tunnel_gear_reset $_gid
            report "resetting the colormode override falls back to Global default" \
                   [expr {[::VMDPathFinder::_tunnel_effective_colormode $_gid] eq "property"}] \
                   "(effective=[::VMDPathFinder::_tunnel_effective_colormode $_gid])"

            # Representation / Material / Property had NO way back to the
            # global: touching any of them pinned that tunnel forever. The
            # global could then be set to Wireframe while the tunnel stayed on
            # Isosurface, showing a bare "Isosurface" with no hint it was an
            # override - the reported "not synced".
            set _svgm $::VMDPathFinder::state(tunnel_display_mode)
            set ::VMDPathFinder::state(tunnel_display_mode) wire
            ::VMDPathFinder::_tunnel_gear_set $_gid wire 0
            report "(setup) an explicit Isosurface override beats the global Wireframe" \
                   [expr {[::VMDPathFinder::_tunnel_effective_repr $_gid] eq "iso"}] \
                   "(effective=[::VMDPathFinder::_tunnel_effective_repr $_gid])"
            report "...and the gear marks the tunnel as customized" \
                   [expr {![::VMDPathFinder::_tunnel_gear_is_default $_gid]}] ""
            ::VMDPathFinder::_tunnel_gear_set $_gid wire ""
            report "clearing the Representation override follows the global again" \
                   [expr {[::VMDPathFinder::_tunnel_effective_repr $_gid] eq "wire"}] \
                   "(effective=[::VMDPathFinder::_tunnel_effective_repr $_gid])"
            # Centerline is a legal value that is NOT a boolean - the old
            # is-default test threw on it, and the caller's catch hid that.
            ::VMDPathFinder::_tunnel_gear_set $_gid wire centerline
            set _cd [catch {::VMDPathFinder::_tunnel_gear_is_default $_gid} _cdv]
            report "a Centerline tunnel does not break the is-customized test" \
                   [expr {!$_cd && $_cdv == 0}] "(rc=$_cd val=$_cdv)"
            ::VMDPathFinder::_tunnel_gear_set $_gid wire ""
            set ::VMDPathFinder::state(tunnel_display_mode) $_svgm

            # Material had the same one-way door.
            set _svgmat $::VMDPathFinder::state(tunnel_display_material)
            set ::VMDPathFinder::state(tunnel_display_material) Glass1
            ::VMDPathFinder::_tunnel_gear_set $_gid material Opaque
            report "(setup) a Material override beats the global material" \
                   [expr {![::VMDPathFinder::_tunnel_gear_is_default $_gid]}] ""
            ::VMDPathFinder::_tunnel_gear_set $_gid material ""
            # REVERSED (C10, by user instruction): an inherited row reads plain
            # "auto", not "<value> (from global)". The suffix form put
            # "Property" next to "Property (from global)" in one menu - two
            # entries whose difference no label can carry.
            report "clearing the Material override follows the global again" \
                   [expr {[::VMDPathFinder::_tunnel_gear_is_default $_gid]
                          && [::VMDPathFinder::_tunnel_inherited_material_label $_gid] eq "auto"}] \
                   "(label=[::VMDPathFinder::_tunnel_inherited_material_label $_gid])"
            set ::VMDPathFinder::state(tunnel_display_material) $_svgmat

            # The Property picker was the last "Global default" in the dialog:
            # it named a place to inherit from, never the property on screen.
            set _svgp $::VMDPathFinder::state(tunnel_prop)
            set ::VMDPathFinder::state(tunnel_prop) hydropathy
            ::VMDPathFinder::_tunnel_gear_set $_gid prop ""
            # Compares against the CANONICAL label rather than a literal: the
            # names are deliberately shared with pore mode, so a
            # hardcoded copy here would just be a fourth place to update.
            report "an inherited Property reads plain \"auto\"" \
                   [expr {[::VMDPathFinder::_tunnel_inherited_prop_label $_gid] eq "auto"}] \
                   "(label=[::VMDPathFinder::_tunnel_inherited_prop_label $_gid])"
            set ::VMDPathFinder::state(tunnel_prop) charge
            # It no longer names the resolved value, so it CANNOT go stale -
            # which is the point of the reversal. What must still hold is that
            # picking it clears the override and the reader falls back.
            report "...and picking it leaves the tunnel resolving to the global" \
                   [expr {[::VMDPathFinder::_tunnel_effective_prop $_gid] eq $::VMDPathFinder::state(tunnel_prop)}] \
                   "(eff=[::VMDPathFinder::_tunnel_effective_prop $_gid] global=$::VMDPathFinder::state(tunnel_prop))"
            ::VMDPathFinder::show_tunnel_gear_settings $_gid
            update idletasks; update
            set GD3 $w.tunnel_gear
            set _nglobal 1
            foreach _m {rep mat pm} {
                set _mw $GD3.$_m.m
                if {![winfo exists $_mw]} continue
                for {set _mi 0} {$_mi <= [$_mw index end]} {incr _mi} {
                    if {[catch {$_mw type $_mi} _mt] || $_mt ne "radiobutton"} continue
                    if {[$_mw entrycget $_mi -label] eq "Global default"} { set _nglobal 0 }
                }
            }
            report "no gear menu still says \"Global default\"" $_nglobal ""
            # The rename exists so MOLE's own tables cannot be read as the HOLE
            # scales of near-identical name, now that both are in one picker.
            report "MOLE's polarity is distinguishable from grantham polarity" \
                   [expr {[::VMDPathFinder::_tunnel_prop_label polarity] ne \
                          [::VMDPathFinder::scheme_display_label polarity]}] \
                   "(mole=[::VMDPathFinder::_tunnel_prop_label polarity])"
            set _hasinherit 1
            foreach _m {rep mat pm} {
                set _mw $GD3.$_m.m
                if {![winfo exists $_mw]} { set _hasinherit 0; continue }
                if {![::VMDPathFinder::_tunnel_is_inherited_label [$_mw entrycget 0 -label]]} { set _hasinherit 0 }
            }
            report "every gear menu offers a way back to the global" $_hasinherit ""
            destroy $GD3
            set ::VMDPathFinder::state(tunnel_prop) $_svgp

            # Setting the HEADER/global Color used to silently apply to only the
            # tunnels with no override of their own - not "every tunnel", which is
            # what the control claims and what the user asked for. It must now
            # clear an existing per-tunnel override too.
            ::VMDPathFinder::_tunnel_gear_color_set $_gid magenta
            report "(setup) per-tunnel override is magenta before the global Color is set" \
                   [expr {[::VMDPathFinder::_tunnel_effective_colormode $_gid] eq "magenta"}] \
                   "(effective=[::VMDPathFinder::_tunnel_effective_colormode $_gid])"
            ::VMDPathFinder::_tunnel_global_gear_color_set auto
            report "setting the global Color clears a per-tunnel override" \
                   [expr {[::VMDPathFinder::_tunnel_effective_colormode $_gid] eq "auto"}] \
                   "(effective=[::VMDPathFinder::_tunnel_effective_colormode $_gid], global=$::VMDPathFinder::state(tunnel_display_color))"

            # The global Color's most basic case - a flat color for every
            # un-overridden tunnel - never actually reached the render path or
            # the row swatch: both only ever read the PER-TUNNEL override
            # array, so a global literal color with no per-tunnel override
            # anywhere silently fell back to the auto rank color everywhere.
            ::VMDPathFinder::_tunnel_global_gear_color_set green
            report "global literal Color is this tunnel's effective colormode" \
                   [expr {[::VMDPathFinder::_tunnel_effective_colormode $_gid] eq "green"}] \
                   "(effective=[::VMDPathFinder::_tunnel_effective_colormode $_gid])"
            report "global literal Color reaches the row swatch, not just the auto rank color" \
                   [expr {[::VMDPathFinder::_tunnel_row_swatch_hex $_gid] eq [::VMDPathFinder::_vmd_color_hex green]}] \
                   "(swatch=[::VMDPathFinder::_tunnel_row_swatch_hex $_gid] expect=[::VMDPathFinder::_vmd_color_hex green])"
            set _rc [catch {::VMDPathFinder::render_tunnels_for_frame $fr} _rcerr]
            report "rendering with a global literal Color does not error" \
                   [expr {!$_rc}] "(rc=$_rc err=$_rcerr)"

            ::VMDPathFinder::_tunnel_global_gear_color_set $_sv_gcolor2

            set ::VMDPathFinder::state(tunnel_prop) $_sv_gprop2
            set ::VMDPathFinder::state(tunnel_display_color) $_sv_gcolor2

            # Task 167: exhaust VMD's real named-color set before repeating.
            set _cnames [::VMDPathFinder::_tunnel_color_names]
            report "tunnel color palette covers most of VMD's named colors" \
                   [expr {[llength $_cnames] >= 20}] "(n=[llength $_cnames])"
            report "color 0 and color 10 are different (old 10-entry palette repeated here)" \
                   [expr {[::VMDPathFinder::_tunnel_color 0] ne [::VMDPathFinder::_tunnel_color 10]}] \
                   "([::VMDPathFinder::_tunnel_color 0] vs [::VMDPathFinder::_tunnel_color 10])"
            report "_tunnel_color_hex resolves every palette entry to a real hex color" \
                   [expr {![string match "*c0c0c0*" [::VMDPathFinder::_tunnel_color_hex 15]]}] \
                   "(hex=[::VMDPathFinder::_tunnel_color_hex 15])"

            # HOLE/Pore mode's own surface Color picker must offer the SAME
            # full VMD set tunnel mode does (it had a hardcoded 12), plus
            # hole_def/property which are data-driven modes, not colors.
            # HOLE/Pore mode's Color picker: a menubutton+menu (consistent with
            # every other picker here), laid out in COLUMNS so it fits on
            # screen. A Tk menu that does not fit is posted and instantly
            # unposted - "closes very fast so the user can not select
            # anything". Measured on this 1080-tall screen: 1 column = 632 px,
            # 20/col = 362 px, 12/col = 218 px.
            set _hc $w.sidebar.nb.hole.hs_box.sc
            if {[winfo exists $_hc]} {
                set _hm $_hc.m
                set _hlabels {}
                for {set _i 0} {$_i <= [$_hm index end]} {incr _i} {
                    if {[catch {$_hm type $_i} _t] || $_t ne "radiobutton"} { continue }
                    lappend _hlabels [$_hm entrycget $_i -label]
                }
                report "HOLE Color picker is a menubutton, like every other picker" \
                       [expr {[winfo class $_hc] eq "Menubutton"}] "(class=[winfo class $_hc])"
                report "HOLE Color picker offers the full VMD color set" \
                       [expr {[llength $_hlabels] >= 30}] "(n=[llength $_hlabels])"
                report "HOLE Color still offers hole_def and property, listed first" \
                       [expr {[lindex $_hlabels 0] eq "hole_def" && [lindex $_hlabels 1] eq "property"}] \
                       "(first two=[lrange $_hlabels 0 1])"
                report "HOLE Color did not lose an already-offered color (white)" \
                       [expr {"white" in $_hlabels}] "(white present=[expr {{white} in $_hlabels}])"
                # The real invariant: the menu must actually FIT. Anything near
                # the old single-column 632 px overflows a 1080 screen for any
                # button in the lower half of it.
                update idletasks
                set _mh [winfo reqheight $_hm]
                report "the Color menu is short enough to post without being clipped" \
                       [expr {$_mh < 300}] "(menu reqheight=${_mh}px, 1-column would be ~632px)"
                set _nbreak 0
                for {set _i 0} {$_i <= [$_hm index end]} {incr _i} {
                    if {![catch {$_hm entrycget $_i -columnbreak} _cb] && $_cb} { incr _nbreak }
                }
                report "the Color menu is laid out in multiple columns" \
                       [expr {$_nbreak >= 2}] "(column breaks=$_nbreak)"
                report "columns are set at build time, never from a -postcommand" \
                       [expr {[$_hm cget -postcommand] eq ""}] \
                       "(postcommand='[$_hm cget -postcommand]')"
                set _svsc $::VMDPathFinder::state(surface_color)
                ::VMDPathFinder::_set_surface_color magenta
                report "picking from the Color menu sets state(surface_color)" \
                       [expr {$::VMDPathFinder::state(surface_color) eq "magenta"}] \
                       "(surface_color=$::VMDPathFinder::state(surface_color))"
                ::VMDPathFinder::_set_surface_color $_svsc
            }

            set _mc $w.plotframe.nb.mean.exportbar.sc
            if {[winfo exists $_mc]} {
                # We are in TUNNEL mode at this point in the file (see the
                # sidebar select above) - hole_def is HOLE's own per-band
                # pore-radius coloring, meaningless for a tunnel's averaged
                # tube (no HOLE profile exists to band a MOLE route by), so it
                # must NOT be offered here - _sync_profile_exportbar_for_mode
                # rebuilds this menu per mode. "property" (MOLE lining
                # properties) is real in both modes and must stay.
                set _mlabels_tunnel {}
                for {set _i 0} {$_i <= [$_mc.m index end]} {incr _i} {
                    if {[catch {$_mc.m type $_i} _t] || $_t ne "radiobutton"} { continue }
                    lappend _mlabels_tunnel [$_mc.m entrycget $_i -label]
                }
                report "Mean Profile color picker offers most of the VMD set in tunnel mode too" \
                       [expr {[llength $_mlabels_tunnel] >= 29}] "(n=[llength $_mlabels_tunnel])"
                report "...but does NOT offer hole_def in tunnel mode (keeps property)" \
                       [expr {"hole_def" ni $_mlabels_tunnel && "property" in $_mlabels_tunnel}] \
                       "(labels=$_mlabels_tunnel)"
                # An already-selected hole_def must not survive the switch
                # INTO tunnel mode either - an inert value the menu no longer
                # offers would leave the surface silently mis-colored.
                set _sv_mscol $::VMDPathFinder::state(mean_surface_color)
                set ::VMDPathFinder::state(mean_surface_color) hole_def
                $w.sidebar.nb select $w.sidebar.nb.hole
                update idletasks; update
                ::VMDPathFinder::_sync_profile_exportbar_for_mode
                $w.sidebar.nb select $w.sidebar.nb.tunnel
                update idletasks; update
                ::VMDPathFinder::_sync_profile_exportbar_for_mode
                report "an active hole_def selection is reset (not left inert) on entering tunnel mode" \
                       [expr {$::VMDPathFinder::state(mean_surface_color) ne "hole_def"}] \
                       "(mean_surface_color=$::VMDPathFinder::state(mean_surface_color))"
                set ::VMDPathFinder::state(mean_surface_color) $_sv_mscol
                ::VMDPathFinder::_sync_mean_surface_color_disp

                # And hole_def comes BACK once the user returns to HOLE mode -
                # this is a per-mode menu rebuild, not a one-way removal.
                $w.sidebar.nb select $w.sidebar.nb.hole
                update idletasks; update
                ::VMDPathFinder::_sync_profile_exportbar_for_mode
                set _mlabels_hole {}
                for {set _i 0} {$_i <= [$_mc.m index end]} {incr _i} {
                    if {[catch {$_mc.m type $_i} _t] || $_t ne "radiobutton"} { continue }
                    lappend _mlabels_hole [$_mc.m entrycget $_i -label]
                }
                report "hole_def is back once the user returns to HOLE mode" \
                       [expr {"hole_def" in $_mlabels_hole}] "(labels=$_mlabels_hole)"
                $w.sidebar.nb select $w.sidebar.nb.tunnel
                update idletasks; update
                ::VMDPathFinder::_sync_profile_exportbar_for_mode
                # Sabotage-checked by hand: removing the mode gate from the
                # $meb.sc.m rebuild in _sync_profile_exportbar_for_mode (offer
                # the same fixed list in both modes, as it used to) turns the
                # three reports above FAIL - confirmed, then restored.
            }

            # The five MOLE-table properties are now offered in pore mode too,
            # and resolve through the SAME table the tunnel engine uses.
            set _pchoices [::VMDPathFinder::_property_scheme_choices]
            set _ptoks {}
            foreach {_v _l} $_pchoices { lappend _ptoks $_v }
            report "pore mode offers MOLE logP/logD/logS/mutability/ionizable" \
                   [expr {"logp" in $_ptoks && "logd" in $_ptoks && "logs" in $_ptoks \
                       && "mutability" in $_ptoks && "ionizable" in $_ptoks}] \
                   "(toks=$_ptoks)"
            report "pore mode did NOT gain a duplicate hydropathy (it is kd)" \
                   [expr {"hydropathy" ni $_ptoks}] "(hydropathy present=[expr {{hydropathy} in $_ptoks}])"
            report "residue_property routes the new tokens to MOLE's own table" \
                   [expr {[::VMDPathFinder::residue_property mutability TRP] == 25 \
                       && [::VMDPathFinder::residue_property logp ILE] == 2.24 \
                       && [::VMDPathFinder::residue_property ionizable ARG] == 1 \
                       && [::VMDPathFinder::residue_property logs ASP] == 2.63}] \
                   "(TRP mut=[::VMDPathFinder::residue_property mutability TRP] ILE logp=[::VMDPathFinder::residue_property logp ILE] ARG ion=[::VMDPathFinder::residue_property ionizable ARG] ASP logs=[::VMDPathFinder::residue_property logs ASP])"
            report "every new pore property has real scale metadata (not the kd default)" \
                   [expr {[dict get [::VMDPathFinder::property_meta mutability] hi] == 117 \
                       && [dict get [::VMDPathFinder::property_meta logd] lo] == -3.00}] \
                   "(mutability hi=[dict get [::VMDPathFinder::property_meta mutability] hi] logd lo=[dict get [::VMDPathFinder::property_meta logd] lo])"

            # Task 168: the swatch itself must follow a gear color override.
            # Reset first: earlier blocks in this same run leave a color
            # override on this tunnel, and now that the in-place swatch update
            # actually reaches the row widget (it used to target a stale
            # id-keyed path and silently no-op) that leftover would make
            # "before" already equal the value under test.
            set kw $P.tunlist.c.inner.rk$_grow
            ::VMDPathFinder::_tunnel_gear_reset $_gid
            set _defhex [$kw cget -background]
            ::VMDPathFinder::_tunnel_gear_set $_gid color magenta
            set _ovrhex [$kw cget -background]
            report "swatch follows a gear color override" \
                   [expr {$_ovrhex eq [::VMDPathFinder::_vmd_color_hex magenta] && $_ovrhex ne $_defhex}] \
                   "(before=$_defhex after=$_ovrhex expect=[::VMDPathFinder::_vmd_color_hex magenta])"
            ::VMDPathFinder::_tunnel_gear_reset $_gid
            report "swatch reverts to the auto rank color on reset" \
                   [expr {[$kw cget -background] eq $_defhex}] \
                   "(after_reset=[$kw cget -background] expect=$_defhex)"
        }

        # The 5 tab exports that used to always read HOLE-only data
        # regardless of mode: tk_getSaveFile is modal, so shadow it to
        # return a fixed path instead of blocking.
        set _exdir [file dirname $::env(GUI_TEST_LOG)]
        proc ::tk_getSaveFile {args} {
            global _exdir; global _exname
            return [file join $_exdir $_exname]
        }
        proc ::tk_messageBox {args} { return ok }
        set ::VMDPathFinder::state(tunnel_prop) hydropathy
        # Profile/Mean/Histogram need only the landed frame (this test runs
        # frame_spec "now", a single frame) and must write real data. Trends/
        # Heatmap are genuine cross-frame series - draw_tunnel_trends_plot and
        # export_tunnel_heatmap_csv both correctly require >=2 frames, so on
        # this single-frame fixture the right behaviour is declining to write
        # anything (via the messageBox stub below), not producing a file.
        foreach {_label _exname _cmd _need_multiframe} {
            "Profile"   tunnel_export_profile.csv  ::VMDPathFinder::export_profile_csv 0
            "Trends"    tunnel_export_trends.csv   ::VMDPathFinder::export_metrics_csv 1
            "Heatmap"   tunnel_export_heatmap.csv  ::VMDPathFinder::export_heatmap_csv 1
            "Mean"      tunnel_export_mean.csv     ::VMDPathFinder::export_mean_profile_csv 0
            "Histogram" tunnel_export_hist.csv     ::VMDPathFinder::export_histogram_csv 0
        } {
            set _outpath [file join $_exdir $_exname]
            catch {file delete $_outpath}
            catch {$_cmd}
            if {$_need_multiframe} {
                report "tunnel-mode $_label export correctly declines on <2 frames" \
                       [expr {![file exists $_outpath]}] "(exists=[file exists $_outpath])"
            } else {
                set _ok [expr {[file exists $_outpath] && [file size $_outpath] > 20}]
                set _detail ""
                if {$_ok} {
                    set _fh [open $_outpath r]; set _detail [string range [read $_fh] 0 80]; close $_fh
                }
                report "tunnel-mode $_label export writes real data, not HOLE-only/empty" $_ok \
                       "($_detail)"
            }
        }
        set ::VMDPathFinder::state(tunnel_prop) $_sv_tprop

        # Coloring on a REAL tunnel: distinct values along it, not a flat fill.
        # ::VMDPathFinder::_tunnel_property_spheres/_range key on the bare MOLE
        # token directly (same as _tunnel_global_gear_set writes into
        # state(tunnel_prop) - see the global gear popup test above).
        set prop hydropathy
        set sp [::VMDPathFinder::_tunnel_property_spheres $fr 1 $prop]
        set uniq [llength [lsort -unique $sp]]
        report "'$prop' varies along tunnel 1 ([llength $sp] points)" \
               [expr {$uniq > 1}] "($uniq distinct values)"
        lassign [::VMDPathFinder::_tunnel_property_range $fr $prop] plo phi
        report "'$prop' has a non-degenerate range" [expr {$phi > $plo}] \
               "($plo .. $phi)"

        # Single-tunnel selection: a real run auto-selects the first (widest-
        # bottleneck) tunnel, and Pore Profile/Trends draw from it.
        report "a tunnel is auto-selected after the run" \
               [expr {$::VMDPathFinder::state(tunnel_selected_id) ne ""}] \
               "(tunnel_selected_id=$::VMDPathFinder::state(tunnel_selected_id))"
        $w.plotframe.nb select $w.plotframe.nb.profile
        update idletasks; update
        after 200 {set ::go4b 1}; vwait ::go4b
        set pcv $w.plotframe.nb.profile.plotarea.cv
        set pitems 0
        catch {set pitems [llength [$pcv find all]]}
        report "tunnel Pore Profile canvas drew something" \
               [expr {[winfo exists $pcv] && $pitems > 3}] "($pitems canvas items)"

        # ITEM 4 (regression, then revised): Fill defaulted ON but drew nothing.
        # profile_view_mode is shared by HOLE's own Fill (real property always
        # chosen - state(profile_color_scheme)) and tunnel's own Fill (state
        # (tunnel_prop), "none" until a user has picked one FOR A TUNNEL) -
        # switching HOLE mode -> Tunnel mode with Fill already on carried the
        # mode over but not a real tunnel property: the menu genuinely read
        # "Fill", the outline drew, and the shading was silently empty.
        #
        # First fix (superseded): _sync_profile_exportbar_for_mode reset Fill
        # -> None in exactly that case. That silenced the empty-shading bug but
        # introduced a worse, silent one: unlike every other picker in this
        # file ("hidden, not reset" - see _update_heatmap_picker_visibility's
        # own comment), this was the one exception that discarded the user's
        # actual setting, and there is no reset on the way BACK to HOLE mode
        # either, so a plain Tunnel round trip permanently lost Fill.
        #
        # Current fix: default tunnel_prop to a real property (hydropathy)
        # instead of turning Fill off - the exact fallback on_profile_view_
        # mode_changed itself already uses when Fill is picked from the
        # tunnel menu directly, just applied one point earlier (mode entry).
        # Fill now survives the HOLE<->Tunnel round trip AND still never
        # renders empty.
        set _sv_pvm_i4 $::VMDPathFinder::state(profile_view_mode)
        set _sv_tprop_i4 $::VMDPathFinder::state(tunnel_prop)
        set ::VMDPathFinder::state(tunnel_prop) none
        $w.sidebar.nb select $w.sidebar.nb.hole
        update idletasks; update
        ::VMDPathFinder::_sync_profile_exportbar_for_mode
        set ::VMDPathFinder::state(profile_view_mode) fill
        ::VMDPathFinder::on_profile_view_mode_changed
        update idletasks; update
        report "(setup) Fill is on, in HOLE mode" \
               [expr {$::VMDPathFinder::state(profile_view_mode) eq "fill"}] \
               "(profile_view_mode=$::VMDPathFinder::state(profile_view_mode))"
        $w.sidebar.nb select $w.sidebar.nb.tunnel
        update idletasks; update
        ::VMDPathFinder::_sync_profile_exportbar_for_mode
        update idletasks; update
        # REVERSED  by user report ("fill was on by default in tunnel
        # mode"). Carrying Fill across the mode switch WAS deliberate - the two
        # modes shared one profile_view_mode and the rule was "hidden, not
        # reset". But sharing meant a pore-mode Fill arrived already on the
        # first time Tunnel mode was ever opened, which reads as a wrong
        # default rather than as preserved state. Each mode now keeps its OWN
        # view mode (_mode_analysis_swap), so neither leaks into the other and
        # both still remember their own choice.
        report "Fill chosen in HOLE mode does NOT leak into Tunnel mode" \
               [expr {$::VMDPathFinder::state(profile_view_mode) eq "none"}] \
               "(profile_view_mode=$::VMDPathFinder::state(profile_view_mode) tunnel_prop=$::VMDPathFinder::state(tunnel_prop))"
        # Sabotage-checked by hand: restoring the old "reset to none" block in
        # place of the tunnel_prop default turns BOTH reports above FAIL
        # (profile_view_mode reads "none") - confirmed, then restored.
        #
        # And the round trip back to HOLE must not have lost anything either -
        # the whole point is that both directions now agree.
        $w.sidebar.nb select $w.sidebar.nb.hole
        update idletasks; update
        ::VMDPathFinder::_sync_profile_exportbar_for_mode
        update idletasks; update
        report "...and HOLE mode still has its own Fill on the way back (per-mode, not lost)" \
               [expr {$::VMDPathFinder::state(profile_view_mode) eq "fill"}] \
               "(profile_view_mode=$::VMDPathFinder::state(profile_view_mode))"

        # The exempted case: tunnel_prop is ALREADY a real property (the user
        # genuinely configured tunnel Fill, in this session or a previous
        # visit to Tunnel mode) - a mode round-trip must leave Fill alone.
        # Under per-mode state this has to be set WHILE IN tunnel mode - that is
        # what "the user configured tunnel Fill" now means. Setting it from HOLE
        # mode configures HOLE's, which is the leak the report above forbids.
        set ::VMDPathFinder::state(tunnel_prop) hydropathy
        $w.sidebar.nb select $w.sidebar.nb.tunnel
        update idletasks; update
        set ::VMDPathFinder::state(profile_view_mode) fill
        ::VMDPathFinder::on_profile_view_mode_changed
        update idletasks; update
        $w.sidebar.nb select $w.sidebar.nb.hole
        update idletasks; update
        ::VMDPathFinder::_sync_profile_exportbar_for_mode
        $w.sidebar.nb select $w.sidebar.nb.tunnel
        update idletasks; update
        ::VMDPathFinder::_sync_profile_exportbar_for_mode
        report "a Fill configured IN tunnel mode survives a round trip (no unprompted reset)" \
               [expr {$::VMDPathFinder::state(profile_view_mode) eq "fill"}] \
               "(profile_view_mode=$::VMDPathFinder::state(profile_view_mode))"
        # Sabotage-checked by hand: dropping the tunnel_prop=="none" guard
        # from _sync_profile_exportbar_for_mode's new Fill reset (reset
        # unconditionally) turns the report just above FAIL, as it must -
        # confirmed, then restored. Dropping the reset entirely (comment it
        # out) turns the "resets to None" report above FAIL instead -
        # confirmed, then restored.
        set ::VMDPathFinder::state(profile_view_mode) $_sv_pvm_i4
        set ::VMDPathFinder::state(tunnel_prop) $_sv_tprop_i4
        ::VMDPathFinder::on_profile_view_mode_changed

        # Fill used to require toggling None<->Fill up to 3 times before it drew
        # anything, IF the selected tunnel had its own flat-color override left
        # over from earlier (want_fill was gated on effective COLORMODE, which a
        # flat override always wins) - Fill must render on the property alone,
        # same as HOLE's own Fill never depends on surface_color.
        set _sel [expr {$::VMDPathFinder::state(tunnel_selected_id)}]
        set _sv_pvm $::VMDPathFinder::state(profile_view_mode)
        set _sv_tprop $::VMDPathFinder::state(tunnel_prop)
        ::VMDPathFinder::_tunnel_gear_color_set $_sel magenta
        set ::VMDPathFinder::state(tunnel_prop) hydropathy
        set ::VMDPathFinder::state(profile_view_mode) fill
        ::VMDPathFinder::on_profile_view_mode_changed
        update idletasks; update
        set _fillpolys 0
        catch {
            foreach _it [$pcv find all] {
                if {[$pcv type $_it] eq "polygon"} { incr _fillpolys }
            }
        }
        report "Fill draws the property shading even with a stale per-tunnel color override" \
               [expr {$_fillpolys > 0}] "($_fillpolys fill polygons, override=magenta)"

        # Task 196: Pore Profile's own property picker (Fill had no direct
        # switcher on the tab itself). Writes the SAME per-tunnel override
        # the gear popup's Property menu does, so 3D color and Fill can
        # never disagree. Task 202: shown ONLY while Fill is selected - a
        # visible "Global default" with nothing consuming it (view mode
        # None) was reported as meaningless clutter, reversing the earlier
        # "stays visible outside Fill too" design.
        set eb $w.plotframe.nb.profile.exportbar
        report "tunnel-mode property picker exists and is visible while Fill is on (not HOLE's psch)" \
               [expr {[winfo exists $eb.tprop] && [winfo ismapped $eb.tprop] \
                   && ![winfo ismapped $eb.psch]}] \
               "(tprop mapped=[winfo ismapped $eb.tprop] psch mapped=[winfo ismapped $eb.psch])"
        set ::VMDPathFinder::state(profile_view_mode) none
        ::VMDPathFinder::on_profile_view_mode_changed
        update idletasks; update
        report "tunnel-mode property picker hides again once Fill is turned off" \
               [expr {![winfo ismapped $eb.tprop]}] "(tprop mapped=[winfo ismapped $eb.tprop])"
        set ::VMDPathFinder::state(profile_view_mode) fill
        ::VMDPathFinder::on_profile_view_mode_changed
        update idletasks; update
        ::VMDPathFinder::_tunnel_gear_reset $_sel
        ::VMDPathFinder::_tunnel_profile_prop_pick charge
        report "picking a property from the Pore Profile tab sets the SAME per-tunnel override the gear popup uses" \
               [expr {[::VMDPathFinder::_tunnel_effective_prop $_sel] eq "charge"}] \
               "(effective=[::VMDPathFinder::_tunnel_effective_prop $_sel])"
        set _rc [catch {::VMDPathFinder::render_tunnels_for_frame $fr} _rcerr]
        report "rendering after a Pore-Profile-tab property pick does not error" \
               [expr {!$_rc}] "(rc=$_rc err=$_rcerr)"
        # "Global default" is deliberately NOT an entry here any more: this
        # picker names WHICH PROPERTY the shading in front of the user is drawn
        # from, so every entry has to be a real quantity. Clearing an override
        # back to "follow the global" lives in that tunnel's own gear popup.
        report "the Fill property picker offers no \"Global default\" entry" \
               [expr {![info exists ::VMDPathFinder::_tunnel_profile_prop_lbl(global)]}] \
               "(exists=[info exists ::VMDPathFinder::_tunnel_profile_prop_lbl(global)])"
        set _nglobal 1
        for {set _mi 0} {$_mi <= [$eb.tprop.m index end]} {incr _mi} {
            if {[$eb.tprop.m type $_mi] eq "radiobutton" \
                    && [$eb.tprop.m entrycget $_mi -label] eq "Global default"} { set _nglobal 0 }
        }
        report "no menu entry in the Fill picker is labelled Global default" \
               [expr {$_nglobal}] "(clean=$_nglobal)"
        # With no override at all, the picker still displays a REAL property -
        # the inherited/effective one by name, never a blank or a placeholder.
        ::VMDPathFinder::_tunnel_gear_reset $_sel
        ::VMDPathFinder::draw_tunnel_profile_plot
        report "picker displays the inherited property by name when there is no override" \
               [expr {$::VMDPathFinder::state(tunnel_profile_prop_disp) ne "" \
                   && $::VMDPathFinder::state(tunnel_profile_prop_disp) ne "Global default"}] \
               "(disp=$::VMDPathFinder::state(tunnel_profile_prop_disp) effective=[::VMDPathFinder::_tunnel_effective_prop $_sel])"

        set ::VMDPathFinder::state(profile_view_mode) $_sv_pvm
        set ::VMDPathFinder::state(tunnel_prop) $_sv_tprop
        ::VMDPathFinder::on_profile_view_mode_changed

        $w.plotframe.nb select $w.plotframe.nb.minr
        update idletasks; update
        after 200 {set ::go4c 1}; vwait ::go4c
        set tcv $w.plotframe.nb.minr.cv
        set titems 0
        catch {set titems [llength [$tcv find all]]}
        # This fixture (1BL8) is single-frame, so draw_tunnel_trends_plot takes
        # the placeholder branch (canvas legitimately empty, grid-removed) - the
        # correct outcome here is either real canvas content (a multi-frame
        # fixture) or the placeholder visibly showing TUNNEL MODE'S OWN text
        # (draw_tunnel_trends_plot's configure call), not raw canvas-item count.
        # The widget's build-time default text is HOLE's own generic message
        # ("Run HOLE on multiple frames...") and would pass a length-only
        # check even if draw_tunnel_trends_plot never ran - checked for
        # "tunnel", which only tunnel mode's own text contains.
        set tplaceholder_shown 0
        catch {set tplaceholder_shown [expr {[winfo ismapped $w.plotframe.nb.minr.placeholder]
            && [string match "*tunnel*" [$w.plotframe.nb.minr.placeholder cget -text]]}]}
        report "tunnel Trends shows a plot or its own placeholder message" \
               [expr {[winfo exists $tcv] && ($titems > 3 || $tplaceholder_shown)}] \
               "($titems canvas items, placeholder shown=$tplaceholder_shown)"

        # _tpp_x's real bug: 1BL8 being single-frame means the canvas-item
        # check above cannot see it. Frame numbers are plain Tcl integers, and
        # int/int division truncates to 0 - every point but the last collapsed
        # onto the left margin (visually "all points smooshed at 0, then a
        # straight line to one point"). Checked directly, independent of any
        # fixture's frame count, at integer x values exactly like real frames.
        set txa [::VMDPathFinder::_tpp_x 0 0 9 55 445]
        set txb [::VMDPathFinder::_tpp_x 1 0 9 55 445]
        set txc [::VMDPathFinder::_tpp_x 5 0 9 55 445]
        set txd [::VMDPathFinder::_tpp_x 9 0 9 55 445]
        report "_tpp_x spaces integer frame numbers, not just the endpoints" \
               [expr {$txb > $txa + 1 && $txc > $txb + 1 && $txd > $txc + 1}] \
               "(x(0)=$txa x(1)=$txb x(5)=$txc x(9)=$txd)"

        # --- Over Time: the Color picker must actually repaint the map ---
        # Reported as "the different color schemes for over time is not
        # correctly wired up". draw_tunnel_heatmap's render cache had its own
        # variable and a key with no heatmap_scheme in it, so every scheme
        # re-blitted the FIRST map drawn. Asserting the key changed would prove
        # nothing about what is on screen, so this samples real pixels out of
        # heatmap_photo. 1BL8 is single-frame; fan it out so the map has an axis.
        set _hsv_trf $::VMDPathFinder::tunnel_result_frames
        set _hsv_tr [array get ::VMDPathFinder::tunnel_results]
        set _hsv_sch $::VMDPathFinder::state(heatmap_scheme)
        set _hfr [::VMDPathFinder::_tunnel_display_frame]
        foreach _f {90101 90102 90103 90104} {
            set ::VMDPathFinder::tunnel_results($_f) $::VMDPathFinder::tunnel_results($_hfr)
            # Lining too, not just geometry: a real run always emits both, and
            # without it every property-driven view here (Over Time's property
            # map, Mean Profile Fill) sees a trajectory with no lining at all
            # and can only be tested in its "no data" branch.
            if {[info exists ::VMDPathFinder::tunnel_lining($_hfr)]} {
                set ::VMDPathFinder::tunnel_lining($_f) $::VMDPathFinder::tunnel_lining($_hfr)
            }
        }
        set ::VMDPathFinder::tunnel_result_frames {90101 90102 90103 90104}
        ::VMDPathFinder::_tunnel_xframe_build
        $w.plotframe.nb select $w.plotframe.nb.heatmap
        update idletasks; update
        proc _hm_sample {} {
            set p $::VMDPathFinder::heatmap_photo
            if {$p eq "" || [catch {image width $p} pw]} { return "NOPHOTO" }
            set ph [image height $p]
            set out {}
            foreach fx {0.15 0.35 0.5 0.72 0.9} {
                foreach fy {0.25 0.5 0.75} {
                    lappend out [$p get [expr {int($pw*$fx)}] [expr {int($ph*$fy)}]]
                }
            }
            return $out
        }
        array set _HMS {}
        foreach _sch {viridis cividis rainbow watermelon} {
            set ::VMDPathFinder::state(heatmap_scheme) $_sch
            ::VMDPathFinder::draw_heatmap
            update idletasks; update
            set _HMS($_sch) [_hm_sample]
        }
        set _hmdiff 1; set _hmsame {}
        foreach _a {viridis cividis rainbow watermelon} {
            foreach _b {viridis cividis rainbow watermelon} {
                if {$_a eq $_b} { continue }
                if {$_HMS($_a) eq $_HMS($_b)} { set _hmdiff 0; lappend _hmsame "$_a==$_b" }
            }
        }
        report "each Over Time color scheme renders a DIFFERENT tunnel map" \
               [expr {$_hmdiff && $_HMS(viridis) ne "NOPHOTO"}] "(identical: $_hmsame)"

        # --- Property-over-time in tunnel mode actually paints a property ---
        # The failure this guards is silent: Color by says Property and a
        # RADIUS map is drawn underneath it.
        set _sv_cby2 [expr {[info exists ::VMDPathFinder::state(heatmap_color_by)] ? \
            $::VMDPathFinder::state(heatmap_color_by) : "radius"}]
        set _sv_tp2 [expr {[info exists ::VMDPathFinder::state(tunnel_prop)] ? \
            $::VMDPathFinder::state(tunnel_prop) : "none"}]
        set _hcv $w.plotframe.nb.heatmap.cv
        $w.plotframe.nb select $w.plotframe.nb.heatmap
        update idletasks; update
        set ::VMDPathFinder::state(tunnel_prop) hydropathy
        set ::VMDPathFinder::state(heatmap_color_by) property
        ::VMDPathFinder::on_heatmap_color_by_changed
        update idletasks; update
        set _hm_txt {}
        foreach _it [$_hcv find withtag all] {
            if {[$_hcv type $_it] eq "text"} { lappend _hm_txt [$_hcv itemcget $_it -text] }
        }
        set _hm_all [join $_hm_txt " | "]
        # Two worlds, one invariant: with real lining data the map must BE the
        # property map; without it the canvas must say why radius is showing.
        # What must never happen is a radius map under a Property setting with
        # nothing on screen to say so.
        set _pb [::VMDPathFinder::_tunnel_heatmap_property_bundle 4 20]
        set _phave [expr {$_pb ne {} && [dict get $_pb ndata] >= 2}]
        report "tunnel Over Time colors by the route's own MOLE property when asked" \
               [expr {[::VMDPathFinder::_tunnel_heatmap_prop] eq "hydropathy" && ($_phave \
                   ? ([string match "*hydropathy*" $_hm_all] && ![string match "*R (Å)*" $_hm_all]) \
                   : [string match "*No hydropathy lining data*" $_hm_all])}] \
               "(have_property_data=$_phave texts=[string range $_hm_all 0 160])"

        # The bundle is a whole-trajectory pass. Assert the cue is ON SCREEN
        # before it starts, not that a cue exists somewhere in the proc.
        proc ::_tcue_visible {} {
            set ph .vmdpathfinder.plotframe.nb.heatmap.placeholder
            if {[llength [$::_hcv find withtag tuncalc]]} { return 1 }
            if {[winfo exists $ph] && [string match "Calculating*" [$ph cget -text]]} { return 1 }
            return 0
        }
        rename ::VMDPathFinder::_tunnel_heatmap_bundle ::_real_thb
        rename ::VMDPathFinder::_tunnel_heatmap_property_bundle ::_real_thpb
        set ::_TCUE 0
        proc ::VMDPathFinder::_tunnel_heatmap_bundle {args} { set ::_TCUE [::_tcue_visible]; return {} }
        proc ::VMDPathFinder::_tunnel_heatmap_property_bundle {args} { set ::_TCUE [::_tcue_visible]; return {} }
        catch {::VMDPathFinder::draw_tunnel_heatmap}
        rename ::VMDPathFinder::_tunnel_heatmap_bundle {}
        rename ::VMDPathFinder::_tunnel_heatmap_property_bundle {}
        rename ::_real_thb  ::VMDPathFinder::_tunnel_heatmap_bundle
        rename ::_real_thpb ::VMDPathFinder::_tunnel_heatmap_property_bundle
        report "tunnel Over Time paints a cue before its trajectory pass" \
               [expr {$::_TCUE == 1}] "(cue visible = $::_TCUE)"
        catch {::VMDPathFinder::draw_tunnel_heatmap}
        update idletasks
        report "...and the cue is gone once the map is drawn" \
               [expr {[llength [$_hcv find withtag tuncalc]] == 0}]
        # REWRITTEN for A1. This used to set the ROUTE's property to "none" and
        # require Over Time to say "Property is None" - an assertion that only
        # made sense while the two shared one value. Over Time now has its own
        # property, which is never "none", so the invariant becomes the
        # stronger one: the route going to None must not disturb this tab at
        # all. (The "radius under a Property setting with nothing saying so"
        # guard it protected is still covered by the report above, which
        # requires the "No <property> lining data" note in the empty case.)
        set ::VMDPathFinder::state(tunnel_prop) none
        ::VMDPathFinder::on_heatmap_color_by_changed
        update idletasks; update
        set _hm_txt2 {}
        foreach _it [$_hcv find withtag all] {
            if {[$_hcv type $_it] eq "text"} { lappend _hm_txt2 [$_hcv itemcget $_it -text] }
        }
        report "the route's property going to None does not disturb Over Time (A1)" \
               [expr {[::VMDPathFinder::_tunnel_heatmap_prop] eq "hydropathy"
                      && ![string match "*Property is None*" [join $_hm_txt2 " | "]]}] \
               "(_tunnel_heatmap_prop=[::VMDPathFinder::_tunnel_heatmap_prop])"
        set ::VMDPathFinder::state(tunnel_prop) $_sv_tp2
        set ::VMDPathFinder::state(heatmap_color_by) $_sv_cby2
        ::VMDPathFinder::on_heatmap_color_by_changed
        update idletasks; update

        # --- The averaged Mean Profile tube is property-COLORED, not flat ---
        # It used to degrade "property" to the route's flat rank color on the
        # grounds that a synthetic tube has no atoms behind it. One distinct
        # color in the written plot IS that degradation, and "no error
        # thrown" does not catch it.
        proc _plot_colors {f} {
            if {![file exists $f]} { return MISSING }
            set fh [open $f r]; set d [read $fh]; close $fh
            array unset c
            foreach ln [split $d "\n"] {
                if {[string match "draw color*" $ln]} { set c([lindex $ln 2]) 1 }
            }
            return [llength [array names c]]
        }
        set _mtcid [::VMDPathFinder::_tunnel_selected_cluster]
        set _sv_gcm [expr {[info exists ::VMDPathFinder::tunnel_gear_cid($_mtcid,colormode)] ? \
            $::VMDPathFinder::tunnel_gear_cid($_mtcid,colormode) : ""}]
        set _sv_gpr [expr {[info exists ::VMDPathFinder::tunnel_gear_cid($_mtcid,prop)] ? \
            $::VMDPathFinder::tunnel_gear_cid($_mtcid,prop) : ""}]
        set ::VMDPathFinder::tunnel_gear_cid($_mtcid,colormode) property
        set ::VMDPathFinder::tunnel_gear_cid($_mtcid,prop) hydropathy
        set _mt_err [catch {::VMDPathFinder::build_and_show_tunnel_mean_surface} _mt_msg]
        set _mt_base [file join $::VMDPathFinder::tunnel_root mean_profile "tunnel_mean_c${_mtcid}"]
        set _mt_pc [_plot_colors "${_mt_base}_hydropathy.plot"]
        set _mt_name [expr {$::VMDPathFinder::tunnel_mean_surface_mol >= 0 ? \
            [molinfo $::VMDPathFinder::tunnel_mean_surface_mol get name] : ""}]
        report "the averaged Mean Profile tube is property-colored, not one flat color" \
               [expr {!$_mt_err && $_mt_pc ne "MISSING" && $_mt_pc > 1}] \
               "(err=$_mt_err/$_mt_msg colors=$_mt_pc)"
        report "...and its name says the property was averaged over the same frames" \
               [expr {[string match "*MEAN over*" $_mt_name] \
                   && [string match "*hydropathy averaged*" $_mt_name]}] "(name=$_mt_name)"
        # Color changes must rebuild it: the guard used to be the cluster id
        # alone, so switching back to a flat color left the property-colored
        # tube on screen.
        set _sv_mbk [expr {[info exists ::VMDPathFinder::_tunnel_mean_built_cid] ? \
            $::VMDPathFinder::_tunnel_mean_built_cid : ""}]
        set ::VMDPathFinder::_tunnel_mean_built_cid [::VMDPathFinder::_tunnel_mean_build_key]
        set ::VMDPathFinder::tunnel_gear_cid($_mtcid,colormode) auto
        report "the tube's rebuild guard notices a color change, not just a new route" \
               [expr {[::VMDPathFinder::_tunnel_mean_build_key] ne $::VMDPathFinder::_tunnel_mean_built_cid}] \
               "(before=$::VMDPathFinder::_tunnel_mean_built_cid after=[::VMDPathFinder::_tunnel_mean_build_key])"
        catch {::VMDPathFinder::build_and_show_tunnel_mean_surface}
        set _mt_name2 [expr {$::VMDPathFinder::tunnel_mean_surface_mol >= 0 ? \
            [molinfo $::VMDPathFinder::tunnel_mean_surface_mol get name] : ""}]
        report "...and a flat-colored tube stops claiming a property" \
               [expr {![string match "*averaged over the same frames*" $_mt_name2]}] "(name=$_mt_name2)"
        if {$::VMDPathFinder::tunnel_mean_surface_mol >= 0} {
            catch {mol delete $::VMDPathFinder::tunnel_mean_surface_mol}
        }
        set ::VMDPathFinder::tunnel_mean_surface_mol -1
        unset -nocomplain ::VMDPathFinder::_tunnel_mean_built_cid
        if {$_sv_mbk ne ""} { set ::VMDPathFinder::_tunnel_mean_built_cid $_sv_mbk }
        foreach {_f _v} [list colormode $_sv_gcm prop $_sv_gpr] {
            if {$_v eq ""} { array unset ::VMDPathFinder::tunnel_gear_cid $_mtcid,$_f } \
            else { set ::VMDPathFinder::tunnel_gear_cid($_mtcid,$_f) $_v }
        }
        rename _plot_colors {}

        # heatmap_photo is ONE image shared by draw_heatmap and
        # draw_tunnel_heatmap. Two independent cache guards over it meant a hit
        # on either could re-blit the other mode's photo (tunnel -> pore ->
        # tunnel showed HOLE's map). Simulated here by planting a foreign photo
        # under a HOLE-shaped key, which is exactly what a mode round-trip left
        # behind.
        set ::VMDPathFinder::state(heatmap_scheme) viridis
        ::VMDPathFinder::draw_heatmap
        update idletasks; update
        set _hmt1 [_hm_sample]
        catch {image delete $::VMDPathFinder::heatmap_photo}
        set ::VMDPathFinder::heatmap_photo [image create photo -width 200 -height 200]
        $::VMDPathFinder::heatmap_photo put "#ff00ff" -to 0 0 200 200
        set ::VMDPathFinder::hm_render_cache "hole-mode-key"
        ::VMDPathFinder::draw_heatmap
        update idletasks; update
        report "a foreign photo in the shared heatmap image is not re-blitted" \
               [expr {[_hm_sample] eq $_hmt1}] "(leaked)"

        # --- Export filename collisions: two exports of different data must
        # never suggest the same default -initialfile. Shadow tk_getSaveFile
        # AGAIN (the loop above's shadow ignored -initialfile entirely) to
        # capture the suggested name instead of writing anything, using this
        # section's still-live 4-frame tunnel fixture (90101-90104) so the
        # multi-frame exports don't bail before ever reaching the dialog.
        rename ::tk_getSaveFile ::tk_getSaveFile_orig_expfn
        proc ::tk_getSaveFile {args} {
            global _capname
            set _capname ""
            foreach {k v} $args { if {$k eq "-initialfile"} { set _capname $v } }
            return ""
        }
        set _sv_tsel [expr {[info exists ::VMDPathFinder::state(tunnel_selected_id)] ? \
            $::VMDPathFinder::state(tunnel_selected_id) : ""}]
        ::VMDPathFinder::export_tunnel_trends_csv
        set _tt_name $_capname
        # What export_metrics_csv's HOLE-mode branch suggests for the SAME
        # tab token - the exact collision this fixes (both used to resolve
        # to "[_export_fig_stem trends].csv", so a tunnel bottleneck series
        # was offered under whatever HOLE metric the user last looked at).
        set _pore_would_be "[::VMDPathFinder::_export_fig_stem trends].csv"
        report "tunnel Trends export no longer collides with HOLE's channel-metrics export" \
               [expr {$_tt_name ne "" && $_tt_name ne $_pore_would_be}] \
               "(tunnel=$_tt_name pore-style=$_pore_would_be)"
        # Sabotage-checked by hand: reverting export_tunnel_trends_csv's
        # -initialfile back to "[_export_fig_stem trends].csv" turns this
        # FAIL (capture becomes identical to pore-style) - confirmed, then
        # restored.

        ::VMDPathFinder::export_tunnel_heatmap_csv
        set _th_name $_capname
        report "tunnel Over Time export is no longer a fixed name shared by every tunnel" \
               [expr {$_th_name ne "" && $_th_name ne "over_time_tunnel_data.csv" \
                   && [string match "*tunnel${_sv_tsel}_*_data*" $_th_name]}] \
               "(got=$_th_name)"
        # Sabotage-checked by hand: reverting to the fixed "over_time_tunnel_
        # data.csv" turns this FAIL - confirmed, then restored.

        # ...and the two QUANTITIES it can show (radius / property) are
        # different data, so they must not share one filename either.
        set _sv_cby [expr {[info exists ::VMDPathFinder::state(heatmap_color_by)] ? \
            $::VMDPathFinder::state(heatmap_color_by) : "radius"}]
        set _sv_tprop [expr {[info exists ::VMDPathFinder::state(tunnel_prop)] ? \
            $::VMDPathFinder::state(tunnel_prop) : "none"}]
        set ::VMDPathFinder::state(tunnel_prop) hydropathy
        set ::VMDPathFinder::state(heatmap_color_by) property
        ::VMDPathFinder::export_tunnel_heatmap_csv
        set _thp_name $_capname
        set ::VMDPathFinder::state(heatmap_color_by) $_sv_cby
        set ::VMDPathFinder::state(tunnel_prop) $_sv_tprop
        report "tunnel Over Time property export is named for the property, not radius" \
               [expr {$_thp_name ne "" && $_thp_name ne $_th_name \
                   && [string match "*hydropathy*" $_thp_name]}] \
               "(radius=$_th_name property=$_thp_name)"

        set _sv_ifc $::VMDPathFinder::ion_flow_cache
        set _sv_ifv [expr {[info exists ::VMDPathFinder::state(ion_flow_view)] ? \
            $::VMDPathFinder::state(ion_flow_view) : ""}]
        set ::VMDPathFinder::state(ion_flow_view) density
        set ::VMDPathFinder::ion_flow_cache [dict create species POT]
        ::VMDPathFinder::export_ion_flow_csv
        set _if_k $_capname
        set ::VMDPathFinder::ion_flow_cache [dict create species CLA]
        ::VMDPathFinder::export_ion_flow_csv
        set _if_cl $_capname
        set ::VMDPathFinder::ion_flow_cache [dict create species All]
        ::VMDPathFinder::export_ion_flow_csv
        set _if_all $_capname
        report "ion-flow grid export names differ by species" \
               [expr {$_if_k ne "" && $_if_k ne $_if_cl && $_if_cl ne $_if_all \
                   && $_if_k ne $_if_all}] \
               "(POT=$_if_k CLA=$_if_cl All=$_if_all)"
        set ::VMDPathFinder::state(ion_flow_view) passage
        set ::VMDPathFinder::ion_flow_cache [dict create species POT traces {x}]
        ::VMDPathFinder::export_ion_flow_csv
        set _ip_k $_capname
        set ::VMDPathFinder::ion_flow_cache [dict create species CLA traces {x}]
        ::VMDPathFinder::export_ion_flow_csv
        set _ip_cl $_capname
        report "ion-passage export names differ by species too (same bug, separate hardcoded name)" \
               [expr {$_ip_k ne "" && $_ip_k ne $_ip_cl}] "(POT=$_ip_k CLA=$_ip_cl)"
        # Sabotage-checked by hand: reverting either -initialfile back to the
        # bare "ion_flow_rz.csv"/"ion_passage.csv" collapses the K+/Cl- pair
        # to one string, turning the matching report FAIL - confirmed, then
        # restored.
        set ::VMDPathFinder::ion_flow_cache $_sv_ifc
        set ::VMDPathFinder::state(ion_flow_view) $_sv_ifv

        report "_export_frame_range_tag ranges an unordered frame list" \
               [expr {[::VMDPathFinder::_export_frame_range_tag {12 3 7}] eq "_f3-12"}] \
               "(got=[::VMDPathFinder::_export_frame_range_tag {12 3 7}])"
        report "_export_frame_range_tag is empty-safe (no dangling separator)" \
               [expr {[::VMDPathFinder::_export_frame_range_tag {}] eq ""}] \
               "(got=[::VMDPathFinder::_export_frame_range_tag {}])"

        rename ::tk_getSaveFile {}
        rename ::tk_getSaveFile_orig_expfn ::tk_getSaveFile

        set ::VMDPathFinder::state(heatmap_scheme) $_hsv_sch
        array unset ::VMDPathFinder::tunnel_results 901??
        array unset ::VMDPathFinder::tunnel_lining 901??
        set ::VMDPathFinder::tunnel_result_frames $_hsv_trf
        array set ::VMDPathFinder::tunnel_results $_hsv_tr
        ::VMDPathFinder::_tunnel_xframe_build

        # --- Item 1: landing on a frame the SELECTED tunnel is absent from
        #     must not say "run HOLE"/"run the tunnel search" (a pore-mode
        #     placeholder leaking through, or ignoring a real selection) and
        #     must not blank the trajectory-wide analyses (Over Time/Trends/
        #     Mean/Histogram summarise the whole trajectory, not "now"; only
        #     Pore Profile is a genuinely per-frame view). Synthetic 3-frame
        #     fixture: the pinned cluster present in 97701/97703, genuinely
        #     absent (empty frame, not just a different rank) from 97702.
        set _af_svtrf $::VMDPathFinder::tunnel_result_frames
        set _af_svtr  [array get ::VMDPathFinder::tunnel_results]
        set _af_svcid [expr {[info exists ::VMDPathFinder::state(tunnel_selected_cid)] ? $::VMDPathFinder::state(tunnel_selected_cid) : ""}]
        set _af_svid  [expr {[info exists ::VMDPathFinder::state(tunnel_selected_id)]  ? $::VMDPathFinder::state(tunnel_selected_id)  : ""}]
        proc _af_pts {x0 rmid} {
            set p {}
            foreach dz {0 1 2 3 4} r [list [expr {$rmid+2}] [expr {$rmid+1}] $rmid [expr {$rmid+1}] [expr {$rmid+2}]] {
                lappend p $x0 0.0 [expr {double($dz)}] $r
            }
            return $p
        }
        array unset ::VMDPathFinder::tunnel_results 977??
        set ::VMDPathFinder::tunnel_results(97701) [list [list 1.0 4.0 0 0 [_af_pts 0.0 1.0]]]
        set ::VMDPathFinder::tunnel_results(97702) {}
        set ::VMDPathFinder::tunnel_results(97703) [list [list 1.0 4.0 0 0 [_af_pts 0.0 1.0]]]
        set ::VMDPathFinder::tunnel_result_frames {97701 97702 97703}
        set ::VMDPathFinder::binned_cache [dict create]
        set ::VMDPathFinder::hm_bundle_cache [dict create]
        ::VMDPathFinder::_tunnel_xframe_build
        set _af_cid $::VMDPathFinder::tunnel_xcid(97701,1)
        set ::VMDPathFinder::state(tunnel_selected_cid) $_af_cid
        # The pin survives an absent frame as "" - _tunnel_sync_selected_id's
        # own real behaviour (proved elsewhere in this file/headless_smoke.tcl);
        # set directly here since molinfo's own frame count has nothing to do
        # with this synthetic frame numbering.
        set ::VMDPathFinder::state(tunnel_selected_id) ""

        $w.plotframe.nb select $w.plotframe.nb.profile
        update idletasks; update
        ::VMDPathFinder::draw_tunnel_profile_plot
        update idletasks; update
        set _pp_cv $w.plotframe.nb.profile.plotarea.cv
        set _pp_txt ""
        catch {
            foreach _it [$_pp_cv find withtag all] {
                if {[$_pp_cv type $_it] eq "text"} { append _pp_txt "[$_pp_cv itemcget $_it -text]|" }
            }
        }
        report "absent-frame Pore Profile does not say 'run HOLE'" \
               [expr {![string match -nocase "*run hole*" $_pp_txt]}] "(text=$_pp_txt)"
        report "absent-frame Pore Profile does not redirect to 'run the tunnel search' (a real selection already exists)" \
               [expr {![string match "*Run the tunnel search*" $_pp_txt]}] "(text=$_pp_txt)"
        report "absent-frame Pore Profile says the tunnel is absent from THIS frame" \
               [expr {[string match -nocase "*absent*frame*" $_pp_txt]}] "(text=$_pp_txt)"
        catch {exec import -window [winfo id $w] $SHOT/absent_frame_profile.png}

        $w.plotframe.nb select $w.plotframe.nb.minr
        update idletasks; update
        ::VMDPathFinder::draw_tunnel_trends_plot
        update idletasks; update
        set _tr_items 0
        catch {set _tr_items [llength [$w.plotframe.nb.minr.cv find all]]}
        set _tr_ph 0
        catch {set _tr_ph [winfo ismapped $w.plotframe.nb.minr.placeholder]}
        report "Trends does not blank on the absent-DISPLAYED-frame (real content, no placeholder)" \
               [expr {$_tr_items > 3 && !$_tr_ph}] "(items=$_tr_items placeholder_shown=$_tr_ph)"
        catch {exec import -window [winfo id $w] $SHOT/absent_frame_trends.png}

        $w.plotframe.nb select $w.plotframe.nb.heatmap
        update idletasks; update
        ::VMDPathFinder::draw_tunnel_heatmap
        update idletasks; update
        set _ov_items 0
        catch {set _ov_items [llength [$w.plotframe.nb.heatmap.cv find all]]}
        set _ov_ph 0
        catch {set _ov_ph [winfo ismapped $w.plotframe.nb.heatmap.placeholder]}
        report "Over Time does not blank on the absent-DISPLAYED-frame" \
               [expr {$_ov_items > 3 && !$_ov_ph}] "(items=$_ov_items placeholder_shown=$_ov_ph)"
        catch {exec import -window [winfo id $w] $SHOT/absent_frame_overtime.png}

        $w.plotframe.nb select $w.plotframe.nb.mean
        update idletasks; update
        ::VMDPathFinder::draw_mean_profile
        update idletasks; update
        set _mp_items 0
        catch {set _mp_items [llength [$w.plotframe.nb.mean.cv find all]]}
        set _mp_ph 0
        catch {set _mp_ph [winfo ismapped $w.plotframe.nb.mean.placeholder]}
        report "Mean Profile does not blank on the absent-DISPLAYED-frame" \
               [expr {$_mp_items > 3 && !$_mp_ph}] "(items=$_mp_items placeholder_shown=$_mp_ph)"
        catch {exec import -window [winfo id $w] $SHOT/absent_frame_mean.png}

        $w.plotframe.nb select $w.plotframe.nb.hist
        update idletasks; update
        ::VMDPathFinder::draw_histogram_tab
        update idletasks; update
        set _hs_items 0
        catch {set _hs_items [llength [$w.plotframe.nb.hist.cv find all]]}
        set _hs_ph 0
        catch {set _hs_ph [winfo ismapped $w.plotframe.nb.hist.placeholder]}
        report "Histogram does not blank on the absent-DISPLAYED-frame" \
               [expr {$_hs_items > 3 && !$_hs_ph}] "(items=$_hs_items placeholder_shown=$_hs_ph)"
        catch {exec import -window [winfo id $w] $SHOT/absent_frame_hist.png}

        array unset ::VMDPathFinder::tunnel_results 977??
        set ::VMDPathFinder::tunnel_result_frames $_af_svtrf
        array set ::VMDPathFinder::tunnel_results $_af_svtr
        set ::VMDPathFinder::state(tunnel_selected_cid) $_af_svcid
        set ::VMDPathFinder::state(tunnel_selected_id) $_af_svid
        set ::VMDPathFinder::binned_cache [dict create]
        set ::VMDPathFinder::hm_bundle_cache [dict create]
        ::VMDPathFinder::_tunnel_xframe_build
        $w.plotframe.nb select $w.plotframe.nb.profile
        update idletasks; update

        # --- Controls that do nothing in tunnel mode must be ABSENT ---
        # draw_tunnel_heatmap reads no heatmap_radius_source (no per-slice
        # ellipse fit for a branching path) and no HOLE property SCHEME (the
        # property comes from the tunnel list's own gear), and
        # draw_tunnel_trends_plot reads no metric at all, so those pickers were
        # live controls with no effect. "Residues..." was worse:
        # show_bottleneck_residues renders HOLE's own bottleneck residues,
        # under a tunnel tab. "Color by" is NOT in this list any more - it
        # drives the radius/property split the checks below exercise.
        set _heb $w.plotframe.nb.heatmap.exportbar
        set _teb $w.plotframe.nb.minr.exportbar
        ::VMDPathFinder::_update_heatmap_picker_visibility
        ::VMDPathFinder::_sync_trends_exportbar_for_mode
        update idletasks
        set _inert {}
        foreach _c {rsrc psch pcompute} {
            if {[winfo manager $_heb.$_c] ne ""} { lappend _inert heatmap.$_c }
        }
        foreach _c {ml metric gear resb} {
            if {[winfo manager $_teb.$_c] ne ""} { lappend _inert trends.$_c }
        }
        report "no inert HOLE-only control is left on the tunnel Over Time/Trends rows" \
               [expr {[llength $_inert] == 0}] "(still shown: $_inert)"
        # Export must be the RIGHT-MOST control on the Trends row. With -side
        # right the packing list fills from the right edge inward, so a -before
        # $eb.export put Residues past it. Checked by PIXELS, not pack order.
        $w.sidebar.nb select $w.sidebar.nb.hole
        set ::VMDPathFinder::state(trends_metric) min_r
        ::VMDPathFinder::_sync_trends_resb
        ::VMDPathFinder::_sync_trends_exportbar_for_mode
        update idletasks; update
        if {[winfo manager $_teb.resb] ne "" && [winfo manager $_teb.export] ne ""} {
            set _rx [expr {[winfo x $_teb.resb] + [winfo width $_teb.resb]}]
            set _ex [expr {[winfo x $_teb.export] + [winfo width $_teb.export]}]
            report "Trends: Export sits to the RIGHT of Residues" \
                   [expr {$_ex > $_rx}] \
                   "(residues right edge=$_rx, export right edge=$_ex)"
        } else {
            report "Trends: Export sits to the RIGHT of Residues" 0 \
                   "(one of resb/export is not packed under Min R)"
        }
        # Back to Tunnel mode: the checks that follow are tunnel-mode ones and
        # this block is nested inside them. Leaving the notebook on the HOLE tab
        # made two later assertions fail for the wrong reason.
        $w.sidebar.nb select $w.sidebar.nb.tunnel
        ::VMDPathFinder::_sync_trends_exportbar_for_mode
        update idletasks; update
        report "the tunnel Over Time row keeps its Color picker and ⚙" \
               [expr {[winfo manager $_heb.sch] ne "" && [winfo manager $_heb.schl] ne "" \
                   && [winfo manager $_heb.gear] ne ""}]
        report "the tunnel Over Time row offers Color by (radius/property)" \
               [expr {[winfo manager $_heb.cby] ne ""}]

        report "the tunnel Trends row keeps Export" \
               [expr {[winfo manager $_teb.export] ne ""}]

        # Passability used to unconditionally read state(selected_result_frame)
        # (a HOLE-only variable run_tunnel_analysis never sets) and show "No
        # frame selected - run HOLE first." even after a real tunnel run - a
        # real bug found and fixed this session. metrics_for_tunnel gives it
        # real geometry (volume, species pass/block) from the selected
        # tunnel's own radius-vs-distance series; conductance stays honestly
        # absent (needs HOLE's TSV-derived Sum(ds/pi r^2), which MOLE never
        # computes) rather than a hand-rolled substitute.
        ::VMDPathFinder::show_passability_dialog
        update idletasks; update
        set pd $w.passability
        set pbody_ok [expr {[winfo exists $pd.body.s1] && ![winfo exists $pd.body.none]}]
        set psum [expr {$pbody_ok ? [$pd.body.s1 cget -text] : "(HOLE placeholder shown)"}]
        report "tunnel Passability shows real per-tunnel data, not the HOLE placeholder" \
               $pbody_ok "($psum)"
        if {$pbody_ok} {
            report "tunnel Passability explains conductance is unavailable, doesn't fake it" \
                   [winfo exists $pd.body.cond.na] ""
        }
        report "Ellipse G is disabled for tunnels (no HOLE equivalent)" \
               [expr {[$pd.btn.ell cget -state] eq "disabled"}] "(ell=[$pd.btn.ell cget -state])"
        # CSV export is NOT disabled in tunnel mode - it's re-routed to the
        # species-table export (export_passability_species_csv), which the
        # whole-trajectory export_metrics_csv has no tunnel equivalent of.
        report "Export CSV is re-routed to the species table in tunnel mode, not disabled" \
               [expr {[$pd.btn.csv cget -state] eq "normal" \
                      && [$pd.btn.csv cget -command] eq "::VMDPathFinder::export_passability_species_csv"}] \
               "(csv=[$pd.btn.csv cget -state] cmd=[$pd.btn.csv cget -command])"
        catch {destroy $pd}

        # The tunnel graphics mol is created with `mol new`, which makes that
        # 0-frame mol VMD's TOP molecule. VMD drives `animate forward` off top, so
        # leaving it there froze playback outright (Play looked dead), and with
        # state(molid) at its "top" default resolve_molid returned the graphics mol
        # - frame_changed then dropped every frame write for the protein and
        # _tunnel_display_frame read a molecule that only ever has frame 0.
        # Sabotage check: without the restore, `animate goto` leaves top's frame -1.
        set _tsm [::VMDPathFinder::ensure_tunnel_surface_mol $mid]
        report "tunnel graphics mol does not steal VMD's top molecule" \
               [expr {[molinfo top] == $mid}] \
               "(top=[molinfo top] protein=$mid tunnelmol=$_tsm)"
        # Must be checked against the "top" DEFAULT: this harness sets
        # state(molid) numerically, and with a numeric molid resolve_molid cannot
        # be fooled - the check would pass against the very bug it guards.
        set _sv_molid $::VMDPathFinder::state(molid)
        set ::VMDPathFinder::state(molid) "top"
        set _rm [::VMDPathFinder::resolve_molid]
        set ::VMDPathFinder::state(molid) $_sv_molid
        report "resolve_molid still finds the trajectory, not the graphics mol" \
               [expr {$_rm == $mid}] "(resolve_molid=$_rm protein=$mid)"

        # ---- Ion Flow in tunnel mode (J16) ----------------------------------
        # Ion Flow measures every ion as (z along ONE straight axis, R from it).
        # That frame is only meaningful for a near-straight pathway: on the
        # 60-tunnel pentamer fixture the side tunnels bend 20-62% of their axial
        # span off their own PCA axis, so a point INSIDE such a tunnel reads as
        # R ~ 33 A and is indistinguishable from bulk. Hence the gate, and hence
        # these checks - the tab being present is not the same as it being right.
        report "Ion Flow is offered in tunnel mode" \
               [expr {[lsearch -exact [::VMDPathFinder::_mode_tab_set tunnel] ionflow] >= 0}] \
               "(tabs=[::VMDPathFinder::_mode_tab_set tunnel])"

        set ifm [::VMDPathFinder::resolve_molid]
        set iff [::VMDPathFinder::_tunnel_display_frame]
        set gth [::VMDPathFinder::_tunnel_flow_gather $ifm $iff]
        # 4 fields = {centers radii atoms axis}, the same shape _asym_gather
        # hands _ion_flow_scan, so the R-Z machinery needs no other branch.
        report "tunnel gather returns a real centreline+axis+atoms for Ion Flow" \
               [expr {[llength $gth] == 4 \
                      && [llength [lindex $gth 0]] >= 3 \
                      && [llength [lindex $gth 2]] >= 4 \
                      && [llength [lindex $gth 3]] == 6}] \
               "(n=[llength $gth] centers=[llength [lindex $gth 0]] atoms=[expr {[llength [lindex $gth 2]]/4}])"

        # Measured ALONG the route, on synthetic geometry so it does not depend
        # on which tunnel this fixture ranks first: an L-shaped route (10 A up
        # z, then 9 A along x). A point on the second leg reads as its arc
        # length with ~0 distance from the route; the old single-axis frame
        # put it several A off-axis, i.e. in bulk, and refused the tunnel.
        set _bnd {}; set _brad {}
        for {set i 0} {$i < 10} {incr i} { lappend _bnd [list 0 0 [expr {$i*1.0}]]; lappend _brad 1.5 }
        for {set i 1} {$i < 10} {incr i} { lappend _bnd [list [expr {$i*1.0}] 0 9.0]; lappend _brad 1.5 }
        set _bpath [::VMDPathFinder::_ion_flow_path_spheres $_bnd $_brad]
        lassign [::VMDPathFinder::_ion_flow_path_coord 5.0 0.0 9.0 $_bpath] _bs _br
        report "a bent route is measured along itself (arc length, distance from the route)" \
               [expr {abs($_bs-14.0) < 0.05 && $_br < 0.05}] \
               "(s=[format %.2f $_bs] R=[format %.2f $_br], want 14 and 0)"
        report "no curvature refusal is left in the tunnel gather" \
               [expr {[string first "TUNNEL_FLOW_MAX_CURVATURE" [info body ::VMDPathFinder::_tunnel_flow_gather]] < 0}] ""

        # The ion scan is measured in one mode's R-Z frame; carrying it across a
        # mode switch would render HOLE data under the tunnel tab.
        set ::VMDPathFinder::ion_flow_cache "sentinel-not-real-data"
        $w.sidebar.nb select $w.sidebar.nb.hole
        update idletasks; update
        report "switching modes clears the ion-flow cache" \
               [expr {$::VMDPathFinder::ion_flow_cache eq ""}] \
               "(cache=$::VMDPathFinder::ion_flow_cache)"
        $w.sidebar.nb select $w.sidebar.nb.tunnel
        update idletasks; update

        # Leaving HOLE mode must hide EVERY displayed HOLE surface, not just
        # one. _solo_surface makes pore/mean/ellipse exclusive WITHIN HOLE
        # mode, but the P/M/T status-row buttons do a plain mol on/off and
        # bypass it, so several really can be on at once - and the old code
        # kept a single tag that the scan loop overwrote, hiding only the last.
        # Sabotage-checked: restoring the single-tag version leaves 2 of 3 on.
        set _svp $::VMDPathFinder::current_surface_mol
        set _svm $::VMDPathFinder::mean_surface_mol
        set _sve $::VMDPathFinder::ellipse_surface_mol
        set _svw $::VMDPathFinder::_hole_surface_was_shown
        set _fake {}
        foreach _nm {t_pore t_mean t_ell} { set _m [mol new]; mol rename $_m $_nm; mol on $_m; lappend _fake $_m }
        lassign $_fake ::VMDPathFinder::current_surface_mol ::VMDPathFinder::mean_surface_mol ::VMDPathFinder::ellipse_surface_mol
        set ::VMDPathFinder::_hole_surface_was_shown ""
        $w.sidebar.nb select $w.sidebar.nb.hole
        update idletasks; update
        $w.sidebar.nb select $w.sidebar.nb.tunnel
        update idletasks; update
        set _nvis 0
        foreach _m $_fake { if {![catch {molinfo $_m get displayed} _d] && $_d} { incr _nvis } }
        report "leaving HOLE mode hides ALL displayed pore surfaces, not just one" \
               [expr {$_nvis == 0}] "(still displayed=$_nvis of 3, remembered=$::VMDPathFinder::_hole_surface_was_shown)"
        $w.sidebar.nb select $w.sidebar.nb.hole
        update idletasks; update
        set _nback 0
        foreach _m $_fake { if {![catch {molinfo $_m get displayed} _d] && $_d} { incr _nback } }
        report "returning to HOLE mode restores every surface that was showing" \
               [expr {$_nback == 3}] "(restored=$_nback of 3)"
        # Same round-trip, for the two exportbars tunnel mode strips down. The
        # controls are HIDDEN there, never reset, so HOLE mode must get all of
        # them back AND keep the user's own metric choice.
        set _gone {}
        foreach _c {cby rsrc sch schl} {
            if {[winfo manager $w.plotframe.nb.heatmap.exportbar.$_c] eq ""} {
                lappend _gone heatmap.$_c
            }
        }
        foreach _c {ml metric resb} {
            if {[winfo manager $w.plotframe.nb.minr.exportbar.$_c] eq ""} {
                lappend _gone trends.$_c
            }
        }
        report "returning to HOLE mode restores the Over Time / Trends controls" \
               [expr {[llength $_gone] == 0}] "(missing: $_gone)"
        report "the mode round-trip does not reset trends_metric" \
               [expr {$::VMDPathFinder::state(trends_metric) eq "min_r"}] \
               "(is $::VMDPathFinder::state(trends_metric))"
        foreach _m $_fake { catch {mol delete $_m} }
        set ::VMDPathFinder::current_surface_mol $_svp
        set ::VMDPathFinder::mean_surface_mol    $_svm
        set ::VMDPathFinder::ellipse_surface_mol $_sve
        set ::VMDPathFinder::_hole_surface_was_shown $_svw
        $w.sidebar.nb select $w.sidebar.nb.tunnel
        update idletasks; update

        # Same class of bug Passability had: _run_ion_flow read HOLE's
        # state(selected_result_frame) unconditionally, so tunnel mode could
        # only ever answer "Run HOLE first". Both set-ups below are required for
        # the check to discriminate - without either, it passed against the
        # restored bug (found by sabotage): a session carrying a HOLE frame
        # never reaches the message, and the ">= 2 frames" guard returns first
        # on this single-frame fixture.
        set _sv_srf $::VMDPathFinder::state(selected_result_frame)
        set _sv_tnf [info body ::VMDPathFinder::traj_numframes]
        set ::VMDPathFinder::state(selected_result_frame) ""
        proc ::VMDPathFinder::traj_numframes {args} { return 2 }
        set ::VMDPathFinder::state(status) ""
        catch {::VMDPathFinder::_run_ion_flow}
        report "tunnel Ion Flow does not tell the user to run HOLE first" \
               [expr {![string match -nocase "*run hole*" $::VMDPathFinder::state(status)]}] \
               "(status=$::VMDPathFinder::state(status))"
        proc ::VMDPathFinder::traj_numframes {} $_sv_tnf
        set ::VMDPathFinder::state(selected_result_frame) $_sv_srf

        # _ion_flow_scan's tunnel branch must resolve EACH frame's tuple via
        # _tunnel_rank_in_frame (the cross-frame cluster's own rank in that
        # frame), not a fixed rank computed once outside the loop - a fixed
        # rank only accidentally matches the right tunnel in another frame and
        # starves rprof on any frame with fewer tunnels than that rank number.
        # Call-counted rather than checked by output: this fixture has no
        # rank churn to make wrong/right visibly differ, but the resolver must
        # still be invoked once per frame either way.
        rename ::VMDPathFinder::_tunnel_rank_in_frame ::VMDPathFinder::_trif_orig_t5
        set ::_trif_calls_t5 0
        proc ::VMDPathFinder::_tunnel_rank_in_frame {frame} {
            incr ::_trif_calls_t5
            return [::VMDPathFinder::_trif_orig_t5 $frame]
        }
        catch {::VMDPathFinder::_ion_flow_scan $ifm $iff}
        report "Ion Flow's tunnel scan resolves each frame's rank via _tunnel_rank_in_frame" \
               [expr {$::_trif_calls_t5 >= [llength $::VMDPathFinder::tunnel_result_frames]}] \
               "(calls=$::_trif_calls_t5 frames=[llength $::VMDPathFinder::tunnel_result_frames])"
        rename ::VMDPathFinder::_tunnel_rank_in_frame {}
        rename ::VMDPathFinder::_trif_orig_t5 ::VMDPathFinder::_tunnel_rank_in_frame

        # And the bulk-boundary reference lines _draw_ion_passage_view's own
        # docstring promises alongside the constriction plane - previously
        # never drawn in either mode.
        set _sv_ifc $::VMDPathFinder::ion_flow_cache
        set _sv_ifv [expr {[info exists ::VMDPathFinder::state(ion_flow_view)] ? $::VMDPathFinder::state(ion_flow_view) : "density"}]
        set ::VMDPathFinder::ion_flow_cache [dict create zmin -10.0 zmax 10.0 zc 0.0 \
            bulk_lo -6.0 bulk_hi 6.0 traces {} nframes 5 box_lz 0.0 species "All" nions 3]
        set ::VMDPathFinder::state(ion_flow_view) passage
        # The canvas must actually be the mapped tab: _draw_ion_passage_view
        # bails out on an unmapped/1x1 canvas (winfo width/height), same as
        # every other plot canvas in this file.
        set _sv_pf_tab [$w.plotframe.nb select]
        $w.plotframe.nb select $w.plotframe.nb.ionflow
        update idletasks; update
        catch {::VMDPathFinder::_draw_ion_passage_view}
        update idletasks; update
        set _cv $w.plotframe.nb.ionflow.cv
        set _nbulk 0
        if {[winfo exists $_cv]} {
            foreach _it [$_cv find withtag all] {
                if {[$_cv type $_it] eq "line" && ![catch {$_cv itemcget $_it -fill} _fc] && $_fc eq "#999999"} { incr _nbulk }
            }
        }
        report "Ion Passage draws the bulk-boundary reference lines its docstring promises" \
               [expr {$_nbulk == 2}] "(grey dashed lines found=$_nbulk)"
        set ::VMDPathFinder::ion_flow_cache $_sv_ifc
        set ::VMDPathFinder::state(ion_flow_view) $_sv_ifv
        $w.plotframe.nb select $_sv_pf_tab
        update idletasks; update

        # Out-of-bounds regression (2a): draw_ion_flow_tab's realize-guard.
        # grid'ing the canvas and drawing into it in the SAME event loop turn
        # (no update idletasks between them) reads STALE Tk geometry (width 1),
        # which _draw_ion_flow_occupancy's own "$W < 80" size gate then bails
        # on - the canvas sits blank with zero drawn items until some LATER
        # event (a <Configure> firing once Tk actually lays it out) redraws it.
        # Reproduced here by recreating the canvas fresh (genuinely never
        # mapped, same as the very first time a session opens this tab) and
        # calling the public entry point with no settling update in between -
        # exactly what a real first-open does.
        $w.plotframe.nb select $w.plotframe.nb.ionflow
        set _ifcv $w.plotframe.nb.ionflow.cv
        destroy $_ifcv
        canvas $_ifcv -bg white -highlightthickness 0
        # Same binding build_gui gives the real canvas, guard included - a
        # stand-in that schedules differently from the product is testing
        # itself.
        bind $_ifcv <Configure> \
            [list ::VMDPathFinder::_on_plot_tab_configure ionflow {::VMDPathFinder::draw_ion_flow_tab}]
        set ::VMDPathFinder::ion_flow_cache [dict create nr 10 nz 20 zmin -15.0 zmax 15.0 \
            r_cut 8.0 rmax_hole 6.0 occ_pct [lrepeat 200 5.0] vr [lrepeat 200 0.2] \
            vz [lrepeat 200 0.2] cnt [lrepeat 200 4] \
            rprof {{-15.0 6.0} {0.0 0.8} {15.0 6.0}} \
            up 1 down 1 net 0 species "All" nions 5 nused 5 zc 0.0]
        set ::VMDPathFinder::state(ion_flow_view) density
        ::VMDPathFinder::draw_ion_flow_tab
        set _ni_immediate [llength [$_ifcv find withtag all]]
        report "a freshly-realized Ion Flow canvas does not silently stay blank forever" \
               [expr {$_ni_immediate > 0}] "(items right after the first draw call=$_ni_immediate - 0 means it is relying entirely on a LATER redraw to ever show anything)"

        after 300 {set ::_go_ifguard 1}; vwait ::_go_ifguard
        update idletasks; update
        set _ni_settled [llength [$_ifcv find withtag all]]
        report "...and a subsequent redraw (deferred by the guard, or the <Configure> it also relies on) does fill it in" \
               [expr {$_ni_settled > 10}] "(items after settling=$_ni_settled)"
        # Sabotage-checked by hand: removing the "update idletasks; if {[winfo
        # width $cv] <= 1} {after ...; return}" block from draw_ion_flow_tab
        # turns the FIRST report above FAIL (immediate items=0) - confirmed,
        # then restored.

        # Out-of-bounds regression (2a): the bottom axis caption ("R from pore
        # axis"/"Z along pore axis"/"Frame") must not draw past the canvas's
        # own bottom edge. Measured directly via canvas bbox, not by eye -
        # anchor n at a fixed H-12/H-10 offset does not know the real glyph
        # height and pushed a couple of pixels past H.
        update idletasks
        set _ifW [winfo width $_ifcv]; set _ifH [winfo height $_ifcv]
        set _ifout 0
        foreach _it [$_ifcv find withtag all] {
            set _bb [$_ifcv bbox $_it]
            if {$_bb eq ""} continue
            lassign $_bb _x0 _y0 _x1 _y1
            if {$_x0 < -1 || $_y0 < -1 || $_x1 > $_ifW+1 || $_y1 > $_ifH+1} { incr _ifout }
        }
        # The PLOT RECT, not just the canvas. The original check compared against
        # the canvas width/height, so a cell overflowing the axes by a few
        # pixels passed while being plainly visible - which is exactly what the
        # user reported. _ionflow_geo carries the rect the axes were drawn in.
        if {[info exists ::VMDPathFinder::ion_flow_geo] && [dict size $::VMDPathFinder::ion_flow_geo]} {
            set _pl [dict get $::VMDPathFinder::ion_flow_geo ml]
            set _pt [dict get $::VMDPathFinder::ion_flow_geo mt]
            set _pw [dict get $::VMDPathFinder::ion_flow_geo pw]
            set _ph [dict get $::VMDPathFinder::ion_flow_geo ph]
            set _over 0; set _worst ""
            # Only the DATA cells: the color bar and axis labels live in the
            # margins by design, and a check that flagged them would be noise.
            set _ncell 0
            foreach _it [$_ifcv find withtag ionflow_cell] {
                incr _ncell
                set _bb [$_ifcv bbox $_it]
                if {[llength $_bb] != 4} continue
                lassign $_bb _x0 _y0 _x1 _y1
                # +2 tolerance: bbox includes the 1px outline Tk adds.
                if {$_x1 > $_pl+$_pw+2 || $_x0 < $_pl-2
                    || $_y1 > $_pt+$_ph+2 || $_y0 < $_pt-2} {
                    incr _over
                    set _worst "x=$_x0..$_x1 y=$_y0..$_y1 rect=$_pl,$_pt..[expr {$_pl+$_pw}],[expr {$_pt+$_ph}]"
                }
            }
            report "(setup) occupancy cells were actually drawn" [expr {$_ncell > 0}] "(cells=$_ncell)"
            report "no occupancy cell draws outside the PLOT rect" \
                   [expr {$_over == 0}] "(overflowing=$_over/$_ncell $_worst)"
        }
        report "no Ion Flow occupancy-view item draws past the canvas edge" \
               [expr {$_ifout == 0}] "(canvas=${_ifW}x${_ifH}, items outside=$_ifout)"
        # Sabotage-checked by hand: reverting the axis-caption fix (anchor n at
        # H-12/H-10 instead of anchor s at H-6) turns this FAIL (1 offending
        # text item, bbox bottom a few px past H) - confirmed, then restored.

        # Out-of-bounds regression (2a-ii): the wall/shell curves and the flux
        # arrows, which the cell clamp above never covered. rprof runs BEYOND
        # zmin/zmax here, as it does on real data.
        #
        # Grid is coarse on purpose: arrow length is 1.4*min(dr,dzc) and the
        # loop samples every other bin, so on the 10x20 grid above no arrow can
        # reach the axes and the arrow half would pass unfixed. rmax_hole 3.0
        # widens the shell so the outermost bin is not clipped away first.
        set ::VMDPathFinder::ion_flow_cache [dict create nr 5 nz 6 zmin -15.0 zmax 15.0 \
            r_cut 8.0 rmax_hole 3.0 occ_pct [lrepeat 30 5.0] vr [lrepeat 30 0.9] \
            vz [lrepeat 30 0.9] cnt [lrepeat 30 4] \
            rprof {{-24.0 7.5} {-15.0 6.0} {0.0 0.8} {15.0 6.0} {24.0 7.5}} \
            up 1 down 1 net 0 species "All" nions 5 nused 5 zc 0.0]
        ::VMDPathFinder::draw_ion_flow_tab
        update idletasks
        if {[info exists ::VMDPathFinder::ion_flow_geo] && [dict size $::VMDPathFinder::ion_flow_geo]} {
            set _pl [dict get $::VMDPathFinder::ion_flow_geo ml]
            set _pt [dict get $::VMDPathFinder::ion_flow_geo mt]
            set _pw [dict get $::VMDPathFinder::ion_flow_geo pw]
            set _ph [dict get $::VMDPathFinder::ion_flow_geo ph]
            # Tolerance is the drawn geometry: a 2px line plus Tk's bbox pixel
            # measures 3px past an edge it is clipped exactly to. The bug
            # overshot by ~170px.
            foreach {_tag _label _tol} {ionflow_wall "wall/shell curve" 4
                                        ionflow_arrow "flux arrow" 4} {
                set _n 0; set _bad 0; set _worst ""
                foreach _it [$_ifcv find withtag $_tag] {
                    incr _n
                    set _bb [$_ifcv bbox $_it]
                    if {[llength $_bb] != 4} continue
                    lassign $_bb _x0 _y0 _x1 _y1
                    if {$_x1 > $_pl+$_pw+$_tol || $_x0 < $_pl-$_tol
                        || $_y1 > $_pt+$_ph+$_tol || $_y0 < $_pt-$_tol} {
                        incr _bad
                        set _worst "x=$_x0..$_x1 y=$_y0..$_y1 rect=$_pl,$_pt..[expr {$_pl+$_pw}],[expr {$_pt+$_ph}]"
                    }
                }
                report "(setup) $_label segments were actually drawn" [expr {$_n > 0}] "(items=$_n)"
                report "no $_label draws outside the PLOT rect, even where the pore outruns the Z window" \
                       [expr {$_bad == 0}] "(overflowing=$_bad/$_n $_worst)"
            }
            # Clipped, not truncated: dropping out-of-range points would pass
            # the bounds check with a wall that stops short of the axes.
            set _wx0 1e30; set _wx1 -1e30
            foreach _it [$_ifcv find withtag ionflow_wall] {
                set _bb [$_ifcv bbox $_it]
                if {[llength $_bb] != 4} continue
                if {[lindex $_bb 0] < $_wx0} { set _wx0 [lindex $_bb 0] }
                if {[lindex $_bb 2] > $_wx1} { set _wx1 [lindex $_bb 2] }
            }
            report "...and the wall is CLIPPED at the window edge, not truncated short of it" \
                   [expr {$_wx0 <= $_pl+3 && $_wx1 >= $_pl+$_pw-3}] \
                   "(wall spans x=$_wx0..$_wx1, rect x=$_pl..[expr {$_pl+$_pw}])"
        }

        # Radius-mismatch documentation (2b): _ion_flow_scan's rprof is a
        # trajectory mean on a FIXED reference axis, not re-anchored to each
        # frame's own bottleneck the way Mean Profile is - measured on real
        # imported data (394-cluster fixture) to read systematically 0.18-0.26
        # A WIDER at the narrowest point, every time, across 3 clusters. The
        # figure's own wall-profile caption must say so, not just differ in
        # axis label wording.
        # The explanation moved OFF the figure (it made the plot chatty) and into
        # the view picker's tooltip - but it must still exist somewhere, so this
        # now checks the tooltip rather than the caption. The caption itself must
        # stay short: assert it does NOT carry the long form any more.
        set _ifitems [$_ifcv find withtag all]
        set _ifcap_long 0
        foreach _it $_ifitems {
            if {[$_ifcv type $_it] ne "text"} continue
            if {[catch {$_ifcv itemcget $_it -text} _txt]} continue
            if {[string match "*not bottleneck-anchored*" $_txt]} { set _ifcap_long 1; break }
        }
        # Over Time in tunnel mode had NO property picker: the bar packed only
        # "Color by" and the property lived in the tunnel list's gear, nowhere
        # near this tab.
        set _sv_cb $::VMDPathFinder::state(heatmap_color_by)
        $w.sidebar.nb select $w.sidebar.nb.tunnel
        set ::VMDPathFinder::state(heatmap_color_by) property
        catch {::VMDPathFinder::_update_heatmap_picker_visibility}
        update idletasks; update
        set _hmb $w.plotframe.nb.heatmap.exportbar
        report "tunnel Over Time in Property mode offers a property picker" \
               [expr {[winfo exists $_hmb.tprop] && [winfo manager $_hmb.tprop] ne ""}] \
               "(manager='[expr {[winfo exists $_hmb.tprop] ? [winfo manager $_hmb.tprop] : {no widget}}]')"
        if {[winfo exists $_hmb.tprop.m]} {
            report "...and it lists the MOLE properties" \
                   [expr {[$_hmb.tprop.m index end] ne "none" && [$_hmb.tprop.m index end] >= 8}] \
                   "(entries=[$_hmb.tprop.m index end])"
        }
        set ::VMDPathFinder::state(heatmap_color_by) radius
        catch {::VMDPathFinder::_update_heatmap_picker_visibility}
        update idletasks; update
        report "...and it disappears in Radius mode" \
               [expr {[winfo manager $_hmb.tprop] eq ""}] \
               "(manager='[winfo manager $_hmb.tprop]')"
        set ::VMDPathFinder::state(heatmap_color_by) $_sv_cb
        catch {::VMDPathFinder::_update_heatmap_picker_visibility}

        # Reported: "fill was on by default in tunnel mode". Entering tunnel
        # mode must not turn Fill on - the pickers are "hidden, not reset" on a
        # mode switch, so a HOLE-mode choice survives, but a fresh None must
        # stay None.
        $w.sidebar.nb select $w.sidebar.nb.hole
        set ::VMDPathFinder::state(profile_view_mode) none
        set ::VMDPathFinder::state(profile_color) 0
        catch {::VMDPathFinder::on_profile_view_mode_changed}
        update idletasks; update
        $w.sidebar.nb select $w.sidebar.nb.tunnel
        update idletasks; update
        report "entering Tunnel mode leaves Pore Profile Fill OFF" \
               [expr {$::VMDPathFinder::state(profile_view_mode) eq "none"
                      && !$::VMDPathFinder::state(profile_color)}] \
               "(view_mode=$::VMDPathFinder::state(profile_view_mode) color=$::VMDPathFinder::state(profile_color))"
        # ...and the picker must SAY None, not just hold it.
        report "...and the view-mode picker reads None" \
               [expr {$::VMDPathFinder::state(profile_view_mode_disp) eq "None"}] \
               "(disp='$::VMDPathFinder::state(profile_view_mode_disp)')"
        # The real report: Fill chosen in PORE mode must not arrive already on
        # when tunnel mode is first opened. The two modes used to share one
        # profile_view_mode.
        $w.sidebar.nb select $w.sidebar.nb.hole
        update idletasks; update
        set ::VMDPathFinder::state(profile_view_mode) fill
        catch {::VMDPathFinder::on_profile_view_mode_changed}
        update idletasks; update
        $w.sidebar.nb select $w.sidebar.nb.tunnel
        update idletasks; update
        report "Fill chosen in Pore mode does NOT carry into Tunnel mode" \
               [expr {$::VMDPathFinder::state(profile_view_mode) eq "none"}] \
               "(tunnel view_mode=$::VMDPathFinder::state(profile_view_mode))"
        $w.sidebar.nb select $w.sidebar.nb.hole
        update idletasks; update
        report "...and Pore mode still gets its own Fill back" \
               [expr {$::VMDPathFinder::state(profile_view_mode) eq "fill"}] \
               "(pore view_mode=$::VMDPathFinder::state(profile_view_mode))"
        set ::VMDPathFinder::state(profile_view_mode) none
        catch {::VMDPathFinder::on_profile_view_mode_changed}
        $w.sidebar.nb select $w.sidebar.nb.tunnel
        update idletasks; update

        # SUPERSEDED (C1/C4): the two are no longer a stacked pair. "Cluster
        # within frame" moved onto the Bottleneck row in the MOLE parameter
        # block, and "Show all" moved BELOW the list it filters. Their relative
        # y-order is now a consequence of that layout, asserted where each one
        # lives rather than against each other.
        if {[winfo exists $P.mp.xclus_within] && [winfo exists $P.tunctl.showall]} {
            report "tunnel panel: Show all now sits BELOW the clustering checkbox" \
                   [expr {[winfo rooty $P.tunctl.showall] > [winfo rooty $P.mp.xclus_within]}] \
                   "(showall y=[winfo rooty $P.tunctl.showall], cluster y=[winfo rooty $P.mp.xclus_within])"
        } else {
            report "tunnel panel: Show all now sits BELOW the clustering checkbox" 0 \
                   "(missing: showall=[winfo exists $P.tunctl.showall] cluster=[winfo exists $P.mp.xclus_within])"
        }
        report "the pore-wall caption is short - the long explanation is not on the figure" \
               [expr {!$_ifcap_long}] ""
        # add_tooltip stores the text inside the <Enter> binding script, so that
        # is where it has to be read from.
        set _iftt ""
        catch {set _iftt [bind $w.plotframe.nb.ionflow.exportbar.vwm <Enter>]}
        report "...but it still documents the per-slice-mean difference in the tooltip" \
               [string match "*per-slice mean*" $_iftt] "(tooltip: $_iftt)"

        set ::VMDPathFinder::ion_flow_cache $_sv_ifc
        set ::VMDPathFinder::state(ion_flow_view) $_sv_ifv
        $w.plotframe.nb select $_sv_pf_tab
        update idletasks; update

        # And the Lining window, with rows in it.
        ::VMDPathFinder::show_tunnel_lining
        update idletasks; update
        after 400 {set ::go5 1}; vwait ::go5
        # It is a child of the main window, not of ".", so name it directly
        # rather than scanning for a stray toplevel.
        set lw $w.tunlining
        report "the Lining window opened" [winfo exists $lw] \
               "(note: $::VMDPathFinder::state(tunnel_tab_note))"
        if {[winfo exists $lw]} {
            report "the Lining window has a real size" \
                   [expr {[winfo width $lw] > 100 && [winfo height $lw] > 100}] \
                   "([winfo width $lw]x[winfo height $lw])"
            set chars 0
            set body ""
            catch {set body [string trim [$lw.txt get 1.0 end]]}
            set chars [string length $body]
            report "the Lining window has rows in it, not an empty shell" \
                   [expr {$chars > 200}] "($chars characters)"
            # Default scope (2.6): exactly the SELECTED tunnel, not every
            # tunnel in the frame. 1BL8 auto-selects tunnel 1 of several found
            # (checked earlier) - the body must name it and no other tunnel.
            set ntun_headers [regexp -all -line {^Tunnel \d+\s} $body]
            set names_selected [expr {[string match "*Tunnel $::VMDPathFinder::state(tunnel_selected_id) *" $body]}]
            report "Lining defaults to the selected tunnel only, not every tunnel" \
                   [expr {$ntun_headers == 1 && $names_selected}] \
                   "($ntun_headers tunnel header(s) for selection $::VMDPathFinder::state(tunnel_selected_id))"
            # The HET row. It is rendered from the engine's H lines, and 1BL8 -
            # the default fixture - has no het residues, so this only means
            # anything on a structure that does. GUI_TEST_HET names the residue
            # the window must show; without it the check is skipped rather than
            # passing vacuously on a structure that could never fail it.
            if {[info exists ::env(GUI_TEST_HET)] && $::env(GUI_TEST_HET) ne ""} {
                # The window is scoped to the SELECTED tunnel by default (2.6),
                # and the auto-selected (widest-bottleneck) tunnel is not
                # necessarily the one carrying the HET residue - tick "show
                # all" first, the same thing a user would do to find it.
                set ::VMDPathFinder::state(tunnel_lining_show_all) 1
                ::VMDPathFinder::_refresh_tunnel_lining_body
                update idletasks; update
                set body [string trim [$lw.txt get 1.0 end]]
                set want $::env(GUI_TEST_HET)
                report "the Lining window shows the HET residue ($want)" \
                       [expr {[string first $want $body] >= 0}] \
                       "(not found in [string length $body] characters)"
            }
            catch {exec import -window [winfo id $lw] $SHOT/lining.png}
        }
        catch {exec import -window [winfo id $w] $SHOT/results.png}
    }

    # Save/Import Phase 2: tunnel-mode importer, mirroring HOLE's own. Reuses
    # this test's own already-computed run (tunnel_root/tunnel_results) as
    # the on-disk fixture rather than running a second search.
    if {$ntun > 0} {
        set _timp_root $::VMDPathFinder::tunnel_root
        report "collect_tunnel_frame_dirs finds this run's own frame folders" \
               [expr {[llength [::VMDPathFinder::collect_tunnel_frame_dirs $_timp_root]] > 0}] \
               "(root=$_timp_root)"

        # Snapshot the live in-memory data, then CLOBBER it, so a successful
        # reload can only have come from disk (out.dat), never from memory.
        array set _timp_orig_results {}
        array set _timp_orig_lining {}
        foreach _tfr $::VMDPathFinder::tunnel_result_frames {
            set _timp_orig_results($_tfr) $::VMDPathFinder::tunnel_results($_tfr)
            if {[info exists ::VMDPathFinder::tunnel_lining($_tfr)]} {
                set _timp_orig_lining($_tfr) $::VMDPathFinder::tunnel_lining($_tfr)
            }
        }
        set _timp_orig_frames $::VMDPathFinder::tunnel_result_frames
        array unset ::VMDPathFinder::tunnel_results; array set ::VMDPathFinder::tunnel_results {}
        array unset ::VMDPathFinder::tunnel_lining;  array set ::VMDPathFinder::tunnel_lining {}
        set ::VMDPathFinder::tunnel_result_frames {}
        set ::VMDPathFinder::tunnel_root ""

        ::VMDPathFinder::import_tunnel_results_from_folder $_timp_root
        set _timp_match 1
        foreach _tfr $_timp_orig_frames {
            if {![info exists ::VMDPathFinder::tunnel_results($_tfr)] \
                    || $::VMDPathFinder::tunnel_results($_tfr) ne $_timp_orig_results($_tfr)} {
                set _timp_match 0
            }
            if {[info exists _timp_orig_lining($_tfr)] \
                    && (![info exists ::VMDPathFinder::tunnel_lining($_tfr)] \
                        || $::VMDPathFinder::tunnel_lining($_tfr) ne $_timp_orig_lining($_tfr))} {
                set _timp_match 0
            }
        }
        report "import_tunnel_results_from_folder reconstructs tunnel_results/lining byte-identical from out.dat" \
               [expr {$::VMDPathFinder::tunnel_result_frames eq $_timp_orig_frames && $_timp_match}] \
               "(frames=$::VMDPathFinder::tunnel_result_frames match=$_timp_match)"

        # Missing out.dat must SKIP that frame, never fall back to .sph
        # (whose geometry is trimmed differently - see terminal-trim memory).
        # This fixture is single-frame only (frame_spec "now"), so removing
        # its one out.dat exercises the "nothing survived" refusal path
        # (its own tk_messageBox, stubbed to a no-op by the export tests
        # above - state(status) is deliberately left untouched on that path,
        # same as import_results_from_folder's own "no frame_* folders
        # found" refusal never touches it either) rather than the "N of M
        # skipped" partial-note path - test_tunnel_import.sh covers THAT
        # scenario headlessly with a real multi-frame trajectory. The
        # invariant that actually matters either way, and what this checks,
        # is that the frame is never silently present with wrong/missing data.
        set _tfr0 [lindex $_timp_orig_frames 0]
        set _tfd0 [file join $_timp_root [format "tunnel_%05d" $_tfr0]]
        set _tof0 [file join $_tfd0 out.dat]
        if {[file exists $_tof0]} {
            file rename $_tof0 "${_tof0}.bak"
            array unset ::VMDPathFinder::tunnel_results; array set ::VMDPathFinder::tunnel_results {}
            set ::VMDPathFinder::tunnel_result_frames {}
            ::VMDPathFinder::import_tunnel_results_from_folder $_timp_root
            report "a frame with a missing out.dat is never silently substituted" \
                   [expr {![info exists ::VMDPathFinder::tunnel_results($_tfr0)] \
                       && [lsearch -exact $::VMDPathFinder::tunnel_result_frames $_tfr0] < 0}] \
                   "(status: $::VMDPathFinder::state(status))"
            file rename "${_tof0}.bak" $_tof0
        }

        # Unified entry point must find tunnel data with NO HOLE data present
        # (this test's own work dir has none) and must not error/pop a
        # spurious "no HOLE results" message.
        set ::VMDPathFinder::state(import_dir) $_timp_root
        array unset ::VMDPathFinder::tunnel_results; array set ::VMDPathFinder::tunnel_results {}
        set ::VMDPathFinder::tunnel_result_frames {}
        set _tuni_rc [catch {::VMDPathFinder::import_all_results_from_folder} _tuni_err]
        report "import_all_results_from_folder loads a tunnel-only directory cleanly" \
               [expr {!$_tuni_rc && [llength $::VMDPathFinder::tunnel_result_frames] > 0}] \
               "(rc=$_tuni_rc err=$_tuni_err frames=$::VMDPathFinder::tunnel_result_frames)"

        # Restore the live in-memory data these checks clobbered, so nothing
        # downstream in this script sees a torn-down tunnel state.
        array unset ::VMDPathFinder::tunnel_results; array set ::VMDPathFinder::tunnel_results {}
        array unset ::VMDPathFinder::tunnel_lining;  array set ::VMDPathFinder::tunnel_lining {}
        foreach _tfr $_timp_orig_frames {
            set ::VMDPathFinder::tunnel_results($_tfr) $_timp_orig_results($_tfr)
            if {[info exists _timp_orig_lining($_tfr)]} {
                set ::VMDPathFinder::tunnel_lining($_tfr) $_timp_orig_lining($_tfr)
            }
        }
        set ::VMDPathFinder::tunnel_result_frames $_timp_orig_frames
        set ::VMDPathFinder::tunnel_root $_timp_root
        catch {::VMDPathFinder::refresh_tunnel_tab}
    }
} else {
    say "  SKIP  no engine binary or no $PDB - results phase not run"
}

# Help > Guide & Citations must actually document Tunnel mode - it was a
# real gap (the whole Guide tab was HOLE-only prose) until this batch added
# a dedicated section, mirroring the user's own original complaint.
::VMDPathFinder::show_about_dialog
update idletasks; update
set _guide_txt [$w.about.nb.guide.t get 1.0 end]
report "Guide tab documents Tunnel mode" \
       [expr {[string first "Tunnel mode" $_guide_txt] >= 0 \
           && [string first "Auto-detect origins" $_guide_txt] >= 0}] \
       "([string length $_guide_txt] characters)"
set _cite_txt [$w.about.nb.cite.t get 1.0 end]
report "Citations tab credits the permeation method" \
       [expr {[string first "Kutzner" $_cite_txt] >= 0 \
           && [string first "10.1016/j.bpj.2011.06.010" $_cite_txt] >= 0}] \
       "([string length $_cite_txt] characters)"
destroy $w.about

# ---- HOLE parameters gear: the MC controls must be VISIBLE, not just wired ----
# Wiring is unit-tested headlessly; this is the other half. Adding a row to a
# shared grid is exactly how this plugin has hidden controls before (the
# `ismapped` trap), so the check is GEOMETRIC - real width/height, inside the
# dialog's own bounds - rather than "does the widget exist".
# Built under CONNOLLY: the Connolly-only rows are hidden for other methods, and
# this block checks every row is drawn inside the window.
set _svpm0 $::VMDPathFinder::state(pore_method)
set _svse0 $::VMDPathFinder::state(search_engine)
set ::VMDPathFinder::state(pore_method) connolly
# Monte Carlo, because the MC rows checked below are hidden under Nelder-Mead
# by design (_update_search_rows). Without this the check fails or passes
# depending on what the saved config last selected.
set ::VMDPathFinder::state(search_engine) mc
::VMDPathFinder::show_hole_params_settings
::VMDPathFinder::_update_search_rows
update idletasks; update
set _hp $w.hole_params_settings
report "the HOLE parameters dialog opens" [winfo exists $_hp] ""
if {[winfo exists $_hp]} {
    wm deiconify $_hp
    update idletasks; update
    set _dh [winfo height $_hp]
    set _dw [winfo width  $_hp]
    report "the dialog has a real size" [expr {$_dw > 100 && $_dh > 60}] "${_dw}x${_dh}"
    foreach {_lbl _p} [list "MC steps" $_hp.hp.ms_e  "MC step size" $_hp.hp.md_e \
                            "MC kT" $_hp.hp.mk_e     "IGNORE" $_hp.hp.ig_e \
                            "Extra cards" $_hp.hp.ex_e "Pore method" $_hp.hp.pm_mb \
                            "sideways gate" $_hp.hp.cgate_c \
                            "atom-name rewriter" $_hp.hp.fixnm_c] {
        if {![winfo exists $_p]} { report "$_lbl exists" 0 "$_p missing"; continue }
        set _x [expr {[winfo rootx $_p] - [winfo rootx $_hp]}]
        set _y [expr {[winfo rooty $_p] - [winfo rooty $_hp]}]
        set _ww [winfo width $_p]; set _wh [winfo height $_p]
        report "$_lbl is drawn inside the dialog" \
            [expr {[winfo ismapped $_p] && $_ww > 4 && $_wh > 4 \
                   && $_x >= 0 && $_y >= 0 \
                   && $_x + $_ww <= $_dw && $_y + $_wh <= $_dh}] \
            "at ${_x},${_y} size ${_ww}x${_wh}"
    }
    # The Mean Profile's own call site, driven through collect_binned_radii:
    # its inversion of the fallback flags and its axis-range pick are wired
    # separately from the Pore Profile's and were otherwise only lint-checked.
    set _mcv $w.plotframe.nb.mean.cv
    if {[winfo exists $_mcv]} {
        # rename, not info args/info body: `info args` reports the NAMES only,
        # so re-creating the proc from it turns nbins's two OPTIONAL arguments
        # into required ones, and every 1-argument call after this point raises.
        rename ::VMDPathFinder::collect_binned_radii ::_real_cbr_mean
        proc ::VMDPathFinder::collect_binned_radii {args} {
            set st {}; set fb {}
            for {set b 0} {$b < 20} {incr b} {
                lappend st [list [expr {3.0 + 0.05*$b}] 0.2 2.5 3.9 5]
                lappend fb [expr {($b >= 5 && $b < 8) || ($b >= 13 && $b < 15) ? 1 : 0}]
            }
            # stats_raw as well as stats: binned_stats_for_mean returns the
            # RAW-POOLED set now (matching MDAnalysis bin_radii), so a stub with
            # only `stats` makes the whole draw error out and every assertion
            # below it reports "found 0" for reasons that have nothing to do
            # with what it is testing.
            return [dict create nframes 5 zmin -10.0 zstep 1.0 \
                stats $st stats_raw $st fallback $fb bins [lrepeat 20 {1 1 1 1 1}]]
        }
        # analysis_mode reads the sidebar tab, so put it on HOLE - an earlier
        # check may have left the notebook on the tunnel tab, which routes the
        # mean through _tunnel_collect_binned_radii instead.
        catch {$w.sidebar.nb select $w.sidebar.nb.hole}
        $w.plotframe.nb select $w.plotframe.nb.mean
        update idletasks
        catch {::VMDPathFinder::draw_mean_profile}
        update idletasks
        set _mm 0
        foreach _it [$_mcv find all] {
            if {[$_mcv type $_it] ne "rectangle"} continue
            if {[catch {$_mcv itemcget $_it -fill} _f]} continue
            if {$_f eq "#c8781e"} { incr _mm }
        }
        report "the Mean Profile marks both sideways openings" [expr {$_mm == 2}] "(found $_mm)"
        rename ::VMDPathFinder::collect_binned_radii {}
        rename ::_real_cbr_mean ::VMDPathFinder::collect_binned_radii
    } else {
        report "the Mean Profile canvas exists" 0 "$_mcv missing"
    }

    # A stub restored from `info args` drops the defaults, which silently makes
    # every 1-argument call downstream raise - it took out the Ion Flow scan.
    set _optok 1
    foreach _a {frame_list spec_key} {
        if {![info default ::VMDPathFinder::collect_binned_radii $_a _dflt]} { set _optok 0 }
    }
    report "collect_binned_radii still has its optional arguments" $_optok \
           "(args now: [info args ::VMDPathFinder::collect_binned_radii])"

    # A ttk notebook delivers <Configure> to EVERY tab's canvas. Both halves
    # matter: the guard must suppress the hidden tabs AND still be what the
    # bindings call, or a correct guard sits there unused.
    set _nb $w.plotframe.nb
    set _routed 0; set _tot 0; set _unrouted {}
    foreach _cvp [list $_nb.profile.plotarea $_nb.heatmap.cv $_nb.minr.cv $_nb.mean.cv \
                       $_nb.hist.cv $_nb.hydration.cv $_nb.ionflow.cv] {
        if {![winfo exists $_cvp]} { continue }
        incr _tot
        if {[string match "*_on_plot_tab_configure*" [bind $_cvp <Configure>]]} {
            incr _routed
        } else {
            lappend _unrouted "[lindex [split $_cvp .] end-1]/[lindex [split $_cvp .] end]=[bind $_cvp <Configure>]"
        }
    }
    report "every analysis tab's <Configure> goes through the visible-tab guard" \
           [expr {$_tot > 0 && $_routed == $_tot}] "($_routed of $_tot; unrouted: $_unrouted)"
    catch {$_nb select $_nb.mean}
    update idletasks
    set ::_GUARD_HIDDEN 0; set ::_GUARD_SHOWN 0
    ::VMDPathFinder::_on_plot_tab_configure hist {set ::_GUARD_HIDDEN 1}
    ::VMDPathFinder::_on_plot_tab_configure mean {set ::_GUARD_SHOWN 1}
    after 400 {set ::_gwait 1}; vwait ::_gwait
    report "a <Configure> on a HIDDEN analysis tab schedules no redraw" \
           [expr {$::_GUARD_HIDDEN == 0}] "(hidden tab ran anyway)"
    report "...and the visible tab still redraws" \
           [expr {$::_GUARD_SHOWN == 1}] "(visible tab did not run)"

    # Advanced Tunnel Parameters: the paired rows, and Align trajectory BELOW
    # Draft detail. Grid coordinates, not existence - every one of these
    # widgets existed before the layout change too.
    proc _adrow {p n} { return [dict get [grid info $p.$n] -row] }
    proc _adcol {p n} { return [dict get [grid info $p.$n] -column] }
    ::VMDPathFinder::show_tunnel_advanced_settings
    set _ad $w.tunnel_advanced_settings
    catch {wm deiconify $_ad}
    update idletasks
    report "Strict interior shares the Filter-boundary-layers row" \
        [expr {[_adrow $_ad fbl_c] == [_adrow $_ad strict_c] \
            && [_adcol $_ad strict_c] > [_adcol $_ad fbl_c]}] \
        "(fbl r[_adrow $_ad fbl_c]c[_adcol $_ad fbl_c] strict r[_adrow $_ad strict_c]c[_adcol $_ad strict_c])"
    report "Max deviation starts its row (the Seen floor moved to the panel)" \
        [expr {[_adcol $_ad mdev_l] == 0}] \
        "(maxdev r[_adrow $_ad mdev_l]c[_adcol $_ad mdev_l])"
    report "Align trajectory sits BELOW Draft detail" \
        [expr {[_adrow $_ad align_c] > [_adrow $_ad dsl]}] \
        "(align r[_adrow $_ad align_c] draft r[_adrow $_ad dsl])"
    report "Show cues and Scale bar share a row" \
        [expr {[_adrow $_ad spm_c] == [_adrow $_ad sbar_c] \
            && [_adcol $_ad sbar_c] > [_adcol $_ad spm_c]}] \
        "(cues r[_adrow $_ad spm_c]c[_adcol $_ad spm_c] bar r[_adrow $_ad sbar_c]c[_adcol $_ad sbar_c])"
    report "Path start and Path end share a row" \
        [expr {[_adrow $_ad mole_path_a_e] == [_adrow $_ad mole_path_b_e]}] \
        "(a r[_adrow $_ad mole_path_a_e] b r[_adrow $_ad mole_path_b_e])"
    # Ratchet, not a pixel-exact pin: 645 px before this batch, 482 after.
    report "the Advanced dialog stays under 560 px tall" \
        [expr {[winfo reqheight $_ad] <= 560}] "([winfo reqheight $_ad] px)"
    set _adunmapped {}
    foreach _adw {fbl_c strict_c mdev_l mdev_e dsl dse align_c spm_c sbar_c \
                  mole_exit_e mole_path_a_e mole_path_b_e exonly_c} {
        if {![winfo ismapped $_ad.$_adw]} { lappend _adunmapped $_adw }
    }
    report "...with every paired control still on screen" \
        [expr {[llength $_adunmapped] == 0}] "(unmapped: $_adunmapped)"
    catch {destroy $_ad}

    # The tunnel list's last row, in the order asked for, and no ellipsis on a
    # button that opens a window.
    set _tcl_order {}
    foreach _tc [pack slaves $P.tunctl] { lappend _tcl_order [lindex [split $_tc .] end] }
    set _il [lsearch -exact $_tcl_order lining]
    set _ip [lsearch -exact $_tcl_order prev]
    set _in [lsearch -exact $_tcl_order next]
    set _it [lsearch -exact $_tcl_order tlin]
    report "the tunnel row reads Lining, the arrows, then Show lining" \
        [expr {$_il >= 0 && $_il < $_ip && $_ip < $_in && $_in < $_it}] \
        "(order: $_tcl_order)"
    report "...and the Lining button carries no ellipsis" \
        [expr {[$P.tunctl.lining cget -text] eq "Lining"}] \
        "([$P.tunctl.lining cget -text])"

    # Window geometry: the main window asks for a size and must get it in ONE
    # wm call; a dialog that asks for none must stay free to size itself, or it
    # can never grow when its content does.
    report "the main window keeps its requested width" \
        [expr {abs([winfo width $w] - 1120) < 40}] "([winfo width $w])"
    report "a size-less dialog is not pinned by the geometry spec" \
        [expr {[::VMDPathFinder::_wm_geom_spec 0 800 600 10 10] eq "+10+10"}] \
        "([::VMDPathFinder::_wm_geom_spec 0 800 600 10 10])"
    report "...and an explicit size is written into it" \
        [expr {[::VMDPathFinder::_wm_geom_spec 1 800 600 10 10] eq "800x600+10+10"}] \
        "([::VMDPathFinder::_wm_geom_spec 1 800 600 10 10])"

    # Every knob I added must be REACHABLE, not merely a persisted state var.
    # Audit after three of them turned out to have no UI at all.
    ::VMDPathFinder::show_hole_params_settings
    update idletasks; update
    set _hg $w.hole_params_settings
    if {[winfo exists $_hg]} {
        set _svpmK $::VMDPathFinder::state(pore_method)
        set ::VMDPathFinder::state(pore_method) connolly
        ::VMDPathFinder::_update_conn_controls
        update idletasks
        # ONE dot-density field in the HOLE gear. The playback one belongs with
        # the other playback knob in Settings, not beside the real density.
        report "the HOLE gear has a single dot-density field" \
            [expr {![winfo exists $_hg.hp.cdd_e]}] ""
        # The atom-name rewriter is a property of the INPUT FILE, not of the pore
        # method, so it stays reachable whatever is selected. The block above
        # opens this dialog under CONNOLLY, which would hide a method-gated row.
        foreach _m {spherical capsule connolly} {
            set ::VMDPathFinder::state(pore_method) $_m
            ::VMDPathFinder::_update_conn_controls
            update idletasks
            report "the atom-name rewriter is reachable under $_m" \
                [expr {[winfo exists $_hg.hp.fixnm_c] && [winfo ismapped $_hg.hp.fixnm_c]}] \
                "(mapped=[winfo ismapped $_hg.hp.fixnm_c])"
        }
        # The mesh knob sets a CONNOLLY-only dot density, so it is shown only
        # there. The triangle knob applies to any method. Both are pore-only
        # (no tunnel-mode reader), so they live in the HOLE gear.
        # Both are sos_triangle knobs, so they live in Settings after the mesher
        # row and appear only when sos_triangle is the mesher.
        set _svpmP $::VMDPathFinder::state(pore_method)
        set _svmsP $::VMDPathFinder::state(mesher)
        ::VMDPathFinder::show_settings_dialog
        set _sd $::VMDPathFinder::_settings_d
        ::VMDPathFinder::_set_mesher sos sos_triangle
        update idletasks
        foreach _m {connolly spherical capsule} {
            set ::VMDPathFinder::state(pore_method) $_m
            ::VMDPathFinder::_update_method_dependent_controls
            update idletasks
            set _want [expr {$_m eq "connolly"}]
            report "the playback mesh knob shows only under connolly (at $_m)" \
                [expr {[winfo ismapped $_sd.ms_dd.e3] == $_want}] \
                "(mesh=[winfo ismapped $_sd.ms_dd.e3] want=$_want)"
            report "the playback triangle knob stays visible under $_m" \
                [winfo ismapped $_sd.ms_dd.e2] ""
            report "dot density stays visible under $_m" \
                [winfo ismapped $_sd.ms_dd.e] ""
        }
        ::VMDPathFinder::_set_mesher csg {Marching cubes}
        update idletasks
        report "the sos_triangle knobs hide under the marching-cubes mesher" \
            [expr {![winfo ismapped $_sd.ms_dd]}] ""
        report "...and the marching-cubes grid entries take their place" \
            [winfo ismapped $_sd.ms_vx] ""
        ::VMDPathFinder::_set_mesher $_svmsP [expr {$_svmsP eq "sos" ? "sos_triangle" : "Marching cubes"}]
        set ::VMDPathFinder::state(pore_method) $_svpmP
        ::VMDPathFinder::_update_method_dependent_controls
        set ::VMDPathFinder::state(pore_method) $_svpmK
        ::VMDPathFinder::_update_conn_controls
    }
    ::VMDPathFinder::show_settings_dialog
    update idletasks; update
    set _sd2 $w.settings
    if {[winfo exists $_sd2]} {
        wm deiconify $_sd2
        update idletasks; update
        # Pore-only knobs left general Settings for the HOLE gear (checked above).
        foreach _w {perf.ds_e perf.cd_e oc2 prebuild_c} {
            report "$_w is no longer in general Settings" \
                [expr {![winfo exists $_sd2.$_w]}] ""
        }
        destroy $_sd2
    }
    ::VMDPathFinder::show_mean_profile_settings
    update idletasks; update
    set _md $w.mean_settings
    if {[winfo exists $_md]} {
        wm deiconify $_md
        update idletasks; update
        # The averaged-occupancy VOLUME feature was removed entirely, so its
        # grid-spacing field must be GONE, not reachable.
        report "the removed volume grid spacing field is gone" \
            [expr {![winfo exists $_md.mv.e]}] \
            "(exists=[winfo exists $_md.mv.e])"
        # The straightness sample cap is no longer user-editable - it's a fixed
        # internal performance guard now, so its old field must be gone.
        report "the straightness sample cap field is gone" \
            [expr {![winfo exists $_md.sn]}] ""
        destroy $_md
    } else {
        report "the Mean Profile settings dialog opens" 0 "$_md missing"
    }

    # _cv_vtext must actually DRAW on whichever Tk this is. A lint pass and a
    # source grep both missed a broken rotate branch here, because nothing in the
    # suite ever called it - the profile then crashed on every redraw.
    set _vc .vmdpathfinder_vtext_probe
    catch {destroy $_vc}
    canvas $_vc -width 200 -height 200
    foreach {_tag _call} [list \
        "text first"  {-text "R (Å)" -anchor center -font {Helvetica 8}} \
        "opts first"  {-anchor n -font {Helvetica 9 bold} -text "Radius (Å)"} \
        "with fill"   {-text "Bottleneck" -fill "#333333" -anchor center}] {
        set _r [catch {::VMDPathFinder::_cv_vtext $_vc 20 100 {*}$_call} _e]
        report "_cv_vtext draws a rotated label ($_tag)" \
            [expr {!$_r && [string is integer -strict $_e]}] "($_e)"
    }
    report "it made one canvas item per call" [llength [$_vc find all]] ""
    destroy $_vc

    # Sideways openings must be MARKED, not only greyed. Drawn on a scratch
    # canvas in both orientations: the marks have to land on the channel axis,
    # which is X when Swap X/Y is off and Y when it is on.
    set _mc .vmdpathfinder_markcv
    catch {destroy $_mc}
    canvas $_mc -width 400 -height 300
    set _ml 50; set _mt 20; set _pw 300; set _ph 200
    set _runs [::VMDPathFinder::_conn_opening_runs {1 0 0 1 1 0 0 1} {0 1 2 3 4 5 6 7}]
    foreach {_sw _tag} {0 "along X" 1 "along Y"} {
        $_mc delete all
        ::VMDPathFinder::_draw_opening_marks $_mc $_runs 0 7 $_ml $_mt $_pw $_ph $_sw
        set _n 0; set _inside 1
        foreach _it [$_mc find all] {
            incr _n
            lassign [$_mc bbox $_it] _x0 _y0 _x1 _y1
            if {$_sw} {
                if {$_x1 > $_ml || $_y0 < $_mt || $_y1 > $_mt+$_ph} { set _inside 0 }
            } else {
                if {$_y0 < $_mt+$_ph || $_x0 < $_ml || $_x1 > $_ml+$_pw} { set _inside 0 }
            }
        }
        report "both openings are marked ($_tag)" [expr {$_n == 2}] "(found $_n)"
        report "the marks sit on the channel axis ($_tag)" $_inside ""
    }
    $_mc delete all
    ::VMDPathFinder::_draw_opening_marks $_mc {} 0 7 $_ml $_mt $_pw $_ph 0
    report "a pore that never opens sideways draws no marks" \
        [expr {[llength [$_mc find all]] == 0}] ""
    destroy $_mc

    # The atom-name rewriter is a HOLE PDB-parser limitation, so it belongs to the
    # HOLE gear, not general Settings - and it must not be left behind in both.
    ::VMDPathFinder::show_settings_dialog
    update idletasks; update
    set _sd $w.settings
    if {[winfo exists $_sd]} {
        wm deiconify $_sd
        update idletasks; update
        report "the settings window is not named for HOLE alone" \
            [expr {[wm title $_sd] eq "VMDPathFinder Settings"}] "(is '[wm title $_sd]')"
        report "the atom-name rewriter has left general Settings" \
            [expr {![winfo exists $_sd.oc2.fixnm_c]}] ""
        destroy $_sd
    } else {
        report "the Settings dialog opens" 0 "$_sd missing"
    }
    # Appearance, in the graphics gear: the legend label, and the ions on two rows.
    ::VMDPathFinder::show_scale_cutoff_settings
    update idletasks; update
    set _gd $w.scale_settings
    if {[winfo exists $_gd.ui.mrshow]} {
        report "the metrics checkbox reads 'Show legend'" \
            [expr {[$_gd.ui.mrshow cget -text] eq "Show legend"}] \
            "(is '[$_gd.ui.mrshow cget -text]')"
    } else {
        report "the legend checkbox exists" 0 "$_gd.ui.mrshow missing"
    }
    if {[winfo exists $_gd.ui.ions]} {
        set _rows {}
        foreach _c [winfo children $_gd.ui.ions] {
            set _r [dict get [grid info $_c] -row]
            if {[lsearch -exact $_rows $_r] < 0} { lappend _rows $_r }
        }
        report "the metrics ions wrap onto two rows" [expr {[llength $_rows] == 2}] \
            "(rows: [lsort $_rows])"
    } else {
        report "the metrics ions row exists" 0 "$_gd.ui.ions missing"
    }

    # The openings list: embedded in the left panel (not a popup), reachable
    # only while pore_lobes is the coloring, and it explains itself rather
    # than showing an empty list when it cannot be built.
    set _svpm3 $::VMDPathFinder::state(pore_method)
    set _svdm3 $::VMDPathFinder::state(display_mode)
    set _svsc3 $::VMDPathFinder::state(surface_color)
    set ::VMDPathFinder::state(pore_method) connolly
    set ::VMDPathFinder::state(display_mode) triangulated
    set ::VMDPathFinder::state(surface_color) hole_def
    ::VMDPathFinder::update_color_row_visibility $::VMDPathFinder::_runpanel
    update idletasks
    set _lp $::VMDPathFinder::_runpanel.lobepanel
    report "the openings panel exists (built once, shown/hidden)" \
        [winfo exists $_lp] ""
    report "...but is hidden for other colorings" \
        [expr {![winfo ismapped $_lp]}] ""
    set ::VMDPathFinder::state(surface_color) pore_lobes
    ::VMDPathFinder::update_color_row_visibility $::VMDPathFinder::_runpanel
    update idletasks
    report "...and appears with the per-opening coloring" \
        [winfo ismapped $_lp] ""
    # The tolerances moved into the global gear - they are set once and rarely
    # revisited, and inline they cost the list two rows of height.
    catch {::VMDPathFinder::show_conn_lobes_global_gear}
    update idletasks
    set _cg .vmdpathfinder.conn_gear
    report "the opening-match tolerances are reachable in the global gear" \
        [expr {[winfo exists $_cg.c.tf.z] && [winfo exists $_cg.c.tf.a] \
               && [winfo exists $_cg.c.sf.e]}] \
        "(gear=[winfo exists $_cg] tolz=[winfo exists $_cg.c.tf.z])"
    catch {destroy $_cg}
    report "it says why there is nothing to list" \
        [expr {[string length [$_lp.msg.l cget -text]] > 10}] \
        "('[$_lp.msg.l cget -text]')"
    # The row list must scroll on its own (many lateral openings can outgrow
    # the panel) without carrying the tolerance/margin controls above it out
    # of view - same _scrollable_fixed pattern as the tunnel list.
    # The reset sits in its own strip, not in the header grid, because the
    # header's data columns are pinned to the body's widths and push anything
    # past them off the right edge. Assert it is INSIDE the panel, which is
    # what "the reset button is not in the view" was.
    # Measured against the RUN PANEL's right edge in ROOT coords. Comparing it
    # to its own strip is vacuous: the strip grows with the header grid, so a
    # button carried off-screen still sits "inside" it.
    catch {::VMDPathFinder::_sync_conn_lobe_width}
    update idletasks
    # Reset now lives in the global gear (it kept being pushed off the header's
    # right edge). The gear button itself is what must stay on screen.
    set _panelr [expr {[winfo rootx $::VMDPathFinder::_runpanel] + [winfo width $::VMDPathFinder::_runpanel]}]
    # The global gear lives in the openings list header now - the duplicate that
    # sat beside Color was removed.
    set _lg $_lp.hdr.gg
    if {[winfo exists $_lg]} {
        set _rr [expr {[winfo rootx $_lg] + [winfo width $_lg]}]
        report "the global region gear is inside the panel width" \
            [expr {[winfo ismapped $_lg] && $_rr <= $_panelr && $_rr > 0}] \
            "(gear right=$_rr panel right=$_panelr)"
    } else {
        report "the global region gear is inside the panel width" 0 "(widget missing)"
    }
    # The scrollbar's lower arrow ran past the panel bottom because the row
    # canvas was a fixed height whatever room there was.
    if {[winfo exists $_lp.rows.sb]} {
        set _panelb [expr {[winfo rooty $::VMDPathFinder::_runpanel] + [winfo height $::VMDPathFinder::_runpanel]}]
        set _sbb [expr {[winfo rooty $_lp.rows.sb] + [winfo height $_lp.rows.sb]}]
        report "the openings scrollbar ends inside the panel" \
            [expr {$_sbb <= $_panelb && $_sbb > 0}] \
            "(scrollbar bottom=$_sbb panel bottom=$_panelb)"
    }
    # The scrollbar must not overlap the row canvas: sizing the canvas against
    # [winfo width] of an unmapped scrollbar (which reports 1) runs it ~12px
    # wide and clips the last column.
    if {[winfo exists $_lp.rows.c] && [winfo exists $_lp.rows.sb]} {
        set _cr [expr {[winfo rootx $_lp.rows.c] + [winfo width $_lp.rows.c]}]
        report "the openings scrollbar does not overlap the row canvas" \
            [expr {$_cr <= [winfo rootx $_lp.rows.sb]}] \
            "(canvas right=$_cr scrollbar x=[winfo rootx $_lp.rows.sb])"
    }
    # Real rows, so the body grid has content for the header to line up against.
    # Without them every body bbox is empty and an alignment check is vacuous.
    set _inner $_lp.rows.c.inner
    set _rr 0
    foreach {_sid _lab _seen _neck _ax _az} {
        0 Pore "100%" "2.1 / -"   12.5 0
        1 OP1  "84%"  "1.9 / 3.2" -8.4 271
        2 OP2  "7%"   "0.8 / 1.1" 21.0 95
    } {
        ::VMDPathFinder::_conn_lobe_row_panel $_inner $_rr $_sid $_lab $_seen $_neck 1 "" $_ax $_az
        incr _rr
    }
    catch {::VMDPathFinder::_conn_lobe_header_marks}
    catch {::VMDPathFinder::_sync_conn_lobe_header_columns}
    catch {pack forget $_lp.msg}
    catch {::VMDPathFinder::_sync_conn_lobe_width}
    update idletasks
    # The list must use the room it is given: it once stopped ~67px short
    # because _sync_conn_lobe_width charged it the height of two frames that
    # had moved into the global gear and were no longer on screen at all.
    # "Reaches the bottom" is only the right shape when there are MORE rows
    # than fit - a list showing every row it has is correctly sized to those
    # rows, and stretching it further is the empty trough the user reported as
    # "the scroll bar is too tall". So: fill the panel, OR show everything.
    set _panelb2 [expr {[winfo rooty $::VMDPathFinder::_runpanel] + [winfo height $::VMDPathFinder::_runpanel]}]
    set _gap [expr {$_panelb2 - [winfo rooty $_lp.rows.c] - [winfo height $_lp.rows.c]}]
    set _allshown [expr {[winfo height $_lp.rows.c] >= [winfo reqheight $_inner]}]
    report "the openings list uses the room it is given" \
        [expr {($_gap >= 0 && $_gap <= 24) || $_allshown}] \
        "(gap=${_gap}px canvas=[winfo height $_lp.rows.c] rows=[winfo reqheight $_inner])"
    report "no widget that moved to the global gear is still built in the panel" \
        [expr {![winfo exists $_lp.tol] && ![winfo exists $_lp.pers]}] ""
    # ...and when the rows DO fit, the canvas is sized to them exactly - no
    # empty trough below the last row, which is what "the scroll bar is too
    # tall" was.
    # FORCE the geometry, or this checks nothing: at the harness's own window
    # height the sizer's result can be right by luck.
    set _sv_geom [wm geometry $::VMDPathFinder::w]
    wm geometry $::VMDPathFinder::w 620x420
    update idletasks
    catch {::VMDPathFinder::_sync_conn_lobe_width}
    update idletasks
    set _needh [winfo reqheight $_inner]
    set _goth  [winfo height $_lp.rows.c]
    report "the openings list is no taller than the rows it holds" \
        [expr {$_goth <= $_needh}] "(canvas=${_goth}px rows=${_needh}px)"
    set _yv [$_lp.rows.c yview]
    report "...so a list that fits is not scrolled" \
        [expr {$_needh > $_goth || ([lindex $_yv 0] <= 0.001 && [lindex $_yv 1] >= 0.999)}] \
        "(yview=$_yv)"
    # Now the case that was BROKEN: more rows than the panel can show. The
    # canvas used to be floored at the rows' full height, so it grew past the
    # notebook tab that bounds it - the tab clipped the overflow, cutting the
    # last row and running the scrollbar below the panel, while yview stayed
    # 0-1 because the list "fit". It must be capped and SCROLL instead.
    for {set _sid 3} {$_sid <= 14} {incr _sid} {
        ::VMDPathFinder::_conn_lobe_row_panel $_inner $_rr $_sid "OP$_sid" "50%" "1.0 / 2.0" 1 "" 0.0 0
        incr _rr
    }
    catch {::VMDPathFinder::_sync_conn_lobe_header_columns}
    catch {::VMDPathFinder::_sync_conn_lobe_width}
    update idletasks
    set _needh2 [winfo reqheight $_inner]
    set _goth2  [winfo height $_lp.rows.c]
    set _panelb3 [expr {[winfo rooty $::VMDPathFinder::_runpanel] + [winfo height $::VMDPathFinder::_runpanel]}]
    set _canvb3  [expr {[winfo rooty $_lp.rows.c] + $_goth2}]
    report "a list too long for the panel stays inside it" \
        [expr {$_canvb3 <= $_panelb3}] "(canvas bottom=$_canvb3 panel bottom=$_panelb3)"
    set _yv2 [$_lp.rows.c yview]
    report "...and scrolls instead of overflowing" \
        [expr {$_needh2 <= $_goth2 || [lindex $_yv2 1] < 0.999}] \
        "(rows=${_needh2}px canvas=${_goth2}px yview=$_yv2)"
    # A part-row at the bottom edge reads as a bug, so the canvas is snapped to
    # a whole number of rows whenever it is scrolling.
    set _rowh 0
    catch {set _rowh [lindex [grid bbox $_inner 0 0] 3]}
    report "...showing whole rows, never a part row" \
        [expr {$_rowh <= 0 || $_needh2 <= $_goth2 || $_goth2 % $_rowh == 0}] \
        "(canvas=${_goth2}px row=${_rowh}px)"
    catch {wm geometry $::VMDPathFinder::w $_sv_geom}
    update idletasks
    # Back to the 3 rows the checks below expect.
    for {set _sid 3} {$_sid <= 14} {incr _sid} {
        foreach _c {sh nm se nk st ax az gr} { catch {grid forget $_inner.$_c$_sid} }
    }
    catch {::VMDPathFinder::_sync_conn_lobe_width}
    update idletasks
    # Left-aligned, and every body column pinned to its header column.
    set _misal {}
    for {set _c 0} {$_c < 8} {incr _c} {
        set _hb [grid bbox $_lp.hdr $_c 0]
        set _bb [grid bbox $_inner $_c 0]
        if {[llength $_hb] == 4 && [llength $_bb] == 4 \
                && [lindex $_hb 0] != [lindex $_bb 0]} {
            lappend _misal "$_c:[lindex $_hb 0]vs[lindex $_bb 0]"
        }
    }
    report "every openings column lines up with its header" \
        [expr {[llength $_misal] == 0}] "($_misal)"
    set _notw {}
    foreach {_hw _bw} {.s .se0 .n .nk0 .st .st0 .ax .ax0 .az .az0} {
        if {[$_lp.hdr$_hw cget -anchor] ne "w"} { lappend _notw "hdr$_hw" }
        if {[$_inner$_bw cget -anchor] ne "w"} { lappend _notw "body$_bw" }
    }
    report "the openings columns and their values are left-aligned" \
        [expr {[llength $_notw] == 0}] "($_notw)"
    # Units live in the TOOLTIP, not the header: these columns are too narrow to
    # spend width on a unit that never changes. % stays - it is what the number
    # IS, not a unit alongside it.
    set _hasunit {}
    foreach _hw {.n .st .ax .az} {
        set _t [$_lp.hdr$_hw cget -text]
        if {[string first \u00c5 $_t] >= 0 || [string first \u00b0 $_t] >= 0} {
            lappend _hasunit $_hw
        }
    }
    report "the openings columns spend no width on a unit" \
        [expr {[llength $_hasunit] == 0}] "($_hasunit)"
    set _lostunit {}
    foreach {_hw _u} {.n \u00c5 .st \u00c5 .ax \u00c5 .az degrees} {
        if {[string first $_u [bind $_lp.hdr$_hw <Enter>]] < 0} { lappend _lostunit $_hw }
    }
    report "...but every one of them still names it on hover" \
        [expr {[llength $_lostunit] == 0}] "($_lostunit)"
    # The global gear is the header's own version of the per-row gear, so it has
    # to sit in the same column at the same size.
    report "the global gear lines up with the per-row gears" \
        [expr {[$_lp.hdr.gg cget -font] eq [$_inner.gr0 cget -font] \
            && [lindex [grid bbox $_lp.hdr 7 0] 0] == [lindex [grid bbox $_inner 7 0] 0]}] \
        "(hdr=[lindex [grid bbox $_lp.hdr 7 0] 0] body=[lindex [grid bbox $_inner 7 0] 0])"
    # Export writes a file, so it goes after every field that is typed into.
    catch {::VMDPathFinder::show_conn_lobes_global_gear}
    update idletasks
    set _cg2 .vmdpathfinder.conn_gear
    if {[winfo exists $_cg2.c.el]} {
        set _exr [lindex [grid info $_cg2.c.el] [expr {[lsearch [grid info $_cg2.c.el] -row]+1}]]
        set _lastfield 0
        foreach _fw {tf sf mshf} {
            if {![winfo exists $_cg2.c.$_fw]} { continue }
            set _fr [lindex [grid info $_cg2.c.$_fw] [expr {[lsearch [grid info $_cg2.c.$_fw] -row]+1}]]
            if {$_fr > $_lastfield} { set _lastfield $_fr }
        }
        report "Export CSV is the last field in the all-regions gear" \
            [expr {$_exr > $_lastfield && $_lastfield > 0}] \
            "(export row=$_exr last typed field row=$_lastfield)"
    } else {
        report "Export CSV is the last field in the all-regions gear" 0 "(no export row)"
    }
    catch {destroy $_cg2}

    # Sorting must not resize a header column - the arrow slot is a figure space
    # when unsorted, so the requested width never changes.
    if {[winfo exists $_lp.hdr.s]} {
        # Drive _conn_lobe_header_marks DIRECTLY. Going through
        # _conn_lobe_sort_by is vacuous on this fixture: it ends in
        # _refresh_conn_lobes_panel, which bails with no site table, so the
        # header text never changes and the check passes no matter what.
        set _sv_sc [expr {[info exists ::VMDPathFinder::state(conn_lobe_sort_col)] ? $::VMDPathFinder::state(conn_lobe_sort_col) : ""}]
        set ::VMDPathFinder::state(conn_lobe_sort_col) ""
        ::VMDPathFinder::_conn_lobe_header_marks
        update idletasks
        set _w0 [winfo reqwidth $_lp.hdr.s]
        set ::VMDPathFinder::state(conn_lobe_sort_col) seen
        set ::VMDPathFinder::state(conn_lobe_sort_dir) -1
        ::VMDPathFinder::_conn_lobe_header_marks
        update idletasks
        set _w1 [winfo reqwidth $_lp.hdr.s]
        set ::VMDPathFinder::state(conn_lobe_sort_col) $_sv_sc
        ::VMDPathFinder::_conn_lobe_header_marks
        report "sorting does not change the Seen column width" \
            [expr {$_w0 == $_w1}] "(before=$_w0 after=$_w1)"
    }
    report "the openings row list is independently scrollable" \
        [expr {[winfo exists $_lp.rows.c] && [winfo exists $_lp.rows.sb] \
               && [winfo exists $_lp.rows.c.inner]}] \
        "(canvas=[winfo exists $_lp.rows.c] scrollbar=[winfo exists $_lp.rows.sb])"
    set ::VMDPathFinder::state(surface_color) $_svsc3
    set ::VMDPathFinder::state(display_mode) $_svdm3
    set ::VMDPathFinder::state(pore_method) $_svpm3
    ::VMDPathFinder::update_color_row_visibility $::VMDPathFinder::_runpanel

    # Under CONNOLLY the ellipse-derived choices must be ABSENT from their menus,
    # not greyed - and must come back, IN THEIR ORIGINAL ORDER, on switching to a
    # method that has a centreline. Restoring by each entry's saved index does
    # not: every hide shifts the entries after it, so the menu comes back
    # scrambled.
    proc _menu_labels {menu} {
        set out {}
        if {![winfo exists $menu]} { return {} }
        set n [$menu index end]
        if {$n eq "none" || $n eq ""} { return {} }
        for {set i 0} {$i <= $n} {incr i} {
            if {[catch {$menu type $i} t]} { continue }
            if {$t in {separator tearoff}} { continue }
            catch {lappend out [$menu entrycget $i -label]}
        }
        return $out
    }
    set _svpm9 $::VMDPathFinder::state(pore_method)
    set _tmenu $w.plotframe.nb.minr.exportbar.metric.m
    set ::VMDPathFinder::state(pore_method) spherical
    catch {::VMDPathFinder::_update_method_dependent_controls}
    update idletasks
    set _before [_menu_labels $_tmenu]
    set ::VMDPathFinder::state(pore_method) connolly
    catch {::VMDPathFinder::_update_method_dependent_controls}
    update idletasks
    set _during [_menu_labels $_tmenu]
    set ::VMDPathFinder::state(pore_method) spherical
    catch {::VMDPathFinder::_update_method_dependent_controls}
    update idletasks
    set _after [_menu_labels $_tmenu]
    report "ellipse metrics are HIDDEN under CONNOLLY, not greyed" \
           [expr {[lsearch -exact $_during "Ellipse Min R"] < 0 \
               && [lsearch -exact $_during "G (ellipse)"] < 0 \
               && [lsearch -exact $_before "Ellipse Min R"] >= 0}] \
           "(connolly menu: $_during)"
    report "...and come back in their original order" \
           [expr {$_after eq $_before}] "(before: $_before / after: $_after)"

    # HOLE refuses 2DMAPS under the capsule card outright, so the entry must be
    # gone - and the build must say why if a saved config selected it anyway.
    set _vmenu $w.plotframe.nb.profile.exportbar.viewmode.m
    set ::VMDPathFinder::state(pore_method) spherical
    catch {::VMDPathFinder::_update_method_dependent_controls}
    update idletasks
    set _ubefore [_menu_labels $_vmenu]
    set ::VMDPathFinder::state(pore_method) capsule
    catch {::VMDPathFinder::_update_method_dependent_controls}
    update idletasks
    set _uduring [_menu_labels $_vmenu]
    # No HOLE run needed: the refusal is a property of the card combination, so
    # _2dmap_build has to give it before it looks at results or its cache.
    if {[catch {::VMDPathFinder::_2dmap_build [lindex [concat $::VMDPathFinder::result_frames 0] 0]} _urefuse]} {
        set _urefuse "ERROR: $_urefuse"
    }
    set ::VMDPathFinder::state(pore_method) spherical
    catch {::VMDPathFinder::_update_method_dependent_controls}
    update idletasks
    set _uafter [_menu_labels $_vmenu]
    report "the Unrolled map is HIDDEN under CAPSULE, not greyed" \
           [expr {[lsearch -exact $_uduring "Unrolled map"] < 0 \
               && [lsearch -exact $_ubefore "Unrolled map"] >= 0}] \
           "(capsule menu: $_uduring)"
    report "...and comes back in its original place for spherical" \
           [expr {$_uafter eq $_ubefore}] "(before: $_ubefore / after: $_uafter)"
    report "...and building one under CAPSULE refuses with a reason" \
           [string match "*capsule*" $_urefuse] "($_urefuse)"
    set ::VMDPathFinder::state(pore_method) $_svpm9
    catch {::VMDPathFinder::_update_method_dependent_controls}

    # The Connolly knobs must be gone - not merely greyed - for other methods,
    # and back when CONNOLLY is selected again.
    set ::VMDPathFinder::state(pore_method) spherical
    ::VMDPathFinder::_update_conn_controls
    update idletasks
    set _hidden 1; set _enabled 0
    foreach _c {cgate_c} {
        # Not catch-guarded: a widget that stopped existing must fail as a
        # named missing knob, not as an errored group.
        report "the gear knob $_c still exists" [winfo exists $_hp.hp.$_c] 1
        if {[winfo exists $_hp.hp.$_c] && [winfo ismapped $_hp.hp.$_c]} { set _hidden 0 }
        catch {if {[$_hp.hp.$_c cget -state] ne "disabled"} { set _enabled 1 }}
    }
    report "the Connolly knobs are hidden for spherical" $_hidden ""
    report "...and disabled, not just hidden" [expr {!$_enabled}] ""
    set ::VMDPathFinder::state(pore_method) connolly
    ::VMDPathFinder::_update_conn_controls
    update idletasks
    set _shown 1
    foreach _c {cgate_c} {
        if {![winfo exists $_hp.hp.$_c] || ![winfo ismapped $_hp.hp.$_c]} { set _shown 0 }
    }
    report "the Connolly knobs come back under CONNOLLY" $_shown ""
    set ::VMDPathFinder::state(pore_method) $_svpm0
    set ::VMDPathFinder::state(search_engine) $_svse0
    ::VMDPathFinder::_update_conn_controls

    # pore_lat splits the CONNOLLY cloud, so it is offered only under CONNOLLY -
    # removed from the menu entirely outside it, not just disabled.
    set _sc $::VMDPathFinder::_runpanel.hs_box.sc.m
    if {[winfo exists $_sc]} {
        set _svm $::VMDPathFinder::state(pore_method)
        set ::VMDPathFinder::state(pore_method) spherical
        ::VMDPathFinder::_update_method_dependent_controls
        report "pore_lat is absent for spherical" \
            [expr {[catch {$_sc index pore_lat}]}] ""
        # Watermelon: a colour MODE beside hole_def, on every picker that
        # colours a surface, and its ten VMD colour slots load on demand.
        report "watermelon is offered on the pore surface colour picker" \
            [expr {![catch {$_sc index watermelon}]}] ""
        report "...and on the Mean Profile colour picker" \
            [expr {![catch {$w.plotframe.nb.mean.exportbar.sc.m index watermelon}]}] ""
        ::VMDPathFinder::_watermelon_apply_vmd_colors
        report "the watermelon slots carry the band RGBs (slot 1047 black, 1056 white)" \
            [expr {[lindex [colorinfo rgb 1047] 0] < 0.01 && [lindex [colorinfo rgb 1056] 0] > 0.99}] \
            "(1047 [colorinfo rgb 1047]; 1056 [colorinfo rgb 1056])"
        report "watermelon keeps the plot's own colours in the renderer gate" \
            [expr {[string first {hole_def watermelon property} [info body ::VMDPathFinder::render_vmd_plot_to_mol]] >= 0}] ""
        # Time/frame lives on the shared Frames bar and drives every per-frame axis.
        report "the Frames bar has the Time/frame entry and unit menu" \
            [expr {[winfo exists $w.bottom.options.tf] && [winfo exists $w.bottom.options.tfu]}] ""
        set ::VMDPathFinder::state(frame_time) 0.5
        ::VMDPathFinder::_frame_time_unit_pick ps
        report "a set time per frame retitles the frame axis with its unit" \
            [expr {[::VMDPathFinder::_frame_axis_label] eq "Time (ps)" && [::VMDPathFinder::_frame_tick_text 4] eq "2.00"}] \
            "([::VMDPathFinder::_frame_axis_label] / [::VMDPathFinder::_frame_tick_text 4])"
        set ::VMDPathFinder::state(frame_time) ""
        ::VMDPathFinder::_frame_time_unit_pick ns
        report "an empty field goes back to bare frame numbers" \
            [expr {[::VMDPathFinder::_frame_axis_label] eq "Frame" && [::VMDPathFinder::_frame_tick_text 4] eq "4"}] ""
        # Ion & Water is measured against ONE run's pore; a new run (the same
        # clear every settings change goes through) must drop it rather than
        # leave the old map on screen.
        set _sv_ifr $::VMDPathFinder::ion_flow_raw; set _sv_ifc $::VMDPathFinder::ion_flow_cache
        set _sv_res $::VMDPathFinder::results; set _sv_rf $::VMDPathFinder::result_frames
        set _sv_pdv $::VMDPathFinder::plot_data_version
        set ::VMDPathFinder::ion_flow_raw [dict create nframes 3 frame_ref 0]
        set ::VMDPathFinder::ion_flow_cache [dict create species K+ nions 1]
        ::VMDPathFinder::clear_results_for_new_settings
        report "a new run clears the Ion & Water result" \
            [expr {$::VMDPathFinder::ion_flow_raw eq "" && $::VMDPathFinder::ion_flow_cache eq ""}] ""
        set ::VMDPathFinder::ion_flow_raw $_sv_ifr; set ::VMDPathFinder::ion_flow_cache $_sv_ifc
        set ::VMDPathFinder::results $_sv_res; set ::VMDPathFinder::result_frames $_sv_rf
        set ::VMDPathFinder::plot_data_version $_sv_pdv
        set ::VMDPathFinder::state(pore_method) connolly
        # The real click path: the menu entry's own -command, not a state poke.
        set ::VMDPathFinder::state(display_mode) triangulated
        ::VMDPathFinder::_update_method_dependent_controls
        report "pore_lat is offered under CONNOLLY" \
            [expr {[$_sc entrycget pore_lat -state] eq "normal"}] ""
        eval [$_sc entrycget pore_lat -command]
        report "clicking pore_lat selects it" \
            [expr {$::VMDPathFinder::state(surface_color) eq "pore_lat"}] \
            "(got $::VMDPathFinder::state(surface_color))"
        ::VMDPathFinder::update_color_row_visibility $::VMDPathFinder::_runpanel
        update idletasks
        report "pore_lat hides the Property picker" \
            [expr {![winfo ismapped $::VMDPathFinder::_runpanel.hs_box.m]}] ""
        set ::VMDPathFinder::state(display_mode) dots
        ::VMDPathFinder::_update_method_dependent_controls
        report "pore_lat is not offered for dots" \
            [expr {[catch {$_sc index pore_lat}]}] ""
        set ::VMDPathFinder::state(display_mode) triangulated
        set ::VMDPathFinder::state(surface_color) pore_lat
        set ::VMDPathFinder::state(pore_method) spherical
        ::VMDPathFinder::_update_method_dependent_controls
        report "leaving CONNOLLY drops the pore_lat coloring" \
            [expr {$::VMDPathFinder::state(surface_color) ne "pore_lat"}] \
            "(now $::VMDPathFinder::state(surface_color))"
        set ::VMDPathFinder::state(pore_method) $_svm
        ::VMDPathFinder::_update_method_dependent_controls
    } else {
        report "the surface color menu exists" 0 "$_sc missing"
    }

    # Mean Profile's 3D mode picker is NEVER shown. The averaged-occupancy
    # Volume mode was removed, so _sync_mean_3d_mode_entries deletes that entry
    # and pins the mode to Isosurface - which left the menubutton offering
    # exactly ONE choice under CONNOLLY, where it used to be packed. A dropdown
    # with a single option is not a control, and the two procs were
    # contradicting each other. These four cases were the OLD contract; they
    # now assert the picker stays hidden in every one of them.
    set _mmode $w.plotframe.nb.mean.exportbar.mode
    set _mbar $w.plotframe.nb.mean.exportbar
    if {[winfo exists $_mmode]} {
        set _sv_pm3 $::VMDPathFinder::state(pore_method)
        set _sv_s3d $::VMDPathFinder::state(show_mean_surface)
        foreach {_pm _s3 _lbl} {
            spherical 0 "spherical, Show3D off"
            connolly  0 "CONNOLLY but Show3D off"
            connolly  1 "CONNOLLY + Show3D on"
            spherical 1 "spherical, Show3D on"
        } {
            set ::VMDPathFinder::state(pore_method) $_pm
            set ::VMDPathFinder::state(show_mean_surface) $_s3
            ::VMDPathFinder::_update_method_dependent_controls
            ::VMDPathFinder::_update_mean_coloring_visibility
            update idletasks
            report "the mean 3D mode picker stays hidden: $_lbl" \
                [expr {[lsearch -exact [pack slaves $_mbar] $_mmode] < 0}] ""
        }
        # ...and the mode itself is pinned, so a persisted "Volume" cannot come back.
        report "...and the mean 3D mode is pinned to Isosurface" \
            [expr {$::VMDPathFinder::state(mean_3d_mode) eq "Isosurface"}] \
            "(is $::VMDPathFinder::state(mean_3d_mode))"
        set ::VMDPathFinder::state(pore_method) $_sv_pm3
        set ::VMDPathFinder::state(show_mean_surface) $_sv_s3d
        ::VMDPathFinder::_update_method_dependent_controls
        ::VMDPathFinder::_update_mean_coloring_visibility
    } else {
        report "the Mean Profile mode picker exists" 0 "$_mmode missing"
    }

    # Appearance lives in the graphics gear now, not here - these are how the
    # pore is DRAWN, not HOLE input cards.
    foreach _w {ui.sbc_m ui.sbcn_m ui.mrshow ui.ions cpm_c} {
        report "$_w is no longer in the HOLE parameters gear" \
            [expr {![winfo exists $_hp.$_w]}] "(exists=[winfo exists $_hp.$_w])"
    }
    ::VMDPathFinder::show_scale_cutoff_settings
    update idletasks; update
    set _gg $w.scale_settings
    foreach _w {ui.sbc_m ui.sbcn_m ui.mrshow ui.ions cpm_c} {
        report "...and is in the graphics gear" \
            [expr {[winfo exists $_gg.$_w] && [winfo manager $_gg.$_w] ne ""}] \
            "(exists=[winfo exists $_gg.$_w])"
    }
    catch {destroy $_gg}

    # Rows a choice enables come after the choice: IGNORE (both engines) sits
    # above the Search picker, the Monte Carlo rows and HOLE's own cards below
    # it - and none of them on top of another.
    set _mcy [winfo rooty $_hp.hp.ms_e]
    set _igy [winfo rooty $_hp.hp.ig_e]
    set _sey [winfo rooty $_hp.hp.se_mb]
    set _rsy [winfo rooty $_hp.hp.rs_e]
    report "IGNORE sits above the Search picker, the MC row and the seed below it" \
        [expr {$_igy < $_sey && $_sey < $_mcy && $_mcy < $_rsy}] "IGNORE y=$_igy, Search y=$_sey, MC y=$_mcy, seed y=$_rsy"
    destroy $_hp
}

# Placed BEFORE the unrolled-map section on purpose. It used to sit after it,
# where two things broke it: that section ends by CLOSING the GUI (the dialog
# check), and its teardown segfaulted VMD outright - so these assertions never
# ran at all. They also must not move INSIDE that section: it is guarded on the
# 1GRM fixture, and a guarded assertion that silently skips is worse than none.
# ---- A1 / A2: which property pickers are joined, and which are not ----------
# The joins live in WRITE TRACES installed while the widgets are built, so they
# cannot be exercised headless. Drive the state variables the pickers write and
# assert what the OTHER panels end up holding.
#
# Target topology (user instruction, reversing the note that stood at
# _sync_property_scheme_across_panels):
#   JOINED       Visualization (hydro_scheme) = Pore Profile Fill
#                (profile_color_scheme) = Mean Profile (mean_hydro_scheme)
#   INDEPENDENT  Over Time (hm_prop_scheme)
$w.sidebar.nb select $w.sidebar.nb.hole
update idletasks; update
set _sv_a_hy  $::VMDPathFinder::state(hydro_scheme)
set _sv_a_pc  $::VMDPathFinder::state(profile_color_scheme)
set _sv_a_mn  $::VMDPathFinder::state(mean_hydro_scheme)
set _sv_a_hm  $::VMDPathFinder::state(hm_prop_scheme)
# Start every panel from a common value so a later "unchanged" is meaningful.
set ::VMDPathFinder::state(hydro_scheme) kd
update idletasks; update
set ::VMDPathFinder::state(hm_prop_scheme) kd
update idletasks; update
# Pick a property in the 3D Visualization panel.
set ::VMDPathFinder::state(hydro_scheme) ww
update idletasks; update
report "A2 Mean Profile follows the 3D visualiser's property" \
    [expr {$::VMDPathFinder::state(mean_hydro_scheme) eq "ww"}] \
    "(mean_hydro_scheme=$::VMDPathFinder::state(mean_hydro_scheme))"
report "A2 ...and so does Pore Profile Fill" \
    [expr {$::VMDPathFinder::state(profile_color_scheme) eq "ww"}] \
    "(profile_color_scheme=$::VMDPathFinder::state(profile_color_scheme))"
report "A1 Over Time does NOT follow it" \
    [expr {$::VMDPathFinder::state(hm_prop_scheme) eq "kd"}] \
    "(hm_prop_scheme=$::VMDPathFinder::state(hm_prop_scheme))"
# ...and the reverse direction: Mean Profile drives the other two.
set ::VMDPathFinder::state(mean_hydro_scheme) lipophilicity
update idletasks; update
report "A2 the join is two-way - Mean Profile drives the 3D visualiser" \
    [expr {$::VMDPathFinder::state(hydro_scheme) eq "lipophilicity"}] \
    "(hydro_scheme=$::VMDPathFinder::state(hydro_scheme))"
# ...and Over Time still cannot reach anything. This is the reported defect:
# "if i change the over time property drop down it also changes the 3d
# visulizer property".
set ::VMDPathFinder::state(hm_prop_scheme) ww
update idletasks; update
report "A1 changing Over Time leaves the 3D visualiser alone" \
    [expr {$::VMDPathFinder::state(hydro_scheme) eq "lipophilicity"}] \
    "(hydro_scheme=$::VMDPathFinder::state(hydro_scheme))"
report "A1 ...and leaves Mean Profile alone" \
    [expr {$::VMDPathFinder::state(mean_hydro_scheme) eq "lipophilicity"}] \
    "(mean_hydro_scheme=$::VMDPathFinder::state(mean_hydro_scheme))"
set ::VMDPathFinder::state(hydro_scheme)          $_sv_a_hy
set ::VMDPathFinder::state(profile_color_scheme) $_sv_a_pc
set ::VMDPathFinder::state(mean_hydro_scheme)     $_sv_a_mn
set ::VMDPathFinder::state(hm_prop_scheme)        $_sv_a_hm
update idletasks; update

# A1 in TUNNEL mode - same rule, different mechanism (a per-tunnel override
# rather than a traced state variable). Both consumers gate on [analysis_mode],
# which reads the notebook, so they only exist here.
if {[llength $::VMDPathFinder::tunnel_xclusters] > 0} {
    $w.sidebar.nb select $w.sidebar.nb.tunnel
    update idletasks; update
    set _sv_t_cid [expr {[info exists ::VMDPathFinder::state(tunnel_selected_cid)]
                         ? $::VMDPathFinder::state(tunnel_selected_cid) : ""}]
    set _sv_t_hm  $::VMDPathFinder::state(hm_tunnel_prop)
    set _sv_t_cby $::VMDPathFinder::state(heatmap_color_by)
    set _tcid [::VMDPathFinder::_tunnel_selected_cluster]
    if {$_tcid ne ""} {
        set ::VMDPathFinder::tunnel_gear_cid($_tcid,prop) charge
        set ::VMDPathFinder::state(heatmap_color_by) property
        set ::VMDPathFinder::state(hm_tunnel_prop) hydropathy
        # Drive the real menu handler.
        ::VMDPathFinder::_hm_tunnel_prop_pick logp
        update idletasks; update
        report "A1 tunnel Over Time plots the property its own picker names" \
            [expr {[::VMDPathFinder::_tunnel_heatmap_prop] eq "logp"}] \
            "(_tunnel_heatmap_prop=[::VMDPathFinder::_tunnel_heatmap_prop])"
        # The stem also carries the mode prefix, the tunnel and the run tag, so
        # match on the property component - present as logp, absent as charge.
        set _a1stem [::VMDPathFinder::export_fig_stem heatmap]
        report "A1 ...the exported figure is named after it, not the route's" \
            [expr {[string match "*over_time_logp*" $_a1stem]
                   && ![string match "*charge*" $_a1stem]}] "($_a1stem)"
        report "A1 ...and the ROUTE keeps the property its own gear was set to" \
            [expr {[::VMDPathFinder::_tunnel_effective_prop_for_cluster $_tcid] eq "charge"}] \
            "(route prop=[::VMDPathFinder::_tunnel_effective_prop_for_cluster $_tcid])"
        report "A1 ...so Pore Profile's picker label did not move either" \
            [expr {$::VMDPathFinder::state(tunnel_profile_prop_disp) ne \
                   $::VMDPathFinder::state(hm_tunnel_prop_disp)}] \
            "(profile='$::VMDPathFinder::state(tunnel_profile_prop_disp)'\
              overtime='$::VMDPathFinder::state(hm_tunnel_prop_disp)')"
        catch {unset ::VMDPathFinder::tunnel_gear_cid($_tcid,prop)}
    }
    set ::VMDPathFinder::state(heatmap_color_by)   $_sv_t_cby
    set ::VMDPathFinder::state(hm_tunnel_prop)      $_sv_t_hm
    set ::VMDPathFinder::state(tunnel_selected_cid) $_sv_t_cid
    $w.sidebar.nb select $w.sidebar.nb.hole
    update idletasks; update
}

# ---- Unrolled pore-wall map (HOLE 2DMAPS) ----
# Rendered, not just constructed: a map that draws one flat color would pass
# any "did it error" check while telling the user nothing. The assertion is on
# DISTINCT PIXEL COLORS in the generated photo.
set _R [file normalize [file join [file dirname $::env(VMDPATHFINDER_TCL)] ..]]
set _pdb [file join $_R vmdpathfinder 1GRM.pdb]
set _rad [file join $_R native stock_build hole2 rad simple.rad]
if {[file readable $_pdb] && [file readable $_rad] \
        && [string trim $::VMDPathFinder::state(hole_exec)] ne ""} {
    # Back to HOLE mode first: draw_profile_plot dispatches to the tunnel
    # renderer before anything else, and the tunnel checks above left the
    # sidebar on the Tunnel tab.
    catch {$w.sidebar.nb select $w.sidebar.nb.hole}
    update idletasks; update
    catch {::VMDPathFinder::_sync_profile_exportbar_for_mode}
    set _um [mol new $_pdb waitfor all]
    set _uw [file join [::VMDPathFinder::get_temp_base] "gui_umap_[pid]"]
    file delete -force $_uw; file mkdir $_uw
    array set ::VMDPathFinder::state [list molid $_um frame_spec 0 selection all \
        radius_file $_rad cpoint {0 0 0} cvect {0 0 1} sample 0.5 endrad 8.0 \
        random_seed 1 pore_method circular display_mode none work_dir $_uw \
        save_results 1 extra_cards {} ignore {} mcstep {} mcdisp {} mckt {}]
    # The return CONTRACT, on a run that really happens: 1 means results exist.
    # It used to fall off the end returning "", so a batch driver could not tell
    # a completed run from a failed one.
    set _urc [::VMDPathFinder::run_analysis]
    report "a completed run_analysis reports success (1), not an empty string" \
        [expr {$_urc eq "1"}] "(returned '$_urc')"
    set _ueb $w.plotframe.nb.profile.exportbar
    set ::VMDPathFinder::state(profile_view_mode) unroll
    ::VMDPathFinder::on_profile_view_mode_changed
    update idletasks; update
    report "the map's layer picker appears in Unrolled mode" \
        [winfo ismapped $_ueb.umlayer] ""
    ::VMDPathFinder::draw_profile_plot 0
    update idletasks; update
    set _ucv $w.plotframe.nb.profile.plotarea.cv
    set _uph ""
    foreach _it [$_ucv find all] {
        if {[$_ucv type $_it] eq "image"} { set _uph [$_ucv itemcget $_it -image] }
    }
    report "the unrolled map draws an image" [expr {[string length $_uph] > 0}] ""
    if {[string length $_uph] > 0} {
        array set _useen {}
        for {set _y 0} {$_y < [image height $_uph]} {incr _y 5} {
            for {set _x 0} {$_x < [image width $_uph]} {incr _x 5} {
                set _useen([$_uph get $_x $_y]) 1
            }
        }
        report "the map carries real structure, not one flat color" \
            [expr {[array size _useen] > 50}] "[array size _useen] distinct colors"
    }

    # ---- prop_* layers use the plugin's property ramp, not the map's own ----
    # "the new properties that this add in the unroll does not match or follow
    # that property coloring there is had": prop_* maps were colored by
    # _2dmap_color over the DATA's 2nd/98th percentiles, so the same property
    # drew in different colors on different structures, and a diverging scale
    # came out sequential. They now go through hydro_hex over property_meta's
    # fixed bounds, exactly like the 3D surface, Fill and the scale bars.
    #
    # The assertion is on PIXELS: every color in the drawn map must be one
    # hydro_hex produces for that property. The old ramp's blues (#1e3c8c and
    # friends) are not in that set, so this cannot pass on the old code.
    set _urd ""
    catch {set _urd [dict get $::VMDPathFinder::results 0 run_dir]}
    set ::VMDPathFinder::state(unroll_layer) prop_kd
    catch {::VMDPathFinder::draw_profile_plot 0}
    update idletasks; update
    set _pph ""
    foreach _it [$_ucv find all] {
        if {[$_ucv type $_it] eq "image"} { set _pph [$_ucv itemcget $_it -image] }
    }
    if {$_pph ne "" && $_urd ne ""} {
        set _pg [::VMDPathFinder::_2dmap_grd_read \
            [::VMDPathFinder::_2dmap_grd_path $_urd prop_kd]]
        array set _pexp {}
        if {$_pg ne {}} {
            foreach _v [dict get $_pg values] {
                set _pexp([string tolower [::VMDPathFinder::hydro_hex $_v kd]]) 1
            }
        }
        set _pbad ""
        set _pseen 0
        for {set _y 0} {$_y < [image height $_pph]} {incr _y 7} {
            for {set _x 0} {$_x < [image width $_pph]} {incr _x 7} {
                lassign [$_pph get $_x $_y] _r _g _b
                set _hx [format "#%02x%02x%02x" $_r $_g $_b]
                incr _pseen
                if {![info exists _pexp($_hx)] && $_pbad eq ""} { set _pbad $_hx }
            }
        }
        report "the prop_kd map is drawn in the property's own ramp" \
            [expr {$_pseen > 100 && [array size _pexp] > 1 && $_pbad eq ""}] \
            "([array size _pexp] expected colors, $_pseen px sampled,\
              first stray '$_pbad')"
        # ...and the SCALE is property_meta's, not this map's percentiles - the
        # bar's end labels are what a reader calibrates against.
        set _pm [::VMDPathFinder::property_meta kd]
        set _plabels {}
        foreach _it [$_ucv find all] {
            if {[$_ucv type $_it] eq "text"} { lappend _plabels [$_ucv itemcget $_it -text] }
        }
        report "...and its color key is labelled with property_meta's bounds" \
            [expr {[lsearch -exact $_plabels [format "%.2f " [dict get $_pm hi]]] >= 0
                   || [lsearch -exact $_plabels [format "%.2f" [dict get $_pm hi]]] >= 0}] \
            "(hi=[dict get $_pm hi] labels=[join [lrange $_plabels end-6 end] {,}])"
        unset -nocomplain _pexp
    }
    set ::VMDPathFinder::state(unroll_layer) touch
    catch {::VMDPathFinder::draw_profile_plot 0}
    update idletasks; update

    # ---- The gear's axis toggles must not be inert in Unrolled --------------
    # Reported as "when in unroll the swap x/y and flip z are not responsive".
    # Flip Z now reverses the map; Swap X/Y is hidden, because this view's X is
    # the ANGLE around the axis, not a spatial coordinate.
    proc _umap_photo_digest {cv} {
        set ph ""
        foreach it [$cv find all] { if {[$cv type $it] eq "image"} { set ph [$cv itemcget $it -image] } }
        if {$ph eq ""} { return "" }
        return [join [$ph data] "\n"]
    }
    set _sv_ufz $::VMDPathFinder::state(plot_flip_z)
    set ::VMDPathFinder::state(plot_flip_z) 0
    catch {::VMDPathFinder::draw_profile_plot 0}; update idletasks; update
    set _ud0 [_umap_photo_digest $_ucv]
    set ::VMDPathFinder::state(plot_flip_z) 1
    catch {::VMDPathFinder::draw_profile_plot 0}; update idletasks; update
    set _ud1 [_umap_photo_digest $_ucv]
    report "(setup) the unrolled map drew pixels to compare" \
        [expr {[string length $_ud0] > 1000}] "([string length $_ud0] chars)"
    report "Flip Z actually changes the unrolled map" \
        [expr {$_ud0 ne "" && $_ud0 ne $_ud1}] ""
    # ...and it MIRRORS it - a flip that merely perturbed the image would pass
    # the check above.
    set _urows0 [split $_ud0 "\n"]
    set _urows1 [split $_ud1 "\n"]
    report "...and it is a mirror, not just a different picture" \
        [expr {[llength $_urows0] == [llength $_urows1]
               && [lindex $_urows0 0] eq [lindex $_urows1 end-1]}] \
        "(rows=[llength $_urows0])"
    set ::VMDPathFinder::state(plot_flip_z) $_sv_ufz
    catch {::VMDPathFinder::draw_profile_plot 0}; update idletasks; update
    # Swap X/Y is not offered in this mode at all.
    set ::VMDPathFinder::state(profile_view_mode) unroll
    ::VMDPathFinder::show_pore_profile_settings
    update idletasks
    report "Swap X/Y is not offered on the Unrolled map" \
        [expr {[winfo exists $w.profile_settings]
               && [winfo manager $w.profile_settings.swap] eq ""}] \
        "(manager='[expr {[winfo exists $w.profile_settings.swap] ? [winfo manager $w.profile_settings.swap] : {gone}}]')"
    catch {destroy $w.profile_settings}
    set ::VMDPathFinder::state(profile_view_mode) fill
    ::VMDPathFinder::show_pore_profile_settings
    update idletasks
    report "...but it is still there for the profile plot" \
        [expr {[winfo exists $w.profile_settings.swap]
               && [winfo manager $w.profile_settings.swap] ne ""}] ""
    catch {destroy $w.profile_settings}
    set ::VMDPathFinder::state(profile_view_mode) unroll
    ::VMDPathFinder::on_profile_view_mode_changed
    update idletasks; update

    # ---- Stabilize must not move the camera --------------------------------
    # _stab_sel_pair builds a scratch molecule and calls `animate dup` on it,
    # which RESETS THE VIEW - measured on 1BL8, the structure jumps from scale
    # 0.02413 to 0.50000 (20.7x) and neither `mol off`, restoring `top`, nor
    # deleting the scratch puts it back. Reported as "with Stabilize on it
    # zooms inside the channel when the run finishes".
    set _cam_mid $::VMDPathFinder::state(molid)
    proc _cam_scale {m} {
        set sc ""
        catch {set sc [lindex [lindex [molinfo $m get scale_matrix] 0] 0 0]}
        return $sc
    }
    set _cam_before [_cam_scale $_cam_mid]
    set _cam_ref {}
    catch {set _cam_ref [lindex [[atomselect $_cam_mid "name CA"] get {x y z}] 0]}
    set _cam_p {}
    catch {set _cam_p [::VMDPathFinder::_stab_sel_pair $_cam_mid "name CA" 0]}
    set _cam_after [_cam_scale $_cam_mid]
    report "(setup) the scratch-molecule path ran" \
        [expr {[llength $_cam_p] >= 4 && $_cam_before ne ""}] \
        "(pair=[llength $_cam_p] scale=$_cam_before)"
    report "Stabilize's scratch molecule does not move the camera" \
        [expr {$_cam_before ne "" && $_cam_after eq $_cam_before}] \
        "(scale before=$_cam_before after=$_cam_after)"
    catch {::VMDPathFinder::_stab_cleanup}

    # ---- Over Time color menu: Watermelon first ---------------------------
    # It is the classic HOLE radius plot; it was last in the list.
    set _cm $w.plotframe.nb.heatmap.exportbar.sch.m
    set _cm_first ""
    catch {set _cm_first [$_cm entrycget 0 -label]}
    report "the Over Time color menu lists Watermelon first" \
        [expr {$_cm_first eq "watermelon"}] "(first entry='$_cm_first')"

    # ---- Hydration energy axis starts at the DATA minimum, not zero --------
    # A G(z) curve that never goes negative was drawn against an axis pinned to
    # 0, flattening it against the top of the plot.
    set _sv_hv ""
    catch {set _sv_hv $::VMDPathFinder::state(hydration_view)}
    set _sv_hd $::VMDPathFinder::hydration_data
    set ::VMDPathFinder::state(hydration_view) energy
    # An all-positive curve: with the old clamp the axis would start at 0.
    set _hz {}; set _hg {}
    for {set _i 0} {$_i < 12} {incr _i} {
        lappend _hz [expr {$_i - 6.0}]
        lappend _hg [expr {3.0 + 0.5*$_i}]
    }
    set ::VMDPathFinder::hydration_data [dict create coords $_hz energy $_hg \
        occupancy [lrepeat 12 1.0] occ_std [lrepeat 12 0.0] \
        energy_std [lrepeat 12 0.0] density [lrepeat 12 0.0334] \
        countspf [lrepeat 12 1.0] radii [lrepeat 12 2.0] \
        nframes 1 nframes_water 1 total_waters 12 wsel water bulk 0.0334 \
        dz 1.0 kT 0.596 min_g 3.0 max_g 8.5 energy_shift 0.0 \
        axis_mode fixed axis {0 0 1} perframe_occ {} perframe_frames {}]
    catch {::VMDPathFinder::draw_hydration_tab}
    update idletasks; update
    set _hcv $w.plotframe.nb.hydration.cv
    set _hlabels {}
    catch {
        foreach _it [$_hcv find all] {
            if {[$_hcv type $_it] eq "text"} { lappend _hlabels [$_hcv itemcget $_it -text] }
        }
    }
    # The lowest y tick is the curve's own minimum. The range deliberately drops
    # the first and last centreline bin, so that is 3.50, not the 3.00 at i=0 -
    # what matters is that it is the DATA minimum and not 0.00.
    report "the energy axis starts at the data minimum, not zero" \
        [expr {[lsearch -exact $_hlabels "3.50"] >= 0
               && [lsearch -exact $_hlabels "0.00"] < 0}] \
        "(labels=[join [lsort -unique $_hlabels] {,}])"
    set ::VMDPathFinder::hydration_data $_sv_hd
    if {$_sv_hv ne ""} { set ::VMDPathFinder::state(hydration_view) $_sv_hv }
    catch {::VMDPathFinder::draw_hydration_tab}

    # ---- Every prop_* layer shares one parse of the frame's inputs ----------
    # The resno/chain grids and the residue table are the same for every
    # property scheme, but were rebuilt for each: 20 grid parses and 10 residue
    # tables to build one frame's ten grids, plus one residue_property call per
    # CELL (197830 of them) where ~20 residue types exist. Counted, not timed -
    # a timing threshold would drift with the machine.
    # A frame that actually HAS its HOLE grids - maps are built per frame now,
    # so frame 0 is not necessarily one of them.
    set _pc_fr ""
    foreach _fr $::VMDPathFinder::result_frames {
        if {[::VMDPathFinder::_2dmap_is_current $_fr]} { set _pc_fr $_fr; break }
    }
    if {$_pc_fr eq ""} {
        say "  SKIP  no unrolled map was built in this pass - nothing to share"
    } else {
    set _pc_rd [dict get $::VMDPathFinder::results $_pc_fr run_dir]
    foreach _t [::VMDPathFinder::_2dmap_prop_tokens] {
        catch {file delete [::VMDPathFinder::_2dmap_prop_path $_pc_rd $_t]}
    }
    catch {unset ::VMDPathFinder::_2dmap_ctx}
    set ::_pc_reads 0
    rename ::VMDPathFinder::_2dmap_grd_read ::VMDPathFinder::_pc_orig_grd_read
    proc ::VMDPathFinder::_2dmap_grd_read {args} {
        incr ::_pc_reads
        return [uplevel 1 [linsert $args 0 ::VMDPathFinder::_pc_orig_grd_read]]
    }
    set _pc_n 0; set _pc_err ""
    foreach _t [::VMDPathFinder::_2dmap_prop_tokens] {
        set _e [::VMDPathFinder::_2dmap_prop_build $_pc_rd $::VMDPathFinder::state(molid) \
                    $_pc_fr $_t]
        if {$_e eq ""} { incr _pc_n } elseif {$_pc_err eq ""} { set _pc_err $_e }
    }
    rename ::VMDPathFinder::_2dmap_grd_read {}
    rename ::VMDPathFinder::_pc_orig_grd_read ::VMDPathFinder::_2dmap_grd_read
    report "(setup) every property grid built" \
        [expr {$_pc_n == [llength [::VMDPathFinder::_2dmap_prop_tokens]]}] \
        "(built=$_pc_n of [llength [::VMDPathFinder::_2dmap_prop_tokens]] frame=$_pc_fr err='$_pc_err' root=[::VMDPathFinder::_2dmap_root])"
    report "the property layers parse the frame's grids ONCE, not once per scheme" \
        [expr {$::_pc_reads <= 2}] \
        "(grid parses=$::_pc_reads for $_pc_n scheme(s); 2 = resno + chain)"
    }

    # ---- Unroll draw cost, end to end (the "2-3 seconds?" report) ----
    # Every stage BELOW the canvas was already measured at ~70 ms total; this
    # is the piece that was never timed. Measured per layer, cold (first draw,
    # which for prop_* also runs _2dmap_prop_build) and warm.
    #
    # It is a THRESHOLD, not a benchmark: the point is to notice if a redraw
    # ever climbs back into seconds, not to pin a number that will drift with
    # the machine. Each layer's own timing is reported so a regression names
    # itself.
    set _uslow {}
    set _utimes {}
    foreach _ul [dict keys [::VMDPathFinder::_2dmap_layers]] {
        set ::VMDPathFinder::state(unroll_layer) $_ul
        set _t0 [clock milliseconds]
        catch {::VMDPathFinder::draw_profile_plot 0}
        update idletasks; update
        set _tcold [expr {[clock milliseconds]-$_t0}]
        set _t0 [clock milliseconds]
        catch {::VMDPathFinder::draw_profile_plot 0}
        update idletasks; update
        set _twarm [expr {[clock milliseconds]-$_t0}]
        lappend _utimes "$_ul ${_tcold}/${_twarm}ms"
        if {$_tcold > 2000 || $_twarm > 1000} { lappend _uslow "$_ul ${_tcold}/${_twarm}ms" }
    }
    report "no unrolled layer takes seconds to draw (cold<2s, warm<1s)" \
        [expr {[llength $_uslow] == 0}] "[join $_utimes {, }]"

    # ---- Selecting Unrolled builds THIS frame, and only this frame ---------
    # It briefly built every frame of the trajectory up front. That is 50 real
    # HOLE runs for maps the user may never look at - "when I choose unroll I
    # want to see the unroll for that frame, why is it processing 50 frames?".
    # The per-frame cost is sub-second now, so it is paid per frame VISITED.
    set _sv_ufs $::VMDPathFinder::state(frame_spec)
    animate dup frame 0 $_um
    set ::VMDPathFinder::state(frame_spec) all
    if {[::VMDPathFinder::run_analysis] eq "1" && [llength $::VMDPathFinder::result_frames] > 1} {
        # ---- Ion Flow's axial window is pooled across the trajectory --------
        # "I want the mean profile to be the reference + the shell" - the window
        # used to be one reference frame's own extent +-3.0; now it is every
        # result frame's OWN centerline projected onto the scan's own axis
        # (same projection the wall curve and the ions are drawn in - see the
        # window comment in _ion_flow_scan), padded by the shell margin instead
        # of a bare 3.0. Recomputed independently here (not via
        # collect_binned_radii's "coord" column, which tracks this projection
        # closely but not exactly - a few A constant offset, measured on a real
        # run) so the check cannot pass by sharing a bug with the code under test.
        set _frref [lindex $::VMDPathFinder::result_frames 0]
        set _ifmol [::VMDPathFinder::resolve_molid]
        set _ifmode [::VMDPathFinder::analysis_mode]
        if {$_ifmode eq "tunnel"} {
            set _ifgather "tunnel"
        } elseif {[::VMDPathFinder::_asym_gather $_ifmol $_frref] eq ""} {
            set _ifgather "asym-empty"
        } else {
            set _ifgather "asym-ok"
        }
        set _ifions [llength [::VMDPathFinder::detect_ions $_ifmol]]
        set _iraw [::VMDPathFinder::_ion_flow_scan $_ifmol $_frref]
        set _pad [expr {max(3.0, [expr {[info exists ::VMDPathFinder::state(ion_flow_shell)] \
            ? $::VMDPathFinder::state(ion_flow_shell) : 3.0}])}]
        set _zpmin 1e30; set _zpmax -1e30
        if {$_iraw ne ""} {
            lassign [dict get $_iraw axis] _pux _puy _puz
            lassign [dict get $_iraw origin] _pmx _pmy _pmz
            foreach _pfr $::VMDPathFinder::result_frames {
                if {![dict exists $::VMDPathFinder::results $_pfr sph_file]} continue
                set _psf [dict get $::VMDPathFinder::results $_pfr sph_file]
                if {![file exists $_psf] || [catch {set _pfh [open $_psf r]}]} continue
                while {[gets $_pfh _pln] >= 0} {
                    if {![string match {ATOM  *} $_pln] && ![string match {HETATM*} $_pln]} continue
                    set _psq [string trim [string range $_pln 22 26]]
                    if {$_psq eq "-999" || $_psq eq "-888"} continue
                    # Same radius resolution + reject as the code under test, so both
                    # sides drop exactly the same degenerate rows (production pools z
                    # AFTER this check - see _ion_flow_scan's own wall-loop comment).
                    if {[::VMDPathFinder::_run_uses_card conn] || [::VMDPathFinder::_run_uses_card connolly]} {
                        set _prr [string trim [string range $_pln 60 65]]
                        if {[string is double -strict $_prr] && $_prr > 900} {
                            set _prr [string trim [string range $_pln 54 59]]
                        }
                    } else {
                        set _prr [string trim [string range $_pln 54 59]]
                    }
                    if {![string is double -strict $_prr] || $_prr <= 0.005} continue
                    set _pcx [string trim [string range $_pln 30 37]]
                    set _pcy [string trim [string range $_pln 38 45]]
                    set _pcz [string trim [string range $_pln 46 53]]
                    if {![string is double -strict $_pcx] || ![string is double -strict $_pcy] \
                        || ![string is double -strict $_pcz]} continue
                    set _pz [expr {($_pcx-$_pmx)*$_pux+($_pcy-$_pmy)*$_puy+($_pcz-$_pmz)*$_puz}]
                    if {$_pz < $_zpmin} { set _zpmin $_pz }
                    if {$_pz > $_zpmax} { set _zpmax $_pz }
                }
                catch {close $_pfh}
            }
        }
        # _ion_flow_scan needs ions; this fixture is a bare channel structure, so
        # the pooling assertion is only meaningful when the structure has some.
        # Reported either way - a silently skipped check reads as a passing one.
        if {$_ifions == 0} {
            say "  SKIP  Ion Flow's axial window (this structure has no ions to scan)"
        } else {
        report "Ion Flow's axial window is pooled across the trajectory, not the reference frame" \
            [expr {$_iraw ne "" && $_zpmin < $_zpmax \
                   && abs([dict get $_iraw zmin] - ($_zpmin-$_pad)) < 0.05 \
                   && abs([dict get $_iraw zmax] - ($_zpmax+$_pad)) < 0.05}] \
            "(ion_flow=[expr {$_iraw ne "" ? [dict get $_iraw zmin] : "?"}]..[expr {$_iraw ne "" ? [dict get $_iraw zmax] : "?"}] independent_pool=[expr {$_zpmin-$_pad}]..[expr {$_zpmax+$_pad}] pad=$_pad old_single_frame_window=[expr {$_iraw ne "" ? [dict get $_iraw bulk_lo]-$_pad : "?"}]..[expr {$_iraw ne "" ? [dict get $_iraw bulk_hi]+$_pad : "?"}] mode=$_ifmode molid=$_ifmol gather=$_ifgather ions=$_ifions frames=[llength $::VMDPathFinder::result_frames])"
        }

        foreach _fr $::VMDPathFinder::result_frames {
            set _frd [dict get $::VMDPathFinder::results $_fr run_dir]
            foreach _f [glob -nocomplain -directory $_frd "holemap*"] { file delete -force $_f }
        }
        array unset ::VMDPathFinder::_2dmap_memo
        set ::VMDPathFinder::state(profile_view_mode) none
        ::VMDPathFinder::on_profile_view_mode_changed
        set ::VMDPathFinder::state(profile_view_mode) unroll
        ::VMDPathFinder::on_profile_view_mode_changed
        update idletasks; update
        set _nbuilt 0
        foreach _fr $::VMDPathFinder::result_frames {
            if {[::VMDPathFinder::_2dmap_is_current $_fr]} { incr _nbuilt }
        }
        report "selecting Unrolled builds exactly one frame's map, not the trajectory's" \
            [expr {$_nbuilt == 1}] \
            "(built=$_nbuilt of [llength $::VMDPathFinder::result_frames])"
        # ...and the one it built is the frame being shown.
        set _dfr [expr {[info exists ::VMDPathFinder::state(selected_result_frame)]
                        && $::VMDPathFinder::state(selected_result_frame) ne ""
                        ? $::VMDPathFinder::state(selected_result_frame)
                        : [lindex $::VMDPathFinder::result_frames 0]}]
        report "...and it is the displayed frame" \
            [::VMDPathFinder::_2dmap_is_current $_dfr] "(frame=$_dfr)"
        # Re-entering must not rebuild what is already there.
        set _mt0 [file mtime [::VMDPathFinder::_2dmap_grd_path \
                      [dict get $::VMDPathFinder::results $_dfr run_dir] touch]]
        set ::VMDPathFinder::state(profile_view_mode) fill
        ::VMDPathFinder::on_profile_view_mode_changed
        set ::VMDPathFinder::state(profile_view_mode) unroll
        ::VMDPathFinder::on_profile_view_mode_changed
        update idletasks; update
        report "...and a Fill -> Unrolled round trip does not rebuild it" \
            [expr {[file mtime [::VMDPathFinder::_2dmap_grd_path \
                    [dict get $::VMDPathFinder::results $_dfr run_dir] touch]] == $_mt0}] ""
        # Ticking Segments is a different map, and must not throw the plain one
        # away - a single on-disk flag stamp used to do exactly that.
        set _sv_useg $::VMDPathFinder::state(unroll_chain_segname)
        set _urd0 [dict get $::VMDPathFinder::results $_dfr run_dir]
        set ::VMDPathFinder::state(unroll_chain_segname) 0
        set _upath_plain [::VMDPathFinder::_2dmap_grd_path $_urd0 touch]
        set ::VMDPathFinder::state(unroll_chain_segname) 1
        set _upath_seg [::VMDPathFinder::_2dmap_grd_path $_urd0 touch]
        report "the two Segments variants are separate files, not one" \
            [expr {$_upath_plain ne $_upath_seg}] \
            "(plain=[file tail $_upath_plain] seg=[file tail $_upath_seg])"
        ::VMDPathFinder::_on_unroll_layer_changed
        update idletasks; update
        report "...and BOTH variants are on disk afterwards" \
            [expr {[file exists $_upath_plain] && [file exists $_upath_seg]}] \
            "(plain=[file exists $_upath_plain] seg=[file exists $_upath_seg])"
        set ::VMDPathFinder::state(unroll_chain_segname) $_sv_useg
    } else {
        report "(setup) multi-frame unroll check ran" 0 \
            "(run_analysis did not produce >1 frame)"
    }
    set ::VMDPathFinder::state(frame_spec) $_sv_ufs

    # Regression: a negative-valued Trends metric (electrostatic potential)
    # used a multiplicative *0.95/*1.05 axis margin, which flips direction for
    # negative numbers and pins the true min/max off the visible plot.
    # Self-contained: draw_minr_tab's only real-data dependency is the early
    # "[llength $result_frames] < 2" gate, so a fake 2-entry list clears it
    # without a real HOLE run; _trend_series is mocked so the metric's own
    # real values (which may not be negative on this fixture) don't matter -
    # only the axis math does.
    set _sv_btm2 $::VMDPathFinder::state(trends_metric)
    set _sv_rf2 $::VMDPathFinder::result_frames
    $w.sidebar.nb select $w.sidebar.nb.hole
    set ::VMDPathFinder::result_frames {0 1 2 3 4}
    rename ::VMDPathFinder::_trend_series ::VMDPathFinder::_real_trend_series_gr
    proc ::VMDPathFinder::_trend_series {metric} {
        return [list {0 1 2 3 4} {-50.2 -60.1 -13.5 -89.6 -55.0}]
    }
    set ::VMDPathFinder::state(trends_metric) electrostatic_potential
    ::VMDPathFinder::draw_minr_tab
    update idletasks
    rename ::VMDPathFinder::_trend_series {}
    rename ::VMDPathFinder::_real_trend_series_gr ::VMDPathFinder::_trend_series
    set _mcv $w.plotframe.nb.minr.cv
    set _mout 0; set _nitem 0
    if {[dict size $::VMDPathFinder::minr_geo]} {
        set _pl [dict get $::VMDPathFinder::minr_geo margin_l]
        set _pt [dict get $::VMDPathFinder::minr_geo margin_t]
        set _pw [dict get $::VMDPathFinder::minr_geo plot_w]
        set _ph [dict get $::VMDPathFinder::minr_geo plot_h]
        foreach _it [$_mcv find withtag minr_pts] {
            incr _nitem
            set _bb [$_mcv bbox $_it]
            if {[llength $_bb] != 4} continue
            lassign $_bb _x0 _y0 _x1 _y1
            if {$_x1 > $_pl+$_pw+2 || $_x0 < $_pl-2 \
                || $_y1 > $_pt+$_ph+2 || $_y0 < $_pt-2} { incr _mout }
        }
    }
    report "(setup) the global-minimum marker was drawn" [expr {$_nitem > 0}] "(items=$_nitem)"
    report "a negative-valued Trends metric keeps its minimum marker inside the plot rect" \
           [expr {$_mout == 0}] "(outside=$_mout/$_nitem)"
    set ::VMDPathFinder::state(trends_metric) $_sv_btm2
    set ::VMDPathFinder::result_frames $_sv_rf2

    # ---- Legend must stay inside the canvas ----
    # The color key is placed at ml+pw+16 with a fixed right margin, and its
    # labels are residue/chain names of unbounded width - so a long label ran
    # off the right edge, and a discrete key with many entries ran off the
    # bottom ("its legend is usually out of bound and unreadable").
    set _ucw [winfo width $_ucv]; set _uch [winfo height $_ucv]
    foreach _ul [dict keys [::VMDPathFinder::_2dmap_layers]] {
        set ::VMDPathFinder::state(unroll_layer) $_ul
        catch {::VMDPathFinder::draw_profile_plot 0}
        update idletasks; update
        set _uover {}
        foreach _it [$_ucv find all] {
            set _bb [$_ucv bbox $_it]
            if {$_bb eq ""} continue
            lassign $_bb _bx1 _by1 _bx2 _by2
            # 2 px of slack: Tk's reported text bbox rounds outward by a pixel.
            if {$_bx2 > $_ucw + 2 || $_by2 > $_uch + 2 || $_bx1 < -2 || $_by1 < -2} {
                set _d "[$_ucv type $_it]@$_bb"
                catch {append _d " '[string range [$_ucv itemcget $_it -text] 0 24]'"}
                lappend _uover $_d
            }
        }
        report "the '$_ul' legend stays inside the ${_ucw}x${_uch} canvas" \
            [expr {[llength $_uover] == 0}] "[join [lrange $_uover 0 2] {; }]"
    }

    # ...and the same check with a PATHOLOGICAL label, because 1GRM cannot
    # produce one. The widest real label is "polar (acidic side)" at ~95 px in
    # a slot that used to be ~40 px wide - but 1GRM's polar map is all zero, so
    # that layer early-returns before the legend is ever drawn and the check
    # above passes without exercising the fix. Stub the label proc instead, the
    # same rename technique headless_smoke uses for analysis_mode.
    rename ::VMDPathFinder::_2dmap_value_label ::VMDPathFinder::_real_2dmap_value_label
    proc ::VMDPathFinder::_2dmap_value_label {layer v} {
        return "an absurdly long legend label $v that no margin would fit"
    }
    set ::VMDPathFinder::state(unroll_layer) chain
    catch {::VMDPathFinder::draw_profile_plot 0}
    update idletasks; update
    set _uover2 {}
    set _usaw 0
    foreach _it [$_ucv find all] {
        set _bb [$_ucv bbox $_it]
        if {$_bb eq ""} continue
        lassign $_bb _bx1 _by1 _bx2 _by2
        if {[$_ucv type $_it] eq "text"
                && [string match "*absurdly long*" [$_ucv itemcget $_it -text]]} { incr _usaw }
        if {$_bx2 > $_ucw + 2 || $_by2 > $_uch + 2} { lappend _uover2 "[$_ucv type $_it]@$_bb" }
    }
    report "a legend label too wide for any margin is elided, not drawn off-canvas" \
        [expr {[llength $_uover2] == 0}] "[join [lrange $_uover2 0 2] {; }]"
    report "...and the map itself still gets most of the width" \
        [expr {[llength [$_ucv find withtag all]] > 5}] "([llength [$_ucv find all]] items)"
    # Eliding is the last resort. A label of a REALISTIC width - the widest one
    # the real code produces is "polar (acidic side)", ~95 px in a slot that was
    # ~40 px - must be shown IN FULL, which is what sizing the margin to the
    # content buys. (1GRM's polar map is all zero, so this label can only be
    # reached through the stub.)
    proc ::VMDPathFinder::_2dmap_value_label {layer v} { return "polar (acidic side)" }
    catch {::VMDPathFinder::draw_profile_plot 0}
    update idletasks; update
    set _ufull 0; set _uelided 0; set _uoff 0
    foreach _it [$_ucv find all] {
        if {[$_ucv type $_it] ne "text"} continue
        set _tt [$_ucv itemcget $_it -text]
        if {![string match "*polar*" $_tt]} continue
        if {$_tt eq "polar (acidic side)"} { incr _ufull } else { incr _uelided }
        lassign [$_ucv bbox $_it] _bx1 _by1 _bx2 _by2
        if {$_bx2 > $_ucw + 2} { incr _uoff }
    }
    report "a realistic legend label is shown in full, not truncated" \
        [expr {$_ufull > 0 && $_uelided == 0 && $_uoff == 0}] \
        "($_ufull full, $_uelided elided, $_uoff off-canvas)"
    rename ::VMDPathFinder::_2dmap_value_label {}
    rename ::VMDPathFinder::_real_2dmap_value_label ::VMDPathFinder::_2dmap_value_label
    set ::VMDPathFinder::state(unroll_layer) touch

    set ::VMDPathFinder::state(unroll_layer) chain
    ::VMDPathFinder::_on_unroll_layer_changed
    update idletasks; update
    report "switching layer relabels the picker" \
        [expr {$::VMDPathFinder::state(unroll_layer_disp) eq "Chain"}] \
        "got '$::VMDPathFinder::state(unroll_layer_disp)'"
    set ::VMDPathFinder::state(unroll_layer) touch
    ::VMDPathFinder::_on_unroll_layer_changed
    set ::VMDPathFinder::state(profile_view_mode) none
    ::VMDPathFinder::on_profile_view_mode_changed
    update idletasks; update
    report "the layer picker hides again outside Unrolled mode" \
        [expr {![winfo ismapped $_ueb.umlayer]}] ""
    # ---- The shared binning engine must name the panel that ASKED ---------
    # collect_binned_radii is shared by the Mean Profile, the Radius Histogram
    # and Over Time, but its progress line hard-coded "Mean profile:" - so an
    # Over Time property compute announced "Mean profile: reading N frames...",
    # naming the wrong panel in the one shared status line. Only appears past
    # its own 25-frame threshold, which is why short runs never showed it.
    foreach {_tabpat _want} {
        *.heatmap "Over Time"
        *.hist    "Radius histogram"
        *.mean    "Mean profile"
        *.minr    "Bottleneck over time"
    } {
        foreach _t [$w.plotframe.nb tabs] {
            if {[string match $_tabpat $_t]} { $w.plotframe.nb select $_t }
        }
        update idletasks
        report "the shared profile binner says '$_want' on its own tab" \
            [expr {[::VMDPathFinder::_binned_radii_caller_label] eq $_want}] \
            "(got '[::VMDPathFinder::_binned_radii_caller_label]')"
    }
    # ...and the progress text must USE it, not a hard-coded panel name. Only
    # the positive half: `info body` includes comments, and the comment that
    # explains this fix quotes the old string, so a "the old text is gone"
    # check matches the prose rather than the code.
    set _cbr [info body ::VMDPathFinder::collect_binned_radii]
    report "...and the progress line uses that label" \
        [expr {[string first {$_label: reading} $_cbr] >= 0
            && [string first {$_label: frame} $_cbr] >= 0}] ""
    # The line must also be CLEARED, or it dangles over every tab afterwards -
    # the status bar is one shared line and nothing else resets it.
    report "...and clears it when the pass finishes" \
        [expr {[string first {set state(status) ""} $_cbr] >= 0}] ""

    # ---- Closing the plugin must take its DIALOGS with it -----------------
    # Every settings/gear panel is a child of $w but its own TOPLEVEL, and
    # withdrawing a parent does NOT withdraw a child toplevel - so closing the
    # plugin left them floating over VMD with nothing behind them. Measured
    # before the fix: 17 of 18 still mapped (settings, the HOLE params / scale /
    # mean / profile / overtime / histogram panels, align, vector, ion flow,
    # hydration, trends, about, import, both tunnel gears, and the Connolly
    # region gear). Only the Message Log closed itself.
    #
    # LAST in the file on purpose: it closes the GUI, so nothing after it could
    # touch a widget anyway.
    set _dlg_opened {}
    foreach _dp {show_settings_dialog show_hole_params_settings
                 show_mean_profile_settings show_ion_flow_settings
                 show_hydration_settings show_about_dialog show_import_dialog
                 show_trends_settings_dialog show_tunnel_advanced_settings} {
        if {![catch {::VMDPathFinder::$_dp}]} { lappend _dlg_opened $_dp }
    }
    catch {::VMDPathFinder::_conn_gear_dialog "*"}
    update idletasks
    proc _mapped_dialogs {} {
        set out {}
        foreach t [winfo children $::VMDPathFinder::w] {
            if {[winfo class $t] ne "Toplevel"} { continue }
            set st "withdrawn"
            catch {set st [wm state $t]}
            if {$st ne "withdrawn"} { lappend out [winfo name $t] }
        }
        return $out
    }
    set _open_before [_mapped_dialogs]
    report "the dialogs under test are actually open first" \
        [expr {[llength $_open_before] >= 8}] "(n=[llength $_open_before])"
    ::VMDPathFinder::close_gui
    update idletasks
    set _open_after [_mapped_dialogs]
    report "closing the plugin closes every dialog with it" \
        [expr {[llength $_open_after] == 0}] "(still open: $_open_after)"
    # ...and they must all come BACK. `raise` alone cannot restore a withdrawn
    # window: four dialogs (about, import, trends, permeation) guarded on
    # `winfo exists` and raised without deiconifying, so once withdrawn they
    # could never be reopened - a latent bug the withdraw above exposed.
    ::VMDPathFinder::show_gui
    update idletasks
    set _reop_bad {}
    foreach _dp $_dlg_opened {
        if {[catch {::VMDPathFinder::$_dp}]} { lappend _reop_bad "$_dp:error"; continue }
    }
    update idletasks
    foreach _t [list settings hole_params_settings mean_settings ionflowcfg \
                     hydrocfg about import trendscfg tunnel_advanced_settings] {
        if {![winfo exists $::VMDPathFinder::w.$_t]} { continue }
        set _st "?"
        catch {set _st [wm state $::VMDPathFinder::w.$_t]}
        if {$_st ne "normal"} { lappend _reop_bad "$_t:$_st" }
    }
    report "...and every one of them reopens afterwards" \
        [expr {[llength $_reop_bad] == 0}] "($_reop_bad)"
    catch {::VMDPathFinder::close_gui}

    # NOT deleted: `mol delete` on this molecule SEGFAULTS VMD (reproduced on
    # every run, with and without close_gui, and with the vmd_frame trace
    # removed first - so it is below the Tcl layer and no catch can hold it).
    # It killed the process here, which is why everything below used to be dead
    # code. VMD is about to exit anyway; the temp dir is what actually needs
    # cleaning, and that still happens on the next line.
    #   catch {mol delete $_um}
    catch {file delete -force $_uw}
}

# Completion marker - the last UNCONDITIONAL statement in the file. The wrapper
# greps for this, so a run that dies anywhere above is a FAILURE rather than a
# silent pass. Deliberately not the trailing summary below: VMD segfaults in its
# own exit path on this file, so nothing after the catch is reliably reached.

# ---- Cavities: cross-frame tracking, the table, and the two start-point rules
# The cavity data is computed for EVERY analysed frame and was previously only
# ever read for the displayed one. These checks cover the parts that turn it
# into something a trajectory can be described with, and the action that makes
# a cavity useful as an input rather than a report.
if {$ntun > 0} {
    set _cfr [::VMDPathFinder::_tunnel_display_frame]
    set _cavs [::VMDPathFinder::_tunnel_cavities $_cfr]
    if {[dict size $_cavs]} {
        set _cid [lindex [dict keys $_cavs] 0]
        set _cv  [dict get $_cavs $_cid]
        report "the engine's own automatic origins (O records) are parsed" \
               [expr {[llength [dict get $_cv origins]] > 0}] \
               "([llength [dict get $_cv origins]] origins on cavity $_cid)"
        set _om [::VMDPathFinder::_cavity_origin $_cv mole]
        set _oc [::VMDPathFinder::_cavity_origin $_cv caver]
        report "the two start-point rules are distinct points, not one dressed as two" \
               [expr {[llength $_om] == 3 && [llength $_oc] == 3 && $_om ne $_oc}] \
               "(MOLE $_om / CAVER $_oc)"
        set _tracks [::VMDPathFinder::_cavity_tracks]
        report "cavities are tracked across frames, not just the landed one" \
               [expr {[llength $_tracks] > 0
                      && [dict get [lindex $_tracks 0] nframes] >= 1
                      && [dict get [lindex $_tracks 0] seen] > 0}] \
               "([llength $_tracks] tracks over [dict get [lindex $_tracks 0] nframes] frames)"
        report "max probe is a real radius" \
               [expr {[::VMDPathFinder::_cavity_max_probe $_cv] > 0}] ""
        # the window and its controls
        ::VMDPathFinder::show_tunnel_cavities
        update idletasks; update
        # The header is FROZEN in its own frame so it stays visible while the body
        # scrolls, which makes them two independent grids. Assert the property
        # that actually matters - the columns line up - rather than the
        # mechanism, which has now changed twice: they shared one grid to fix
        # the drift, then had to be split again to pin the header.
        set _hf $w.tuncav.hdr
        set _bf $w.tuncav.sc.c.inner
        set _ncol 0; set _aligned 0; set _off {}
        if {[winfo exists $_hf] && [winfo exists $_bf]} {
            for {set _c 0} {$_c < 20} {incr _c} {
                if {![winfo exists $_hf.h$_c]} { continue }
                incr _ncol
                set _hb ""; set _bb ""
                catch {set _hb [grid bbox $_hf $_c 0]}
                catch {set _bb [grid bbox $_bf $_c 1]}
                if {[llength $_hb] == 4 && [llength $_bb] == 4} {
                    set _d [expr {abs([lindex $_hb 0] - [lindex $_bb 0])}]
                    if {$_d <= 3} { incr _aligned } else { lappend _off "col$_c:${_d}px" }
                }
            }
        }
        report "the frozen header's columns line up with the body's" \
               [expr {$_ncol > 3 && $_aligned == $_ncol}] \
               "($_aligned of $_ncol within 3 px; off: $_off)"
        report "the cavity table scrolls and the window stays bounded" \
               [expr {[winfo exists $w.tuncav.sc.sb]
                      && [winfo reqheight $w.tuncav] < 700}] \
               "(height [winfo reqheight $w.tuncav] px)"
        # The canvas is as wide as the table: every row's buttons, gear
        # included, sit inside it. Sized before the header pinning, it came
        # out 216 px short and the four buttons were past the right edge.
        set _cvw [winfo width $w.tuncav.sc.c]
        set _gr 0
        catch {set _gr [expr {[winfo x $w.tuncav.sc.c.inner.gear1] + [winfo width $w.tuncav.sc.c.inner.gear1]}]}
        report "every row button, the gear included, is inside the cavity table's canvas" \
               [expr {[winfo ismapped $w.tuncav.sc.c.inner.gear1] && $_gr > 0 && $_gr <= $_cvw}] \
               "(gear right edge $_gr px, canvas $_cvw px)"
        report "the cavities window has no note line under the table" \
               [expr {![winfo exists $w.tuncav.note]}] ""
        # The wheel reaches only the widget under the pointer, so every row
        # label needs the binding or the table scrolls only over blank space.
        set _wb 0; set _wn 0
        foreach _kid [winfo children $w.tuncav.sc.c.inner] {
            incr _wn
            if {[bind $_kid <Button-5>] ne ""} { incr _wb }
        }
        report "every cavity row widget scrolls with the wheel" \
               [expr {$_wn > 5 && $_wb == $_wn}] "($_wb of $_wn bound)"
        # The clickable volume must LOOK clickable, not just carry a tooltip.
        set _vc -1
        for {set c 0} {$c < 20} {incr c} {
            if {[winfo exists $w.tuncav.hdr.h$c]
                && [string match "Volume*" [$w.tuncav.hdr.h$c cget -text]]} { set _vc $c; break }
        }
        set _vf ""
        catch {set _vf [$w.tuncav.sc.c.inner.v1_$_vc cget -font]}
        report "a plottable volume is drawn as a link (underlined)" \
               [expr {[lsearch -exact $_vf underline] >= 0}] "(font '$_vf')"
        # A gear change on an unticked pocket did nothing visible.
        set _t1 [lindex [dict get $::VMDPathFinder::_cavity_row_map 1] 0]
        set ::VMDPathFinder::tunnel_cavity_shown($_t1) 0
        set ::VMDPathFinder::state(cavgear_tid) $_t1
        ::VMDPathFinder::_cavity_gear_set cavgear_style spheres
        report "picking a look in the gear shows that pocket" \
               [::VMDPathFinder::_tunnel_cavity_shown $_t1] ""
        set ::VMDPathFinder::tunnel_cavity_shown($_t1) 0
        catch {::VMDPathFinder::_cavity_gear_set cavgear_style auto}
        set ::VMDPathFinder::tunnel_cavity_shown($_t1) 0
        # One master checkbox replaced the Show all / Hide all button pair, and
        # colour/material/spheres moved to a per-row gear.
        # The master checkbox sits in the HEADER's column 0, directly above the
        # per-row ticks and left of Id, not in the controls lane.
        report "the cavities window offers the master checkbox, the start-point menu and a per-row gear (Color by lives in the gear)" \
               [expr {[winfo exists $w.tuncav.hdr.h0]
                      && [winfo class $w.tuncav.hdr.h0] eq "Checkbutton"
                      && [winfo exists $w.tuncav.ctl.rm]
                      && ![winfo exists $w.tuncav.ctl.pm]
                      && [winfo exists $w.tuncav.sc.c.inner.gear1]
                      && [winfo exists $w.tuncav.sc.c.inner.use1]}] \
               "(allc=[winfo exists $w.tuncav.hdr.h0] gear1=[winfo exists $w.tuncav.sc.c.inner.gear1])"
        # The gear is the LAST widget in its row: per-pocket appearance, not
        # data, so it sits past the action buttons.
        set _g $w.tuncav.sc.c.inner
        set _gearcol -1; set _maxcol -1
        foreach _kid [winfo children $_g] {
            set _gi [grid info $_kid]
            set _ri [lsearch $_gi -row]; set _cix [lsearch $_gi -column]
            if {$_ri < 0 || $_cix < 0} { continue }
            if {[lindex $_gi [expr {$_ri+1}]] != 1} { continue }
            set _cc [lindex $_gi [expr {$_cix+1}]]
            if {$_cc > $_maxcol} { set _maxcol $_cc }
            if {[string match "*gear1" $_kid]} { set _gearcol $_cc }
        }
        report "the cavity gear is the last column in its row" \
               [expr {$_gearcol >= 0 && $_gearcol == $_maxcol}] \
               "(gear at column $_gearcol, last is $_maxcol)"

        # The Seen light must describe the frame BEING VIEWED, not the frame the
        # window was opened on. Nothing called _cavity_refresh on a frame change,
        # so it never moved once the window was up.
        set _seencol -1
        for {set c 0} {$c < 20} {incr c} {
            if {[winfo exists $w.tuncav.hdr.h$c]
                && [string match "Seen*" [$w.tuncav.hdr.h$c cget -text]]} { set _seencol $c; break }
        }
        set _before ""; set _after ""
        if {$_seencol >= 0 && [winfo exists $_g.v1_$_seencol]} {
            set _before [$_g.v1_$_seencol cget -foreground]
            # drive a frame change through the same proc the scrubber reaches
            set _saveframe $::VMDPathFinder::state(selected_result_frame)
            catch {::VMDPathFinder::_cavity_refresh}
            set _after [$_g.v1_$_seencol cget -foreground]
            set ::VMDPathFinder::state(selected_result_frame) $_saveframe
        }
        report "the cavity Seen light is refreshable in place (green/red, not a rebuild)" \
               [expr {$_seencol >= 0 && $_after in {#2a9d3f #c0392b}}] \
               "(col $_seencol, before '$_before' after '$_after')"
        # The title carries the frame too, and only the rebuild wrote it.
        catch {wm title $w.tuncav "Cavities - frame stale"}
        catch {::VMDPathFinder::_cavity_refresh}
        report "the cavities window title follows the frame on a refresh, not only on a rebuild" \
               [expr {[wm title $w.tuncav] eq "Cavities - frame [::VMDPathFinder::_tunnel_display_frame]"}] \
               "(title '[wm title $w.tuncav]')"
        report "_cavity_refresh is wired into the frame-change path" \
               [expr {[string first "_cavity_refresh" \
                   [info body ::VMDPathFinder::frame_changed_settle]] >= 0}] \
               "(frame_changed_settle must call it, or scrubbing never updates the table)"

        # sorting actually reorders
        set ::VMDPathFinder::state(cavity_sort_col) vol
        set ::VMDPathFinder::state(cavity_sort_dir) desc
        ::VMDPathFinder::show_tunnel_cavities
        update idletasks; update
        # Find the Volume cell by its HEADING, not by a column index: the index
        # moved twice already (the Type column became conditional, and the two
        # volume columns merged), and each time this read a different column and
        # "failed" for a reason that had nothing to do with sorting.
        proc _cav_volcol {w} {
            # Headings live in the FROZEN header frame, not in the scrolling
            # body - they moved there when the header was pinned. Both are
            # checked so this keeps working either way.
            for {set c 0} {$c < 20} {incr c} {
                foreach _h [list $w.tuncav.hdr.h$c $w.tuncav.sc.c.inner.h$c] {
                    if {![winfo exists $_h]} { continue }
                    if {[string match "Volume*" [$_h cget -text]]} { return $c }
                }
            }
            return -1
        }
        set _vc [_cav_volcol $w]
        report "the cavity table still has a Volume column" [expr {$_vc >= 0}] \
               "(no heading starting \"Volume\")"
        set _fd ""; catch {set _fd [$w.tuncav.sc.c.inner.v1_$_vc cget -text]}
        ::VMDPathFinder::_cavity_sort vol
        update idletasks; update
        set _vc [_cav_volcol $w]
        set _fa ""; catch {set _fa [$w.tuncav.sc.c.inner.v1_$_vc cget -text]}
        report "clicking a cavity column header reverses the sort" \
               [expr {$_fd ne "" && $_fa ne "" && $_fd != $_fa}] \
               "(desc '$_fd', asc '$_fa' - blank means the cell path moved)"
        # cavities draw on their OWN molecule, not the routes'
        set ::VMDPathFinder::state(cavity_shown_all) 1; ::VMDPathFinder::_cavity_show_all_toggle
        update idletasks; update
        # ask the RENDER which molecule it used, rather than creating one here
        # and hoping the two agree
        set _cm [::VMDPathFinder::_render_cavities_for_frame $_cfr]
        update idletasks; update
        set _tm [::VMDPathFinder::ensure_tunnel_surface_mol $mid]
        set _cg [expr {$_cm ne "" ? [llength [graphics $_cm list]] : -1}]
        report "cavities draw on their own track, not the routes'" \
               [expr {$_cm ne "" && $_cm != $_tm && $_cg > 0}] \
               "(cavity mol $_cm with $_cg primitives, route mol $_tm)"
        set ::VMDPathFinder::state(cavity_shown_all) 0; ::VMDPathFinder::_cavity_show_all_toggle
        update idletasks; update
        report "Hide all clears the cavity track" \
               [expr {$_cm eq "" || [llength [graphics $_cm list]] == 0}] ""
        # "use as start point" fills the field and says which rule it used
        set _saved_start $::VMDPathFinder::state(tunnel_start)
        set ::VMDPathFinder::state(cavity_origin_rule) mole
        ::VMDPathFinder::_cavity_use_as_start $_cfr $_cid
        set _s1 $::VMDPathFinder::state(tunnel_start)
        set _st1 $::VMDPathFinder::state(status)
        set ::VMDPathFinder::state(cavity_origin_rule) caver
        ::VMDPathFinder::_cavity_use_as_start $_cfr $_cid
        report "a cavity can seed the search, and reports which rule it used" \
               [expr {[llength $_s1] == 3 && [string match "*MOLE*" $_st1]
                      && $::VMDPathFinder::state(tunnel_start) ne $_s1
                      && [string match "*CAVER*" $::VMDPathFinder::state(status)]}] \
               "(MOLE $_s1 / CAVER $::VMDPathFinder::state(tunnel_start))"
        # Colour by a property: the cavity surface goes through the SAME
        # per-residue sidecar + recolour kernel a route and the pore wall use.
        # The two residue tables are not interchangeable - MOLE's own
        # charge/polarity/hydropathy are different constants from the HOLE
        # scales of similar name - and mole_residue_property answers 0.0 for a
        # token it does not carry, which produced a uniformly zero, flat
        # surface rather than an error. So check the VALUES, not just that a
        # file appeared.
        set _side "/tmp/vmdpathfinder_cavprop_[pid].txt"
        set _nrow 0
        catch {set _nrow [::VMDPathFinder::write_cavity_property_sidecar \
            $mid $_cfr $_cid $_side kd]}
        set _vlo 1e30; set _vhi -1e30; set _cols4 1
        if {$_nrow > 0 && ![catch {open $_side r} _sfh]} {
            foreach _row [split [string trim [read $_sfh]] "\n"] {
                if {[llength $_row] != 4} { set _cols4 0; continue }
                set _v [lindex $_row 3]
                if {$_v < $_vlo} { set _vlo $_v }
                if {$_v > $_vhi} { set _vhi $_v }
            }
            close $_sfh
        }
        catch {file delete $_side}
        report "a cavity's property sidecar carries real per-residue values" \
               [expr {$_nrow > 0 && $_cols4 && $_vhi > $_vlo}] \
               "($_nrow rows, kd range $_vlo..$_vhi - a flat range means the wrong table answered)"
        report "kr is not offered for cavities (atom-level, no residue value)" \
               [expr {"kr" ni [::VMDPathFinder::_cavity_prop_tokens]
                      && "kd" in [::VMDPathFinder::_cavity_prop_tokens]}] ""
        # and the colouring reaches the drawn surface
        set ::VMDPathFinder::tunnel_cavity_shown([dict get [lindex [::VMDPathFinder::_cavity_tracks] 0] tid]) 1
        set ::VMDPathFinder::state(cavity_prop) none
        set _cmA [::VMDPathFinder::_render_cavities_for_frame $_cfr]
        set _colA {}
        if {$_cmA ne ""} {
            foreach _it [graphics $_cmA list] {
                set _i [graphics $_cmA info $_it]
                if {[lindex $_i 0] eq "color"} { lappend _colA [lindex $_i 1] }
            }
        }
        set ::VMDPathFinder::state(cavity_prop) kd
        set _cmB [::VMDPathFinder::_render_cavities_for_frame $_cfr]
        set _colB {}
        if {$_cmB ne ""} {
            foreach _it [graphics $_cmB list] {
                set _i [graphics $_cmB info $_it]
                if {[lindex $_i 0] eq "color"} { lappend _colB [lindex $_i 1] }
            }
        }
        # Report the artefact too: if the recolour kernel could not run, the
        # renderer falls back to the flat colour and the colour counts are
        # equal - which must read as "the recolour did not happen", not as a
        # silently acceptable pass.
        set _rank [::VMDPathFinder::_cavity_rank_in_frame \
            [dict get [lindex [::VMDPathFinder::_cavity_tracks] 0] tid] $_cfr]
        set _fdc [file join $::VMDPathFinder::tunnel_root [format tunnel_%05d $_cfr]]
        set _cplot [file join $_fdc [format "cavity_%02d_kd_v1.plot" $_rank]]
        set _cgeo 0
        catch {set _cgeo [::VMDPathFinder::surface_has_geometry $_cplot]}
        # The recolour runs in sos_triangle; without that feature the renderer
        # falls back to the flat colour by design, and the assertion below would
        # be testing the environment rather than the code.
        set _h3d 0
        catch {set _h3d [::VMDPathFinder::sos_triangle_has_feature hydro3d]}
        report "colouring a cavity by a property reaches the drawn surface" \
               [expr {$_cgeo && [llength [lsort -unique $_colB]] > [llength [lsort -unique $_colA]]}] \
               "(why='[expr {[info exists ::VMDPathFinder::_cavity_color_why] ? $::VMDPathFinder::_cavity_color_why : {unset}}]' hydro3d=$_h3d prop=$::VMDPathFinder::state(cavity_prop) rank=$_rank exists=[file exists $_cplot] geometry=$_cgeo; flat [llength [lsort -unique $_colA]] colours, by-property [llength [lsort -unique $_colB]])"
        set ::VMDPathFinder::state(cavity_prop) none
        set ::VMDPathFinder::state(cavity_shown_all) 0; ::VMDPathFinder::_cavity_show_all_toggle
        set ::VMDPathFinder::state(tunnel_start) $_saved_start
        catch {destroy $w.tuncav}
    }
}

say "  ---- ALL CHECKS COMPLETE"


    # Closing the plugin must leave it REOPENABLE. vmd_install_extension
    # remembers the toplevel the extension returned the first time and just
    # maps that path afterwards, so destroying the window stranded the
    # Extensions entry for the rest of the session; and the entry is a toggle,
    # so VMD's own state has to be told it went off or the next click no-ops.
} err]} {
    incr fails
    say "  FAIL  the check itself errored: $err"
    say "$::errorInfo"
}
say "  ---- controls checked, $fails failed"
close $LOG
quit
