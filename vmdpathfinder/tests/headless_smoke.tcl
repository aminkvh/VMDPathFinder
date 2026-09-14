# Headless smoke test - run by test_headless_smoke.sh under `vmd -dispdev text`.
#
# Asserts NUMBERS, not "it ran". `vmd -dispdev text` exits 0 from plenty of broken
# states (a failed import happily reported "0 frames" and carried on), so a test
# that only checks for the absence of an error would have sailed straight through
# the bug this file exists to catch.
#
# Deliberately uses NO Tk stubs. The plugin must survive a genuinely Tk-less
# interpreter on its own - stubbing winfo/tk_messageBox here would hide exactly
# the class of defect being tested (headless GUI calls).
set pass 0; set fail 0
proc chk {name got want} {
    global pass fail
    if {$got eq $want} { incr pass; puts "  PASS  $name = $got" } \
    else { incr fail; puts "  FAIL  $name = $got (expected $want)" }
}
# [info script] is EMPTY under `vmd -e`, so the wrapper passes the directory in
# explicitly; fall back to cwd for a hand-run.
set here [expr {[info exists ::env(VMDPATHFINDER_TEST_DIR)] && $::env(VMDPATHFINDER_TEST_DIR) ne ""
                ? $::env(VMDPATHFINDER_TEST_DIR) : [pwd]}]
cd [file join $here ..]
source vmdpathfinder.tcl

# 1. No Tk at all - this is the predicate R-07 introduced and the thing that regressed.
chk "_have_tk (must be 0 headless)" [::VMDPathFinder::_have_tk] 0
# The dated build stamp is OPTIONAL as of 1.0.0 - dated stamps belong to nightly
# builds, and a tagged release is identified by its version alone. So assert the
# VERSION instead, and additionally that the two places declaring it inside this file
# agree: "bumped one place, forgot the other" is the failure this check exists for,
# and an empty stamp no longer detects it.
chk "version present" [expr {$::VMDPathFinder::version ne "" ? 1 : 0}] 1

# 2. The plugin's own parser on a FROZEN fixture.
#    ⚠️ This deliberately does NOT read a run directory under vmdpathfinder/. The first
#    version of this test asserted against hole_output_step5_assembly.hmr, which is a
#    LIVE working directory - the user re-ran the analysis, the numbers moved, the test
#    went red, and later the directory was cleared away entirely. A fixture must be data
#    the test owns and nothing else writes.
set fd [file join $here fixtures profile_1BL8]
if {[file isdirectory $fd]} {
    set r [::VMDPathFinder::parse_profile [file join $fd hole_out.txt] [file join $fd hole_profile.tsv] 1]
    chk "profile points"     [dict get $r points]     639
    chk "profile min_radius" [dict get $r min_radius] 0.53057
    chk "profile min_coord"  [dict get $r min_coord]  35.07169
} else { puts "  SKIP  profile fixture missing" }

# 2b. CONNOLLY with a FAILED slice (fixtures/connolly_failed_slice - see its README).
#     Both assertions below were RED before : min_radius came back 0.0
#     because HOLE's uninitialised requiv=0 was read as a real radius, and the
#     conductance factor came back as the SPHERICAL 10.80189 because the Connolly
#     column was Infinity and the code fell through to column 4.
set cfd [file join $here fixtures connolly_failed_slice hole_profile.tsv]
if {[file exists $cfd]} {
    set cr [::VMDPathFinder::parse_profile_from_tsv $cfd 1]
    # A failed slice must NOT be reported as a sealed pore.
    chk "connolly failed-slice min_radius" [dict get $cr min_radius] 0.254
    chk "connolly run detected"            [dict get $cr conn_run]   1
    # The factor must be the rebuilt CONNOLLY one, never the spherical 10.80189 and
    # never Infinity.
    set cF [::VMDPathFinder::profile_cond_F $cr]
    chk "connolly F is finite"      [expr {[string is double -strict $cF] && $cF > 0 && $cF < 1.0e7}] 1
    chk "connolly F is not spherical" [expr {abs($cF - [dict get $cr cond_F]) > 0.01}] 1
    chk "connolly F value"          [format %.4f $cF] 10.4807
} else { puts "  SKIP  connolly failed-slice fixture missing" }

# 3. The full batch import path, unstubbed. This is what broke: activate_molecule ->
#    refresh_results_list / update_frame_slider / update_transport_for_frame /
#    select_result / draw_profile_plot all called `winfo`, which is UNDEFINED here.
set psf [file join $here .. step5_assembly.hmr.psf]
set dcd [file join $here .. sim_1.dcd]
if {[file exists $psf] && [file exists $dcd]
    && [file isdirectory [file join $here .. hole_output_step5_assembly.hmr]]} {
    set m [mol new $psf type psf waitfor all]
    mol addfile $dcd type dcd waitfor all molid $m
    set ::VMDPathFinder::state(import_dir) [file normalize [file join $here .. hole_output_step5_assembly.hmr]]
    # Live directory: present only if the user has a current run. Skipped when absent
    # rather than failing - this arm tests the headless IMPORT PATH, not any number.
    set err ""
    if {[catch {::VMDPathFinder::import_results_from_folder} e]} { set err $e }
    chk "import raised no error" [expr {$err eq "" ? 1 : 0}] 1
    if {$err ne ""} { puts "        error: $err" }
    # Assert the PATH worked, not a count: the run directory is the user's live data
    # and its frame count changes every time they recompute. Hardcoding 50 here made
    # this test fail for a reason that had nothing to do with the code.
    chk "imported at least one frame" [expr {[llength $::VMDPathFinder::result_frames] >= 1 ? 1 : 0}] 1

    # Bottleneck residues must resolve on EVERY imported frame. They silently
    # covered 29 of 50: _hole_bottleneck_point rebuilt a 3D point from the TSV's
    # cen_line_d along CPOINT/CVECT, which landed ~8.5 A off HOLE's own minimum
    # sphere and out in bulk (nearest atom 8 A), so no residue lined it; and a
    # negative radius (a sterically CLOSED pore - real data) was rejected outright.
    # Asserted as full coverage, not a hardcoded count, so it tracks the user's
    # live run the way the checks above deliberately do.
    set _nbn 0
    set _nfr [llength $::VMDPathFinder::result_frames]
    foreach _f $::VMDPathFinder::result_frames {
        set _pt [::VMDPathFinder::_hole_bottleneck_point $_f]
        if {$_pt eq ""} { continue }
        lassign $_pt _bx _by _bz _br
        if {[llength [::VMDPathFinder::_bottleneck_residue_labels $m $_f \
                [list $_bx $_by $_bz] $_br]] > 0} { incr _nbn }
    }
    chk "bottleneck residues resolve on every imported frame ($_nbn/$_nfr)" \
        [expr {$_nfr > 0 && $_nbn == $_nfr ? 1 : 0}] 1
} else { puts "  SKIP  import path (needs psf/dcd + a current run directory)" }

# 4. CAVER trajectory ranking, checked against CAVER's OWN published summary for
#    the DhaA trajectory. This is
#    the only external ground truth available for the cross-snapshot layer: MOLE
#    validates the PER-SNAPSHOT tunnels but has no trajectory concept at all, so
#    the clustering/priority half has to be validated against CAVER's numbers.
#      priority = (No_snaps / N_total) * Avg_throughput
#    with the divisor being EVERY snapshot analysed (rarity is penalised, not
#    averaged away) and ONE pathway per snapshot per cluster (the highest
#    throughput), so near-duplicates in one frame cannot inflate a cluster.
# The FORMULA is what these six rows validate, so the throughput source is
# stubbed to the tuple's own field. In real use _tunnel_throughput computes
# e^(-0.1*int ds/r^2) from the profile, because MOLE writes literal 0.0 into the
# cost/throughput columns of every T record - reading that field would make every
# cluster tie at priority 0.
proc ::VMDPathFinder::_tunnel_throughput {tuple} { return [lindex $tuple 3] }
set NTOT 10000
foreach {cid nsnaps avgthr stated} {
    1 9634 0.50998 0.49132
    2 6658 0.40239 0.26791
    3 4855 0.40268 0.19550
    4 5415 0.32219 0.17447
    5 3877 0.34484 0.13369
    6 2765 0.30686 0.08485
} {
    array unset ::VMDPathFinder::tunnel_results
    set cluster {}
    for {set f 0} {$f < $nsnaps} {incr f} {
        # tuple = {bottleneck length cost throughput pts}
        set ::VMDPathFinder::tunnel_results($f) [list [list 1.0 0 0 $avgthr {}]]
        lappend cluster [list $f 1]
    }
    set got [::VMDPathFinder::_tunnel_cluster_priority $cluster $NTOT]
    chk "CAVER priority cluster $cid ([format %.5f $got] vs $stated)" \
        [expr {abs($got - $stated) < 1e-5 ? 1 : 0}] 1
}
# One pathway per snapshot: a same-frame near-duplicate must NOT add throughput,
# and the HIGHEST of the two must be the one counted.
array unset ::VMDPathFinder::tunnel_results
set ::VMDPathFinder::tunnel_results(0) [list [list 1.0 0 0 0.20 {}] [list 1.0 0 0 0.60 {}]]
set p_one  [::VMDPathFinder::_tunnel_cluster_priority {{0 2}} 10]
set p_both [::VMDPathFinder::_tunnel_cluster_priority {{0 1} {0 2}} 10]
chk "same-frame duplicates do not inflate priority" \
    [expr {abs($p_one - $p_both) < 1e-12 ? 1 : 0}] 1
chk "the highest-throughput pathway in a snapshot is the one counted" \
    [expr {abs($p_both - 0.06) < 1e-9 ? 1 : 0}] 1
array unset ::VMDPathFinder::tunnel_results

# 5. The cross-snapshot lookup must FOLLOW a cluster across frames, and must say
#    "absent" rather than silently substituting whatever holds that rank. Built on
#    a synthetic 3-frame set where the same tunnel sits at rank 1, 3 and (absent).
array unset ::VMDPathFinder::tunnel_results
proc _mkpts {x} {
    set p {}
    for {set i 0} {$i < 12} {incr i} { lappend p $x 0.0 [expr {$i*1.0}] 1.5 }
    return $p
}
# frame 0: rank1 = tunnel A ; frame 1: rank1 = far tunnel, rank2 = tunnel A
set ::VMDPathFinder::tunnel_results(0) [list [list 1.5 0 0 0.9 [_mkpts 0.0]]]
set ::VMDPathFinder::tunnel_results(1) [list [list 1.5 0 0 0.9 [_mkpts 40.0]] \
                                      [list 1.5 0 0 0.8 [_mkpts 0.2]]]
set ::VMDPathFinder::tunnel_results(2) [list [list 1.5 0 0 0.9 [_mkpts 80.0]]]
set ::VMDPathFinder::tunnel_result_frames {0 1 2}
set ::VMDPathFinder::state(tunnel_cluster) 3.0
set ::VMDPathFinder::state(tunnel_xframe_max) 10
::VMDPathFinder::_tunnel_xframe_build
proc ::VMDPathFinder::_tunnel_display_frame {} { return 0 }
set ::VMDPathFinder::state(tunnel_selected_id) 1
chk "cross-frame lookup follows the tunnel to its rank 2 in frame 1" \
    [::VMDPathFinder::_tunnel_rank_in_frame 1] 2
chk "cross-frame lookup keeps rank 1 in its own frame" \
    [::VMDPathFinder::_tunnel_rank_in_frame 0] 1
chk "cross-frame lookup reports ABSENT where the tunnel is not found" \
    [expr {[::VMDPathFinder::_tunnel_rank_in_frame 2] eq "" ? 1 : 0}] 1
array unset ::VMDPathFinder::tunnel_results
set ::VMDPathFinder::tunnel_result_frames {}

# 5b. The trajectory-wide collectors (Over Time / Trends / Mean Profile /
#     Histogram's data source) must not blank on a frame the SELECTED
#     cluster is merely absent from. state(tunnel_selected_id) is a RANK in
#     the DISPLAYED frame and is legitimately "" there (5's own check just
#     proved that "absent" case is real) - gating the collectors on it
#     instead of the frame-independent CLUSTER pin (state(tunnel_selected_
#     cid), via _tunnel_selected_cluster) blanked every trajectory-wide view
#     the instant you stepped onto such a frame, even though their own loops
#     already walk every frame regardless of which one is displayed.
#
#     Also checks the collectors' cache keys directly: two DIFFERENT
#     clusters that happen to share the same RANK in their own frames (a
#     rank-keyed cache key cannot tell them apart) must not read back each
#     other's data.
array unset ::VMDPathFinder::tunnel_results
proc _tpts {x0 rmid} {
    # 5 points along z, dipping to $rmid at the middle - a real bottleneck
    # (not a flat radius), so a wrong-cluster cache hit is numerically
    # distinguishable from the right one.
    set p {}
    foreach dz {0 1 2 3 4} r [list [expr {$rmid+2}] [expr {$rmid+1}] $rmid [expr {$rmid+1}] [expr {$rmid+2}]] {
        lappend p $x0 0.0 [expr {double($dz)}] $r
    }
    return $p
}
set ::VMDPathFinder::tunnel_results(0) [list [list 1.0 4.0 0 0 [_tpts 0.0 1.0]]]
set ::VMDPathFinder::tunnel_results(1) {}
set ::VMDPathFinder::tunnel_results(2) [list [list 1.0 4.0 0 0 [_tpts 0.0 1.0]]]
set ::VMDPathFinder::tunnel_results(3) [list [list 5.0 4.0 0 0 [_tpts 100.0 5.0]]]
set ::VMDPathFinder::tunnel_result_frames {0 1 2 3}
set ::VMDPathFinder::state(tunnel_cluster) 3.0
set ::VMDPathFinder::state(tunnel_xframe_max) 10
set ::VMDPathFinder::binned_cache [dict create]
set ::VMDPathFinder::hm_bundle_cache [dict create]
::VMDPathFinder::_tunnel_xframe_build
chk "synthetic fixture forms exactly 2 clusters (A present twice, B once)" \
    [llength $::VMDPathFinder::tunnel_xclusters] 2
set cidA $::VMDPathFinder::tunnel_xcid(0,1)
set cidB $::VMDPathFinder::tunnel_xcid(3,1)
chk "the two synthetic clusters are distinct" [expr {$cidA != $cidB ? 1 : 0}] 1

set ::VMDPathFinder::state(tunnel_selected_cid) $cidA
::VMDPathFinder::_tunnel_sync_selected_id 1
chk "tunnel_selected_id is empty on the frame the pinned cluster is absent from" \
    [expr {$::VMDPathFinder::state(tunnel_selected_id) eq "" ? 1 : 0}] 1

set radiiA [::VMDPathFinder::_tunnel_collect_binned_radii 20]
chk "_tunnel_collect_binned_radii does not blank on that absent-DISPLAYED-frame" \
    [expr {$radiiA ne {} ? 1 : 0}] 1
chk "...and still pools BOTH of the cluster's real frames (0 and 2)" \
    [expr {$radiiA ne {} ? [dict get $radiiA nframes] : -1}] 2

set bundleA [::VMDPathFinder::_tunnel_heatmap_bundle 40 20]
chk "_tunnel_heatmap_bundle (Over Time) does not blank on that absent-DISPLAYED-frame" \
    [dict get $bundleA ndata] 2

# _tunnel_effective_prop_for_cluster (Mean Profile Fill's property source)
# must resolve a gear override through the CLUSTER too - the rank-keyed
# mirror it replaces here is only populated for ranks present in the landed
# frame, so it goes stale on the very frame this is about.
set ::VMDPathFinder::tunnel_gear_cid($cidA,prop) logp
chk "_tunnel_effective_prop_for_cluster reads a gear override on an absent-DISPLAYED-frame" \
    [::VMDPathFinder::_tunnel_effective_prop_for_cluster $cidA] logp
unset ::VMDPathFinder::tunnel_gear_cid($cidA,prop)

# Rank COLLISION: A is rank 1 wherever it is present (frames 0/2); B is
# ALSO rank 1 in its own only frame (3) - the exact aliasing a rank-keyed
# cache confuses. Computed (not just synced) while landed ON A's own present
# frame, so a rank-keyed cache actually WRITES an entry under "tun:1|..." -
# the earlier absent-frame call never reached the cache at all (old code
# returned {} before ever touching it), so it alone could not exercise this.
::VMDPathFinder::_tunnel_sync_selected_id 0
chk "(setup) A really is rank 1 where it is present" $::VMDPathFinder::state(tunnel_selected_id) 1
::VMDPathFinder::_tunnel_collect_binned_radii 20
set ::VMDPathFinder::state(tunnel_selected_cid) $cidB
::VMDPathFinder::_tunnel_sync_selected_id 3
chk "(setup) B is ALSO rank 1 in its own frame - the collision this checks" \
    $::VMDPathFinder::state(tunnel_selected_id) 1
set radiiB [::VMDPathFinder::_tunnel_collect_binned_radii 20]
set _minB 1e30
if {$radiiB ne {}} {
    foreach _s [dict get $radiiB stats] { if {$_s ne {} && [lindex $_s 0] < $_minB} { set _minB [lindex $_s 0] } }
}
chk "cluster B's own bottleneck radius comes back (not A's, via a same-rank cache collision)" \
    [expr {abs($_minB - 5.0) < 1e-6 ? 1 : 0}] 1

array unset ::VMDPathFinder::tunnel_results
set ::VMDPathFinder::tunnel_result_frames {}
set ::VMDPathFinder::state(tunnel_selected_cid) ""
set ::VMDPathFinder::state(tunnel_selected_id) ""
set ::VMDPathFinder::binned_cache [dict create]
set ::VMDPathFinder::hm_bundle_cache [dict create]

# 6. Provenance manifest. A saved tunnel directory could not be reproduced or
#    even interpreted later: selection, MOLE parameters, origin, alignment and
#    engine build are all invisible in the .sph/out.dat files themselves.
set _mdir [file join $here _manifest_test]
catch {file delete -force $_mdir}
file mkdir $_mdir
set ::VMDPathFinder::state(selection) "protein and not water"
catch {::VMDPathFinder::_write_tunnel_manifest $_mdir 0 {0 1 2} [dict create] {1.0 2.0 3.0} 1 mole-c}
set _mf [file join $_mdir vmdpathfinder_tunnel_manifest.txt]
set _mtxt ""
if {[file exists $_mf]} { set _fh [open $_mf r]; set _mtxt [read $_fh]; close $_fh }
chk "tunnel run writes a provenance manifest" [expr {$_mtxt ne "" ? 1 : 0}] 1
foreach _k {plugin_version engine engine_stamp selection frame_list origin_mode
            origin_point align_trajectory cluster_threshold xframe_max_ranks
            lining_shell_A mole_parameters} {
    chk "manifest records $_k" [expr {[string match "*$_k*=*" $_mtxt] ? 1 : 0}] 1
}
chk "manifest records the ACTUAL selection, not a default" \
    [expr {[string match "*protein and not water*" $_mtxt] ? 1 : 0}] 1
catch {file delete -force $_mdir}

# 7. Rendered-tunnel terminal trim. A MOLE tunnel's clearance radius runs away
#    where it leaves the structure, and meshing those spheres balloons the mouth.
#    The trim must cut ONLY the runaway ends and must never touch a real pore.
set _mk {}
for {set i 0} {$i < 20} {incr i} { lappend _mk 0.0 0.0 [expr {$i*1.0}] 2.0 }
chk "trim leaves a normal-radius tunnel untouched" \
    [llength [::VMDPathFinder::_tunnel_render_centers $_mk]] 20
set _bal {}
for {set i 0} {$i < 20} {incr i} {
    lappend _bal 0.0 0.0 [expr {$i*1.0}] [expr {$i < 15 ? 2.0 : 9.0}]
}
set _tr [::VMDPathFinder::_tunnel_render_centers $_bal]
chk "trim removes a runaway terminal balloon" [llength $_tr] 15
set _rs {}
foreach _e $_tr { lappend _rs [lindex $_e 3] }
chk "trim leaves no sphere above the cap" \
    [expr {[lindex [lsort -real $_rs] end] <= 6.0 ? 1 : 0}] 1
# A route that is wide along its WHOLE length must still be drawn - being wide
# everywhere is itself the signal that it is not a channel, not a reason to hide it.
set _wide {}
for {set i 0} {$i < 20} {incr i} { lappend _wide 0.0 0.0 [expr {$i*1.0}] 9.0 }
chk "trim never deletes an entirely-wide route" \
    [llength [::VMDPathFinder::_tunnel_render_centers $_wide]] 20

# 8. A REFUSAL (engine ran, declined bad input) must not be reported as
#    "unavailable" (engine missing/broken install) - two different problems
#    with two different fixes, real user confusion when conflated (a
#    multi-conformer atom set on 1MXT reported as "MOLE engine unavailable",
#    sending the user looking for a missing binary).
set _mdir2 [file join $here _altloc_test]
catch {file delete -force $_mdir2}
file mkdir $_mdir2
set _apdb [file join $_mdir2 altloc.pdb]
set _afh [open $_apdb w]
puts $_afh "ATOM      1  N   ALA A   1       0.000   0.000   0.000  1.00  0.00           N"
puts $_afh "ATOM      2  CA  ALA A   1       1.458   0.000   0.000  1.00  0.00           C"
puts $_afh "ATOM      3  C   ALA A   1       2.009   1.420   0.000  1.00  0.00           C"
puts $_afh "ATOM      4  O   ALA A   1       1.400   2.470   0.000  1.00  0.00           O"
puts $_afh "ATOM      5  CB AALA A   1       2.000  -1.200   1.000  0.50  0.00           C"
puts $_afh "ATOM      6  CB BALA A   1       2.100  -1.300  -1.000  0.50  0.00           C"
puts $_afh "ATOM      7  N   GLY A   2       3.300   1.400   0.000  1.00  0.00           N"
puts $_afh "ATOM      8  CA  GLY A   2       4.000   2.700   0.100  1.00  0.00           C"
puts $_afh "ATOM      9  C   GLY A   2       5.500   2.700   0.200  1.00  0.00           C"
puts $_afh "ATOM     10  O   GLY A   2       6.200   3.700   0.200  1.00  0.00           O"
puts $_afh "ATOM     11  N   ALA A   3       6.000   1.500   0.300  1.00  0.00           N"
puts $_afh "ATOM     12  CA  ALA A   3       7.400   1.400   0.400  1.00  0.00           C"
puts $_afh "ATOM     13  C   ALA A   3       8.000   2.800   0.500  1.00  0.00           C"
puts $_afh "ATOM     14  O   ALA A   3       7.400   3.900   0.500  1.00  0.00           O"
puts $_afh "ATOM     15  CB  ALA A   3       8.000   0.500  -0.800  1.00  0.00           C"
close $_afh
set _am [mol new $_apdb]
set ::VMDPathFinder::state(molid) $_am
set ::VMDPathFinder::state(selection) "protein"
set _arc [catch {::VMDPathFinder::tunnel_search $_am 0 {2.0 1.0 0.0} [dict create]} _amsg]
chk "engine ran and errored" $_arc 1
chk "refusal is NOT reported as unavailable" \
    [expr {[string match "*unavailable*" $_amsg] ? 0 : 1}] 1
chk "refusal names the actual cause" \
    [expr {[string match "*refused this input*" $_amsg] ? 1 : 0}] 1
chk "refusal preserves the engine's own diagnostic" \
    [expr {[string match "*alternate location*" $_amsg] ? 1 : 0}] 1
catch {mol delete $_am}
catch {file delete -force $_mdir2}

# 9. MOLE-native-format export: same file layout/column names as a real MOLE
#    run, so a user can diff the output directly against
#    vmdpathfinder/tests/fixtures/mole_reference/<structure>/ without translating columns.
array unset ::VMDPathFinder::tunnel_results
array unset ::VMDPathFinder::tunnel_lining
proc _mkpts2 {x} {
    set p {}
    for {set i 0} {$i < 5} {incr i} { lappend p $x 0.0 [expr {$i*1.0}] 1.5 }
    return $p
}
set ::VMDPathFinder::tunnel_results(0) [list [list 1.5 4.0 0 0.9 [_mkpts2 0.0] 1]]
set ::VMDPathFinder::tunnel_result_frames {0}
proc ::VMDPathFinder::_tunnel_display_frame {} { return 0 }
set _outdir [file join $here _mole_fmt_test]
catch {file delete -force $_outdir}
file mkdir $_outdir
proc tk_chooseDirectory {args} { return $::_outdir }
::VMDPathFinder::export_mole_native_format
set _tc ""
if {[file exists [file join $_outdir tunnels.csv]]} {
    set _fh [open [file join $_outdir tunnels.csv] r]; set _tc [read $_fh]; close $_fh
}
chk "MOLE-format export writes tunnels.csv with MOLE's own header" \
    [expr {[string match "Id,Length,Charge,Ionizable,Hydropathy,Hydrophobicity,Polarity,LogP,LogD,LogS,Mutability*" $_tc] ? 1 : 0}] 1
chk "MOLE-format export names the tunnel T<rank>C<cavity>" \
    [expr {[string match "*T1C1*" $_tc] ? 1 : 0}] 1
set _pc ""
if {[file exists [file join $_outdir tunnel_1.csv]]} {
    set _fh [open [file join $_outdir tunnel_1.csv] r]; set _pc [read $_fh]; close $_fh
}
chk "MOLE-format export writes tunnel_1.csv with MOLE's own header" \
    [expr {[string match {*"T","Distance","Radius","FreeRadius","BRadius","X","Y","Z"*} $_pc] ? 1 : 0}] 1
catch {file delete -force $_outdir}
array unset ::VMDPathFinder::tunnel_results
array unset ::VMDPathFinder::tunnel_lining
set ::VMDPathFinder::tunnel_result_frames {}

# --- HOLE's 80-char FORTRAN control record --------------------------------
# coord and sphpdb are bare names for this reason, but the RADIUS path was
# written in full. Past 80 chars HOLE truncates it and the whole run dies with
# "Cannot open bond/vdw radius input file" - no profile, no .sph, no surface,
# and on screen only "no pore found". Latent for ~/hole2/rad/simple.rad, fatal
# for a deep one, which is why it survived: every short-path install works.
set _cdir [file join [::VMDPathFinder::get_temp_base] "vmdpathfinder_card_[pid]"]
file mkdir $_cdir
set _deep [file join $_cdir [string repeat "averylongdirectoryname/" 4]]
file mkdir $_deep
set _rad [file join $_deep simple.rad]
set _rh [open $_rad w]; puts $_rh "VDWR ??? ??? 1.85"; close $_rh
set _save $::VMDPathFinder::state(radius_file)
set ::VMDPathFinder::state(radius_file) $_rad
::VMDPathFinder::write_control_file [file join $_cdir hole.inp] input_frame.pdb hole_out.sph
set ::VMDPathFinder::state(radius_file) $_save
set _ch [open [file join $_cdir hole.inp] r]
set _cards [split [string trimright [read $_ch] "\n"] "\n"]
close $_ch
set _longest 0
foreach _l $_cards { if {[string length $_l] > $_longest} { set _longest [string length $_l] } }
chk "no control card exceeds HOLE's 80-char record" [expr {$_longest <= 80 ? 1 : 0}] 1
# Bare name only helps if the file is actually there to open.
set _staged 0
foreach _l $_cards {
    if {[string match "radius *" $_l]} {
        set _rf [string trim [string range $_l 6 end]]
        set _staged [file exists [file join $_cdir $_rf]]
    }
}
chk "the radius file is staged next to the control file" $_staged 1
catch {file delete -force $_cdir}

# --- a display-mode switch must invalidate cached surfaces ----------------
# apply_display_change stamped last_geom_key BEFORE its "no result row
# selected" guard, so a mode change made in that state (the normal state after
# Run + Play) recorded itself as applied while dropping nothing. Every later
# call compared equal, so frames already cached under the old mode kept
# rendering in it: centerline selected, isosurface on screen, and only on the
# frames that happened to be cached. Asserted on the ASSET KINDS, which is
# what the renderer dispatches on - a check that only read state(display_mode)
# would have passed throughout the bug.
set ::VMDPathFinder::results [dict create 0 [dict create asset [dict create kind vmd_plot path /x] ] \
                                    1 [dict create asset [dict create kind vmd_plot path /y] ]]
set ::VMDPathFinder::last_geom_key "mesh"
set ::VMDPathFinder::state(display_mode) centerline
set ::VMDPathFinder::state(selected_result_frame) ""
catch {::VMDPathFinder::apply_display_change}
set _stale 0
foreach _f {0 1} {
    if {[dict get $::VMDPathFinder::results $_f asset] ne {}} { incr _stale }
}
chk "a mode switch with no row selected still drops cached surfaces" $_stale 0
# And it must NOT claim the change was applied if it bailed before invalidating.
chk "the geometry key tracks the mode that was actually applied" \
    $::VMDPathFinder::last_geom_key "centerline"

# A crash inside HOLE must be reported AS a crash. HOLE prints a Fortran runtime
# error, not its own "***ERROR***" block, so it used to fall through to "no pore
# found - try setting CVECT", sending the user to fix something that is not
# broken. The `sphbox` card triggers this for real: a format-descriptor bug in
# HOLE 2 itself. Synthetic fixture on purpose - the point is the parser, and a
# test that needed the crashing binary would skip on any machine without it.
set _cr [file join [::VMDPathFinder::get_temp_base] "vmdpathfinder_crash_[pid].txt"]
set _fh [open $_cr w]
puts $_fh " Have read  1360 atom records."
puts $_fh "Fortran runtime error: Expected INTEGER for item 2, got LOGICAL"
puts $_fh ""
puts $_fh "Error termination. Backtrace:"
close $_fh
set _cp [::VMDPathFinder::parse_profile $_cr [file join [::VMDPathFinder::get_temp_base] "vmdpathfinder_crash_[pid].tsv"]]
chk "a HOLE crash is not reported as a valid profile" [dict get $_cp valid] 0
set _cm [dict get $_cp message]
chk "the crash message quotes the real fault" \
    [string match "*Fortran runtime error*" $_cm] 1
chk "the crash message does NOT blame CVECT/CPOINT" \
    [string match "*CVECT*" $_cm] 0
chk "the crash message does NOT blame the radius file" \
    [string match "*van der Waals*" $_cm] 0
# The threaded parser is a separate copy running in a bare interpreter; it must
# carry the same helper or it faults in the worker instead of reporting.
chk "the worker thread gets the hint helper too" \
    [string match "*proc _hole_error_hint*" [::VMDPathFinder::_thread_parse_initscript]] 1
# A Thread::create startup script that just RETURNS kills the worker (Tcl
# Thread manual) - the async sends would then hit a dead target, or the vwait
# would never return. The script must end by entering the event loop.
set _tis [::VMDPathFinder::_thread_parse_initscript]
chk "the worker init script enters thread::wait" \
    [string match "*thread::wait*" $_tis] 1
chk "...as its LAST statement, not before the procs are defined" \
    [expr {[string first "thread::wait" $_tis] > [string last "proc _hole_error_hint" $_tis]}] 1
# The threaded path must be able to give up. Without a catch around the send
# and a bounded wait, a dead worker hangs the GUI with no route to the serial
# fallback that already exists below it.
set _pb [info body ::VMDPathFinder::parse_profiles_batch]
chk "the async send is guarded so the serial fallback is reachable" \
    [string match "*catch {thread::send -async*" $_pb] 1
chk "the collect vwait has a watchdog rather than waiting forever" \
    [expr {[string match "*after 600000*" $_pb] && [string match "*_thr_dead*" $_pb]}] 1
catch {file delete -force $_cr}

# MC search controls (mcstep / mcdisp / mckt). Six places have to agree or the
# field is decorative: control file, fallback translator, validation, and the run
# signature - which is the one that fails SILENTLY, by reusing a cached frame
# computed at a different setting.
set _mw [file join [::VMDPathFinder::get_temp_base] "vmdpathfinder_mc_[pid]"]
file mkdir $_mw
array set ::VMDPathFinder::state [list sample 0.5 endrad 8.0 shorto 0 random_seed 1 \
    ignore {} extra_cards {} pore_method circular radius_file /dev/null \
    cpoint {0 0 0} cvect {0 0 1} hole_exec {} mcstep {} mcdisp {} mckt {}]
# Blank must emit NO card, so HOLE keeps its own defaults instead of us
# restating numbers that could drift from the binary's.
::VMDPathFinder::write_control_file [file join $_mw a.inp] in.pdb o.sph {0 0 0} {0 0 1}
set _fh [open [file join $_mw a.inp]]; set _a [read $_fh]; close $_fh
chk "blank MC fields emit no card" [regexp -all {mc(step|disp|kt)} $_a] 0
set _sig_blank [::VMDPathFinder::run_signature -1 all]
array set ::VMDPathFinder::state {mcstep 300 mcdisp 0.2 mckt 0.15}
::VMDPathFinder::write_control_file [file join $_mw b.inp] in.pdb o.sph {0 0 0} {0 0 1}
set _fh [open [file join $_mw b.inp]]; set _b [read $_fh]; close $_fh
foreach _c {"mcstep 300" "mcdisp 0.2" "mckt 0.15"} {
    chk "control file carries '$_c'" [string match "*$_c*" $_b] 1
}
lassign [::VMDPathFinder::_hole_tcl_args_from_inp [file join $_mw b.inp]] _st _ar
chk "the fallback translates the MC cards" $_st ok
# hole.f calls it MCDISP; the engine's own flag is -mclen. A straight-through
# name would silently drop it.
foreach {_f _v} {-mcstep 300 -mclen 0.2 -mckt 0.15} {
    chk "fallback gets $_f" [lindex $_ar [expr {[lsearch -exact $_ar $_f]+1}]] $_v
}
chk "a changed MC setting is a different run" \
    [expr {[::VMDPathFinder::run_signature -1 all] ne $_sig_blank}] 1
foreach _bad {0 -5 abc} {
    set ::VMDPathFinder::state(mcstep) $_bad
    chk "MC steps '$_bad' is rejected" [catch {::VMDPathFinder::validate_inputs}] 1
}
array set ::VMDPathFinder::state {mcstep {} mcdisp {} mckt {}}
catch {file delete -force $_mw}

# --- refresh_results_list must invalidate; _redisplay_results_list must not ---
# The mode switch and the GUI reopen only REDISPLAY the frame list, but both used
# to route through refresh_results_list, whose unconditional bump wiped every
# analysis cache in both modes plus the Over Time "click Compute" gate. Headless,
# analysis_mode is pinned to "hole" and $w.sidebar.nb never exists, so the mode
# switch itself is unreachable here - assert the split directly instead, which is
# the part that discriminates. section B.
set ::VMDPathFinder::result_frames {0}
set ::VMDPathFinder::results [dict create 0 [dict create run_id 1 \
    profile [dict create valid 1 min_radius 1.25 points {}]]]
::VMDPathFinder::refresh_results_list
set ::VMDPathFinder::_hm_computed_scheme "kd"
dict set ::VMDPathFinder::hm_prop_cache probe 1
set _v0 $::VMDPathFinder::plot_data_version
::VMDPathFinder::_redisplay_results_list
chk "redisplay keeps the data version" $::VMDPathFinder::plot_data_version $_v0
chk "redisplay keeps the Over Time compute gate" $::VMDPathFinder::_hm_computed_scheme kd
chk "redisplay keeps the property cache" [dict size $::VMDPathFinder::hm_prop_cache] 1
::VMDPathFinder::refresh_results_list
chk "a real refresh bumps the data version" \
    [expr {$::VMDPathFinder::plot_data_version != $_v0}] 1
chk "a real refresh clears the compute gate" $::VMDPathFinder::_hm_computed_scheme ""
chk "a real refresh clears the property cache" [dict size $::VMDPathFinder::hm_prop_cache] 0

# --- a crashed HOLE engine must not be registered as a result -------------
# The job script runs cp/awk/printf/rm AFTER the engine, so the pipe close only
# ever saw the last command's status and a segfaulting HOLE looked clean. The
# engine's own status is now recorded per frame; these assert the reader that
# Phase 3 gates on. Absent file => "" => treated as no evidence of a crash, so
# imported/older runs stay usable.
set _sd [file join $::env(HOME) .vmdpathfinder_status_test]
catch {file delete -force $_sd}
file mkdir $_sd
chk "no status file reads as unknown, not failure" [::VMDPathFinder::_hole_frame_status $_sd] ""
set _fh [open [file join $_sd vmdpathfinder_status.dat] w]; puts -nonewline $_fh "0"; close $_fh
chk "a clean run reports 0" [::VMDPathFinder::_hole_frame_status $_sd] 0
set _fh [open [file join $_sd vmdpathfinder_status.dat] w]; puts -nonewline $_fh "139\n"; close $_fh
chk "a segfault (139) is reported, whitespace trimmed" [::VMDPathFinder::_hole_frame_status $_sd] 139
catch {file delete -force $_sd}
# ORDER is the whole invariant here: $? must be read before the script's
# cp/awk/printf/rm can overwrite it. Checked against the GENERATOR's body (the
# ordering of its "puts $fh" lines) - a real end-to-end run needs a HOLE binary
# and a loaded trajectory, neither of which this suite has.
set _body [info body ::VMDPathFinder::run_analysis]
set _emit {}
foreach _l [split $_body "\n"] {
    set _t [string trim $_l]
    if {![string match "puts \$fh*" $_t]} { continue }
    lappend _emit $_t
}
set _ei -1; set _si -1
for {set _i 0} {$_i < [llength $_emit]} {incr _i} {
    set _l [lindex $_emit $_i]
    if {$_ei < 0 && [string match "*hole.inp*hole_out.txt*" $_l]} { set _ei $_i }
    if {$_si < 0 && [string match "*_vh_rc=*" $_l]}               { set _si $_i }
}
chk "the job script captures the engine status" [expr {$_si >= 0}] 1
chk "...on the line right after the engine, before cp/awk/rm clobber it" \
    [expr {$_ei >= 0 && $_si == $_ei + 1}] 1
# ...and the script must EXIT with it, so the job pool's failure count and
# vmdpathfinder_status.dat cannot disagree about whether the frame succeeded.
chk "the job script exits with the engine's status, not the cleanup's" \
    [expr {[lindex $_emit end] eq "puts \$fh \"exit \\\$_vh_rc\""}] 1

# --- tunnel run: re-entrancy guard + no stale out.dat -----------------------
# The job pool calls [update], so a second Run click could re-enter the tunnel
# run and launch a second set of engines against the same directories. And the
# engine only truncates its output AFTER computing, so a crashed run left the
# previous out.dat completely intact for the parser to read back as new.
set ::VMDPathFinder::busy 1
set ::VMDPathFinder::state(status) ""
::VMDPathFinder::run_tunnel_analysis
chk "a second tunnel Run is refused while one is in progress" \
    [string match "*already in progress*" $::VMDPathFinder::state(status)] 1
chk "...and the guard did not clear the flag it was guarding" $::VMDPathFinder::busy 1
set ::VMDPathFinder::busy 0
set _rtb [info body ::VMDPathFinder::run_tunnel_analysis]
chk "every early return in the tunnel run hands the busy flag back" \
    [expr {[regexp -all {set busy 0} $_rtb] >= [regexp -all {\n\s+return\n} $_rtb]}] 1
chk "the job script deletes any previous out.dat before running the engine" \
    [string match "*rm -f*out.dat*" $_rtb] 1
chk "...before the engine line, not after it" \
    [expr {[string first "rm -f \[shell_quote \[file join \$fd out.dat\]\]" $_rtb] > 0
           && [string first "rm -f \[shell_quote \[file join \$fd out.dat\]\]" $_rtb]
              < [string first "OMP_NUM_THREADS=1" $_rtb]}] 1
# An error thrown anywhere inside the tunnel run must not leave Run dead.
chk "the dispatcher releases busy if the tunnel run throws" \
    [string match "*catch {run_tunnel_analysis}*" [info body ::VMDPathFinder::run_current_mode]] 1

# --- stale-tmp sweeper must understand all three naming layouts -------------
# It only ever parsed vmdpathfinder_<type>_<pid> (pid at index 2), so automatic
# results (/tmp/vmdpathfinder_<pid>) and per-frame HOLE scratch
# (/dev/shm/vmdpathfinder_<pid>_f<frame>) survived a killed session - the latter in
# RAM. A dead pid is one that cannot exist; a live one is this process.
set _dead 999999
while {[file isdirectory [file join / proc $_dead]]} { incr _dead }
set _live [pid]
set _made {}
foreach _n [list vmdpathfinder_hole_$_dead vmdpathfinder_$_dead vmdpathfinder_${_dead}_f7] {
    set _p [file join /tmp $_n]
    catch {file mkdir $_p}
    lappend _made $_p
}
foreach _n [list vmdpathfinder_hole_$_live vmdpathfinder_$_live vmdpathfinder_${_live}_f7] {
    set _p [file join /tmp $_n]
    catch {file mkdir $_p}
    lappend _made $_p
}
# Backdate the DEAD session's dirs past the age guard. A running session writes
# to its scratch, so the guard only sweeps what has been untouched for an hour -
# that is what makes the sweep safe inside a PID namespace, where /proc cannot
# see the owner and "absent" would otherwise mean "delete a live session's".
foreach _n [list vmdpathfinder_hole_$_dead vmdpathfinder_$_dead vmdpathfinder_${_dead}_f7] {
    catch {file mtime [file join /tmp $_n] [expr {[clock seconds] - 7200}]}
}
::VMDPathFinder::_sweep_stale_tmpdirs
set _dead_left 0
foreach _n [list vmdpathfinder_hole_$_dead vmdpathfinder_$_dead vmdpathfinder_${_dead}_f7] {
    if {[file isdirectory [file join /tmp $_n]]} { incr _dead_left }
}
set _live_left 0
foreach _n [list vmdpathfinder_hole_$_live vmdpathfinder_$_live vmdpathfinder_${_live}_f7] {
    if {[file isdirectory [file join /tmp $_n]]} { incr _live_left }
}
chk "the sweeper removes all 3 layouts left by a dead session" $_dead_left 0
# The age guard itself: a dead pid's FRESH scratch is left alone, because in a
# PID namespace an unseeable-but-live owner looks exactly like a dead one.
set _fresh [file join /tmp vmdpathfinder_hole_${_dead}_fresh]
catch {file mkdir $_fresh}
lappend _made $_fresh
::VMDPathFinder::_sweep_stale_tmpdirs
chk "a dead pid's RECENTLY-touched scratch is spared (namespace safety)" \
    [file isdirectory $_fresh] 1
catch {file mtime $_fresh [expr {[clock seconds] - 7200}]}
::VMDPathFinder::_sweep_stale_tmpdirs
chk "...and swept once it is genuinely old" [file isdirectory $_fresh] 0
chk "...and never touches a LIVE session's temp dirs" $_live_left 3
foreach _p $_made { catch {file delete -force $_p} }
chk "the sweeper also scans /dev/shm, not just /tmp" \
    [string match "*/dev/shm*" [info body ::VMDPathFinder::_sweep_stale_tmpdirs]] 1

# --- a hand-edited config must not smuggle shell syntax into `sh -c` --------
# The scheme values are interpolated into the sos_triangle command lines, which
# run via sh -c. They are quoted there now; this is the second layer - the
# config loader itself refuses a value that is not a bare token.
set _cfgsave ""
if {[file exists $::VMDPathFinder::config_file]} {
    set _fh [open $::VMDPathFinder::config_file r]; set _cfgsave [read $_fh]; close $_fh
}
set _fh [open $::VMDPathFinder::config_file w]
puts $_fh "hydro_scheme = kd; touch /tmp/vmdpathfinder_pwn_$::VMDPathFinder::version"
puts $_fh "heatmap_scheme = \$(id)"
puts $_fh "mole_cover = 10.0"
close $_fh
set ::VMDPathFinder::state(hydro_scheme) kd
set ::VMDPathFinder::state(heatmap_scheme) watermelon
::VMDPathFinder::load_config
chk "an injected hydro_scheme is refused, not stored" \
    [string match "*;*" $::VMDPathFinder::state(hydro_scheme)] 0
chk "a \$(...) heatmap_scheme is refused too" \
    [string match "*\$*" $::VMDPathFinder::state(heatmap_scheme)] 0
chk "...while an ordinary numeric key still loads" $::VMDPathFinder::state(mole_cover) 10.0
# And the command lines themselves must quote the scheme, not interpolate raw.
# Read from the LOADED proc bodies, not by re-opening the file: every other
# argument on those lines already goes through shell_quote, the scheme did not.
set _raw 0
foreach _pr {_hydro_recolor_cmd build_hydro_surface _hydro_batch_jobs} {
    if {[info procs ::VMDPathFinder::$_pr] eq ""} { continue }
    incr _raw [regexp -all {hydro-scheme \$scheme} [info body ::VMDPathFinder::$_pr]]
}
chk "no sos_triangle command line interpolates the scheme unquoted" $_raw 0
catch {file delete $::VMDPathFinder::config_file}
if {$_cfgsave ne ""} {
    set _fh [open $::VMDPathFinder::config_file w]; puts -nonewline $_fh $_cfgsave; close $_fh
}

# --- worker fault injection: the pool must COUNT failures, not swallow them --
# Every consumer of run_shell_pool now branches on its return value (the HOLE
# run names crashed frames, the 3D average refuses to publish a partial), so
# the count itself has to be right. Injected here with real failing jobs rather
# than asserted from source text.
set _fj [file join $::env(HOME) .vmdpathfinder_faultinject]
catch {file delete -force $_fj}
file mkdir $_fj
proc _mkjob {dir name body} {
    set f [file join $dir $name]
    set fh [open $f w]; puts $fh "#!/bin/sh"; puts $fh $body; close $fh
    file attributes $f -permissions 0755
    return [list $name [list |sh $f]]
}
set _jobs {}
lappend _jobs [_mkjob $_fj ok1.sh  "exit 0"]
lappend _jobs [_mkjob $_fj bad1.sh "exit 1"]
lappend _jobs [_mkjob $_fj ok2.sh  "exit 0"]
lappend _jobs [_mkjob $_fj bad2.sh "exit 3"]
chk "run_shell_pool counts exactly the jobs that failed" \
    [::VMDPathFinder::run_shell_pool $_jobs 2 "fault-injection test" "job(s)"] 2
set _alljobs [list [_mkjob $_fj ok3.sh "exit 0"] [_mkjob $_fj ok4.sh "exit 0"]]
chk "...and reports zero when they all succeed" \
    [::VMDPathFinder::run_shell_pool $_alljobs 2 "fault-injection test" "job(s)"] 0
# A job killed by a signal (the segfault case) must count too, not just a
# nonzero exit - this is the shape the HOLE crash path actually sees.
set _sig [list [_mkjob $_fj sig.sh "kill -SEGV \$\$"]]
chk "...and a job killed by a signal counts as failed" \
    [::VMDPathFinder::run_shell_pool $_sig 1 "fault-injection test" "job(s)"] 1
catch {file delete -force $_fj}
# The consumers must actually branch on that count.
chk "the 3D-average path refuses to publish when any worker failed" \
    [string match "*_n3dfail > 0*" [info body ::VMDPathFinder::build_mean_hydro3d_average]] 1

# --- the unrolled map must not re-run HOLE on every redraw -------------------
# _draw_unrolled_map calls _2dmap_ensure on EVERY draw and the build is a
# BLOCKING exec, so an unmemoised failure re-ran HOLE per redraw with the UI
# frozen and nothing ever appearing.
set ::VMDPathFinder::result_frames {49}
set ::VMDPathFinder::results [dict create 49 [dict create run_dir /nonexistent_vmdpathfinder_rd \
    sph_file /nonexistent_vmdpathfinder_sph profile [dict create valid 1 min_radius 1.0 points {}]]]
array unset ::VMDPathFinder::_2dmap_memo
rename ::VMDPathFinder::_2dmap_build ::VMDPathFinder::_2dmap_build_real
set ::_bcalls 0
proc ::VMDPathFinder::_2dmap_build {frame} { incr ::_bcalls; return "boom" }
foreach _i {1 2 3 4 5} { ::VMDPathFinder::_2dmap_ensure 49 }
chk "5 redraws build the map ONCE, not 5 times" $::_bcalls 1
chk "...and the failure message is still returned each time" \
    [::VMDPathFinder::_2dmap_ensure 49] boom
array unset ::VMDPathFinder::_2dmap_memo
::VMDPathFinder::_2dmap_ensure 49
chk "clearing the memo lets it rebuild" $::_bcalls 2
rename ::VMDPathFinder::_2dmap_build {}
rename ::VMDPathFinder::_2dmap_build_real ::VMDPathFinder::_2dmap_build
# The map run must use the same OMP environment as the batch: only CONNOLLY
# parallelises inside a frame, and this was the one HOLE call without it.
chk "the map run passes an env prefix to exec" \
    [string match "*_hole_env_args*" [info body ::VMDPathFinder::_2dmap_build]] 1
chk "_hole_env_args produces exec-able `env VAR=VAL` args" \
    [lindex [::VMDPathFinder::_hole_env_args 1] 0] env
chk "...carrying the OMP settings the batch uses" \
    [expr {[string match "*OMP_NUM_THREADS=*" [::VMDPathFinder::_hole_env_args 1]]
           && [string match "*OMP_STACKSIZE=*" [::VMDPathFinder::_hole_env_args 1]]}] 1

# --- shipped defaults for the two view pickers ------------------------------
# Reported twice as "Fill is on by default" / "Over Time defaults to Property".
# The code defaults are None and Radius and no path forces either, so pin them:
# if anything ever changes them, this says so instead of another bug report.
# They are also in skip_keys, so a stale ~/.vmdpathfinder_config cannot resurrect them.
::VMDPathFinder::load_config
chk "Pore Profile view mode defaults to None" $::VMDPathFinder::state(profile_view_mode) none
chk "...with Fill off" $::VMDPathFinder::state(profile_color) 0
chk "Over Time colors by Radius, not Property" $::VMDPathFinder::state(heatmap_color_by) radius
foreach _k {profile_view_mode profile_color heatmap_color_by} {
    chk "$_k is never persisted (a stale config cannot turn it on)" \
        [expr {$_k in [::VMDPathFinder::_config_skip_keys]}] 1
}

# A crashed frame must be counted ONCE. The job script exits with the engine's
# status, so run_shell_pool's close already counts it; the Phase 3 status-file
# check must exclude the frame WITHOUT incrementing again.
set _p3 [info body ::VMDPathFinder::run_analysis]
set _gate [string first {_hole_frame_status $run_dir} $_p3]
set _tail [string range $_p3 $_gate [expr {$_gate + 900}]]
# Strip comment lines first - the fix's own comment mentions the counter it
# removes, which would defeat a naive substring match.
set _code {}
foreach _l [split $_tail "\n"] {
    if {[string match "#*" [string trim $_l]]} continue
    append _code $_l "\n"
}
chk "a crashed frame is excluded but not double-counted" \
    [expr {[string match "*lappend _crashed_frames*" $_code]
           && ![string match "*incr hole_failures*" $_code]}] 1

# --- the property scale bar must follow the MEAN surface too ----------------
# Both the resize watcher and the visibility checkbox asked only
# state(surface_color) - the MAIN per-frame surface. With just the Mean Profile
# isosurface shown and property-colored, the watcher decided the bar was
# inactive and returned WITHOUT re-arming, and the checkbox returned before
# doing anything: the bar appeared only when the main surface happened to be
# property-colored too. That is the reported "sometimes it is not shown".
set _sv_sc  $::VMDPathFinder::state(surface_color)
set _sv_sms $::VMDPathFinder::state(show_mean_surface)
set _sv_msc $::VMDPathFinder::state(mean_surface_color)
set _sv_mm  $::VMDPathFinder::mean_surface_mol
set ::VMDPathFinder::state(surface_color) hole_def
set ::VMDPathFinder::state(show_mean_surface) 0
set ::VMDPathFinder::mean_surface_mol -1
chk "nothing property-colored: no scale-bar owner" [::VMDPathFinder::_scalebar_owner] {}
set ::VMDPathFinder::state(surface_color) property
chk "main surface property-colored: the pore owns the bar" \
    [lindex [::VMDPathFinder::_scalebar_owner] 0] pore
# The discriminating case: main surface NOT property, mean surface IS.
set ::VMDPathFinder::state(surface_color) hole_def
set ::VMDPathFinder::state(show_mean_surface) 1
set ::VMDPathFinder::mean_surface_mol 7
set ::VMDPathFinder::state(mean_surface_color) property
set ::VMDPathFinder::state(mean_hydro_scheme) kd
chk "mean surface alone still owns the bar" \
    [lindex [::VMDPathFinder::_scalebar_owner] 0] mean
chk "...and carries the MEAN's own scheme, not the main panel's" \
    [lindex [::VMDPathFinder::_scalebar_owner] 1] kd
set ::VMDPathFinder::state(mean_surface_color) green
chk "a flat-colored mean surface owns nothing" [::VMDPathFinder::_scalebar_owner] {}
set ::VMDPathFinder::state(surface_color) $_sv_sc
set ::VMDPathFinder::state(show_mean_surface) $_sv_sms
set ::VMDPathFinder::state(mean_surface_color) $_sv_msc
set ::VMDPathFinder::mean_surface_mol $_sv_mm

# --- a failed RE-RUN must not leave the previous run's result active --------
# `results` persists across runs (Run extends an existing set), so a frame that
# was recomputed and failed used to keep its earlier profile in the list and in
# every mean/trend that reads result_frames - a good-looking number from a run
# the user had explicitly replaced.
set _sv_res $::VMDPathFinder::results
set _sv_rf  $::VMDPathFinder::result_frames
set ::VMDPathFinder::results [dict create 3 [dict create frame 3 profile {a b}] \
                                    7 [dict create frame 7 profile {c d}]]
set ::VMDPathFinder::result_frames {3 7}
chk "dropping an unknown frame reports nothing dropped" \
    [::VMDPathFinder::_drop_result_frame 99] 0
chk "dropping a known frame reports it" [::VMDPathFinder::_drop_result_frame 3] 1
chk "...and it is gone from results" [dict exists $::VMDPathFinder::results 3] 0
chk "...and gone from result_frames" $::VMDPathFinder::result_frames {7}
chk "...while the other frame is untouched" [dict exists $::VMDPathFinder::results 7] 1
set ::VMDPathFinder::results $_sv_res
set ::VMDPathFinder::result_frames $_sv_rf

# Both Phase 3 failure paths must call it, and neither may fire for a REUSED
# frame (nothing was recomputed for those, so their result is still valid).
set _ra [info body ::VMDPathFinder::run_analysis]
set _npar [string first {![dict exists $parsed $frame]} $_ra]
chk "the unparseable-frame path drops a stale result" \
    [string match {*_drop_result_frame*} [string range $_ra $_npar [expr {$_npar + 400}]]] 1
set _crash [string first {lappend _crashed_frames} $_ra]
chk "the crashed-frame path drops a stale result" \
    [string match {*_drop_result_frame*} [string range $_ra $_crash [expr {$_crash + 400}]]] 1
chk "a reused frame is exempt from the drop" \
    [string match {*lsearch -exact $reused $frame] < 0 && \[_drop_result_frame*} $_ra] 1
chk "dropped frames are named to the user" \
    [string match {*_stale_dropped*} $_ra] 1

# --- a tunnel mesh must not outlive the .sph it was built from --------------
# render_tunnels_for_frame reused any .plot that merely HAD geometry. A re-run
# into the same output root rewrites the .sph in place (tunnel_* dirs are only
# cleared with Overwrite on, with Tk, and outside a temp root), so the screen
# kept showing the PREVIOUS run's tube.
set _mt /tmp/vmdpathfinder_meshcur_[pid]
file mkdir $_mt
set _plot [file join $_mt t.plot]
set _sph  [file join $_mt t.sph]
set _fh [open $_plot w]; puts $_fh "draw trinorm {0 0 0} {1 0 0} {0 1 0} {0 0 1} {0 0 1} {0 0 1}"; close $_fh
set _fh [open $_sph w];  puts $_fh "sphere"; close $_fh
file mtime $_plot 2000
file mtime $_sph  1000
chk "a mesh NEWER than its .sph is current" [::VMDPathFinder::_tunnel_mesh_current $_plot $_sph] 1
file mtime $_sph 3000
chk "a mesh OLDER than its .sph is stale (the re-run case)" \
    [::VMDPathFinder::_tunnel_mesh_current $_plot $_sph] 0
file mtime $_sph 2000
chk "equal mtimes count as current" [::VMDPathFinder::_tunnel_mesh_current $_plot $_sph] 1
file delete $_sph
chk "no .sph to rebuild from: keep what is on disk" \
    [::VMDPathFinder::_tunnel_mesh_current $_plot $_sph] 1
set _fh [open $_plot w]; puts $_fh "# header only, no primitives"; close $_fh
chk "a geometry-less plot is never current" [::VMDPathFinder::_tunnel_mesh_current $_plot $_sph] 0
file delete -force $_mt

# All three reuse sites must go through it, or the one that does not silently
# reinstates the stale mesh (the serial path runs whenever todo <= 1).
chk "the mesh-job builder checks staleness" \
    [string match {*_tunnel_mesh_current $plot $sph*} [info body ::VMDPathFinder::_tunnel_mesh_jobs]] 1
set _rt [info body ::VMDPathFinder::render_tunnels_for_frame]
chk "the pool's todo list checks staleness" \
    [expr {[llength [regexp -all -inline {_tunnel_mesh_current} $_rt]] >= 2}] 1
chk "the serial rebuild path checks staleness too" \
    [string match {*!\[_tunnel_mesh_current $plot $sph\]*} $_rt] 1
# Without set -e a failed sph_process still fell through to sos_triangle, which
# meshed a stale .sos into a .plot that passes every validity check there is.
chk "the mesh script aborts on the first failed stage" \
    [string match "*\nset -e\n*" [::VMDPathFinder::_surface_mesh_script 6 a.sph a.sos a.plot]] 1

# --- dot density reaches /bin/sh, and it is PERSISTED ----------------------
# state(dot_density) is written to ~/.vmdpathfinder_config, so a hand-edited or
# corrupted config reaches the mesh command without ever passing validate_inputs.
chk "a sane dot density is passed through" [::VMDPathFinder::_dotden_arg 12] 12
chk "shell metacharacters never reach the command line" \
    [::VMDPathFinder::_dotden_arg {5; touch /tmp/pwned}] 15
chk "out of sph_process's own 1-100 range falls back" [::VMDPathFinder::_dotden_arg 0] 15
chk "...at the top end too" [::VMDPathFinder::_dotden_arg 101] 15
chk "an empty value falls back" [::VMDPathFinder::_dotden_arg ""] 15
set _sv_dd $::VMDPathFinder::state(dot_density)
set ::VMDPathFinder::state(dot_density) {6 && touch /tmp/pwned}
chk "the shared command builder sanitises it" \
    [string match {*touch*} [::VMDPathFinder::_sph_process_cmd $::VMDPathFinder::state(dot_density) {} a.sph a.sos]] 0
set ::VMDPathFinder::state(dot_density) $_sv_dd

# --- a tunnel run must be abortable ----------------------------------------
# The frame loop already honoured _abort_requested, but run_tunnel_analysis
# never called _begin_calc, so the button that sets the flag was never shown.
set _rta [info body ::VMDPathFinder::run_tunnel_analysis]
chk "the tunnel run raises the Abort button" [string match {*_begin_calc*} $_rta] 1
chk "the tunnel run's frame loop honours the flag" [string match {*_abort_requested*} $_rta] 1
# Ten exit paths hand `busy` back; every one must hand the abort lifecycle back
# too, or the button outlives the run that owns it.
set _nbusy 0; set _nend 0
foreach _l [split $_rta "\n"] {
    set _t [string trim $_l]
    if {$_t eq "set busy 0"} { incr _nbusy }
    if {$_t eq "_end_calc"}  { incr _nend }
}
chk "every busy-clearing exit also ends the calculation" \
    [expr {$_nbusy > 0 && $_nend == $_nbusy}] 1

# --- Stabilize: the per-frame fit must not rebuild its world every frame -----
# The residual WARNING check was 97% of the whole stabilize path (491 ms vs 14
# ms of real work per 1000 frames) because it marshalled every scoped atom into
# Tcl and looped over it. It now runs in C against a cached scratch molecule.
# The three things that can go wrong with that are asserted here.
# Its own fixture: the earlier altloc PDB's directory is deleted long before
# this point, and depending on it made every check below run on undefined
# variables - which `chk` reported as PASS. Self-contained, so it cannot rot.
set _sdir [file join $here _stab_test]
catch {file delete -force $_sdir}
file mkdir $_sdir
set _spdb [file join $_sdir stab.pdb]
set _sfh [open $_spdb w]
set _sn 0
foreach {_sx _sy _sz} {0.0 0.0 0.0  3.8 0.4 0.0  7.6 0.0 0.6  11.4 0.5 0.0  15.2 0.0 0.3} {
    incr _sn
    puts $_sfh [format "ATOM  %5d  CA  ALA A%4d    %8.3f%8.3f%8.3f  1.00  0.00           C" \
        $_sn $_sn $_sx $_sy $_sz]
}
close $_sfh
set _sm [mol new $_spdb]
animate dup $_sm
set _ssel "name CA"
set _stop [molinfo top]
set _snmol [llength [molinfo list]]
::VMDPathFinder::_stab_cleanup
set _p1 [::VMDPathFinder::_stab_fit_point $_sm $_ssel 0 1 {2.0 1.0 0.0} cpoint]
chk "the fit actually returned a point (guards every check below)" [llength $_p1] 3
# VMD's "protein" needs a real backbone, so a CA-only fixture matches NOTHING
# under it - and an empty selection used to yield a transform anyway. Assert
# the scope is non-empty so this can never silently test nothing again.
chk "the alignment scope actually matched atoms" \
    [llength [lindex [::VMDPathFinder::_stab_sel_pair $_sm $_ssel 0] 2]] 5
# Assert the PAIR refuses, not just that the fit returns {}: without the guard
# the fit still returned {} (via a caught "no atoms selected"), so testing the
# fit alone could not tell the guard from the accident.
chk "an empty scope is refused before any fit is attempted" \
    [::VMDPathFinder::_stab_sel_pair $_sm "name ZZZZ" 0] {}
chk "...and the caller therefore keeps its static value" \
    [::VMDPathFinder::_stab_fit_point $_sm "name ZZZZ" 0 1 {2.0 1.0 0.0} cpoint] {}
# An independent implementation: fresh selections, no cache, no scratch.
set _fr [atomselect $_sm $_ssel frame 0]
set _fc [atomselect $_sm $_ssel frame 1]
set _fp [coordtrans [measure fit $_fr $_fc] {2.0 1.0 0.0}]
$_fr delete; $_fc delete
set _same [expr {[llength $_p1] == 3 && [llength $_fp] == 3}]
foreach _a $_p1 _b $_fp { if {abs($_a-$_b) > 1e-12} { set _same 0 } }
chk "the cached fit returns the SAME point as a fresh-selection fit" $_same 1
# Without this the rest of the block is vacuous: if no scratch molecule was
# built, the C fast path never ran and the guards below assert nothing.
set _sp [::VMDPathFinder::_stab_sel_pair $_sm $_ssel 0]
chk "a scratch molecule really was built (else the fast path is untested)" \
    [expr {[llength $_sp] == 5 && [lindex $_sp 3] ne "" && [lindex $_sp 4] ne ""}] 1
# `mol new` steals "top" - verified, it does - so anything reading
# [molinfo top] would otherwise get the scratch instead of the structure.
chk "creating the scratch molecule does not steal top" [molinfo top] $_stop
# _stab_cleanup runs on every run exit path, including abort. If it does not
# delete the scratch MOLECULE, a stray entry is left in VMD's molecule list.
::VMDPathFinder::_stab_cleanup
chk "cleanup empties the selection cache" [dict size $::VMDPathFinder::_stab_selcache] 0
chk "cleanup leaves no scratch molecule behind" [llength [molinfo list]] $_snmol
# The Tcl loop stays reachable: it is the fallback when no scratch can be made.
chk "the pure-Tcl residual path is still there as a fallback" \
    [string match {*measure rmsd $scratch $cur_sel*} [info body ::VMDPathFinder::_stab_fit_rmsd]] 1
catch {mol delete $_sm}
catch {file delete -force $_sdir}

# --- tunnel property recolor: the values must be in .sph ORDER --------------
# The C recolor indexes values by sphere position in the .sph file, which is
# written from _tunnel_render_centers (terminal runaway spheres TRIMMED off
# each end). _tunnel_property_spheres returns one entry per point of the FULL
# profile. Feeding the untrimmed list to the binary shifts every color along
# the tube by however many spheres were trimmed - a silent, plausible-looking
# miscoloring, which is the whole reason this alignment is asserted.
array unset ::VMDPathFinder::tunnel_results
array unset ::VMDPathFinder::tunnel_lining
# 6 spheres; the FIRST and LAST blow past the 6.0 A render cap, so exactly one
# is trimmed from each end and the .sph holds the middle four.
set _tp {}
foreach {_x _r} {0.0 9.0   1.0 2.0   2.0 2.5   3.0 2.2   4.0 2.1   5.0 9.5} {
    lappend _tp $_x 0.0 0.0 $_r
}
set ::VMDPathFinder::tunnel_results(0) [list [list 1 1.0 5.0 0.0 $_tp]]
# One layer per sphere midpoint so the interpolation returns each layer's own
# value at its own sphere: values become 10,11,12,13,14,15 in profile order.
set _tly {}
set _tk 0
foreach _d {0.0 1.0 2.0 3.0 4.0 5.0} {
    lappend _tly [dict create start $_d end $_d charge [expr {10 + $_tk}]]
    incr _tk
}
set ::VMDPathFinder::tunnel_lining(0) [dict create 1.layers $_tly]
set _tcen [::VMDPathFinder::_tunnel_render_centers $_tp _tspan]
chk "the render cap trimmed one runaway sphere from each end" [llength $_tcen] 4
chk "...and reported the surviving span" $_tspan {1 4}
set _tvals [::VMDPathFinder::_tunnel_property_values 0 1 charge]
chk "one value per sphere ACTUALLY written to the .sph" \
    [llength $_tvals] [llength $_tcen]
# The discriminating assertion: untrimmed values would start at 10, not 11.
chk "values start at the FIRST SURVIVING sphere, not the first profile point" \
    [expr {int([lindex $_tvals 0])}] 11
chk "...and end at the last surviving one" [expr {int([lindex $_tvals end])}] 14
array unset ::VMDPathFinder::tunnel_results
array unset ::VMDPathFinder::tunnel_lining

# --- the tunnel list must not scan every frame for every cluster ------------
# _tunnel_cluster_rows probed `info exists tunnel_xrank($cid,$fr)` for EVERY
# result frame of EVERY cluster - clusters x frames, tens of millions of
# iterations on a 10k-frame run, before one row widget exists. It now indexes
# the array's own keys, which is bounded by real memberships. Same rows, same
# order: asserted against the frame-scan it replaced.
array unset ::VMDPathFinder::tunnel_xrank
array unset ::VMDPathFinder::tunnel_lining
set ::VMDPathFinder::tunnel_result_frames {0 1 2 3 4 5}
set ::VMDPathFinder::tunnel_xclusters {{a} {b} {c}}
# cluster 1 in frames 5,0,3 (deliberately out of order in insertion terms),
# cluster 2 in frame 2 only, cluster 3 in none (must be dropped: nb == 0).
foreach {_c _f} {1 5  1 0  1 3  2 2} { set ::VMDPathFinder::tunnel_xrank($_c,$_f) 1 }
proc ::VMDPathFinder::_tunnel_tuple_for {fr rk} { return [list [expr {1.0+$fr}] [expr {10.0+$fr}]] }
set _rows [::VMDPathFinder::_tunnel_cluster_rows]
chk "a cluster present in NO frame is dropped" [llength $_rows] 2
chk "rows stay in cluster order" \
    [list [dict get [lindex $_rows 0] cid] [dict get [lindex $_rows 1] cid]] {1 2}
chk "member frame count is right" [dict get [lindex $_rows 0] nframes] 3
# The discriminating one: bneck is a MEAN over members, so a wrong or
# duplicated membership list changes it. Frames 0,3,5 -> (1+4+6)/3 = 3.6667.
chk "bottleneck mean is over exactly the member frames" \
    [format %.4f [dict get [lindex $_rows 0] bneck]] 3.6667
chk "...and length likewise ((10+13+15)/3)" \
    [format %.4f [dict get [lindex $_rows 0] len]] 12.6667
chk "seen percent is against ALL result frames, not just members" \
    [format %.2f [dict get [lindex $_rows 0] seen]] 50.00
array unset ::VMDPathFinder::tunnel_xrank
set ::VMDPathFinder::tunnel_xclusters {}
set ::VMDPathFinder::tunnel_result_frames {}

# --- a degenerate unrolled map must be REFUSED, not drawn -------------------
# HOLE writes a well-formed DSAA header with ny = 0 when it traced no pore
# (measured on 9HNR: "73 0", against a real 73 x 93 on KcsA). nx*ny = 0 made
# every validity check pass, so the renderer drew whatever zero rows yield -
# an "oddly simple" figure instead of an honest "no map".
set _gdir [file join $here _grd_test]
catch {file delete -force $_gdir}
file mkdir $_gdir
proc _wgrd {path nx ny} {
    set fh [open $path w]
    puts $fh "DSAA"
    puts $fh "$nx $ny"
    puts $fh "-180.0 180.0"
    puts $fh "0.0 [expr {$ny > 0 ? 10.0 : 0.0}]"
    puts $fh "0.0 10.0"
    for {set i 0} {$i < $nx*$ny} {incr i} { puts -nonewline $fh "[expr {1.0 + $i%7}] " }
    puts $fh ""
    close $fh
}
_wgrd [file join $_gdir empty.grd] 73 0
_wgrd [file join $_gdir real.grd]  73 5
chk "a zero-row grid is refused" [::VMDPathFinder::_2dmap_grd_read [file join $_gdir empty.grd]] {}
set _rg [::VMDPathFinder::_2dmap_grd_read [file join $_gdir real.grd]]
chk "a real grid still reads" [dict get $_rg ny] 5
chk "...with all its values" [llength [dict get $_rg values]] 365
_wgrd [file join $_gdir onerow.grd] 73 1
chk "a single-row grid is refused too (nothing to interpolate)" \
    [::VMDPathFinder::_2dmap_grd_read [file join $_gdir onerow.grd]] {}
catch {file delete -force $_gdir}

# --- abort must not leak the RAM-backed scratch -----------------------------
# run.sh removes its own /dev/shm dir after HOLE exits, but Abort KILLS the
# process tree, so those frames never reach that line. The error path already
# swept; abort is not an error, so it fell through and leaked multi-GB dirs.
set _ra2 [info body ::VMDPathFinder::run_analysis]
set _sweep "dict for {_fr _td} $frame_tmp_dirs { catch {file delete -force $_td} }"
set _nsweep [llength [regexp -all -inline -- {dict for \{_fr _td\} \$frame_tmp_dirs} $_ra2]]
chk "the scratch sweep runs on the NORMAL/abort path too, not only on error" \
    [expr {$_nsweep >= 2}] 1
# It has to be OUTSIDE the catch that handles a mid-stream error, or an abort
# (which is not an error) never reaches it.
set _cpos [string first {catch {$sel delete}} $_ra2]
chk "...and it sits after the streaming loop, where abort lands" \
    [expr {$_cpos >= 0 && [string first {file delete -force $_td} \
        [string range $_ra2 $_cpos [expr {$_cpos + 600}]]] >= 0}] 1

# --- item 9: the HOLE residue scales must work in TUNNEL mode too -----------
# MOLE's out.dat carries its own per-layer columns but none of the HOLE scales.
# They are computable from the same layer's residue list, so tunnel mode now
# offers them - averaged the unweighted way MOLE's own Y records are, and under
# the SAME display names pore mode uses, so one name means one quantity.
foreach _t {kd ww lipophilicity} {
    chk "tunnel mode offers the '$_t' scale" [expr {$_t in [::VMDPathFinder::_tunnel_prop_tokens]}] 1
    chk "...labelled exactly as in pore mode" \
        [::VMDPathFinder::_tunnel_prop_label $_t] [::VMDPathFinder::scheme_display_label $_t]
}
# Water G(z) needs a Hydration run tunnel mode cannot produce - offering it
# puts a control on screen that can never resolve, which is the defect batch
# item 13 already fixed once.
foreach _t {gz} {
    chk "tunnel mode does NOT offer '$_t' (it can never resolve there)" \
        [expr {$_t in [::VMDPathFinder::_tunnel_prop_tokens]}] 0
}
# esp WAS in that list for the same reason and no longer is: it never needed
# MOLE's tables, only the structure's formal charges (_esp_formal_charges, the
# same set pore mode's readout and overlay use), evaluated at the route's own
# points rather than per lining residue.
chk "tunnel mode offers 'esp'" \
    [expr {"esp" in [::VMDPathFinder::_tunnel_prop_tokens]}] 1
chk "...routed to the per-point evaluator, not the layer table" \
    [expr {[string first {_tunnel_esp_spheres} \
        [info body ::VMDPathFinder::_tunnel_property_spheres]] >= 0}] 1
chk "...on its own adaptive range, like pore mode's esp" \
    [expr {[string first {_esp_percentile_range} \
        [info body ::VMDPathFinder::_tunnel_property_range]] >= 0}] 1
# The averaging itself: two residues, so the layer value is their mean.
set _ly [dict create start 0.0 end 1.0 \
    residues [list [dict create resname ILE resid 1 chain A] \
                   [dict create resname ALA resid 2 chain A] \
                   [dict create resname ARG resid 3 chain A]]]
# ILE +4.5, ALA +1.8, ARG -4.5: a mean that is NOT zero, so a wrong
# denominator, a dropped residue or a swapped table all change it.
set _want [expr {([::VMDPathFinder::residue_property kd ILE] + \
                  [::VMDPathFinder::residue_property kd ALA] + \
                  [::VMDPathFinder::residue_property kd ARG]) / 3.0}]
chk "a layer's scale value is the mean over its lining residues" \
    [format %.6f [::VMDPathFinder::_tunnel_layer_scale $_ly kd]] [format %.6f $_want]
chk "...and it is the SAME table pore mode uses (ILE/ARG differ in sign)" \
    [expr {[::VMDPathFinder::residue_property kd ILE] > 0 && [::VMDPathFinder::residue_property kd ARG] < 0}] 1
chk "a layer with no residues has no value, rather than a fake 0" \
    [::VMDPathFinder::_tunnel_layer_scale [dict create start 0.0 end 1.0 residues {}] kd] {}

# --- the depth pass must not DISCARD pending relaxations --------------------
# It relaxed from every boundary vertex separately behind a fixed nt queue
# whose `tail` counted TOTAL enqueues, not live occupancy. On hitting the cap
# it ran `set q {}; set head 0; set tail 0`, abandoning that source and leaving
# vertices at their 1e300 / INT_MAX sentinel to be read as real depths.
# Unbounding the queue alone HANGS (Bellman-Ford once per source, measured);
# the fix is a multi-source pass - BFS for hops, Dijkstra for length.
# Strip COMMENTS before matching: the fix's own comment quotes the code it
# removed, so a naive substring match finds the very line it is asserting gone.
# (This exact trap already bit the double-count test once.)
set _dbody {}
foreach _l [split [info body ::VMDPathFinder::Mole::compute_depth] "\n"] {
    if {[string match "#*" [string trim $_l]]} continue
    append _dbody $_l "\n"
}
chk "the depth pass is multi-source, not per-source relaxation" \
    [string match {*boundary) $i\]} { lappend q $i }*} $_dbody] 1
chk "the nt enqueue cap is gone" [string match {*if {$tail < $nt}*} $_dbody] 0
chk "...and so is the ring reset that dropped the queue" \
    [string match {*set q {}; set head 0; set tail 0*} $_dbody] 0
# Behavioural, on a graph dense enough that the OLD nt cap was reached: no
# connected vertex may be left at the sentinel.
set _nt 60
array set _C {}
set _C(nt) $_nt
set _C(alive) [lrepeat $_nt 1]
set _C(boundary) [concat 1 [lrepeat [expr {$_nt-1}] 0]]
set _C(depth) [lrepeat $_nt 0]
set _C(depthlen) [lrepeat $_nt 0.0]
set _C(tn) {}
set _C(elen) {}
for {set _i 0} {$_i < $_nt} {incr _i} {
    lappend _C(tn) [expr {$_i+1 < $_nt ? $_i+1 : -1}] [expr {$_i-1}] \
                   [expr {($_i*7+3) % $_nt}] [expr {($_i*13+5) % $_nt}]
    lappend _C(elen) 1.0 1.0 5.0 5.0
}
::VMDPathFinder::Mole::compute_depth _C 0
set _unreached 0
foreach _d $_C(depth) { if {$_d >= 0x7fffffff} { incr _unreached } }
chk "every connected vertex gets a real hop depth" $_unreached 0
chk "the source itself is at depth 0" [lindex $_C(depth) 0] 0
# Vertex 1 is a direct neighbour of the single source, so exactly 1 hop.
chk "a direct neighbour is one hop" [lindex $_C(depth) 1] 1
::VMDPathFinder::Mole::compute_depth _C 1
set _unreachedl 0
foreach _d $_C(depthlen) { if {$_d >= 1e300} { incr _unreachedl } }
chk "every connected vertex gets a real path length" $_unreachedl 0
# Dijkstra must take the SHORT chain (1.0 each), never the 5.0 shortcut.
chk "Dijkstra prefers the short edges (vertex 3 at 3.0, not 5.0)" \
    [format %.1f [lindex $_C(depthlen) 3]] 3.0
array unset _C

# --- exact nearest-five ties must resolve the SAME way everywhere -----------
# The C grid path walks atoms in cell-bucket order, its brute-force path in
# index order, and the Tcl port scans ascending - so "first encountered wins"
# made the three disagree on an exact tie. Radii could differ (0.6 vs 0.2) and
# lining identities differ even where radii agreed. Ties are the NORMAL case on
# a symmetric multimer. Rank is now (squared distance, atom index): a total
# order, so traversal order cannot matter.
# Eight atoms EXACTLY equidistant from the origin (cube corners): every
# distance ties, so the choice is decided purely by the tie-break.
set _cx {}
foreach {_a _b _c} {1 1 1  1 1 -1  1 -1 1  1 -1 -1  -1 1 1  -1 1 -1  -1 -1 1  -1 -1 -1} {
    lappend _cx $_a $_b $_c
}
lassign [::VMDPathFinder::Mole::nearest5 0.0 0.0 0.0 $_cx 8] _sel _sd
chk "an all-tie neighbourhood still returns five atoms" [llength $_sel] 5
chk "...and picks the LOWEST indices, in order" $_sel {0 1 2 3 4}
chk "...with every distance genuinely equal" \
    [expr {abs([lindex $_sd 0] - [lindex $_sd 4]) < 1e-12}] 1
# Reversing the atom order must give the same ANSWER SET shape - the rule is
# index-based, so it now selects the first five of whatever order is given,
# which is what makes it reproducible rather than traversal-dependent.
lassign [::VMDPathFinder::Mole::nearest5 0.0 0.0 0.0 $_cx 8] _sel2 _sd2
chk "the same query twice gives the identical selection" $_sel2 $_sel

# --- alignment: progress, abort, and not doing it twice ---------------------
# The tunnel run auto-aligns on EVERY run, and align_trajectory had no progress
# and no abort. Per-frame cost is small (0.05 ms on a 4.6k-atom system) but
# `$all move` rewrites every atom of every frame, so on a big solvated system x
# 10k frames it is minutes of frozen UI - which is what "the alignment took too
# long" is. Superposition is idempotent, so a repeat is waste, not error.
set _ab [info body ::VMDPathFinder::align_trajectory]
chk "alignment reports progress while it runs" [string match {*Aligning trajectory: *} $_ab] 1
chk "...and can be aborted" [string match {*_abort_requested*} $_ab] 1
chk "an aborted alignment ERRORS rather than claiming success" \
    [string match {*partly aligned*} $_ab] 1
# The idempotence guard is keyed on everything the result depends on.
set _sig1 [::VMDPathFinder::_align_signature 0 "protein and name CA" 0 100]
chk "a fresh signature is not marked done" \
    [::VMDPathFinder::_align_already_done 0 "protein and name CA" 0 100] 0
::VMDPathFinder::_align_mark_done 0 "protein and name CA" 0 100
chk "...and is after marking" [::VMDPathFinder::_align_already_done 0 "protein and name CA" 0 100] 1
chk "a DIFFERENT selection is not covered by it" \
    [::VMDPathFinder::_align_already_done 0 "protein" 0 100] 0
chk "a different reference frame is not covered either" \
    [::VMDPathFinder::_align_already_done 0 "protein and name CA" 5 100] 0
chk "a different frame count is not covered (trajectory changed)" \
    [::VMDPathFinder::_align_already_done 0 "protein and name CA" 0 200] 0
# The tunnel run must consult it, or the saving never happens.
chk "the tunnel run skips an alignment it already did" \
    [string match {*_align_already_done*} [info body ::VMDPathFinder::run_tunnel_analysis]] 1
set ::VMDPathFinder::_align_done {}

# --- the live frame marker must never reach an exported figure --------------
# Every plot draws a current-frame indicator so you can see where you are in
# the trajectory. Only the HEATMAP export passed its tag to be hidden, so the
# Trends and Ion Flow exports shipped the marker into the saved figure. The tag
# is now resolved from the tab, not named at each export button.
foreach {_tab _tag} {trends minr_indicator heatmap heatmap_indicator
                     ionflow ion_passage_indicator hydration hyd_hm_indicator} {
    chk "the '$_tab' export hides its frame marker" \
        [expr {$_tag in [::VMDPathFinder::_export_live_tags $_tab]}] 1
}
# A tab with no live overlay must not invent one.
foreach _tab {profile mean hist} {
    chk "the '$_tab' export hides nothing it should not" [::VMDPathFinder::_export_live_tags $_tab] {}
}
# And the wrapper must actually apply them, on top of anything passed in.
chk "the export wrapper merges the tab's live tags" \
    [string match {*_export_live_tags $tab*} [info body ::VMDPathFinder::_export_fig]] 1
# The tags must be the ones the drawing code really uses, or hiding is a no-op.
foreach {_p _tag} {update_minr_indicator minr_indicator
                   update_ion_passage_indicator ion_passage_indicator} {
    chk "$_p really draws items tagged $_tag" \
        [string match "*-tags $_tag*" [info body ::VMDPathFinder::$_p]] 1
}

# --- export FILENAMES must identify the data uniquely -----------------------
# Audit after "the names do not cover all the combinations an output can
# cover". Three collisions existed and every one SILENTLY overwrote:
#   MODE   - profile/mean/trends/heatmap/hist all exist in BOTH modes with
#            different data and produced the same filename in both;
#   TUNNEL - in tunnel mode those plots are of the SELECTED tunnel;
#   FRAME  - the Pore Profile is per-frame.
# The CSV exporters already carried id/frame/range tags; the figure path did
# not. Tunnel mode does NOT get a frame tag on trajectory-wide plots, where a
# frame number would be actively misleading.
# analysis_mode reads the Tk notebook and is always "hole" headless, so it is
# stubbed here - the naming logic under test is what matters, not how the mode
# is discovered. Restored at the end of the block.
rename ::VMDPathFinder::analysis_mode ::VMDPathFinder::_real_analysis_mode
proc ::VMDPathFinder::analysis_mode {} { return $::_test_mode }
set ::_test_mode hole
set _sv_tid  [expr {[info exists ::VMDPathFinder::state(tunnel_selected_id)] ? $::VMDPathFinder::state(tunnel_selected_id) : ""}]
set _sv_srf  [expr {[info exists ::VMDPathFinder::state(selected_result_frame)] ? $::VMDPathFinder::state(selected_result_frame) : ""}]

set ::_test_mode hole
set ::VMDPathFinder::state(selected_result_frame) 12
set _pore_profile [::VMDPathFinder::export_fig_stem profile]
set _pore_trends  [::VMDPathFinder::export_fig_stem trends]
set _pore_hist    [::VMDPathFinder::export_fig_stem hist]
chk "a pore-mode profile names its frame" [string match {*_frame12} $_pore_profile] 1
chk "a trajectory-wide plot gets no frame NUMBER (the stem's own vs_frame is not one)" [regexp {_frame[0-9]+} $_pore_trends] 0

set ::_test_mode tunnel
set ::VMDPathFinder::state(tunnel_selected_id) 7
set _tun_profile [::VMDPathFinder::export_fig_stem profile]
set _tun_trends  [::VMDPathFinder::export_fig_stem trends]
set _tun_hist    [::VMDPathFinder::export_fig_stem hist]
chk "tunnel mode is named, so it cannot overwrite the pore figure" \
    [expr {$_tun_profile ne $_pore_profile}] 1
chk "...for Trends too" [expr {$_tun_trends ne $_pore_trends}] 1
chk "...and the Histogram, which had a fixed name" [expr {$_tun_hist ne $_pore_hist}] 1
chk "the tunnel figure says which mode it is" [string match {tunnel_*} $_tun_trends] 1
chk "...and which tunnel" [string match {*_tunnel7*} $_tun_trends] 1
set ::VMDPathFinder::state(tunnel_selected_id) 3
chk "a DIFFERENT tunnel gets a different filename" \
    [expr {[::VMDPathFinder::export_fig_stem trends] ne $_tun_trends}] 1
# The mode prefix must not double up on a stem that already says "tunnel".
set ::VMDPathFinder::state(tunnel_selected_id) 7
chk "the mode prefix is not applied twice" \
    [expr {[llength [regexp -all -inline {tunnel_} [::VMDPathFinder::export_fig_stem trends]]] <= 1}] 1

# --- The rest of the combination space -------------------------------------
# The user's worked example was Over Time: "2 radius sources x 4 colors + 12
# properties". Radius source and property were already named; the COLOR SCHEME
# was not, so the same map exported in two schemes silently overwrote. Two more
# tabs had the same shape of gap.
set ::_test_mode hole
set ::VMDPathFinder::state(heatmap_color_by) radius
set ::VMDPathFinder::state(heatmap_radius_source) hole
foreach _s {viridis cividis rainbow watermelon} {
    set ::VMDPathFinder::state(heatmap_scheme) $_s
    set _hs($_s) [::VMDPathFinder::export_fig_stem heatmap]
}
chk "each Over Time color scheme gets its own filename" \
    [llength [lsort -unique [list $_hs(viridis) $_hs(cividis) $_hs(rainbow) $_hs(watermelon)]]] 4
set ::VMDPathFinder::state(heatmap_radius_source) ellipse
chk "...and the radius source is still named alongside it" \
    [expr {[::VMDPathFinder::export_fig_stem heatmap] ne $_hs(watermelon)}] 1
set ::VMDPathFinder::state(heatmap_radius_source) hole
# The Pore Profile tab draws three different figures; only one of them is a
# profile. The unrolled wall map exported as "pore_profile", and each of its
# 12 layers overwrote the last.
set _sv_pvm [expr {[info exists ::VMDPathFinder::state(profile_view_mode)] ? $::VMDPathFinder::state(profile_view_mode) : "none"}]
set ::VMDPathFinder::state(profile_view_mode) unroll
set ::VMDPathFinder::state(unroll_layer) prop_kd
set _u1 [::VMDPathFinder::export_fig_stem profile]
set ::VMDPathFinder::state(unroll_layer) chain
set _u2 [::VMDPathFinder::export_fig_stem profile]
chk "the unrolled map is not named 'pore_profile'" \
    [expr {![string match {*pore_profile*} $_u1]}] 1
chk "...it says which layer it is" [string match {*pore_wall_map_kd*} $_u1] 1
chk "...and two layers cannot collide" [expr {$_u1 ne $_u2}] 1
set ::VMDPathFinder::state(profile_view_mode) $_sv_pvm
# The Histogram plots one of three aggregators and named all three the same.
set _sv_agg $::VMDPathFinder::state(hist_aggregator)
set ::VMDPathFinder::state(hist_aggregator) Mean
set _g1 [::VMDPathFinder::export_fig_stem hist]
set ::VMDPathFinder::state(hist_aggregator) Min
chk "each histogram aggregator gets its own filename" \
    [expr {[::VMDPathFinder::export_fig_stem hist] ne $_g1}] 1
set ::VMDPathFinder::state(hist_aggregator) $_sv_agg

rename ::VMDPathFinder::analysis_mode {}
rename ::VMDPathFinder::_real_analysis_mode ::VMDPathFinder::analysis_mode
set ::VMDPathFinder::state(tunnel_selected_id) $_sv_tid
if {$_sv_srf ne ""} { set ::VMDPathFinder::state(selected_result_frame) $_sv_srf }

# --- A2: OUR properties as unrolled-map layers ------------------------------
# HOLE's 2DMAPS card writes exactly five grids and there is no card for more.
# But one of those five, `resno`, already names the residue each cell's wall
# atom belongs to, and `chain` disambiguates it - so a property layer needs no
# ray-casting of its own: read HOLE's answer for WHICH residue, then evaluate
# any scale on it, into the same .grd shape the reader/cache/renderer expect.
set _pdir [file join $here _propmap_test]
catch {file delete -force $_pdir}
file mkdir $_pdir
# A tiny structure with residues of KNOWN, DIFFERENT kd values.
set _ppdb [file join $_pdir p.pdb]
set _pfh [open $_ppdb w]
set _pn 0
foreach {_rid _rn} {1 ILE 2 ARG 3 ALA} {
    foreach _an {N CA C O} {
        incr _pn
        puts $_pfh [format "ATOM  %5d  %-3s %3s A%4d    %8.3f%8.3f%8.3f  1.00  0.00           C" \
            $_pn $_an $_rn $_rid [expr {$_pn*1.5}] 0.0 0.0]
    }
}
close $_pfh
set _pm [mol new $_ppdb waitfor all]
set _sv_selp $::VMDPathFinder::state(selection)
set ::VMDPathFinder::state(selection) "all"
# HOLE-shaped resno/chain grids: 3 columns x 2 rows, cells naming residues
# 1,2,3 on row 1 and 3,2,1 on row 2 - so a transposed or reversed read shows up.
proc _wgrd2 {path nx ny vals} {
    set fh [open $path w]
    puts $fh "DSAA"; puts $fh "$nx $ny"; puts $fh "0.0 1.0"; puts $fh "0.0 1.0"
    puts $fh "0.0 1.0"; puts $fh [join $vals " "]; close $fh
}
_wgrd2 [::VMDPathFinder::_2dmap_grd_path $_pdir resno] 3 2 {1 2 3 3 2 1}
_wgrd2 [::VMDPathFinder::_2dmap_grd_path $_pdir chain] 3 2 {1 1 1 1 1 1}
set _perr [::VMDPathFinder::_2dmap_prop_build $_pdir $_pm 0 kd]
chk "a property grid builds from HOLE's own resno/chain grids" $_perr {}
set _pg [::VMDPathFinder::_2dmap_grd_read [::VMDPathFinder::_2dmap_prop_path $_pdir kd]]
chk "...with the SAME shape as the grid it was derived from" \
    [list [dict get $_pg nx] [dict get $_pg ny]] {3 2}
chk "...and one value per cell" [llength [dict get $_pg values]] 6
# The discriminating check: each cell must carry that residue's own kd value,
# in cell order. ILE +4.5, ARG -4.5, ALA +1.8.
set _want {}
foreach _r {ILE ARG ALA ALA ARG ILE} { lappend _want [format %.3f [::VMDPathFinder::residue_property kd $_r]] }
set _got {}
foreach _v [dict get $_pg values] { lappend _got [format %.3f $_v] }
chk "every cell carries ITS OWN residue's value, in cell order" $_got $_want
# A cell whose resno matches no residue must not fake a value.
_wgrd2 [::VMDPathFinder::_2dmap_grd_path $_pdir resno] 3 2 {1 2 3 999 999 999}
file delete [::VMDPathFinder::_2dmap_prop_path $_pdir kd]
chk "an unresolved cell is neutral, not invented" \
    [expr {[::VMDPathFinder::_2dmap_prop_build $_pdir $_pm 0 kd] eq ""
           && [lindex [dict get [::VMDPathFinder::_2dmap_grd_read \
                  [::VMDPathFinder::_2dmap_prop_path $_pdir kd]] values] 3] == 0.0}] 1
# The layers must actually be OFFERED, and route to the derived path.
set _lay [::VMDPathFinder::_2dmap_layers]
chk "the layer picker offers our scales" [dict exists $_lay prop_kd] 1
chk "...labelled as everywhere else in the plugin" \
    [lindex [dict get $_lay prop_kd] 0] [::VMDPathFinder::scheme_display_label kd]
chk "a prop_ layer resolves to its scale" [::VMDPathFinder::_2dmap_layer_scheme prop_kd] kd
chk "a HOLE layer does not" [::VMDPathFinder::_2dmap_layer_scheme touch] {}
chk "an unknown prop_ token is refused, not guessed" \
    [::VMDPathFinder::_2dmap_layer_scheme prop_nonsense] {}
chk "the grd path for a prop layer is the DERIVED file" \
    [::VMDPathFinder::_2dmap_grd_path $_pdir prop_kd] [::VMDPathFinder::_2dmap_prop_path $_pdir kd]
set ::VMDPathFinder::state(selection) $_sv_selp
catch {mol delete $_pm}
catch {file delete -force $_pdir}

# --- item 17: one NAME per quantity, across both modes ----------------------
# logP/logD/logS/mutability/ionizable are the SAME MOLE tables in both modes
# but were "LogP" in tunnel mode and "MOLE logP" in pore mode - one quantity,
# two names. And since item 9 put the HOLE scales into the tunnel picker too,
# MOLE's own hydropathy/polarity/charge now sit beside grantham polarity and
# formal charge, which are DIFFERENT quantities with near-identical names.
foreach _t {logp logd logs mutability ionizable} {
    chk "'$_t' is named identically in both modes" \
        [::VMDPathFinder::_tunnel_prop_label $_t] [::VMDPathFinder::scheme_display_label $_t]
}
foreach {_t _want} {hydropathy "MOLE hydropathy" polarity "MOLE polarity" charge "MOLE charge"} {
    chk "MOLE's own '$_t' says so, so it cannot be read as the HOLE scale" \
        [::VMDPathFinder::_tunnel_prop_label $_t] $_want
}
# The pair that would otherwise be indistinguishable in one picker.
chk "MOLE polarity and grantham polarity are distinguishable" \
    [expr {[::VMDPathFinder::_tunnel_prop_label polarity] ne [::VMDPathFinder::scheme_display_label polarity]}] 1
chk "MOLE charge and formal charge are distinguishable" \
    [expr {[::VMDPathFinder::_tunnel_prop_label charge] ne [::VMDPathFinder::scheme_display_label charge]}] 1
# Every token the picker offers must produce a non-empty, non-token label.
foreach _t [::VMDPathFinder::_tunnel_prop_tokens] {
    set _lbl [::VMDPathFinder::_tunnel_prop_label $_t]
    chk "'$_t' has a real display label" [expr {$_lbl ne "" && $_lbl ne "none"}] 1
}
chk "an empty token reads None" [::VMDPathFinder::_tunnel_prop_label ""] None

# --- two runs over the SAME frames must not collide -------------------------
# Mode/tunnel/frame tags cover "different data from one run". They do NOT cover
# "same frames, different run" - a second run at a different probe radius wrote
# the same filenames and overwrote the first.
rename ::VMDPathFinder::analysis_mode ::VMDPathFinder::_real_analysis_mode2
proc ::VMDPathFinder::analysis_mode {} { return $::_test_mode2 }
set ::_test_mode2 tunnel
rename ::VMDPathFinder::_tunnel_cfg ::VMDPathFinder::_real_tunnel_cfg
set ::_test_cfg "probe 1.4 interior 1.25"
proc ::VMDPathFinder::_tunnel_cfg {} { return $::_test_cfg }
# REWRITTEN: the tag used to be a 6-hex-digit hash of the run signature. It
# worked, but it read as noise on every filename ("there is a odd combination of
# numbers and text at the end of the exports why?"). It is now a run NUMBER, and
# the first run carries no tag at all - so the ordinary single-run case, which
# is nearly all of them, produces clean names. The collision guard it exists for
# is unchanged and still asserted below.
set _sv_erm $::VMDPathFinder::state(export_run_map)
set _sv_ern $::VMDPathFinder::state(export_run_next)
set ::VMDPathFinder::state(export_run_map) {}
set ::VMDPathFinder::state(export_run_next) 1
set _t1 [::VMDPathFinder::_export_run_tag]
chk "the FIRST run needs no tag - its names are already unique" $_t1 {}
chk "the SAME run gives the SAME tag (a re-export overwrites its own file)" \
    [::VMDPathFinder::_export_run_tag] $_t1
set ::_test_cfg "probe 2.0 interior 1.25"
set _t2 [::VMDPathFinder::_export_run_tag]
chk "a DIFFERENT run parameter gets its own tag rather than colliding" \
    [expr {$_t2 ne $_t1}] 1
chk "...and it is readable, not a hash" [regexp {^_run[0-9]+$} $_t2] 1
# Going back to the first run must return the FIRST tag, not allocate a third.
set ::_test_cfg "probe 1.4 interior 1.25"
chk "returning to an earlier run reuses its number" [::VMDPathFinder::_export_run_tag] $_t1
set ::_test_cfg "probe 2.0 interior 1.25"
# It must reach the actual filename, not just exist.
chk "the run tag is part of the export stem" \
    [string match "*$_t2" [::VMDPathFinder::export_fig_stem trends]] 1
# No signature (imported results) must give no tag, never a fabricated one.
proc ::VMDPathFinder::_tunnel_cfg {} { return "" }
chk "an unresolvable run adds nothing rather than inventing a tag" \
    [::VMDPathFinder::_export_run_tag] {}
chk "...and no hash-shaped tag survives anywhere" \
    [regexp {_r[0-9a-f]{6}} [::VMDPathFinder::export_fig_stem trends]] 0
# The collision this guards against is mostly a CROSS-SESSION one: run with one
# set of parameters today, different ones tomorrow, export both into the same
# folder. A session-local counter would call both "the first run" - the second
# would also be untagged and would silently overwrite the first. So the map is
# persisted; simulate the restart by reloading the state from what was saved.
proc ::VMDPathFinder::_tunnel_cfg {} { return $::_test_cfg }
set ::_test_cfg "probe 3.5 interior 1.25"
set _t3 [::VMDPathFinder::_export_run_tag]
chk "a third distinct run gets a third number" \
    [expr {$_t3 ne $_t1 && $_t3 ne $_t2}] 1
chk "the map is persisted, not session-local" \
    [expr {[llength $::VMDPathFinder::state(export_run_map)] == 6}] 1
# Trimming must never RENUMBER: a survivor demoted to 1 would become untagged
# and collide with the original run 1's files.
set ::VMDPathFinder::state(export_run_next) 99
set ::_test_cfg "probe 9.9 interior 1.25"
chk "numbers come from the counter, never from a position" \
    [::VMDPathFinder::_export_run_tag] "_run99"
set ::_test_cfg "probe 3.5 interior 1.25"
chk "...and an earlier run still answers with ITS number" \
    [::VMDPathFinder::_export_run_tag] $_t3
chk "neither key is on the load-side skip list" \
    [expr {"export_run_map" ni [::VMDPathFinder::_config_skip_keys]
           && "export_run_next" ni [::VMDPathFinder::_config_skip_keys]}] 1
# The REAL round trip. Setting the state variable and reading it back only
# exercises the in-memory list; what the fix claims is that the numbering
# survives a VMD restart, and that runs through save_config's writer and
# load_config's `key = value` parser. A key that saves but does not load is
# silently equivalent to no persistence at all.
set _sv_cfgfile $::VMDPathFinder::config_file
set ::VMDPathFinder::config_file [file join [::VMDPathFinder::get_temp_base] "vmdpathfinder_cfg_test_[pid]"]
proc ::VMDPathFinder::_tunnel_cfg {} { return $::_test_cfg }
set ::VMDPathFinder::state(export_run_map)  {}
set ::VMDPathFinder::state(export_run_next) 1
set ::_test_cfg "probe 1.1 interior 1.25"
::VMDPathFinder::_export_run_tag
set ::_test_cfg "probe 2.2 interior 1.25"
set _sv_endrad $::VMDPathFinder::state(endrad)
set ::VMDPathFinder::state(endrad) 99.5
set _tp [::VMDPathFinder::_export_run_tag]
set ::VMDPathFinder::state(endrad) $_sv_endrad
chk "(setup) a second run is tagged before the restart" [expr {$_tp ne ""}] 1
chk "...and _export_run_tag saved the config by itself" [file exists $::VMDPathFinder::config_file] 1
set _cfgtxt ""
catch { set _fh [open $::VMDPathFinder::config_file r]; set _cfgtxt [read $_fh]; close $_fh }
chk "...writing only the run number, not the live settings" \
    [expr {[string match "*export_run_map*" $_cfgtxt] && ![string match "*endrad*" $_cfgtxt]}] 1
# Simulate the restart: wipe the in-memory map, reload from disk.
set ::VMDPathFinder::state(export_run_map)  {}
set ::VMDPathFinder::state(export_run_next) 1
::VMDPathFinder::load_config
chk "the map really comes back off disk" \
    [expr {[llength $::VMDPathFinder::state(export_run_map)] == 4}] 1
chk "...so the same run keeps its number across a restart" \
    [::VMDPathFinder::_export_run_tag] $_tp
set ::_test_cfg "probe 1.1 interior 1.25"
chk "...and the FIRST run is still the untagged one" [::VMDPathFinder::_export_run_tag] {}
catch {file delete -force $::VMDPathFinder::config_file}
set ::VMDPathFinder::config_file $_sv_cfgfile
set ::VMDPathFinder::state(export_run_map)  $_sv_erm
set ::VMDPathFinder::state(export_run_next) $_sv_ern
# Every CSV exporter must carry it too - they had the same collision, and
# their tunnel/frame/range tags do not distinguish two runs over one window.
set _ncsv 0
foreach _p {export_ion_flow_csv export_passability_species_csv
            export_tunnel_trends_csv export_metrics_csv export_tunnel_profile_csv
            export_profile_csv export_heatmap_csv export_tunnel_heatmap_csv} {
    if {[string match {*_export_run_tag*} [info body ::VMDPathFinder::$_p]]} { incr _ncsv }
}
chk "every CSV exporter carries the run tag ($_ncsv/8)" $_ncsv 8
rename ::VMDPathFinder::_tunnel_cfg {}
rename ::VMDPathFinder::_real_tunnel_cfg ::VMDPathFinder::_tunnel_cfg
rename ::VMDPathFinder::analysis_mode {}
rename ::VMDPathFinder::_real_analysis_mode2 ::VMDPathFinder::analysis_mode

# --- within-frame clustering must be built PER FRAME, on demand -------------
# It is a DISPLAY-only grouping and its only consumer asks for one frame, but
# it was computed for EVERY result frame at run and import time. MEASURED on
# the real 8 986-frame trajectory: ~20 ms/frame, 20x the whole cross-frame
# cost, for ~3 routes per frame nobody looks at - 216 s of the load.
array unset ::VMDPathFinder::tunnel_results
array unset ::VMDPathFinder::tunnel_clusters
array set ::VMDPathFinder::tunnel_clusters {}
unset -nocomplain ::VMDPathFinder::_tunnel_clusters_th
proc _mkt {x} {
    set p {}
    for {set i 0} {$i < 6} {incr i} { lappend p $x 0.0 [expr {$i*1.0}] 1.5 }
    return [list 1.5 6.0 0.0 0.0 $p]
}
set ::VMDPathFinder::tunnel_results(0) [list [_mkt 0.0] [_mkt 0.1] [_mkt 9.0]]
set ::VMDPathFinder::tunnel_results(1) [list [_mkt 0.0] [_mkt 5.0]]
set ::VMDPathFinder::tunnel_result_frames {0 1}
set ::VMDPathFinder::state(tunnel_cluster) 1.0
::VMDPathFinder::_tunnel_ensure_clusters_for 0
chk "the requested frame is clustered" [info exists ::VMDPathFinder::tunnel_clusters(0)] 1
chk "...and ONLY that frame - no eager pass over the rest" \
    [info exists ::VMDPathFinder::tunnel_clusters(1)] 0
# Near-duplicates merge, the distant route does not: 3 routes -> 2 clusters.
chk "the grouping is real, not a pass-through" [llength $::VMDPathFinder::tunnel_clusters(0)] 2
set _c0 $::VMDPathFinder::tunnel_clusters(0)
::VMDPathFinder::_tunnel_ensure_clusters_for 0
chk "a second call is cached, not recomputed to a different answer" \
    $::VMDPathFinder::tunnel_clusters(0) $_c0
# Changing the threshold must invalidate, or the list keeps showing groups from
# a threshold the user has moved away from.
set ::VMDPathFinder::state(tunnel_cluster) 99.0
::VMDPathFinder::_tunnel_ensure_clusters_for 0
chk "a threshold change invalidates the cache" \
    [expr {[llength $::VMDPathFinder::tunnel_clusters(0)] == 1}] 1
chk "...and drops other frames' stale groupings too" \
    [info exists ::VMDPathFinder::tunnel_clusters(1)] 0
chk "an unknown frame is a no-op, not an error" \
    [catch {::VMDPathFinder::_tunnel_ensure_clusters_for 99}] 0
# Neither the run nor the import may reinstate an all-frames pass.
foreach _p {run_tunnel_analysis import_tunnel_results_from_folder} {
    set _b {}
    foreach _l [split [info body ::VMDPathFinder::$_p] "\n"] {
        if {[string match "#*" [string trim $_l]]} continue
        append _b $_l "\n"
    }
    chk "$_p does not cluster every frame up front" \
        [string match {*foreach fr $tunnel_result_frames*tunnel_cluster *} $_b] 0
}
# The consumer must build its own frame, or a lazily-loaded frame shows
# ungrouped rows while the checkbox says otherwise.
chk "_tunnel_list_rows ensures the frame it is about to draw" \
    [string match {*_tunnel_ensure_clusters_for $frame*} [info body ::VMDPathFinder::_tunnel_list_rows]] 1
array unset ::VMDPathFinder::tunnel_results
array unset ::VMDPathFinder::tunnel_clusters
set ::VMDPathFinder::tunnel_result_frames {}

# --- the startup scratch sweep must identify the OWNER correctly ------------
# Four naming layouts exist, not three. For vmdpathfinder_<type>_<pid>_<ms> the old
# "last integer" rule picked the MILLISECOND TIMESTAMP as the pid - a 13-digit
# value that is never a live pid, so /proc/<ms> never existed and the directory
# was deleted on sight, including a RUNNING session's.
set _swp [info body ::VMDPathFinder::_sweep_stale_tmpdirs]
chk "the sweeper takes the FIRST integer, not the last" \
    [string match {*set pid $_p; break*} $_swp] 1
chk "...and knows about the 4-part layout" [string match {*<type>_<pid>_<ms>*} $_swp] 1
# /proc is not proof of absence inside a PID namespace, where the /proc cannot
# see the owner - "absent" would then mean "delete a live session's scratch".
chk "an age guard backs up the /proc check" [string match {*file mtime $d*} $_swp] 1
chk "...and the guard is a real interval, not zero" [string match {*3600*} $_swp] 1
# Behavioural: the pid extraction itself, on all four layouts.
proc _pidof {name} {
    set parts [lrange [split $name _] 1 end]
    set pid ""
    if {[string is integer -strict [lindex $parts 0]]} {
        set pid [lindex $parts 0]
    } else {
        foreach _p $parts { if {[string is integer -strict $_p]} { set pid $_p; break } }
    }
    return $pid
}
chk "vmdpathfinder_<pid>"                [_pidof vmdpathfinder_4242] 4242
chk "vmdpathfinder_<pid>_f<frame>"       [_pidof vmdpathfinder_4242_f7] 4242
chk "vmdpathfinder_<type>_<pid>"         [_pidof vmdpathfinder_batch_4242] 4242
chk "vmdpathfinder_<type>_<pid>_<ms> (the one that was wrong)" \
    [_pidof vmdpathfinder_clip_4242_1755000000000] 4242

# --- a TRUNCATED out.dat must not become a half-built tunnel ----------------
# The MOLE engine killed mid-write leaves a partial final record. `lindex` past
# the end returns "", so a short T line became a tunnel with an EMPTY
# bottleneck, and a short P line appended ""/""/"" as coordinates - neither
# fails until something downstream tries arithmetic on it.
set _good "T 1 1.50 20.0 0.0 0.0\nP 1 0.0 0.0 0.0 1.5 1.5 0.0\nP 1 0.0 0.0 1.0 1.4 1.4 0.0\n"
set _tp [::VMDPathFinder::_tunnel_parse_text $_good]
chk "a complete record parses" [llength $_tp] 1
chk "...with its bottleneck" [lindex [lindex $_tp 0] 0] 1.50
chk "...and both points" [llength [lindex [lindex $_tp 0] 4]] 8
# Truncated mid-T: the record must be dropped, not admitted with empty fields.
set _trunc "T 1 1.50 20.0 0.0 0.0\nP 1 0.0 0.0 0.0 1.5 1.5 0.0\nT 2 1.20"
set _tt [::VMDPathFinder::_tunnel_parse_text $_trunc]
chk "a truncated T record is dropped, not admitted" [llength $_tt] 1
chk "...and the COMPLETE tunnel before it survives" [lindex [lindex $_tt 0] 0] 1.50
# Truncated mid-P: no empty coordinates may reach the point list.
set _tp2 [::VMDPathFinder::_tunnel_parse_text "T 1 1.50 20.0 0.0 0.0\nP 1 0.0 0.0 0.0 1.5 1.5 0.0\nP 1 0.0"]
set _npts [llength [lindex [lindex $_tp2 0] 4]]
chk "a truncated P record adds no point" $_npts 4
set _empty 0
foreach _v [lindex [lindex $_tp2 0] 4] { if {$_v eq ""} { incr _empty } }
chk "...so no empty coordinate reaches the point list" $_empty 0

# --- overwrite prompts -------------------------------------------------------
# A pore run never overwrites: every run gets its own folder (_run_root_new),
# so run_analysis has no prompt at all. The tunnel run still reuses one folder
# and prompts before clobbering - only with a GUI, and only under the plugin's
# own window (VMD's Tk Console has Tk but not $w).
set _rab [info body ::VMDPathFinder::run_analysis]
set _rtb [info body ::VMDPathFinder::run_tunnel_analysis]
chk "a pore run makes its own folder and never prompts to overwrite" \
    [expr {[string first {confirm_overwrite_dialog} $_rab] < 0
           && [string first {_run_root_new} $_rab] >= 0}] 1
chk "the tunnel run still prompts before clobbering" \
    [expr {[string first {confirm_overwrite_dialog} $_rtb] >= 0}] 1
chk "run_tunnel_analysis gates its prompt on an enclosing _have_tk" \
    [string match {*!$is_tmp && \[_have_tk\] && \[winfo exists $w\]*} $_rtb] 1

# --- the accel manifest must record sph_process's own patch -----------------
# apply_patches.py has ALWAYS applied sphqpu_par.f (its patch list and
# OMP_FILES both name it), but build-hole-optimized.sh's manifest never emitted
# a line for it - and update_sph_accel_status looks for exactly that line. So a
# genuinely accelerated sph_process reported "not accelerated" AND had its
# toggle disabled, leaving no way to force the serial cull. Verified the binary
# really is parallel: 1.78 s at 1 thread vs 0.39 s at 8, byte-identical output.
# The manifest is emitted by the ONE install script,
# build-vmdpathfinder-optimized.sh (it builds HOLE, sph_process, sos_triangle and
# mole_tunnel_engine).
set _bhs [file join $here .. .. native build-vmdpathfinder-optimized.sh]
if {[file exists $_bhs]} {
    set _fh [open $_bhs r]; set _bt [read $_fh]; close $_fh
    chk "the build manifest records sphqpu_par.f" \
        [string match {*patch sphqpu_par.f*} $_bt] 1
    # Every patch apply_patches.py applies should be recorded, or the indicator
    # under-reports again the next time one is added.
    set _ap [file join $here .. .. native connolly_patches apply_patches.py]
    if {[file exists $_ap]} {
        set _fh [open $_ap r]; set _at [read $_fh]; close $_fh
        set _missing {}
        foreach _pf {hcapen_fast.f coarea_fast.f holcal_par.f holeen_par.f sphqpu_par.f} {
            if {[string match "*$_pf*" $_at] && ![string match "*patch $_pf*" $_bt]} {
                lappend _missing $_pf
            }
        }
        chk "every applied patch is recorded in the manifest ($_missing)" [llength $_missing] 0
    }
}
# build-hole-optimized.sh was first reduced to a delegating shim and then
# REMOVED outright (one build entry point). A second build script carrying its
# own copy of the build is what silently stopped recording sphqpu_par.f once
# already, so its ABSENCE is the invariant now - re-adding one under the old
# name would recreate exactly that trap.
chk "there is no second HOLE build script (one entry point)" \
    [file exists [file join $here .. .. native build-hole-optimized.sh]] 0

# The reader side must accept the line the writer emits.
chk "the indicator looks for the patch line the build writes" \
    [string match {*patch sphqpu_par.f*} [info body ::VMDPathFinder::update_sph_accel_status]] 1

# --- switching AWAY from the Unrolled map must actually redraw --------------
# on_profile_view_mode_changed drove only the fill/asymmetry FLAGS and left the
# redraw to their handlers, which fire on flag CHANGE. The Unrolled map sets
# neither flag, so unroll -> None changed nothing, nothing redrew, and the
# canvas kept the map while the picker read "None".
chk "the view-mode handler redraws unconditionally" \
    [string match {*redraw_profile_plot*} [info body ::VMDPathFinder::on_profile_view_mode_changed]] 1
# And the redraw itself must still branch to the map only for unroll.
chk "the plot draws the map ONLY in unroll mode" \
    [string match {*profile_view_mode) eq "unroll"*_draw_unrolled_map*} \
        [info body ::VMDPathFinder::draw_profile_plot]] 1


# --- ABORT must not leave a truncated Over Time result behind ---------------
# BEHAVIOUR test, not a source-text one. The fast path kills its jobs on abort,
# so whatever it returns is a TRUNCATION. Two things used to happen anyway:
# the partial bundle was CACHED (gated only on nframes > 0) and so outlived the
# abort, and control fell through to the pure-Tcl path - the slowest code in
# the file, which polled nothing, so aborting made it take LONGER.
set _sv_hpc $::VMDPathFinder::hm_prop_cache
set _sv_ar [expr {[info exists ::VMDPathFinder::state(abort_requested)] ? $::VMDPathFinder::state(abort_requested) : 0}]
set ::VMDPathFinder::hm_prop_cache [dict create]
rename ::VMDPathFinder::fast_available ::VMDPathFinder::_real_pfa
rename ::VMDPathFinder::heatmap_prop_bundle_fast ::VMDPathFinder::_real_hpbf
proc ::VMDPathFinder::fast_available {args} { if {$args eq "props residue"} { return 1 }; ::VMDPathFinder::_real_pfa {*}$args }
# A PARTIAL result: some frames survived the kill. This is exactly the shape
# that used to be cached as if it were complete.
proc ::VMDPathFinder::heatmap_prop_bundle_fast {a b c} { return [dict create nframes 3 partial yes] }
# 1. Not aborted: the bundle is returned AND cached (unchanged behaviour).
set ::VMDPathFinder::state(abort_requested) 0
set _r1 [::VMDPathFinder::heatmap_property_bundle 4 8]
chk "a complete run still returns its frames" [dict get $_r1 nframes] 3
chk "...and is still cached" [expr {[dict size $::VMDPathFinder::hm_prop_cache] == 1}] 1
# 2. Aborted: the SAME partial result must be refused and NOT cached.
set ::VMDPathFinder::hm_prop_cache [dict create]
set ::VMDPathFinder::state(abort_requested) 1
set _r2 [::VMDPathFinder::heatmap_property_bundle 4 8]
chk "an ABORTED run reports zero frames, not a partial count" [dict get $_r2 nframes] 0
chk "...and says it was aborted" [expr {[dict exists $_r2 aborted] && [dict get $_r2 aborted]}] 1
chk "...and caches NOTHING, so it cannot outlive the abort" \
    [dict size $::VMDPathFinder::hm_prop_cache] 0
set ::VMDPathFinder::state(abort_requested) $_sv_ar
rename ::VMDPathFinder::fast_available {}
rename ::VMDPathFinder::_real_pfa ::VMDPathFinder::fast_available
rename ::VMDPathFinder::heatmap_prop_bundle_fast {}
rename ::VMDPathFinder::_real_hpbf ::VMDPathFinder::heatmap_prop_bundle_fast
set ::VMDPathFinder::hm_prop_cache $_sv_hpc
# The slow Tcl fallback must poll the flag and use `update`, or the click is
# never even SEEN during it (idletasks does not process button presses).
set _hpb [info body ::VMDPathFinder::heatmap_property_bundle]
# The guard has to be in THIS proc. The loop text is identical in
# heatmap_esp_bundle, and a first-match edit put it there instead - this
# assertion is what caught that.
chk "...the property bundle really does poll it" \
    [expr {[string first {_abort_requested} $_hpb] >= 0}] 1
chk "...and refuses to return a truncated bundle" \
    [expr {[string first {aborted 1} $_hpb] >= 0}] 1
# The sibling ESP bundle shares the identical loop and must not keep the bug.
set _esp [info body ::VMDPathFinder::heatmap_esp_bundle]
chk "the ESP bundle polls abort too" [expr {[string first {_abort_requested} $_esp] >= 0}] 1
chk "...and also refuses a truncated bundle" [expr {[string first {aborted 1} $_esp] >= 0}] 1


# --- the property write must SURVIVE its own render (the inert-control cause) -
# _tunnel_gear_set writes the rank key always, but mirrored to the cluster only
# when tunnel_xcid had an entry. It then calls render_tunnels_for_frame, whose
# _tunnel_sync_gear_from_cluster treats the CLUSTER store as authoritative and
# UNSETS the rank entry when the cluster has none - so an unmirrored write was
# erased by the very render its own setter triggered. That is what "changing
# the property does nothing" actually was.
array unset ::VMDPathFinder::tunnel_gear_prop
array unset ::VMDPathFinder::tunnel_gear_cid
array unset ::VMDPathFinder::tunnel_xcid
set _sv_tsi [expr {[info exists ::VMDPathFinder::state(tunnel_selected_id)] ? $::VMDPathFinder::state(tunnel_selected_id) : ""}]
set _sv_tsc [expr {[info exists ::VMDPathFinder::state(tunnel_selected_cid)] ? $::VMDPathFinder::state(tunnel_selected_cid) : ""}]
# Stub the render so the test exercises the WRITE, not the drawing.
rename ::VMDPathFinder::render_tunnels_for_frame ::VMDPathFinder::_real_rtff
proc ::VMDPathFinder::render_tunnels_for_frame {args} {}
rename ::VMDPathFinder::_on_tunnel_selection_changed ::VMDPathFinder::_real_otsc
proc ::VMDPathFinder::_on_tunnel_selection_changed {args} {}
rename ::VMDPathFinder::_tunnel_display_frame ::VMDPathFinder::_real_tdf
proc ::VMDPathFinder::_tunnel_display_frame {} { return 0 }
# The failing case: selected tunnel 4, pinned cluster 9, but NO rank->cluster
# entry for this frame (the cluster has no rank here).
set ::VMDPathFinder::state(tunnel_selected_id) 4
set ::VMDPathFinder::state(tunnel_selected_cid) 9
::VMDPathFinder::_tunnel_gear_set 4 prop charge
chk "the write reaches the CLUSTER store even with no rank->cid entry" \
    [expr {[info exists ::VMDPathFinder::tunnel_gear_cid(9,prop)]
           && $::VMDPathFinder::tunnel_gear_cid(9,prop) eq "charge"}] 1
# ...which is what makes it survive the cluster sync that erases rank keys.
::VMDPathFinder::_tunnel_sync_gear_from_cluster 0 4
chk "...so a rank-keyed value is not the only copy" \
    [expr {[info exists ::VMDPathFinder::tunnel_gear_cid(9,prop)]}] 1
# And the reader Over Time actually uses must see it.
chk "the cluster reader returns the property that was set" \
    [::VMDPathFinder::_tunnel_effective_prop_for_cluster 9] charge
# With a real rank->cid entry the original path still works.
set ::VMDPathFinder::tunnel_xcid(0,4) 12
::VMDPathFinder::_tunnel_gear_set 4 prop logp
chk "a real rank->cid mapping still mirrors to ITS cluster" \
    [::VMDPathFinder::_tunnel_effective_prop_for_cluster 12] logp
array unset ::VMDPathFinder::tunnel_gear_prop
array unset ::VMDPathFinder::tunnel_gear_cid
array unset ::VMDPathFinder::tunnel_xcid
set ::VMDPathFinder::state(tunnel_selected_id) $_sv_tsi
set ::VMDPathFinder::state(tunnel_selected_cid) $_sv_tsc
rename ::VMDPathFinder::render_tunnels_for_frame {}
rename ::VMDPathFinder::_real_rtff ::VMDPathFinder::render_tunnels_for_frame
rename ::VMDPathFinder::_on_tunnel_selection_changed {}
rename ::VMDPathFinder::_real_otsc ::VMDPathFinder::_on_tunnel_selection_changed
rename ::VMDPathFinder::_tunnel_display_frame {}
rename ::VMDPathFinder::_real_tdf ::VMDPathFinder::_tunnel_display_frame

# --- the GLOBAL property must not be masked by per-tunnel overrides ----------
# state(tunnel_prop) is only the FALLBACK, so any tunnel that ever had a
# property set masked it permanently. The `color` branch already cleared
# overrides; `prop` did not. "Changing the global property does nothing."
array unset ::VMDPathFinder::tunnel_gear_prop
array unset ::VMDPathFinder::tunnel_gear_cid
set ::VMDPathFinder::tunnel_gear_prop(2) charge
set ::VMDPathFinder::tunnel_gear_cid(7,prop) charge
rename ::VMDPathFinder::render_tunnels_for_frame ::VMDPathFinder::_real_rtff2
proc ::VMDPathFinder::render_tunnels_for_frame {args} {}
rename ::VMDPathFinder::_on_tunnel_selection_changed ::VMDPathFinder::_real_otsc2
proc ::VMDPathFinder::_on_tunnel_selection_changed {args} {}
::VMDPathFinder::_tunnel_global_gear_set prop logs
chk "a global property clears the rank-keyed overrides that masked it" \
    [info exists ::VMDPathFinder::tunnel_gear_prop(2)] 0
chk "...and the cluster-keyed ones too" [info exists ::VMDPathFinder::tunnel_gear_cid(7,prop)] 0
chk "...so every tunnel now resolves to the global" \
    [::VMDPathFinder::_tunnel_effective_prop_for_cluster 7] logs
# Global COLOR must still clear color, not property.
set ::VMDPathFinder::tunnel_gear_prop(2) charge
::VMDPathFinder::_tunnel_global_gear_set colormode auto
chk "a global COLOR does not wipe property overrides" \
    [info exists ::VMDPathFinder::tunnel_gear_prop(2)] 1
array unset ::VMDPathFinder::tunnel_gear_prop
array unset ::VMDPathFinder::tunnel_gear_cid
rename ::VMDPathFinder::render_tunnels_for_frame {}
rename ::VMDPathFinder::_real_rtff2 ::VMDPathFinder::render_tunnels_for_frame
rename ::VMDPathFinder::_on_tunnel_selection_changed {}
rename ::VMDPathFinder::_real_otsc2 ::VMDPathFinder::_on_tunnel_selection_changed

# --- the global gear must offer the SAME property list as everywhere else ----
chk "the global gear no longer carries a hardcoded token list" \
    [string match {*foreach tok \[_tunnel_prop_tokens\]*} \
        [info body ::VMDPathFinder::show_tunnel_global_gear_settings]] 1
# The label arrays it used are gone; one proc names every token now.
chk "kd has a label from the single label proc" [::VMDPathFinder::_tunnel_prop_label kd] [::VMDPathFinder::scheme_display_label kd]


# --- Mean Profile: IsoSurface revealed dropdowns nothing consulted (D3/D4) ---
# build_and_show_tunnel_mean_surface read ONLY the per-tunnel *_cid resolvers,
# never mean_surface_color / mean_surface_material - while
# _update_mean_coloring_visibility packs those two dropdowns exactly when the
# surface is switched on. So turning IsoSurface on revealed two live-looking
# controls the builder never read: "no material, no property, no color".
set _bmb [info body ::VMDPathFinder::build_and_show_tunnel_mean_surface]
chk "the mean surface reads the tab's own Material" \
    [expr {[string first {state(mean_surface_material)} $_bmb] >= 0}] 1
chk "...and the tab's own Color" \
    [expr {[string first {state(mean_surface_color)} $_bmb] >= 0}] 1
# A control that changes nothing on screen is the same bug in another form, so
# the rebuild key must carry them.
set _sv_mm [expr {[info exists ::VMDPathFinder::state(mean_surface_material)] ? $::VMDPathFinder::state(mean_surface_material) : ""}]
set _sv_mc [expr {[info exists ::VMDPathFinder::state(mean_surface_color)] ? $::VMDPathFinder::state(mean_surface_color) : ""}]
set _sv_cid [expr {[info exists ::VMDPathFinder::state(tunnel_selected_cid)] ? $::VMDPathFinder::state(tunnel_selected_cid) : ""}]
set ::VMDPathFinder::state(tunnel_selected_cid) 3
set ::VMDPathFinder::state(mean_surface_material) Opaque
set ::VMDPathFinder::state(mean_surface_color) green
set _k1 [::VMDPathFinder::_tunnel_mean_build_key]
set ::VMDPathFinder::state(mean_surface_material) Glass1
set _k2 [::VMDPathFinder::_tunnel_mean_build_key]
chk "changing Material changes the rebuild key" [expr {$_k1 ne $_k2}] 1
set ::VMDPathFinder::state(mean_surface_color) property
set _k3 [::VMDPathFinder::_tunnel_mean_build_key]
chk "changing Color changes it too" [expr {$_k3 ne $_k2}] 1
chk "...and the same settings give the same key (still cacheable)" \
    [expr {$_k3 eq [::VMDPathFinder::_tunnel_mean_build_key]}] 1
set ::VMDPathFinder::state(mean_surface_material) $_sv_mm
set ::VMDPathFinder::state(mean_surface_color) $_sv_mc
set ::VMDPathFinder::state(tunnel_selected_cid) $_sv_cid

# --- the tunnel wiring must survive a menu rebuild ---------------------------
# refresh_property_scheme_menus rebuilt the Mean Profile and Over Time menus
# with HOLE bindings unconditionally, from five call sites, silently undoing
# the tunnel rewire - which is why the earlier Mean Profile fix did not stick.
set _rps [info body ::VMDPathFinder::refresh_property_scheme_menus]
chk "the menu rebuild re-applies the tunnel wiring" \
    [expr {[string first {_sync_mean_prop_picker_for_mode} $_rps] >= 0
           && [string first {_populate_hm_tunnel_prop_menu} $_rps] >= 0}] 1
chk "...and only in tunnel mode" \
    [expr {[string first {eq "tunnel"} $_rps] >= 0}] 1


# --- tunnel Histogram Min/Max/Mean: reported wrong, MEASURED correct (D5) ----
# "the min value is definitely not min". Tested end to end through the real
# collector with known radii: it is right. Recorded so the next report starts
# from evidence rather than re-deriving this.
#
# The likely confusion: the tunnel LIST's Bneck column is a cross-frame MEAN
# (_tunnel_cluster_rows averages each cluster's members), while the Histogram's
# Min is the smallest RAW sphere radius in a bin. They are different
# quantities and SHOULD differ - the list value is never the smaller one.
array unset ::VMDPathFinder::tunnel_results
proc _hmk {rads} {
    set p {}; set i 0
    foreach r $rads { lappend p 0.0 0.0 [expr {$i*1.0}] $r; incr i }
    return $p
}
set ::VMDPathFinder::tunnel_results(0) [list [list 1.0 5.0 0.0 0.0 [_hmk {3.0 2.0 1.0 2.0 3.0}]]]
set ::VMDPathFinder::tunnel_results(1) [list [list 1.0 5.0 0.0 0.0 [_hmk {4.0 3.0 2.5 3.0 4.0}]]]
set _sv_trf $::VMDPathFinder::tunnel_result_frames
set ::VMDPathFinder::tunnel_result_frames {0 1}
rename ::VMDPathFinder::_tunnel_rank_in_frame ::VMDPathFinder::_real_trif
proc ::VMDPathFinder::_tunnel_rank_in_frame {f} { return 1 }
rename ::VMDPathFinder::_tunnel_tuple_for ::VMDPathFinder::_real_ttf
proc ::VMDPathFinder::_tunnel_tuple_for {f rk} {
    variable tunnel_results
    if {![info exists tunnel_results($f)]} { return "" }
    return [lindex $tunnel_results($f) 0]
}
rename ::VMDPathFinder::_tunnel_selected_cluster ::VMDPathFinder::_real_tsc
proc ::VMDPathFinder::_tunnel_selected_cluster {} { return 1 }
set _sv_bc $::VMDPathFinder::binned_cache
set ::VMDPathFinder::binned_cache {}
set _hd [::VMDPathFinder::_tunnel_collect_binned_radii 5]
set _hmin 1e9; set _hmax -1e9
foreach _s [dict get $_hd stats_raw] {
    if {$_s eq {}} continue
    lassign $_s _mean _std _mn _mx _n
    if {$_mn < $_hmin} { set _hmin $_mn }
    if {$_mx > $_hmax} { set _hmax $_mx }
}
chk "the histogram's Min really is the smallest radius" $_hmin 1.0
chk "...and its Max really is the largest" $_hmax 4.0
# bin_stats' tuple order is what the aggregator indexes (Min=2, Max=3, Mean=0).
set _bs [lindex [::VMDPathFinder::bin_stats {{1.0 2.0 6.0}}] 0]
chk "bin_stats puts mean at index 0" [format %.1f [lindex $_bs 0]] 3.0
chk "...min at index 2" [lindex $_bs 2] 1.0
chk "...and max at index 3" [lindex $_bs 3] 6.0
set ::VMDPathFinder::binned_cache $_sv_bc
set ::VMDPathFinder::tunnel_result_frames $_sv_trf
array unset ::VMDPathFinder::tunnel_results
rename ::VMDPathFinder::_tunnel_rank_in_frame {}
rename ::VMDPathFinder::_real_trif ::VMDPathFinder::_tunnel_rank_in_frame
rename ::VMDPathFinder::_tunnel_tuple_for {}
rename ::VMDPathFinder::_real_ttf ::VMDPathFinder::_tunnel_tuple_for
rename ::VMDPathFinder::_tunnel_selected_cluster {}
rename ::VMDPathFinder::_real_tsc ::VMDPathFinder::_tunnel_selected_cluster

# D5's real cause: the axis is a 5% TRIMMED max, so a bar taller than it is
# capped at that height rather than stretching the axis. The stats themselves
# are correct (asserted above) - min/max/mean always come from the same
# per-bin list (bin_stats, asserted above), so a capped Mean bar is a display
# choice, not the Mean being wrong. The distinct-color "N bar(s) exceed the
# axis" callout that used to mark capped bars was removed (decided unnecessary,
# user ) - a capped bar now renders exactly like any other.
set _dh [info body ::VMDPathFinder::draw_histogram_tab]
chk "a bar taller than the trimmed axis is still capped, not stretched" \
    [expr {[string first {v_draw} $_dh] >= 0 && [string first {> $ymax} $_dh] >= 0}] 1
chk "...with no distinguishing color or exceed-axis callout left on the plot" \
    [expr {[string first {exceed the axis} $_dh] < 0 && [string first {9ac0e8} $_dh] < 0}] 1

# --- C10: an inherited row reads plain "auto" (REVERSAL, by user instruction) -
# The "(from global)" suffix was introduced so a control names what it SHOWS.
# In the Color menu that produced "Property" next to "Property (from global)"
# - two entries whose difference no label can carry. Plain "auto" states the
# same fact (this tunnel makes no choice of its own) without the collision.
chk "an inherited row reads exactly \"auto\"" [::VMDPathFinder::_tunnel_inherited_only_label] auto
foreach _p {_tunnel_inherited_repr_label _tunnel_inherited_material_label
            _tunnel_inherited_prop_label _tunnel_inherited_label} {
    chk "$_p returns the bare word" [::VMDPathFinder::$_p ""] auto
}
# The picker must still RECOGNISE it, or choosing "auto" would be ignored.
chk "\"auto\" is recognised as the inherit choice" [::VMDPathFinder::_tunnel_is_inherited_label auto] 1
chk "a real value is not" [::VMDPathFinder::_tunnel_is_inherited_label Wireframe] 0
# Old forms still accepted so a stale label cannot strand a menu.
chk "the old suffix form is still tolerated" \
    [::VMDPathFinder::_tunnel_is_inherited_label "Rank (from global)"] 1
# And nothing user-facing still says the old phrase.
set _srcbits 0
foreach _p {_tunnel_inherited_repr_label _tunnel_inherited_material_label
            _tunnel_inherited_prop_label _tunnel_inherited_label} {
    if {[string first "from global" [::VMDPathFinder::$_p ""]] >= 0} { incr _srcbits }
}
chk "no inherited label still shows \"from global\"" $_srcbits 0

# --- tunnel passability really computes (D1) --------------------------------
# The species table was wired to metrics_for_tunnel all along; what was broken
# was _refresh_passability_base, which computes PORE-mode ellipse conductance
# from state(selected_result_frame) - still holding whatever HOLE frame was
# last selected - and displayed it inside the TUNNEL dialog. Two different
# channels' numbers in one table, with nothing saying so.
chk "the ellipse conductance refuses to run in tunnel mode" \
    [expr {[string first {eq "tunnel"} [info body ::VMDPathFinder::_show_ellipse_conductance]] >= 0}] 1
rename ::VMDPathFinder::_tunnel_selected_tuple ::VMDPathFinder::_real_tst
proc ::VMDPathFinder::_tunnel_selected_tuple {} {
    set p {}; set i 0
    foreach r {3.0 2.0 1.0 2.0 3.0} { lappend p 0.0 0.0 [expr {$i*1.0}] $r; incr i }
    return [list 1.0 5.0 0.0 0.0 $p]
}
set _pm [::VMDPathFinder::metrics_for_tunnel]
chk "a selected tunnel yields metrics" [expr {[dict size $_pm] > 0}] 1
chk "...with the bottleneck as its min radius" [dict get $_pm min_radius] 1.0
set _pa [dict get $_pm passability]
chk "...and a species passability table" [expr {[llength $_pa] > 0}] 1
# Physics check: at r=1.0 A water (1.40) cannot pass; Na+ passes bare (0.95)
# but not hydrated (3.58). A table that says otherwise is not wired to rmin.
set _wi [lsearch -exact $_pa Water]
set _nai [lsearch -exact $_pa Na]
chk "water is blocked by a 1.0 A bottleneck" \
    [dict get [lindex $_pa [expr {$_wi+1}]] pass_bare] 0
chk "Na+ passes bare but NOT hydrated" \
    [list [dict get [lindex $_pa [expr {$_nai+1}]] pass_bare] \
          [dict get [lindex $_pa [expr {$_nai+1}]] pass_hyd]] {1 0}
rename ::VMDPathFinder::_tunnel_selected_tuple {}
rename ::VMDPathFinder::_real_tst ::VMDPathFinder::_tunnel_selected_tuple

# --- C11: the tunnel property list matches pore mode's set and ORDER --------
set _tt [::VMDPathFinder::_tunnel_prop_tokens]
chk "the shared HOLE scales come first, in pore-mode order" \
    [lrange $_tt 0 3] {kd ww kr lipophilicity}
chk "...then MOLE's own tables" [lindex $_tt 4] charge
# kr sits in pore mode's own position. It must NOT be a residue_property lookup:
# there is no kr branch there, so that would report Kyte-Doolittle numbers under
# the Kapcha-Rossky name. It goes through the atoms instead.
chk "residue_property still has no kr branch to fall through to" \
    [expr {[::VMDPathFinder::residue_property kr ILE] == [::VMDPathFinder::residue_property kd ILE]}] 1
chk "so the layer scale routes kr away from that table" \
    [expr {[string first "_tunnel_layer_kr" [info body ::VMDPathFinder::_tunnel_layer_scale]] >= 0}] 1

# --- A1: tunnel-mode Over Time's property is INDEPENDENT of the 3D route's ---
# RED before this fix: _hm_tunnel_prop_pick called _tunnel_profile_prop_pick, so
# touching a 2D plot's picker rewrote the SELECTED tunnel's own property
# override - which is what recolored the 3D visualiser. The assertion that
# matters is the NEGATIVE one: the route's property must not have moved.
set _sv_a1_id  [expr {[info exists ::VMDPathFinder::state(tunnel_selected_id)]  ? $::VMDPathFinder::state(tunnel_selected_id)  : ""}]
set _sv_a1_cid [expr {[info exists ::VMDPathFinder::state(tunnel_selected_cid)] ? $::VMDPathFinder::state(tunnel_selected_cid) : ""}]
set _sv_a1_hm  $::VMDPathFinder::state(hm_tunnel_prop)
array unset ::VMDPathFinder::tunnel_gear_cid
array unset ::VMDPathFinder::tunnel_gear_prop
array unset ::VMDPathFinder::tunnel_xcid
set ::VMDPathFinder::state(tunnel_selected_id)  4
set ::VMDPathFinder::state(tunnel_selected_cid) 21
set ::VMDPathFinder::tunnel_xcid(0,4) 21
::VMDPathFinder::_tunnel_gear_set 4 prop charge
chk "A1 setup: the route's own property is charge" \
    [::VMDPathFinder::_tunnel_effective_prop_for_cluster 21] charge
# Drive Over Time's picker - the real handler its menu entries are bound to.
::VMDPathFinder::_hm_tunnel_prop_pick logp
chk "A1 Over Time's property moved to the picked one" [::VMDPathFinder::_hm_tunnel_prop] logp
chk "A1 ...and the ROUTE's property did not follow it" \
    [::VMDPathFinder::_tunnel_effective_prop_for_cluster 21] charge
chk "A1 ...nor did the rank-keyed store the gear popup reads" \
    [::VMDPathFinder::_tunnel_effective_prop 4] charge
# The two consumers - _tunnel_heatmap_prop (the renderer) and export_fig_stem
# (the filename) - both gate on [analysis_mode], which is read off the Tk
# notebook and is therefore always "hole" here. They are asserted in
# gui_reachable.tcl instead, with tunnel mode actually selected.
array unset ::VMDPathFinder::tunnel_gear_cid
array unset ::VMDPathFinder::tunnel_gear_prop
array unset ::VMDPathFinder::tunnel_xcid
set ::VMDPathFinder::state(tunnel_selected_id)  $_sv_a1_id
set ::VMDPathFinder::state(tunnel_selected_cid) $_sv_a1_cid
set ::VMDPathFinder::state(hm_tunnel_prop)      $_sv_a1_hm

# A2 / A1 in PORE mode is a write-TRACE behaviour, so it cannot be tested here
# (traces are installed while building Tk widgets) - see gui_reachable.tcl. What
# is checkable headless is the target set the sync proc iterates, since a stale
# entry there is silent: the sync just stops reaching that panel.
# Wrapped in a proc so the body never becomes a top-level command RESULT - this
# script is fed to vmd on stdin, which echoes those, and a 30-line proc body in
# the middle of the test log buries the assertions around it.
proc _spb_targets {needle} {
    set b [info body ::VMDPathFinder::_sync_property_scheme_across_panels]
    # Strip comments first: the header names every panel, including the one this
    # is checking is ABSENT, so an unstripped body matches its own prose.
    regsub -all {(?m)^\s*#.*$} $b {} b
    return [expr {[string first $needle $b] >= 0}]
}
chk "A2 Mean Profile is a sync target" [_spb_targets {mean_hydro_scheme}] 1
chk "A1 Over Time is NOT a sync target" [_spb_targets {hm_prop_scheme}] 0

# --- Pore vs sideways spill --------------------------------------------------
# A straight pore of radius 3 along z, with dots at r=2 (inside) and r=15 (spill).
set _cd [file join $here _conn_gate_test]
catch {file delete -force $_cd}
file mkdir $_cd
set _cs [file join $_cd cls.sph]
set _fh [open $_cs w]
for {set z -10} {$z <= 10} {incr z 2} {
    puts $_fh [format "ATOM  %5d  QSS SPH S%4d    %8.3f%8.3f%8.3f%6.2f%6.2f" \
        [expr {$z+100}] 1 0.0 0.0 [expr {double($z)}] 1.00 3.00]
}
set _i 0
for {set z -8} {$z <= 8} {incr z 2} {
    foreach r {2.0 15.0} {
        incr _i
        puts $_fh [format "ATOM  %5d  QSS SPH S%4d    %8.3f%8.3f%8.3f%6.2f%6.2f" \
            [expr {$_i+900}] -999 $r 0.0 [expr {double($z)}] 1.00 1.00]
    }
}
close $_fh
set _cls [::VMDPathFinder::_conn_classify_sph $_cs {0 0 1} {0 0 0} 2.0]
chk "the classifier keeps the dots inside the wall"  [dict get $_cls n_pore] 9
chk "...and separates the ones that escaped sideways" [dict get $_cls n_lat] 9
set _cls10 [::VMDPathFinder::_conn_classify_sph $_cs {0 0 1} {0 0 0} 20.0]
chk "a wide margin calls everything pore" [dict get $_cls10 n_lat] 0
set _pf [file join $_cd pore.sph]
::VMDPathFinder::_write_conn_region_sph $_cls pore $_pf
chk "a region file keeps the centreline records" \
    [expr {[::VMDPathFinder::_sph_point_count $_pf] == 9 + 11}] 1

# Containment: with the gate off nothing about the mesh path may change.
set _sv_g [expr {[info exists ::VMDPathFinder::state(conn_pore_gate)] ? $::VMDPathFinder::state(conn_pore_gate) : 0}]
set _sv_m [expr {[info exists ::VMDPathFinder::state(conn_pore_margin)] ? $::VMDPathFinder::state(conn_pore_margin) : 2.0}]
set _sv_pm $::VMDPathFinder::state(pore_method)
set ::VMDPathFinder::state(pore_method) connolly
set ::VMDPathFinder::state(conn_pore_gate) 0
# Under sos_triangle the settle pass keeps the full cloud and tags "_full";
# the marching-cubes mesher (when a multicall is configured) has no such tag.
set _fx [expr {[::VMDPathFinder::_csg_can_mesh] ? "" : "_full"}]
chk "gate off leaves the mesh filename alone" [::VMDPathFinder::_conn_surface_suffix] $_fx
set ::VMDPathFinder::state(conn_pore_gate) 1
set ::VMDPathFinder::state(conn_pore_margin) 2.0
chk "gate on tags the mesh with its margin" [::VMDPathFinder::_conn_surface_suffix] "${_fx}_porem20"
set ::VMDPathFinder::state(conn_pore_margin) 3.5
chk "a margin change moves the tag" [::VMDPathFinder::_conn_surface_suffix] "${_fx}_porem35"
set ::VMDPathFinder::state(pore_method) spherical
chk "no other method sees the gate" [::VMDPathFinder::_conn_surface_suffix] ""
set ::VMDPathFinder::state(pore_method) $_sv_pm
set ::VMDPathFinder::state(conn_pore_gate) $_sv_g
set ::VMDPathFinder::state(conn_pore_margin) $_sv_m
catch {file delete -force $_cd}

# --- The Connolly gate must not leak into other methods ---------------------
set _sv_pm2 $::VMDPathFinder::state(pore_method)
set _sv_g2  $::VMDPathFinder::state(conn_pore_gate)
set ::VMDPathFinder::state(pore_method) connolly
set ::VMDPathFinder::state(conn_pore_gate) 1
set ::VMDPathFinder::state(conn_pore_margin) 2.0
chk "the gate tags the mesh" [::VMDPathFinder::_conn_surface_suffix] \
    "[expr {[::VMDPathFinder::_csg_can_mesh] ? "" : "_full"}]_porem20"
set ::VMDPathFinder::state(pore_method) spherical
chk "it does not reach another method" [::VMDPathFinder::_conn_surface_suffix] ""
set ::VMDPathFinder::state(pore_method) $_sv_pm2
set ::VMDPathFinder::state(conn_pore_gate) $_sv_g2

# A reduced cloud is named after the cloud it reduces, so the trim/gate variants
# cannot serve each other's file through the mtime check.
chk "the reduced cloud follows its input's name" \
    [file rootname [file tail "hole_conn_pore_m20.sph"]]_render.sph \
    "hole_conn_pore_m20_render.sph"

# --- The Mean Profile's straightness note is SAMPLED -------------------------
# It parses a full .sph per frame (47 ms on a CONNOLLY cloud) for a one-line
# summary, so a long run spent minutes there before the profile could draw:
# measured at 2000 frames, 94.5 s exhaustive against 9.2 s sampled, and flat at
# 10,000. The note reports how many frames it actually measured.
chk "the straightness note samples rather than walking every frame" \
    [expr {[string first "_axis_straightness_sample_cap" \
        [info body ::VMDPathFinder::_axis_straightness_summary]] >= 0}] 1
chk "the cap has a sane default" [::VMDPathFinder::_axis_straightness_sample_cap] 200
chk "the note says when it sampled" \
    [expr {[string first "sampled" [info body ::VMDPathFinder::_draw_axis_straightness_note]] >= 0}] 1

# --- CONNOLLY draws during playback instead of waiting for it to stop --------
# A large CONNOLLY cloud was skipped entirely on the draft pass, so playback
# showed NO surface until it stopped. That was written when a draft frame cost
# the same as a full one; at the draft dot density it is 344 ms against 1543 ms.
set _lsf [info body ::VMDPathFinder::load_surface_for_frame]
chk "the blanket CONNOLLY draft skip is gone" \
    [expr {[string first {$draft && [_is_large_conn_sph $_sphf]} $_lsf] >= 0}] 0
# ...but a draft mesh must never be served when full quality was asked for, or
# the settle pass would re-render the cheap mesh it is supposed to replace.
chk "a draft mesh is dropped when full quality is asked for" \
    [expr {[string first {*_draft*.vmd_plot} $_lsf] >= 0}] 1
chk "...and only when NOT drafting" \
    [expr {[string first "!\$draft && \$asset ne" $_lsf] >= 0}] 1

# --- The two playback knobs act on DIFFERENT stages --------------------------
# They sit next to each other, so it must be clear they are not two versions of
# one thing: one thins what is DRAWN from an existing mesh (any method), the
# other lowers the density the CONNOLLY mesh is BUILT at (that method only).
chk "the stride thins the render" \
    [expr {[string first {state(draft_stride)} [info body ::VMDPathFinder::load_surface_for_frame]] >= 0}] 1
chk "...and the draft density feeds the BUILD" \
    [expr {[string first "_conn_draft_dotden" \
        [info body ::VMDPathFinder::_create_plot_asset_body]] >= 0}] 1
chk "the build density is CONNOLLY-only" \
    [expr {[string first "_run_uses_card conn" [info body ::VMDPathFinder::_conn_surface_suffix]] >= 0}] 1
set _svdd [expr {[info exists ::VMDPathFinder::state(dot_density)] ? $::VMDPathFinder::state(dot_density) : 20}]
set ::VMDPathFinder::state(dot_density) 4
chk "the playback mesh never exceeds the real density" \
    [expr {[::VMDPathFinder::_conn_draft_dotden] <= 4}] 1
set ::VMDPathFinder::state(dot_density) $_svdd

# --- The averaged volume is a CONNOLLY feature -------------------------------
# It came out of the CONNOLLY work; hiding its mode entry is not containment on
# its own, because a saved config or a script call still reaches the proc.
chk "the volume builder refuses a non-CONNOLLY run" \
    [expr {[string first "_run_uses_card conn" $_smv] >= 0}] 1
set _umd [info body ::VMDPathFinder::_update_method_dependent_controls]
chk "...and its mode-menu entry is synced only for CONNOLLY" \
    [expr {[string first "_sync_mean_3d_mode_entries" $_umd] >= 0}] 1
# IsoSurface and Volume share one mol slot - a mode switch while shown must
# delete whatever's loaded before building the other, or both would render at
# once (the original "M shows both together" bug).
set _osst [info body ::VMDPathFinder::on_show_mean_surface_toggled]
chk "the show-toggle deletes any existing mean-3D mol before rebuilding" \
    [expr {[string first "mol delete \$mean_surface_mol" $_osst] >= 0}] 1

# --- Long runs say what they are doing ---------------------------------------
foreach {_p _lbl} {collect_binned_radii "the mean collector" heatmap_bundle "Over Time"} {
    set _b [info body ::VMDPathFinder::$_p]
    chk "$_lbl reports progress on a long run" \
        [expr {[string first "update idletasks" $_b] >= 0
               && [string first {state(status)} $_b] >= 0}] 1
}

# --- A lateral lobe must not contain the main pore ---------------------------
# The centreline spheres were written into EVERY region file, so each lobe's mesh
# carried the whole pore tube - 21 lobes meant 21 copies of the pore.
set _brm [info body ::VMDPathFinder::_build_conn_region_meshes]
chk "only the pore region gets the centreline records" \
    [expr {[string first {$name eq "pore"} $_brm] >= 0}] 1
chk "a built region mesh is reused rather than rebuilt" \
    [expr {[string first "surface_has_geometry \$rplot" $_brm] >= 0}] 1
chk "the classification is memoised for toggling" \
    [expr {[llength [info procs ::VMDPathFinder::_conn_classify_cached]] > 0}] 1

# --- Region meshes (pore + lobes) build in parallel, not one at a time -------
# Independent per-region files (own .sph/.sos/.vmd_plot), so N of them are
# embarrassingly parallel - only sph_process's dot-count-then-maybe-retry
# needs care. Verified for real (byte-identical output, both the parallel and
# the forced-fallback path, against the original serial builder) against a
# 7-region real CONNOLLY frame outside this suite; these are the structural/
# cheap regression checks that belong in headless_smoke.
chk "2+ regions dispatch through the parallel builder" \
    [expr {[string first "_build_conn_regions_parallel" $_brm] >= 0}] 1
set _bcp [info body ::VMDPathFinder::_build_conn_regions_parallel]
chk "the parallel builder resolves a blank dotden the same way run_sph_process does" \
    [expr {[string first {$dotden ne "" ? $dotden : $state(dot_density)} $_bcp] >= 0}] 1
chk "a region that overshoots the ceiling falls back through the one surface pipeline" \
    [expr {[string first "surface_mesh \$rsph \$rplot draw \$rdd" $_bcp] >= 0
           && [string first "_legacy_sos \$sph \$sos \$color \$dd" \
                   [info body ::VMDPathFinder::surface_mesh]] >= 0
           && [string first "run_sph_process \$sph \$sos \$color \$dd" \
                   [info body ::VMDPathFinder::_legacy_sos]] >= 0}] 1
# --- Surface smoothing: one entry, both meshers, window from VMD --------------
chk "surface_smooth is persisted with the other mesher settings" [expr {"surface_smooth" in [::VMDPathFinder::_config_persistent_keys]}] 1
set _sv_ss $::VMDPathFinder::state(surface_smooth)
set ::VMDPathFinder::state(surface_smooth) off
chk "smoothing off: no window" [::VMDPathFinder::_surface_smooth_window] 0
chk "...no tag in plot names" [::VMDPathFinder::_surface_smooth_tag] ""
set ::VMDPathFinder::state(surface_smooth) 2
chk "a fixed half-width is the window" [::VMDPathFinder::_surface_smooth_window] 2
chk "...and tags the plot name" [::VMDPathFinder::_surface_smooth_tag] "_s2"
# union only ever gates the CSG voxel tag now - the smoothing tag applies to
# every surface surface_plot_name names, tunnels (union=1) included, so a
# tunnel mesh built under one window size is never confused for another's.
chk "surface_plot_name's smoothing tag no longer depends on \$union" \
    [expr {[string first {$union ? "" : [_surface_smooth_tag]} [info body ::VMDPathFinder::surface_plot_name]] < 0}] 1
chk "...and tags a union=1 (tunnel) name too" \
    [string match "*_s2*" [::VMDPathFinder::surface_plot_name /tmp foo draw 1]] 1
foreach _p {surface_mesh surface_mesh_cmd} {
    chk "$_p takes the window" [expr {[lsearch [info args ::VMDPathFinder::$_p] with] >= 0}] 1
}
chk "the marching mesher gets --with" [expr {[string first {lappend _mopts --with} [info body ::VMDPathFinder::surface_mesh]] >= 0}] 1
chk "the legacy pair smooths its dot cloud" [expr {[string first {_sos_smooth_cmd} [info body ::VMDPathFinder::_legacy_sos]] >= 0}] 1
chk "...and the pool command too" [expr {[string first {_sos_smooth_cmd} [info body ::VMDPathFinder::surface_mesh_cmd]] >= 0}] 1
chk "the Tcl fallback answers --sos-smooth" [expr {[string first {--sos-smooth} [info body ::VMDPathFinder::_hole_tcl_driver]] >= 0}] 1
# A frame with no usable surface (failed run, no sph_file) inside the window
# must be backfilled by reaching one frame further, not just dropped - a
# window of N promises N real neighbours, not N index slots.
set _sv_rf $::VMDPathFinder::result_frames
set _sv_res $::VMDPathFinder::results
set _smgap /tmp/vmdpathfinder_smoothgap_[pid]
catch {file delete -force $_smgap}
file mkdir $_smgap
set ::VMDPathFinder::result_frames {0 1 2 3 4 5}
set ::VMDPathFinder::results {}
foreach _f {0 1 2 3 4 5} {
    set _sph [file join $_smgap "f$_f.sph"]
    if {$_f != 2} { close [open $_sph w] }
    dict set ::VMDPathFinder::results $_f [dict create sph_file $_sph]
}
chk "reach-further backfills a missing interior frame" \
    [lsort -integer [::VMDPathFinder::_surface_smooth_frames 3]] {0 1 4 5}
chk "...and still clamps at the trajectory edge" \
    [lsort -integer [::VMDPathFinder::_surface_smooth_frames 1]] {0 3 4}
set ::VMDPathFinder::result_frames $_sv_rf
set ::VMDPathFinder::results $_sv_res
catch {file delete -force $_smgap}
# Tunnel-mode smoothing is keyed by cross-frame CLUSTER, not by frame's
# sph_file directly - a bare rank is not a stable identity across frames.
chk "_tunnel_mesh_jobs threads the frame through for per-id smoothing" \
    [expr {[lsearch [info args ::VMDPathFinder::_tunnel_mesh_jobs] frame] >= 0}] 1
set _sv_txf $::VMDPathFinder::tunnel_result_frames
set _sv_tr  $::VMDPathFinder::tunnel_root
set _sv_txr [array get ::VMDPathFinder::tunnel_xrank]
set ::VMDPathFinder::tunnel_result_frames {0 1 2}
set ::VMDPathFinder::tunnel_root $_smgap
array unset ::VMDPathFinder::tunnel_xrank
array set ::VMDPathFinder::tunnel_xrank {}
# cluster c1 is rank 1 in every frame; c2 only exists in frames 0 and 1.
array set ::VMDPathFinder::tunnel_xrank {c1,0 1 c1,1 1 c1,2 1 c2,0 2 c2,1 2}
foreach {_fr _rk} {0 1 1 1 2 1 0 2 1 2} {
    file mkdir [file join $_smgap [format "tunnel_%05d" $_fr]]
    close [open [file join $_smgap [format "tunnel_%05d" $_fr] [format "tunnel_%02d.sph" $_rk]] w]
}
chk "cluster lookup resolves a tracked rank" [::VMDPathFinder::_tunnel_cluster_for_rank 1 1] c1
chk "...and returns empty for an untracked one" [::VMDPathFinder::_tunnel_cluster_for_rank 2 2] ""
chk "tunnel window (c1, mid frame, both neighbours present)" \
    [llength [::VMDPathFinder::_tunnel_smooth_with 1 1]] 2
chk "tunnel window (c2, mid frame, absent from frame 2 -> only 1 neighbour)" \
    [llength [::VMDPathFinder::_tunnel_smooth_with 1 2]] 1
set ::VMDPathFinder::tunnel_result_frames $_sv_txf
set ::VMDPathFinder::tunnel_root $_sv_tr
array unset ::VMDPathFinder::tunnel_xrank
array set ::VMDPathFinder::tunnel_xrank $_sv_txr
catch {file delete -force $_smgap}
set ::VMDPathFinder::state(surface_smooth) $_sv_ss
# The fallback must retry at the region's OWN density, not the shared one -
# retrying a big-sphere lobe at the pore's density rebuilds it coarse, which is
# the bug the per-region density exists to fix.
chk "...at that region's own density, with the shared one only as a default" \
    [expr {[string first {if {![string is integer -strict $rdd] || $rdd < 1} { set rdd $dotden }} \
        $_bcp] >= 0}] 1
chk "the parallel wave also uses each region's own density" \
    [expr {[string first {_sph_process_cmd $rdd $cflag $rsph $rsos} $_bcp] >= 0}] 1
# Degenerate calls must not error - the real multi-region case is verified
# outside this suite (needs real HOLE/sph_process binaries + a multi-lobe run).
chk "an empty region list returns cleanly" \
    [expr {[dict size [::VMDPathFinder::_build_conn_regions_parallel {} 15]] == 0}] 1

# --- Switching pore method clears what is loaded -----------------------------
# Files on disk are untouched; only the plugin's own results go, so the panel
# cannot show one method's numbers under another's heading.
# Exercised, not grepped: a source match proves nothing about behaviour.
set _sv_pmX $::VMDPathFinder::state(pore_method)
set _sv_resX $::VMDPathFinder::results
set _sv_rfX $::VMDPathFinder::result_frames
set ::VMDPathFinder::state(pore_method) circular
set ::VMDPathFinder::results [dict create 0 [dict create run_dir /tmp profile [dict create valid 1]] \
                                    1 [dict create run_dir /tmp profile [dict create valid 1]]]
set ::VMDPathFinder::result_frames {0 1}
catch {::VMDPathFinder::_set_pore_method connolly Connolly}
chk "changing the method really drops the loaded frames" [llength $::VMDPathFinder::result_frames] 0
chk "...and switches the method" $::VMDPathFinder::state(pore_method) "connolly"
chk "...and says so" [expr {[string match "*cleared 2 loaded frame*" $::VMDPathFinder::state(status)]}] 1
# Re-picking the same method must NOT clear - a no-op click would wipe a session.
set ::VMDPathFinder::results [dict create 0 [dict create run_dir /tmp profile [dict create valid 1]]]
set ::VMDPathFinder::result_frames {0}
catch {::VMDPathFinder::_set_pore_method connolly Connolly}
chk "re-picking the same method keeps them" [llength $::VMDPathFinder::result_frames] 1
# Clearing the DATA without refreshing the tabs looks like nothing happened.
set _spm [info body ::VMDPathFinder::_set_pore_method]
foreach _r {refresh_results_list redraw_visible_analysis_tab redraw_profile_plot} {
    chk "the method change also calls $_r" [expr {[string first $_r $_spm] >= 0}] 1
}
set ::VMDPathFinder::state(pore_method) $_sv_pmX
set ::VMDPathFinder::results $_sv_resX
set ::VMDPathFinder::result_frames $_sv_rfX
set _crn [info body ::VMDPathFinder::clear_results_for_new_settings]
chk "clear_results_for_new_settings clears through the cache registry" [expr {[string first {cache_clear run} $_crn] >= 0}] 1
foreach _c {conn_site_cache _conn_cls_memo _conn_unroll_memo} { set ::VMDPathFinder::$_c [dict create k 1] }
::VMDPathFinder::cache_clear run
foreach _c {conn_site_cache _conn_cls_memo _conn_unroll_memo} {
    chk "the clear drops $_c too" [dict size [set ::VMDPathFinder::$_c]] 0
}

# --- The unrolled map never points at a layer that is gone -------------------
set _sv_pm9 $::VMDPathFinder::state(pore_method)
set _sv_ul2 $::VMDPathFinder::state(unroll_layer)
set _sv_pk2 $::VMDPathFinder::_unroll_layer_picked
set ::VMDPathFinder::state(pore_method) connolly
set ::VMDPathFinder::state(unroll_layer) connolly
set ::VMDPathFinder::_unroll_layer_picked 1
set ::VMDPathFinder::state(pore_method) spherical
::VMDPathFinder::_apply_default_unroll_layer
chk "leaving CONNOLLY drops the Connolly-only layer" $::VMDPathFinder::state(unroll_layer) "touch"
set ::VMDPathFinder::state(pore_method) connolly
::VMDPathFinder::_apply_default_unroll_layer
chk "...and coming back restores it" $::VMDPathFinder::state(unroll_layer) "connolly"
set ::VMDPathFinder::_unroll_layer_picked $_sv_pk2
set ::VMDPathFinder::state(unroll_layer) $_sv_ul2
set ::VMDPathFinder::state(pore_method) $_sv_pm9

# --- Kapcha-Rossky in tunnel mode --------------------------------------------
# KR is ATOM-level, so it cannot be read off a residue table the way kd/ww are.
# It used to be withheld rather than silently reported as Kyte-Doolittle; it is
# computed from the loaded structure's atoms now, with pore mode's own rule.
chk "tunnel mode offers Kapcha-Rossky" \
    [expr {[lsearch -exact [::VMDPathFinder::_tunnel_prop_tokens] kr] >= 0}] 1
chk "...and it is one of the shared HOLE scales" \
    [expr {[lsearch -exact [::VMDPathFinder::_tunnel_scale_tokens] kr] >= 0}] 1
chk "a layer with no residues yields nothing, not a number" \
    [::VMDPathFinder::_tunnel_layer_scale [dict create] kr] ""
# The rule pore mode uses, spot-checked against the paper's own cases.
chk "KR: aliphatic carbon is hydrophobic"  [::VMDPathFinder::kr_static ALA CB] 1.0
chk "KR: backbone carbonyl C is polar"     [::VMDPathFinder::kr_static ALA C] -1.0
chk "KR: N and O are polar"                [list [::VMDPathFinder::kr_static ALA N] [::VMDPathFinder::kr_static ALA O]] {-1.0 -1.0}
chk "KR: proline N is the exception"       [::VMDPathFinder::kr_static PRO N] 1.0
chk "KR: amide/guanidinium carbons are polar" \
    [list [::VMDPathFinder::kr_static ASN CG] [::VMDPathFinder::kr_static GLN CD] [::VMDPathFinder::kr_static ARG CZ]] {-1.0 -1.0 -1.0}

# --- The chain map names what the structure calls things ---------------------
# HOLE numbers chains 1,2,3... in first-appearance order, and the key said
# "chain 1" - which names nothing the user chose, least of all in Segments mode
# where those letters are a stand-in the plugin substituted itself.
set _sv_cn $::VMDPathFinder::_2dmap_chain_names
set ::VMDPathFinder::_2dmap_chain_names {PROA PROB PROC}
chk "the key names the segment, not an index" \
    [::VMDPathFinder::_2dmap_chain_label_for 2] "PROB"
chk "...for every captured name" \
    [list [::VMDPathFinder::_2dmap_chain_label_for 1] [::VMDPathFinder::_2dmap_chain_label_for 3]] {PROA PROC}
chk "a value past the captured list falls back" \
    [::VMDPathFinder::_2dmap_chain_label_for 9] "chain 9"
set ::VMDPathFinder::_2dmap_chain_names {}
chk "and with nothing captured it falls back too" \
    [::VMDPathFinder::_2dmap_chain_label_for 2] "chain 2"
set ::VMDPathFinder::_2dmap_chain_names $_sv_cn

# --- The unrolled map opens on a layer that suits the run --------------------
# HOLE's five 2DMAPS layers are a ray cast from the axis and are byte-identical
# whatever the pore method (verified on one frame at a fixed seed), so a CONNOLLY
# run opening on "Wall distance" would show a measurement that ignores the cloud
# it just computed.
set _sv_pm8 $::VMDPathFinder::state(pore_method)
set _sv_ul [expr {[info exists ::VMDPathFinder::state(unroll_layer)] ? $::VMDPathFinder::state(unroll_layer) : "touch"}]
set _sv_pick $::VMDPathFinder::_unroll_layer_picked
set ::VMDPathFinder::_unroll_layer_picked 0
set ::VMDPathFinder::state(pore_method) spherical
chk "plain HOLE opens on the wall-distance ray cast" \
    [::VMDPathFinder::_default_unroll_layer_for_run] "touch"
set ::VMDPathFinder::state(pore_method) connolly
chk "a CONNOLLY run opens on the Connolly surface" \
    [::VMDPathFinder::_default_unroll_layer_for_run] "connolly"
::VMDPathFinder::_apply_default_unroll_layer
chk "...and the layer actually moves there" $::VMDPathFinder::state(unroll_layer) "connolly"
# An explicit pick must survive: it is the user's, not the method's.
set ::VMDPathFinder::_unroll_layer_picked 1
set ::VMDPathFinder::state(unroll_layer) touch
::VMDPathFinder::_apply_default_unroll_layer
chk "an explicit choice is not overridden" $::VMDPathFinder::state(unroll_layer) "touch"
set ::VMDPathFinder::_unroll_layer_picked $_sv_pick
set ::VMDPathFinder::state(unroll_layer) $_sv_ul
set ::VMDPathFinder::state(pore_method) $_sv_pm8

# --- Per-frame water density belongs to ONE picker ---------------------------
# Pore Profile Fill offered both "water density" (trajectory average) and
# "water density, this frame", which reads as two properties and duplicates the
# Hydration tab's own per-frame panel. Over Time lost pfdens for the same
# reason; the 3D surface KEEPS it, because a per-frame surface needs a per-frame
# field and it is the only water option there.
chk "Pore Profile Fill does not offer pfdens" \
    [expr {[lsearch -exact [::VMDPathFinder::_profile_fill_scheme_choices] pfdens] >= 0}] 0
chk "...but keeps the trajectory average when hydration exists" \
    [expr {[lsearch -exact [::VMDPathFinder::_property_scheme_choices] dens] >= 0
           ? [lsearch -exact [::VMDPathFinder::_profile_fill_scheme_choices] dens] >= 0 : 1}] 1
chk "Over Time still does not offer it either" \
    [expr {[lsearch -exact [::VMDPathFinder::_heatmap_scheme_choices] pfdens] >= 0}] 0
chk "the 3D surface still does" \
    [expr {[hydration_perframe_available]
           ? [lsearch -exact [::VMDPathFinder::_surface_scheme_choices] pfdens] >= 0 : 1}] 1
chk "...and labels it plainly there, having no sibling to disambiguate from" \
    [::VMDPathFinder::_surface_scheme_label pfdens] "water density"
chk "the Fill's own scheme list is the shared one plus watermelon, minus pfdens" \
    [expr {[llength [::VMDPathFinder::_profile_fill_scheme_choices]]
           <= [llength [::VMDPathFinder::_property_scheme_choices]] + 2
           && [lindex [::VMDPathFinder::_profile_fill_scheme_choices] 0] eq "watermelon"}] 1

# --- Mean pore VOLUME, not a revolved tube -----------------------------------
# Occupancy over the trajectory is well-posed where averaging point clouds is
# not: it needs no correspondence between frames, only a shared coordinate
# frame - so a run whose axis drifts per frame must be refused, not averaged.
set _sv_rf3 $::VMDPathFinder::result_frames
set ::VMDPathFinder::result_frames {}
set ::VMDPathFinder::result_frames $_sv_rf3

# --- A CONNOLLY surface built for scrubbing is the cheap one -----------------
# Measured on a 22,265-dot Nav frame: build cost goes as ~density^1.6 and the
# POINT count barely matters (culling 22,511 -> 3,216 saved 1.6x; dropping the
# density 20 -> 6 saved 3.6x). So draft lowers the density, not the point count.
set _sv_dd $::VMDPathFinder::state(dot_density)
set _sv_cdd [expr {[info exists ::VMDPathFinder::state(conn_draft_dotden)] ? $::VMDPathFinder::state(conn_draft_dotden) : 6}]
set ::VMDPathFinder::state(dot_density) 20
chk "draft builds at a lower dot density than full" \
    [expr {[::VMDPathFinder::_conn_draft_dotden] < [::VMDPathFinder::_conn_safe_dotden 0]}] 1
set ::VMDPathFinder::state(dot_density) 4
chk "...but never ABOVE the user's own density" \
    [expr {[::VMDPathFinder::_conn_draft_dotden] <= 4}] 1
set ::VMDPathFinder::state(dot_density) 20
set ::VMDPathFinder::state(conn_draft_dotden) 0
chk "a nonsense draft density falls back" [::VMDPathFinder::_conn_draft_dotden] 6
set ::VMDPathFinder::state(conn_draft_dotden) $_sv_cdd
set ::VMDPathFinder::state(dot_density) $_sv_dd

# A draft mesh must never be served as the full one. Under sos_triangle the
# settle pass keeps the full cloud and is tagged _full (the untagged name held
# meshes of the thinned cloud); the marching-cubes mesher draws one mesh for
# both and tags nothing.
set _sv_pm7 $::VMDPathFinder::state(pore_method)
set _sv_ms7 $::VMDPathFinder::state(mesher)
set ::VMDPathFinder::state(pore_method) connolly
set ::VMDPathFinder::state(mesher) sos
set ::VMDPathFinder::_conn_draft_build 0
set _sfx_full [::VMDPathFinder::_conn_surface_suffix]
set ::VMDPathFinder::_conn_draft_build 1
set _sfx_draft [::VMDPathFinder::_conn_surface_suffix]
chk "the draft mesh gets its own filename" [expr {$_sfx_draft ne $_sfx_full}] 1
chk "...and the full one is tagged _full" $_sfx_full "_full"
chk "...and the draft one _draft" $_sfx_draft "_draft"
set ::VMDPathFinder::state(mesher) csg
if {[::VMDPathFinder::_csg_can_mesh]} {
    chk "...and the mesher builds one untagged mesh, draft or not" [::VMDPathFinder::_conn_surface_suffix] ""
    set ::VMDPathFinder::_conn_draft_build 0
    chk "...for the settle pass too" [::VMDPathFinder::_conn_surface_suffix] ""
}
set ::VMDPathFinder::_conn_draft_build 0
set ::VMDPathFinder::state(mesher) $_sv_ms7
set ::VMDPathFinder::state(pore_method) $_sv_pm7
chk "create_plot_asset takes a draft flag" \
    [expr {[lsearch -exact [info args ::VMDPathFinder::create_plot_asset] draft] >= 0}] 1

# --- Unrolled map from the CONNOLLY cloud ------------------------------------
# Every other unrolled layer is a ray cast from the axis and is byte-identical
# under any pore method; this one is the flood-fill cloud, so it is offered only
# for CONNOLLY and is the only layer that measures the Connolly surface itself.
set _sv_pm6 $::VMDPathFinder::state(pore_method)
set ::VMDPathFinder::state(pore_method) spherical
chk "the Connolly layer is not offered for plain HOLE" \
    [expr {[lsearch -exact [::VMDPathFinder::_2dmap_layers] connolly] >= 0}] 0
set ::VMDPathFinder::state(pore_method) connolly
chk "...and is offered under CONNOLLY" \
    [expr {[lsearch -exact [::VMDPathFinder::_2dmap_layers] connolly] >= 0}] 1
set ::VMDPathFinder::state(pore_method) $_sv_pm6

# A straight pore of radius 3 with one sideways escape at a known azimuth.
set _ug [file join $here _unroll_test]
catch {file delete -force $_ug}
file mkdir $_ug
set _us [file join $_ug u.sph]
set _fh [open $_us w]
for {set z -10} {$z <= 10} {incr z 2} {
    puts $_fh [format "ATOM  %5d  QSS SPH S%4d    %8.3f%8.3f%8.3f%6.2f%6.2f" \
        [expr {$z+200}] 1 0.0 0.0 [expr {double($z)}] 1.00 3.00]
}
set _i 0
for {set z -8} {$z <= 8} {incr z 2} {
    foreach th {0 90 180 270} {
        incr _i
        set _r [expr {($z == 0 && $th == 90) ? 20.0 : 2.5}]
        set _rad [expr {$th * acos(-1.0)/180.0}]
        puts $_fh [format "ATOM  %5d  QSS SPH S%4d    %8.3f%8.3f%8.3f%6.2f%6.2f" \
            [expr {$_i+900}] -999 [expr {$_r*cos($_rad)}] [expr {$_r*sin($_rad)}] \
            [expr {double($z)}] 1.00 1.00]
    }
}
close $_fh
set _ugrid [::VMDPathFinder::_conn_unroll_grid $_us {0 0 1} {0 0 0} 20 36]
chk "the map has the shape every unrolled consumer reads" \
    [expr {[dict exists $_ugrid nx] && [dict exists $_ugrid ny] && [dict exists $_ugrid values]}] 1
chk "...with one value per cell" \
    [expr {[llength [dict get $_ugrid values]] == [dict get $_ugrid nx]*[dict get $_ugrid ny]}] 1
set _mx 0.0
foreach _v [dict get $_ugrid values] { if {$_v > $_mx} { set _mx $_v } }
chk "the sideways escape reaches far past the wall" [expr {$_mx > 15.0}] 1
catch {file delete -force $_ug}
set ::VMDPathFinder::state(pore_method) $_sv_pm6

# --- The message log ---------------------------------------------------------
# The status bar shows one line and the console scrolls away under VMD's own
# output, so anything the user must act on has to be recoverable afterwards.
set ::VMDPathFinder::msg_log {}
::VMDPathFinder::_log_msg info "first"
::VMDPathFinder::_log_msg warn "second"
chk "messages are kept" [llength $::VMDPathFinder::msg_log] 2
chk "...with their level" [lindex [lindex $::VMDPathFinder::msg_log end] 1] "warn"
::VMDPathFinder::_log_msg warn "second"
chk "an immediate repeat is not logged twice" [llength $::VMDPathFinder::msg_log] 2
::VMDPathFinder::_log_msg info ""
chk "an empty message is ignored" [llength $::VMDPathFinder::msg_log] 2
set ::VMDPathFinder::msg_log {}
for {set _i 0} {$_i < 600} {incr _i} { ::VMDPathFinder::_log_msg info "m$_i" }
chk "the buffer is bounded" [expr {[llength $::VMDPathFinder::msg_log] <= 500}] 1
chk "...keeping the newest" [lindex [lindex $::VMDPathFinder::msg_log end] 2] "m599"

# A warning the user must act on reaches the status bar, not just the console.
set ::VMDPathFinder::msg_log {}
::VMDPathFinder::_note "no radius for 12 atoms" warn
chk "_note reaches the status bar" $::VMDPathFinder::state(status) "no radius for 12 atoms"
chk "...and the log" [lindex [lindex $::VMDPathFinder::msg_log end] 2] "no radius for 12 atoms"
chk "...at warn level" [lindex [lindex $::VMDPathFinder::msg_log end] 1] "warn"
set ::VMDPathFinder::msg_log {}

# --- The GUI must not need Tk 8.6 --------------------------------------------
# VMD 1.9.4 ships Tk 8.5.6. Rotated axis labels (canvas -angle) are the only 8.6
# feature the GUI used; _cv_vtext stacks the characters instead where -angle is
# missing, so no axis is left unlabelled.
set _pf [file join $here .. vmdpathfinder.tcl]
set _fh [open $_pf r]; set _src [read $_fh]; close $_fh
chk "the GUI asks for Tk 8.5, not 8.6" \
    [expr {[string first {package require Tk 8.5} $_src] >= 0}] 1
chk "...and no longer demands 8.6 anywhere" \
    [expr {[string first {package require Tk 8.6} $_src] < 0}] 1
# The one remaining -angle is _cv_angle_supported's own probe, which has to use
# it to find out whether it works.
set _ang 0
foreach _l [split $_src \n] {
    if {[string match "*#*" $_l] && [string first "create text" $_l] > [string first "#" $_l]} continue
    if {[regexp {create text.*-angle} $_l]} { incr _ang }
}
# Exactly two: the capability probe, and _cv_vtext's own rotate branch. Every
# other rotated label goes through the helper.
chk "canvas -angle survives only in the two helpers" $_ang 2
chk "...the capability probe" \
    [expr {[regexp {create text.*-angle} [info body ::VMDPathFinder::_cv_angle_supported]]}] 1
chk "...and the helper's rotate branch" \
    [expr {[regexp {create text.*-angle} [info body ::VMDPathFinder::_cv_vtext]]}] 1
chk "lmap is gone too - it is 8.6 and stock 8.5 lacks it" \
    [expr {[regexp -line {^[^#]*\mlmap\M} $_src]}] 0
chk "the rotated-label helper exists" \
    [expr {[llength [info procs ::VMDPathFinder::_cv_vtext]] > 0}] 1
chk "and the -bisect shim is still there" \
    [expr {[llength [info procs ::VMDPathFinder::_asym_bisect_floor]] > 0}] 1

# --- Every histogram aggregate shares ONE honest axis ------------------------
# Mean used to scale to a 5%-TRIMMED max while Min/Max used the true max, and
# any bar above that trimmed ceiling was silently clipped to the axis top. On
# a CONNOLLY run (where ~30% of bins take the spherical fallback and the
# vestibule bins are huge) that drew Mean SHORTER than Min for the same bin -
# the arithmetically impossible "mean is not between min and max" the user
# hit. The numbers were always fine: mean/min/max all come from one stats_raw
# entry. The axis was the lie, and the clip hid it.
set _hb [info body ::VMDPathFinder::draw_histogram_tab]
chk "the histogram no longer special-cases Min/Max against Mean" \
    [expr {[string first {$agg in {Min Max}} $_hb] >= 0}] 0
chk "...and no aggregate is drawn against a trimmed axis" \
    [expr {[string first {_trimmed_bound $vals} $_hb] >= 0}] 0
# Mean/min/max are provably ordered when they come from one bin_stats entry -
# assert that directly, so a future refactor cannot reintroduce a mixed source.
set _bs [::VMDPathFinder::bin_stats [list {1.0 2.0 3.0 10.0} {5.0}]]
lassign [lindex $_bs 0] _bmean _bstd _bmin _bmax _bn
chk "bin_stats: mean sits between min and max" \
    [expr {$_bmin <= $_bmean && $_bmean <= $_bmax}] 1
chk "...with min/max being the real extremes" [list $_bmin $_bmax] {1.0 10.0}

# --- Ellipse metrics must not compute where there is no ellipse --------------
set _sv_pm5 $::VMDPathFinder::state(pore_method)
set _sv_tm5 $::VMDPathFinder::state(trends_metric)
set ::VMDPathFinder::state(pore_method) spherical
chk "an ellipse metric is fine for plain HOLE" [::VMDPathFinder::_trend_metric_available ellipse_min_r] 1
set ::VMDPathFinder::state(pore_method) connolly
chk "Ellipse Min R is refused under CONNOLLY" [::VMDPathFinder::_trend_metric_available ellipse_min_r] 0
chk "...as are the other ellipse metrics" \
    [list [::VMDPathFinder::_trend_metric_available ellipse_volume] \
          [::VMDPathFinder::_trend_metric_available g_ellipse]] {0 0}
chk "...while Min R itself still works" [::VMDPathFinder::_trend_metric_available min_r] 1
set ::VMDPathFinder::state(pore_method) capsule
chk "CAPSULE refuses it too" [::VMDPathFinder::_trend_metric_available ellipse_min_r] 0
set ::VMDPathFinder::state(pore_method) connolly
::VMDPathFinder::_set_trend_metric ellipse_min_r
chk "selecting it does not switch the metric" \
    [expr {$::VMDPathFinder::state(trends_metric) ne "ellipse_min_r"}] 1
set ::VMDPathFinder::state(pore_method) $_sv_pm5
set ::VMDPathFinder::state(trends_metric) $_sv_tm5

# --- The .sph handed to the binary must carry the radius the plugin reads -----
# sos_triangle always reads radius from beta and never skips escaped rows, so a
# CAPSULE file (radius in occupancy, beta 0.00) has to be normalised first.
# Asserts the GUARANTEE, not the mechanism: every row the binary sees reports in
# beta exactly what _sph_centerline_radius reports for the source row.
set _sv_pmb $::VMDPathFinder::state(pore_method)
set _bsph [file join $here _binsph_capsule.sph]
set _bfh [open $_bsph w]
puts $_bfh [format "ATOM  %5d  QC1 SPH S%4d    %8.3f%8.3f%8.3f%6.2f%6.2f" 1 0 0.0 0.0 0.0 3.74 0.00]
puts $_bfh [format "ATOM  %5d  QC2 SPH S%4d    %8.3f%8.3f%8.3f%6.2f%6.2f" 2 1 1.0 0.0 2.0 4.04 0.00]
puts $_bfh [format "ATOM  %5d  QC1 SPH S%4d    %8.3f%8.3f%8.3f%6.2f%6.2f" 3 -888 9.0 9.0 9.0 24.39 0.00]
close $_bfh
set ::VMDPathFinder::state(pore_method) capsule
set _bout [::VMDPathFinder::_hydro_sph_for_binary $_bsph]
chk "a CAPSULE .sph is normalised before the binary sees it" \
    [expr {$_bout ne $_bsph && [file exists $_bout]}] 1
set _bsrc {}
set _fh [open $_bsph r]
while {[gets $_fh _l] >= 0} {
    if {![string match {ATOM  *} $_l]} continue
    if {[::VMDPathFinder::_sph_line_is_flood_fill $_l]} continue
    lappend _bsrc [::VMDPathFinder::_sph_centerline_radius $_l]
}
close $_fh
set _bgot {}
set _fh [open $_bout r]
while {[gets $_fh _l] >= 0} {
    if {![string match {ATOM  *} $_l]} continue
    lappend _bgot [string trim [string range $_l 60 65]]
}
close $_fh
chk "...its beta column now reports _sph_centerline_radius" \
    [expr {[llength $_bgot] > 0 && $_bgot eq $_bsrc}] 1
chk "...and the escaped row never reaches the binary" [llength $_bgot] 2
# CONNOLLY is the regression risk: its beta IS the radius, its escaped rows carry
# the >900 marker the C reader keys on, and the lobe recolour needs the dots. Use
# a file with that real shape - a capsule file down the Connolly branch would
# only prove the early return fires.
set _csph [file join $here _binsph_connolly.sph]
set _cfh [open $_csph w]
puts $_cfh [format "ATOM  %5d  QSS SPH S%4d    %8.3f%8.3f%8.3f%6.2f%6.2f" 1 0 0.0 0.0 0.0 7.78 11.33]
puts $_cfh [format "ATOM  %5d  QSS SPH S%4d    %8.3f%8.3f%8.3f%6.2f%6.2f" 2 -999 1.0 1.0 1.0 1.30 1.30]
puts $_cfh [format "ATOM  %5d  QSS SPH S%4d    %8.3f%8.3f%8.3f%6.2f%6.2f" 3 2 2.0 0.0 4.0 7.77 999.99]
close $_cfh
set ::VMDPathFinder::state(pore_method) connolly
chk "a CONNOLLY .sph reaches the binary untouched" \
    [::VMDPathFinder::_hydro_sph_for_binary $_csph] $_csph
chk "...and no normalised copy is written beside it" \
    [file exists "[file rootname $_csph]_clbeta.sph"] 0
catch {file delete $_csph}
catch {file delete $_bsph}
catch {file delete "[file rootname $_bsph]_clbeta.sph"}
set ::VMDPathFinder::state(pore_method) $_sv_pmb

# --- Packed coordinate record: who is allowed to receive one -----------------
# Only a HOLE carrying the tsatr_fast.f patch can read it. Everything else -
# stock HOLE, the pure-Tcl engine, and a user who asked to keep the PDB - has to
# keep getting a real PDB, so these are the gates that must never silently open.
set _sv_keep [expr {[info exists ::VMDPathFinder::state(keep_input_pdb)] ? $::VMDPathFinder::state(keep_input_pdb) : 0}]
set ::VMDPathFinder::state(keep_input_pdb) 1
chk "'Keep input_frame.pdb' forces the PDB path" [::VMDPathFinder::_hole_fast_coord_available] 0
set ::VMDPathFinder::state(keep_input_pdb) $_sv_keep
set _fcb [info body ::VMDPathFinder::_hole_fast_coord_available]
chk "...and the packed path needs the manifest feature" \
    [expr {[string first {fast-coord-read} $_fcb] >= 0}] 1
set _rab [info body ::VMDPathFinder::run_analysis]
chk "the pure-Tcl engine never gets a packed record" \
    [expr {[string first {$_fb_script eq "" && [_hole_fast_coord_available]} $_rab] >= 0}] 1
chk "the control file names whichever coord file was written" \
    [expr {[string first {write_control_file [file join $tmp_dir hole.inp] $_coord_name} $_rab] >= 0}] 1
chk "a moving selection rebuilds the identity half" \
    [expr {[string first {$_ib ne $_fc_idx} $_rab] >= 0}] 1
# I4 is what HOLE reads the residue number with, and it ABORTS the run on a
# non-numeric - which is exactly what VMD writes past resid 9999 ("271a").
set _idb [info body ::VMDPathFinder::_hole_coord_identity]
chk "a residue number VMD could not fit in 4 columns refuses the packed path" \
    [expr {[string first {string is integer -strict $v} $_idb] >= 0}] 1
chk "...and the identity comes from a written PDB, not a second column rule" \
    [expr {[string first {$sel writepdb $tmp_pdb} $_idb] >= 0}] 1

# --- Ion Flow's frame playhead must follow the frame in TUNNEL mode too ------
# Ion Flow runs in both modes, and its passage plot is the only view with a frame
# axis. HOLE drives the playhead from select_result; both tunnel frame paths
# return before reaching it, so the playhead sat frozen where the plot was built.
set _fcb2 [info body ::VMDPathFinder::frame_changed]
set _gtb  [info body ::VMDPathFinder::goto_trajectory_frame]
chk "the VMD-driven tunnel frame path moves the Ion Flow playhead" \
    [expr {[string first {update_ion_passage_indicator} $_fcb2] >= 0}] 1
chk "...and so does the plugin-driven one" \
    [expr {[string first {update_ion_passage_indicator} $_gtb] >= 0}] 1
# It sits with the other two indicators those paths already drove - if a future
# edit drops it again, this is the pairing that broke.
foreach _b [list $_fcb2 $_gtb] {
    chk "the playhead is driven alongside the min-R indicator" \
        [expr {[string first {update_minr_indicator} $_b] >= 0
               && [string first {update_ion_passage_indicator} $_b] >= 0}] 1
}
# A tunnel .sph is written by write_stock_sph_file (radius in BOTH columns, no
# escaped rows), so the capsule normaliser must leave it alone - and must not
# consult the PORE tab's method picker for a tunnel surface.
set _hsb [info body ::VMDPathFinder::_hydro_sph_for_binary]
chk "tunnel .sph files bypass the capsule normaliser" \
    [expr {[string first {[analysis_mode] eq "tunnel"} $_hsb] >= 0}] 1

# --- Tunnel property scales must not borrow another scale's bounds ----------
# "polarity" is the one token whose NAME is shared with a DIFFERENT scale:
# property_meta's is Grantham (4.9..13.0), tunnel mode's values are MOLE's own
# table. Normalising one by the other put ALL 20 standard residues outside the
# range, so the gradient collapsed to two colours. Assert the bounds actually
# contain the data, computed from the table rather than restated as constants -
# a restated number is what drifted in the first place.
set _res {ALA ARG ASN ASP CYS GLU GLN GLY HIS ILE LEU LYS MET PHE PRO SER THR TRP TYR VAL}
foreach _p {polarity hydropathy hydrophobicity logp logd logs mutability} {
    lassign [::VMDPathFinder::_tunnel_property_range 0 $_p] _lo _hi
    set _out 0
    foreach _r $_res {
        set _v [::VMDPathFinder::mole_residue_property $_p $_r]
        if {$_v < $_lo || $_v > $_hi} { incr _out }
    }
    chk "tunnel '$_p' scale covers its own residue values" $_out 0
}
# The MOLE tables that pore mode also serves must agree residue-for-residue, or
# the same property name means two things depending on which tab you are on.
foreach _p {hydropathy charge logp logd logs mutability} {
    set _d 0
    foreach _r $_res {
        set _a [::VMDPathFinder::mole_residue_property $_p $_r]
        set _b ""
        catch {set _b [::VMDPathFinder::residue_property $_p $_r]}
        if {$_b ne "" && [string is double -strict $_b] && abs($_a-$_b) > 1e-9} { incr _d }
    }
    chk "'$_p' reports the same value in both modes" $_d 0
}
# "Pore facing" lives in the shared Scale/Cutoff dialog and is not gated by mode,
# so it was visible in tunnel mode while doing nothing to the tunnel surface.
set _wt [info args ::VMDPathFinder::write_tunnel_hydro3d_residue_sidecar]
chk "the tunnel sidecar can apply the facing filter" \
    [expr {[lsearch -glob $_wt cl_sph*] >= 0}] 1
chk "...and honours the same checkbox pore mode does" \
    [expr {[string first {state(hydro_facing)} \
        [info body ::VMDPathFinder::write_tunnel_hydro3d_residue_sidecar]] >= 0}] 1
# The MOLE input's identity columns cannot change between frames; rebuilding them
# every frame cost 81 of 94 ms, serially, before the search pool even starts.
chk "the MOLE atom lines reuse a cached identity tail" \
    [expr {[string first {_mole_atom_tail_key} \
        [info body ::VMDPathFinder::_tunnel_atoms_mole]] >= 0}] 1
chk "...keyed so a changed selection rebuilds it" \
    [expr {[string first {[$sel get index]} \
        [info body ::VMDPathFinder::_tunnel_atoms_mole]] >= 0}] 1

# --- The MOLE engine's packed coordinate record ------------------------------
# Same trade as HOLE's: the 12-column text costs ~38 ms/frame of Tcl formatting,
# and that is the rate the whole tunnel search is fed at. Only an engine carrying
# the packed reader may be sent one; anything else keeps getting text.
set _mfa [info body ::VMDPathFinder::_mole_fast_atoms_available]
chk "the packed record needs the manifest feature" \
    [expr {[string first {fast-atoms-read} $_mfa] >= 0}] 1
chk "...read from the ENGINE's own directory, not HOLE's" \
    [expr {[string first {[file dirname $exe]} $_mfa] >= 0}] 1
set _wap [info body ::VMDPathFinder::_tunnel_write_atoms_file]
chk "the writer falls back to text when the engine cannot read packed" \
    [expr {[string first {_mole_fast_atoms_available} $_wap] >= 0
           && [string first {_tunnel_atoms_mole} $_wap] >= 0}] 1
# The identity half must be reused, not rebuilt - rebuilding it per frame is the
# entire cost this path exists to avoid, and it silently looks correct.
# Anchor on the CALL and the early RETURN, not on the bare proc name - the name
# also appears in the comment above, which is what made a position test pass
# while measuring nothing.
set _mpi [info body ::VMDPathFinder::_mole_packed_identity]
set _ci [string first {return $_mole_pack_blob} $_mpi]
set _bi [string first {_tunnel_atoms_mole $molid $frame} $_mpi]
chk "the packed identity checks its cache BEFORE rebuilding" \
    [expr {$_ci >= 0 && $_bi > $_ci}] 1
chk "...and is keyed on the selection's own index list" \
    [expr {[string first {[$sel get index]} \
        [info body ::VMDPathFinder::_tunnel_write_atoms_packed]] >= 0}] 1
# Writing atoms.txt inside the pool is what lets it overlap the running engines.
set _rta [info body ::VMDPathFinder::run_tunnel_analysis]
chk "each frame's MOLE input is written by the pool, not up front" \
    [expr {[string first {_tunnel_write_atoms_file} $_rta] >= 0}] 1
chk "run_shell_pool runs a job's prep just before launching it" \
    [expr {[string first {uplevel #0 $prep} [info body ::VMDPathFinder::run_shell_pool]] >= 0}] 1

# --- The tunnel mean CURVE and the mean TUBE must describe the same object ---
# The mean profile's axis is bottleneck-relative, so its members only overlap
# fully near s=0 and the union of their extents runs far past any real tunnel.
# _draw_mean_profile_body trims by cov_min_frames and, absent that key, trims
# NOTHING - which is how a 47-frame cluster drew a 74 A curve for a 30 A tube.
set _tcb [info body ::VMDPathFinder::_tunnel_collect_binned_radii]
chk "the tunnel mean publishes a coverage floor at all" \
    [expr {[string first {cov_min_frames} $_tcb] >= 0}] 1
chk "...and a coverage range for the draw to trim to" \
    [expr {[string first {cov_lo} $_tcb] >= 0 && [string first {cov_hi} $_tcb] >= 0}] 1
# HALF the frames - the rule _tunnel_mean_centerline already applies to the mean
# SURFACE. If these two ever disagree the curve and the tube go back to
# describing different lengths, which is the defect this pins.
chk "the floor is half the contributing frames, matching the mean tube" \
    [expr {[string first {ceil($nframes / 2.0)} $_tcb] >= 0}] 1
chk "...and the mean tube still restricts to half its members" \
    [expr {[string first {half} [info body ::VMDPathFinder::_tunnel_mean_centerline]] >= 0}] 1
# HOLE mode's axis is the pore's own, not bottleneck-aligned, and keeps 5%.
chk "HOLE mode's own floor is unchanged" \
    [expr {[string first {$nframes * 0.05} [info body ::VMDPathFinder::collect_binned_radii]] >= 0}] 1

# --- Tunnel property pickers: one list, one default, one way back ------------
# Every property control in tunnel mode draws from _tunnel_prop_tokens, and each
# token has to resolve to both a label and a range or the picker offers an entry
# that cannot be rendered.
set _tt [::VMDPathFinder::_tunnel_prop_tokens]
set _unres 0
foreach _t $_tt {
    if {[catch {::VMDPathFinder::_tunnel_prop_label $_t} _l] || $_l eq ""} { incr _unres; continue }
    if {[catch {::VMDPathFinder::_tunnel_property_range 0 $_t} _r] || $_r eq ""} { incr _unres }
}
chk "every tunnel property token resolves to a label and a range" $_unres 0
# The property default is kd in every mode. Tunnel mode's was "none" (so Fill
# shaded nothing until you picked one) and the heatmap's was "hydropathy".
# Read from the SHIPPED defaults block, not from live state - assertions earlier
# in this file set these, so a live read measures the last test, not the default.
set _dfh [open vmdpathfinder.tcl r]; set _dtxt [read $_dfh]; close $_dfh
foreach _k {hydro_scheme hm_prop_scheme mean_hydro_scheme tunnel_prop} {
    chk "the shipped default for $_k is kd" \
        [expr {[regexp "\n\\s+$_k \"?kd\"?\n" $_dtxt] ? 1 : 0}] 1
}
# Over Time's tunnel default stays "hydropathy" - three assertions pin it as the
# route's own MOLE property, and MOLE's hydropathy table IS Kyte-Doolittle
# (0 of 20 residues differ), so the VALUE is already kd under MOLE's name.
chk "Over Time's tunnel default is MOLE hydropathy" \
    [expr {[regexp "\n\\s+hm_tunnel_prop \"hydropathy\"\n" $_dtxt] ? 1 : 0}] 1
set _hd 0
foreach _r {ALA ARG ASN ASP CYS GLU GLN GLY HIS ILE LEU LYS MET PHE PRO SER THR TRP TYR VAL} {
    if {abs([::VMDPathFinder::mole_residue_property hydropathy $_r]
            - [::VMDPathFinder::residue_property kd $_r]) > 1e-9} { incr _hd }
}
chk "...which is numerically Kyte-Doolittle" $_hd 0
# Picking a property on the Pore Profile Fill writes that TUNNEL's own override,
# and an override silently shadows the header gear - so the same picker has to
# offer the way back, or using it once makes the global control look dead.
set _pk [info body ::VMDPathFinder::_tunnel_profile_prop_pick]
chk "the Fill picker can clear an override, not only set one" \
    [expr {[string first {_tunnel_gear_set $id prop $tok} $_pk] >= 0}] 1
chk "...and its menu offers the same 'auto' entry the per-tunnel gear does" \
    [expr {[string first {_tunnel_inherited_only_label} [info body ::VMDPathFinder::build_gui]] >= 0}] 1
# P and T are the same slot in different modes; only one may be on screen.
set _vb [info body ::VMDPathFinder::_update_surface_vis_buttons]
chk "the pore/tunnel visibility buttons are gated on the mode" \
    [expr {[string first {pack forget $w.bottom.statusrow.vistoggle.pore} $_vb] >= 0
           && [string first {pack forget $w.bottom.statusrow.vistoggle.tunnel} $_vb] >= 0}] 1

# --- The tunnel gear property menus: short labels, two even columns ----------
# Long labels ran to 19 characters, so the menu was one tall strip and the
# menubutton resized with the selection. The short form keeps MOLE's prefix (its
# charge/polarity/hydropathy are NOT the HOLE scales of the same name) but as "M".
set _tt2 [::VMDPathFinder::_tunnel_prop_tokens]
set _mx 0
foreach _t $_tt2 {
    set _sh [::VMDPathFinder::_tunnel_prop_label_short $_t]
    if {$_sh eq ""} { set _mx 999 ; break }
    if {[string length $_sh] > $_mx} { set _mx [string length $_sh] }
}
chk "every property has a short label that fits the menubutton" \
    [expr {$_mx > 0 && $_mx <= 14}] 1
chk "...and MOLE's tables stay distinguishable from the HOLE scales" \
    [expr {[::VMDPathFinder::_tunnel_prop_label_short hydropathy] ne
           [::VMDPathFinder::_tunnel_prop_label_short kd]}] 1
# A menubutton shows its -textvariable while the menu stores -value. If a writer
# uses the long form and the entries the short one, the radiobutton indicator
# points at nothing - the menu opens with no selection marked.
set _src [open vmdpathfinder.tcl r]; set _stxt [read $_src]; close $_src
# -line matters: without it Tcl's "." matches newlines, so ".*" spans the whole
# file and the pattern always hits.
chk "no gear writer sets the display var from the LONG label" \
    [regexp -line {set (state\(tunnel_prop_disp\)|::VMDPathFinder::_tgear_prop_disp).*_tunnel_prop_label[^_]} $_stxt] 0
# Both gears lay the property menu out in two even columns - the individual one
# had no column break on this menu at all.
chk "the global gear balances its property menu" \
    [expr {[string first {_menu_two_columns $d.pm.m} \
        [info body ::VMDPathFinder::show_tunnel_global_gear_settings]] >= 0}] 1
chk "...and so does the per-tunnel gear" \
    [expr {[string first {_menu_two_columns $d.pm.m} \
        [info body ::VMDPathFinder::show_tunnel_gear_settings]] >= 0}] 1
chk "two even columns means ceil(n/2), not the screen-height count" \
    [expr {[string first {ceil($n / 2.0)} [info body ::VMDPathFinder::_menu_two_columns]] >= 0}] 1

# --- The channel axis must be a UNIT vector for every input ------------------
# Callers project onto it as one. The power iteration seeds at (1,1,1) and breaks
# on the first pass when the covariance is degenerate - one centre, or all of
# them coincident - which returned that seed unnormalised and scaled every
# channel coordinate by 1.73. Orientation is otherwise free: PCA has no
# preferred direction, so a horizontal tunnel is as well handled as a vertical.
foreach {_nm _pts} [list \
        alongX {{0 0 0} {1 0 0} {2 0 0}} \
        alongY {{0 0 0} {0 1 0} {0 2 0}} \
        alongZ {{0 0 0} {0 0 1} {0 0 2}} \
        diagonal {{0 0 0} {1 1 1} {2 2 2}} \
        single {{1 2 3}} \
        coincident {{5 5 5} {5 5 5} {5 5 5}}] {
    lassign [::VMDPathFinder::channel_axis_pca $_pts] _ax _ay _az
    chk "channel axis is unit length for $_nm" \
        [expr {abs(sqrt($_ax*$_ax+$_ay*$_ay+$_az*$_az) - 1.0) < 1e-9}] 1
}
lassign [::VMDPathFinder::channel_axis_pca {{0 0 0} {1 0 0} {2 0 0}}] _hx _hy _hz
chk "...and a horizontal tunnel really resolves along X" \
    [expr {abs(abs($_hx) - 1.0) < 1e-9}] 1

# --- Tunnel lining follows what is DRAWN, not the highlighted row ------------
set _ul [info body ::VMDPathFinder::update_tunnel_lining_rep]
chk "the lining reads the show/hide state, not just the selection" \
    [expr {[string first {tunnel_shown($_rk)} $_ul] >= 0}] 1
chk "...and unions every shown tunnel's layers" \
    [expr {[string first {foreach id2 $ids} $_ul] >= 0}] 1
chk "...falling back to the selected row when nothing is ticked" \
    [expr {[string first {tunnel_selected_id} $_ul] >= 0}] 1

# --- Tunnel mode draws ONE 3-D track at a time -------------------------------
# The averaged tube averages the very routes the per-frame track draws, so both
# on screen is two coincident surfaces reading as one doubled wall.
# Pore mode has the same rule and had the same hole: the buttons soloed, the
# BUILDER did not, so any rebuild by another route left both surfaces drawn.
chk "building the pore-mode mean hides the per-frame pore" \
    [expr {[string first {_solo_surface mean} \
        [info body ::VMDPathFinder::build_and_show_mean_surface]] >= 0}] 1
chk "building the mean tube hides the per-frame tunnels" \
    [expr {[string first {_tunnel_hide_geometry_for_mean 1} \
        [info body ::VMDPathFinder::build_and_show_tunnel_mean_surface]] >= 0}] 1
chk "...and the M button routes through the same hide" \
    [expr {[string first {_tunnel_hide_geometry_for_mean} \
        [info body ::VMDPathFinder::_tunnel_toggle_mean_surface_visibility]] >= 0}] 1
set _tt3 [info body ::VMDPathFinder::toggle_tunnel_surface_visibility]
chk "...and showing the tunnels takes the view back from the tube" \
    [expr {[string first {mol off $tunnel_mean_surface_mol} $_tt3] >= 0}] 1
# analysis_mode reads the sidebar notebook and answers "hole" whenever there is
# no Tk, so gating this on it would switch the rule off in every batch path.
# Match the CALL form, not the bare word: the word also appears in the comment
# that explains why the call is absent, which is enough to satisfy a loose needle.
chk "...gated on the mean MOL, not on analysis_mode" \
    [expr {[string first {$tunnel_mean_surface_mol >= 0} $_tt3] >= 0
           && [string first {[analysis_mode]} $_tt3] < 0}] 1

# --- Mean Profile's two mesh controls must not be live-but-inert -------------
# Both read only in HOLE mode's builder, while the tunnel tube is built by a
# different proc - so in tunnel mode they sat enabled and drove nothing.
set _bts [info body ::VMDPathFinder::build_and_show_tunnel_mean_surface]
chk "the averaged tube honours 'Render smoothly'" \
    [expr {[string first {state(mean_smooth_mesh)} $_bts] >= 0
           && [string first {smooth_mesh_plot} $_bts] >= 0}] 1
chk "...and skips it for Centerline, which draws beads not a mesh" \
    [expr {[string first {ne "centerline"} $_bts] >= 0}] 1
set _lock [info body ::VMDPathFinder::_sync_mean_settings_lock]
# Accurate 3D selects build_mean_hydro3d_average, which only HOLE mode's builder
# reaches - there is no per-triangle averaging for the tube, so it is greyed.
chk "Accurate 3D is greyed in tunnel mode rather than left inert" \
    [expr {[string first {[analysis_mode] eq "tunnel"} $_lock] >= 0}] 1
chk "...and Accurate 3D is still not wired into the tunnel builder" \
    [expr {[string first {mean_hydro_3d_accurate} $_bts] < 0}] 1
# The dots/centerline grey-out excluded tunnel mode, so Dots offered smoothing there.
chk "the smoothing grey-out applies in both modes" \
    [expr {[string first {[analysis_mode] ne "tunnel" && $_mdm_now} $_lock] < 0}] 1

# --- Browse opens where the file it replaces lives ---------------------------
chk "a bare command name falls back to home" \
    [::VMDPathFinder::_browse_start_dir "hole"] [file normalize ~]
chk "an empty path falls back to home" \
    [::VMDPathFinder::_browse_start_dir ""] [file normalize ~]
chk "a real path opens in its own directory" \
    [::VMDPathFinder::_browse_start_dir [file join $here somefile.rad]] $here

# --- A hidden opening must change the file the surface is drawn from ---------
set _sv_l1 [expr {[info exists ::VMDPathFinder::state(conn_site_show,1)] ? $::VMDPathFinder::state(conn_site_show,1) : 1}]
set ::VMDPathFinder::state(conn_site_show,1) 1
set _tag_on [::VMDPathFinder::_conn_lobes_tag]
set ::VMDPathFinder::state(conn_site_show,1) 0
chk "hiding an opening moves the plot path" \
    [expr {[::VMDPathFinder::_conn_lobes_tag] ne $_tag_on}] 1
set ::VMDPathFinder::state(conn_site_show,1) 1
chk "...and showing it again returns the original" [::VMDPathFinder::_conn_lobes_tag] $_tag_on
set _c1 [expr {[info exists ::VMDPathFinder::state(conn_site_colormode,1)] ? $::VMDPathFinder::state(conn_site_colormode,1) : ""}]
set ::VMDPathFinder::state(conn_site_colormode,1) "lime"
chk "a color change moves it too" \
    [expr {[::VMDPathFinder::_conn_lobes_tag] ne $_tag_on}] 1
if {$_c1 ne ""} { set ::VMDPathFinder::state(conn_site_colormode,1) $_c1 } else { unset ::VMDPathFinder::state(conn_site_colormode,1) }
set ::VMDPathFinder::state(conn_site_show,1) $_sv_l1

# --- Water schemes are listed even before Hydration has run ------------------
# They used to vanish, which read as "this plugin cannot do that" rather than
# "run Hydration first". The menu greys them instead - see _populate_scheme_menu.
set _msc [::VMDPathFinder::_mean_hydro_scheme_choices]
chk "water G(z) is always offered"    [expr {[lsearch -exact $_msc gz] >= 0}] 1
chk "water density is always offered" [expr {[lsearch -exact $_msc dens] >= 0}] 1
chk "and they are the ones needing hydration" \
    [list [::VMDPathFinder::_scheme_needs_hydration gz] [::VMDPathFinder::_scheme_needs_hydration dens] \
          [::VMDPathFinder::_scheme_needs_hydration kd]] {1 1 0}

# --- Over Time must see the property Mean Profile already computed -----------
# collect_binned_property primes the 3D cache or the FAST-PATH cache depending
# on Accurate 3D; a check against only the 3D one makes Over Time demand a
# Compute click for data that already exists.
chk "the fast-path property cache has its own peek" \
    [expr {[llength [info procs ::VMDPathFinder::_fastpath_props_all_cached]] > 0}] 1
chk "it reports nothing cached for no frames" \
    [::VMDPathFinder::_fastpath_props_all_cached {} kd] 0
chk "kr never uses the fast path, so it never claims a hit" \
    [::VMDPathFinder::_fastpath_props_all_cached {0 1} kr] 0
chk "Over Time consults it alongside the 3D cache" \
    [expr {[string first "_fastpath_props_all_cached" [info body ::VMDPathFinder::draw_heatmap]] >= 0}] 1

# --- Lateral openings: clustering and cross-frame identity -------------------
lassign [::VMDPathFinder::_conn_axis_basis 0.0 0.0 1.0] _b1x _b1y _b1z _b2x _b2y _b2z
chk "the azimuth basis is perpendicular to the axis" \
    [expr {abs($_b1z) < 1e-9 && abs($_b2z) < 1e-9}] 1
chk "...and its two vectors are perpendicular to each other" \
    [expr {abs($_b1x*$_b2x + $_b1y*$_b2y + $_b1z*$_b2z) < 1e-9}] 1
chk "...and both are unit length" \
    [expr {abs(hypot($_b1x,$_b1y)-1.0) < 1e-9 && abs(hypot($_b2x,$_b2y)-1.0) < 1e-9}] 1

# Two clouds far apart in azimuth must come out as two lobes, not one.
set _lzt {}
for {set _i 0} {$_i < 200} {incr _i} {
    lappend _lzt [list [expr {-5.0 + ($_i % 10)}] [expr {0.1 * (($_i % 7) - 3) * 0.1}]]
}
for {set _i 0} {$_i < 200} {incr _i} {
    lappend _lzt [list [expr {-5.0 + ($_i % 10)}] [expr {3.0 + 0.1 * (($_i % 7) - 3) * 0.1}]]
}
set _fl [::VMDPathFinder::_conn_split_lobes [dict create lat_zt $_lzt]]
chk "two clouds a half-turn apart are two lobes" [llength $_fl] 2

# The identity trap: single-link agglomeration walks two lobes of ONE frame into
# one site through a third frame. A site that means two openings at once is
# worse than no identity at all.
# Frame 1 has TWO openings that both sit nearest the same frame-0 site; without
# a one-lobe-per-frame rule both land in it and the site means two openings.
set _pf [list 0 [list [list 0.0 0.0 100 {}]] \
              1 [list [list 1.0 0.0 100 {}] [list 2.0 0.0 100 {}]]]
set _pool [::VMDPathFinder::_conn_pool_lobe_sites $_pf]
set _coll 0
foreach _st [dict get $_pool sites] {
    set _fs {}
    foreach _in [lindex $_st 3] { lappend _fs [lindex $_in 0] }
    if {[llength $_fs] != [llength [lsort -unique $_fs]]} { incr _coll }
}
chk "a site never holds two openings from one frame" $_coll 0
chk "...so the second one starts a site of its own" \
    [llength [dict get $_pool sites]] 2

# Color must key on the SITE, so it survives a rank change between frames.
set _svc1 [expr {[info exists ::VMDPathFinder::state(conn_site_color,1)] ? $::VMDPathFinder::state(conn_site_color,1) : ""}]
catch {unset ::VMDPathFinder::state(conn_site_color,1)}
catch {unset ::VMDPathFinder::state(conn_site_color,2)}
chk "each opening gets its own color" \
    [expr {[::VMDPathFinder::_conn_site_color 1] ne [::VMDPathFinder::_conn_site_color 2]}] 1
chk "...and the same site keeps it" \
    [expr {[::VMDPathFinder::_conn_site_color 3] eq [::VMDPathFinder::_conn_site_color 3]}] 1
if {$_svc1 ne ""} { set ::VMDPathFinder::state(conn_site_color,1) $_svc1 }

# A lobe must map to the site nearest its own centroid, not its position in the
# render's lobe list. Table has site A near (z=10,az=0), site B near (z=50,az=180);
# the render's lobe list is given in the OPPOSITE order, so a positional mapping
# would swap them.
set _tbl [dict create sites [list [list 10.0 0.0 5 {}] [list 50.0 3.14159265358979 5 {}]]]
set _rlobes [list [list 50.2 3.10 20] [list 9.7 0.05 15]]
set _lmap [::VMDPathFinder::_conn_lobe_site_map $_tbl 0 $_rlobes]
chk "the near-B lobe (list position 0) maps to site B, not site 1" \
    [dict get $_lmap 0] 2
chk "the near-A lobe (list position 1) maps to site A, not site 2" \
    [dict get $_lmap 1] 1

# A lobe sitting entirely inside an axial range HOLE's own search escaped
# (beta>900, cross-section not enclosed) must be flagged, so a list full of
# search-escape artifacts is visibly diagnosable rather than looking like
# arbitrary clustering noise.
chk "_conn_t_is_escaped hits a t inside a range" \
    [::VMDPathFinder::_conn_t_is_escaped 5.0 {{4.0 6.0}} 0.0] 1
chk "...misses a t between two ranges" \
    [::VMDPathFinder::_conn_t_is_escaped 10.0 {{4.0 6.0} {14.0 16.0}} 0.0] 0
chk "...honours the padding" \
    [::VMDPathFinder::_conn_t_is_escaped 6.5 {{4.0 6.0}} 1.0] 1
set _elzt {}
for {set _i 0} {$_i < 20} {incr _i} {
    lappend _elzt [list 5.0 [expr {0.01*$_i}]]
}
for {set _i 0} {$_i < 20} {incr _i} {
    lappend _elzt [list 20.0 [expr {3.0 + 0.01*$_i}]]
}
set _ecls [dict create lat_zt $_elzt escaped_ranges {{4.0 6.0}}]
set _elobes [::VMDPathFinder::_conn_split_lobes $_ecls]
chk "two lobes, one entirely inside an escaped range, one not" [llength $_elobes] 2
foreach _lb $_elobes {
    lassign $_lb _ezc _eaz _en _eidx _eef
    if {abs($_ezc-5.0) < 0.5} {
        chk "the escaped-range lobe is flagged ~100%" [expr {$_eef > 0.99}] 1
    } else {
        chk "the clean lobe is flagged 0%" $_eef 0.0
    }
}

set _sv_pm4 $::VMDPathFinder::state(pore_method)
set ::VMDPathFinder::state(pore_method) spherical
chk "another method has no lateral openings to list" \
    [dict get [::VMDPathFinder::_conn_site_table] status] "notconn"
set ::VMDPathFinder::state(pore_method) $_sv_pm4

# --- Sideways openings are counted as RUNS, not points -----------------------
chk "two separate openings are two runs" \
    [llength [::VMDPathFinder::_conn_opening_runs {1 0 0 1 1 0 0 1} {0 1 2 3 4 5 6 7}]] 2
chk "...and each run carries its span" \
    [lrange [lindex [::VMDPathFinder::_conn_opening_runs {1 0 0 1 1 0 0 1} {0 1 2 3 4 5 6 7}] 0] 0 1] {1 2}
chk "an opening running to the end is closed off" \
    [llength [::VMDPathFinder::_conn_opening_runs {1 1 0 0} {0 1 2 3}]] 1
chk "a fully open profile is one run" \
    [llength [::VMDPathFinder::_conn_opening_runs {0 0 0} {0 1 2}]] 1
chk "nothing open is no runs" \
    [llength [::VMDPathFinder::_conn_opening_runs {1 1 2} {0 1 2}]] 0

# --- Atom names HOLE cannot read ---------------------------------------------
# HOLE puts PDB column 13 in HTEST and only reassembles the name when it is "H",
# so a 4-character CHARMM name like C210 arrives as "210" and matches no radius
# record. The rewriter shifts those so the element sits where HOLE looks.
set _anf [file join [::VMDPathFinder::get_temp_base] "atomnm_[pid].pdb"]
set _fh [open $_anf w]
puts $_fh "ATOM      1  N   PRO P 119      23.499  10.000  1.000  1.00  0.00"
puts $_fh "ATOM      2 HG21 ILE P 120      24.000  10.000  1.000  1.00  0.00"
puts $_fh "ATOM      3 C210 POPCM   1      25.094  49.173 10.101  0.00  0.00"
puts $_fh "END"
close $_fh
set _ann [::VMDPathFinder::_normalize_pdb_atom_names $_anf]
chk "only the unreadable names are rewritten" $_ann 1
set _fh [open $_anf r]; set _antxt [split [read $_fh] "\n"]; close $_fh
chk "...a 3-char protein name is untouched" \
    [string range [lindex $_antxt 0] 12 15] " N  "
chk "...a 4-char hydrogen is untouched (HOLE reassembles those itself)" \
    [string range [lindex $_antxt 1] 12 15] "HG21"
chk "...and a 4-char carbon moves so HOLE reads the element" \
    [string range [lindex $_antxt 2] 12 15] " C21"
# Columns after the name must not shift, or every downstream field moves.
chk "...without disturbing the rest of the record" \
    [string range [lindex $_antxt 2] 17 25] "POPCM   1"
catch {file delete $_anf}

# --- The mean carries the Connolly/spherical mixture through -----------------
# _resolve_conn_radii falls back to the spherical probe radius where the pore
# opens sideways, so a mean bin fed by both is not one quantity. The collector
# must report which bins those are, or the plot cannot mark them.
set _fbz {}; set _fby {}; set _fbr {}
for {set _i 0} {$_i < 20} {incr _i} {
    lappend _fbz [expr {$_i * 1.0}]
    lappend _fby [expr {2.0 + 0.1*$_i}]
    lappend _fbr [expr {($_i >= 8 && $_i <= 11) ? 0 : 1}]
}
set _sv_res $::VMDPathFinder::results
set _sv_rf  $::VMDPathFinder::result_frames
set ::VMDPathFinder::results [dict create 0 [dict create run_dir /tmp \
    profile [dict create valid 1 xvalues $_fbz yvalues $_fby rsources $_fbr \
        points 20 min_radius 2.0 min_coord 0.0]]]
set ::VMDPathFinder::result_frames {0}
set _sv_pm3 $::VMDPathFinder::state(pore_method)
set ::VMDPathFinder::state(pore_method) connolly
catch {unset ::VMDPathFinder::binned_cache}
set ::VMDPathFinder::binned_cache [dict create]
set _fbd [::VMDPathFinder::collect_binned_radii 20 {0} "fbtest"]
chk "the mean collector reports a per-bin fallback flag" \
    [expr {[dict exists $_fbd fallback]}] 1
set _fbl [expr {[dict exists $_fbd fallback] ? [dict get $_fbd fallback] : {}}]
set _fbn 0
foreach _v $_fbl { if {$_v} { incr _fbn } }
chk "...flagged for the bins fed by a spherical fallback, and only those" \
    [expr {$_fbn > 0 && $_fbn <= 6}] 1
# The same rows on a SPHERICAL run carry rsrc all-0, which would flag every bin
# and grey the whole mean profile. The flag only means anything under CONNOLLY.
set ::VMDPathFinder::state(pore_method) spherical
set ::VMDPathFinder::binned_cache [dict create]
set _fbd2 [::VMDPathFinder::collect_binned_radii 20 {0} "fbtest2"]
set _fbl2 [expr {[dict exists $_fbd2 fallback] ? [dict get $_fbd2 fallback] : {}}]
chk "a spherical run flags nothing" [llength $_fbl2] 0
set ::VMDPathFinder::state(pore_method) $_sv_pm3
set ::VMDPathFinder::results $_sv_res
set ::VMDPathFinder::result_frames $_sv_rf
catch {unset ::VMDPathFinder::binned_cache}
set ::VMDPathFinder::binned_cache [dict create]

# --- Every HOLE run is seeded ------------------------------------------------
# HOLE's pore search is Monte Carlo. Unseeded, two runs of the same frame gave
# 73x311 and 73x304 slices - and since the unrolled map is a SECOND HOLE run,
# an unseeded map was traced from a different pore than the profile beside it.
set _sd_f [file join [::VMDPathFinder::get_temp_base] "seedchk_[pid].inp"]
set _sv_seed $::VMDPathFinder::state(random_seed)
proc _sd_cards {path} {
    set fh [open $path r]; set t [read $fh]; close $fh
    set out {}
    foreach l [split $t "\n"] { if {[string trim $l] ne ""} { lappend out [lindex $l 0] } }
    return $out
}
set ::VMDPathFinder::state(random_seed) ""
::VMDPathFinder::write_control_file $_sd_f in.pdb out.sph {0 0 0} {0 0 1}
chk "a blank seed field still writes a raseed card" \
    [expr {[lsearch -exact [_sd_cards $_sd_f] raseed] >= 0}] 1
chk "...and it is the plugin's default, 1" [::VMDPathFinder::_hole_seed] 1
set ::VMDPathFinder::state(random_seed) 7
::VMDPathFinder::write_control_file $_sd_f in.pdb out.sph {0 0 0} {0 0 1}
chk "an explicit seed is honoured" [::VMDPathFinder::_hole_seed] 7
# The seed is part of the map's identity, or maps traced under another one
# (every map made before this was fixed) are reused as if they matched.
set _sd_r7 [::VMDPathFinder::_2dmap_grd_path /tmp touch]
set ::VMDPathFinder::state(random_seed) 1
set _sd_r1 [::VMDPathFinder::_2dmap_grd_path /tmp touch]
chk "a map traced under a different seed is a different file" \
    [expr {$_sd_r7 ne $_sd_r1}] 1
set ::VMDPathFinder::state(random_seed) $_sv_seed
catch {file delete $_sd_f}

# --- Abort must stop the WHOLE pipeline, not one stage of it -----------------
# Invariant: a proc long enough to need `update` is long enough to need an
# abort check. Structural, because a newly added unguarded stage is the
# regression and no behaviour test can see one not yet written.
proc _abort_unguarded_stages {} {
    set src [split [read [set _f [open "vmdpathfinder.tcl" r]]] "\n"]
    close $_f
    set cur ""; array set upd {}; array set chk {}
    set n 0
    foreach l $src {
        incr n
        if {[regexp {^proc (::VMDPathFinder::\S+)} $l -> nm]} { set cur $nm; continue }
        if {$cur eq ""} continue
        # FIRST of each, by line number. "Mentions abort somewhere" is too weak:
        # deleting a stage's ENTRY guard left its later between-phase checks in
        # place and the check stayed green (verified by sabotage). The invariant
        # is that you can abort BEFORE the stage starts yielding, so the abort
        # check has to come before the first `update` - or immediately after it,
        # which is the idiomatic form (the click is only deliverable once
        # `update` has run, so polling on the next line is equivalent).
        if {[regexp {^\s*update\s*$} $l] && ![info exists upd($cur)]} { set upd($cur) $n }
        if {([string first "_abort_requested" $l] >= 0
             || [string first "_abort_stop" $l] >= 0) && ![info exists chk($cur)]} {
            set chk($cur) $n
        }
    }
    set bad {}
    foreach nm [array names upd] {
        if {![info exists chk($nm)] || $chk($nm) > $upd($nm) + 3} { lappend bad $nm }
    }
    return [lsort $bad]
}
set _unguarded [_abort_unguarded_stages]
# _redisplay_results_list is a pure UI relist with no computation to abort.
set _unguarded [lsearch -all -inline -not -exact $_unguarded ::VMDPathFinder::_redisplay_results_list]
chk "every stage that yields to the event loop also honours Abort" \
    [expr {[llength $_unguarded] == 0 ? 1 : $_unguarded}] 1
# ...and a HOLE run must not hand an aborted run to the surface prebuild.
proc _ra_guards_prebuild {} {
    set b [info body ::VMDPathFinder::run_analysis]
    regsub -all {(?m)^\s*#.*$} $b {} b
    return [regexp {_abort_requested\]\s*&&\s*\\?\s*\n?\s*\(\$state\(prebuild_surfaces\)} $b]
}
chk "an aborted run does not start the surface prebuild" [_ra_guards_prebuild] 1

# --- Ion Flow: "flip Z" must flip BOTH views ---------------------------------
# Reported as "the check boxxes in ion flow gear setting does not work". The
# occupancy map honoured both toggles; Ion Passage honoured NEITHER - it maps Z
# onto its Y axis through _ipv_y, which never read the state variable. Drive the
# mapper directly: flipping must move a point to the mirrored position.
set _sv_ifz [expr {[info exists ::VMDPathFinder::state(ion_flow_flip_z)] ? $::VMDPathFinder::state(ion_flow_flip_z) : 0}]
set ::VMDPathFinder::state(ion_flow_flip_z) 0
# z=0 in a 0..10 span, plot from y=100 spanning 200px -> the TOP of the plot.
set _y0 [::VMDPathFinder::_ipv_y 0 0 10 100 200]
set ::VMDPathFinder::state(ion_flow_flip_z) 1
set _y1 [::VMDPathFinder::_ipv_y 0 0 10 100 200]
chk "Ion Passage: flip Z actually moves the point" [expr {$_y0 != $_y1}] 1
chk "...to the mirrored position, not an arbitrary one" \
    [expr {abs(($_y0 - 100) + ($_y1 - 100) - 200) < 1e-9}] 1
set ::VMDPathFinder::state(ion_flow_flip_z) 0
chk "...and unticking puts it back" [::VMDPathFinder::_ipv_y 0 0 10 100 200] $_y0
set ::VMDPathFinder::state(ion_flow_flip_z) $_sv_ifz
# Swap X/Y is GONE from this dialog by user instruction: Ion Passage plots FRAME
# on X, so swapping would put time on the vertical axis - it could never work
# there, which is half of what "the checkboxes do not work" meant.
proc _ifs_body_has {needle} {
    set b [info body ::VMDPathFinder::show_ion_flow_settings]
    regsub -all {(?m)^\s*#.*$} $b {} b
    return [expr {[string first $needle $b] >= 0}]
}
chk "the Ion Flow gear no longer offers swap X/Y" [_ifs_body_has {swap X/Y}] 0
chk "...but still offers flip Z" [_ifs_body_has {flip Z}] 1

# --- run_analysis has a return CONTRACT (batch scripts depend on it) --------
# It used to fall off the end, so every path returned "" and a `vmd -dispdev
# text` driver could not tell a completed run from a failed one. The documented
# batch path silently "succeeded" on failure.
set _sv_busy $::VMDPathFinder::busy
set ::VMDPathFinder::busy 1
chk "a run refused because one is in progress returns 0, not empty" \
    [::VMDPathFinder::run_analysis] 0
set ::VMDPathFinder::busy $_sv_busy
# Proc-wrapped so the (long) body never becomes a top-level command result -
# this script is fed to vmd on stdin, which echoes those.
proc _ra_body_has {re} {
    set b [info body ::VMDPathFinder::run_analysis]
    regsub -all {(?m)^\s*#.*$} $b {} b
    return [regexp $re $b]
}
# Every exit has to carry a value; a bare `return` reintroduces the empty
# result on exactly the path that took it.
proc _ra_bare_returns {} {
    set b [info body ::VMDPathFinder::run_analysis]
    regsub -all {(?m)^\s*#.*$} $b {} b
    return [llength [regexp -all -inline {(?m)^[ \t]*return[ \t]*$} $b]]
}
chk "no path of run_analysis returns empty" [_ra_bare_returns] 0
chk "...and the normal end returns the success/failure flag" \
    [_ra_body_has {return \[expr \{\$_failed \|\| \$_cancelled}] 1
# The error path must not depend on Tk being present. tk_messageBox was called
# unconditionally, so headless the REAL error was replaced by "invalid command
# name tk_messageBox".
chk "the failure path guards tk_messageBox on _have_tk" \
    [_ra_body_has {_have_tk\]\} \{\s*\n\s*tk_messageBox}] 1
chk "...and logs the error where a batch run can see it" \
    [_ra_body_has {vmdcon -err "VMDPathFinder: run failed}] 1

# --- per-frame axis persistence + lookup (Ion Flow drift fix) -------------------
chk "nearest: exact match returns itself" \
    [::VMDPathFinder::_nearest_int_in_sorted_list 20 {10 20 30}] 20
chk "nearest: below range clamps to the first" \
    [::VMDPathFinder::_nearest_int_in_sorted_list 1 {10 20 30}] 10
chk "nearest: above range clamps to the last" \
    [::VMDPathFinder::_nearest_int_in_sorted_list 99 {10 20 30}] 30
chk "nearest: a tie breaks to the smaller value" \
    [::VMDPathFinder::_nearest_int_in_sorted_list 15 {10 20}] 10
chk "nearest: a single-element list always wins" \
    [::VMDPathFinder::_nearest_int_in_sorted_list 500 {7}] 7
chk "nearest: picks the CLOSER of two unevenly spaced neighbours" \
    [::VMDPathFinder::_nearest_int_in_sorted_list 12 {0 10 40}] 10

set _axdir [file join [::VMDPathFinder::get_temp_base] "vmdpathfinder_axis_[pid]"]
file mkdir $_axdir
chk "_parse_cpoint_cvect_file: missing file returns empty" \
    [::VMDPathFinder::_parse_cpoint_cvect_file [file join $_axdir nope.dat]] ""
set _axf [file join $_axdir vmdpathfinder_frame_axis.dat]
set _fh [open $_axf w]
puts -nonewline $_fh "cpoint|1.0 2.0 3.0|cvect|0.0 0.0 5.0"
close $_fh
chk "_parse_cpoint_cvect_file: reads cpoint verbatim" \
    [lrange [::VMDPathFinder::_parse_cpoint_cvect_file $_axf] 0 2] {1.0 2.0 3.0}
chk "...and normalizes cvect (0 0 5 -> 0 0 1)" \
    [lrange [::VMDPathFinder::_parse_cpoint_cvect_file $_axf] 3 5] {0.0 0.0 1.0}
chk "_frame_axis_persisted reads vmdpathfinder_frame_axis.dat, not the signature" \
    [::VMDPathFinder::_frame_axis_persisted $_axdir] \
    [::VMDPathFinder::_parse_cpoint_cvect_file $_axf]

# _frame_cpoint_cvect must PREFER the real per-frame axis over the run's nominal
# signature when both exist - sabotage-checked: reverting _frame_cpoint_cvect to
# skip _frame_axis_persisted and go straight to the signature makes this compare
# the SIGNATURE's cpoint (9 9 9) against the frame_axis file's (1 2 3) and fail.
set _sigf [file join $_axdir vmdpathfinder_signature.dat]
set _fh [open $_sigf w]
puts -nonewline $_fh "sel|protein|cpoint|9.0 9.0 9.0|cvect|0.0 0.0 1.0"
close $_fh
set _sv_results $::VMDPathFinder::results
set ::VMDPathFinder::results [dict create 0 [dict create run_dir $_axdir]]
chk "_frame_cpoint_cvect prefers the real per-frame axis over the nominal signature" \
    [lrange [::VMDPathFinder::_frame_cpoint_cvect 0] 0 2] {1.0 2.0 3.0}
file delete -force $_axf
chk "...and falls back to the signature once no per-frame axis is persisted" \
    [lrange [::VMDPathFinder::_frame_cpoint_cvect 0] 0 2] {9.0 9.0 9.0}
set ::VMDPathFinder::results $_sv_results
file delete -force $_axdir

# --- ion_radius_fallback: Nightingale (1959) Table I crystal radii --------------
set _iondir [file join [::VMDPathFinder::get_temp_base] "vmdpathfinder_ionrad_[pid]"]
file mkdir $_iondir
set _radbase [file join $_iondir base.rad]
set _fh [open $_radbase w]
puts $_fh "remark: minimal stand-in for simple.rad's own shape"
puts $_fh "VDWR CA?? ALA 1.90"
puts $_fh "VDWR C??? ??? 1.85"
puts $_fh "VDWR O??? ??? 1.65"
puts $_fh "VDWR S??? ??? 2.00"
puts $_fh "VDWR N??? ??? 1.75"
puts $_fh "VDWR H??? ??? 1.00"
puts $_fh "VDWR P??? ??? 2.10"
close $_fh
set _radbase_before [exec cat $_radbase]

set _sv_state [array get ::VMDPathFinder::state]
set ::VMDPathFinder::state(radius_file) $_radbase
set ::VMDPathFinder::state(ion_radius_fallback) 0

set _rules_off [hole::read_rad_file $_radbase]
chk "before the fallback: a sodium ion (SOD/SOD) silently collides with the sulphur wildcard" \
    [hole::radius_for $_rules_off SOD SOD] 2.00
chk "...and a chloride ion (CLA/CLA) silently collides with the carbon wildcard" \
    [hole::radius_for $_rules_off CLA CLA] 1.85
chk "...and potassium (K/POT) - this project's own documented real HOLE crash - errors, matching the real binary" \
    [catch {hole::radius_for $_rules_off K POT}] 1

set ::VMDPathFinder::state(ion_radius_fallback) 1
set _eff [::VMDPathFinder::_effective_radius_file]
chk "fallback ON: the effective radius file is a NEW path, not the original" \
    [expr {$_eff ne $_radbase}] 1
chk "...and the original file on disk is untouched" [exec cat $_radbase] $_radbase_before

set _rules_on [hole::read_rad_file $_eff]
chk "after the fallback: sodium (SOD/SOD) gets Nightingale's Na+ crystal radius" \
    [hole::radius_for $_rules_on SOD SOD] 0.95
chk "...chloride (CLA/CLA) gets Cl-'s" [hole::radius_for $_rules_on CLA CLA] 1.81
chk "...potassium (K/POT), the crash case, now resolves instead of erroring" \
    [hole::radius_for $_rules_on K POT] 1.33
chk "...plain AMBER-style atom name NA/NA also resolves (Na+)" \
    [hole::radius_for $_rules_on NA NA] 0.95
chk "...a genuinely unmatched atom still errors - no silent universal catch-all" \
    [catch {hole::radius_for $_rules_on ZZ XYZ}] 1

chk "containment: an ordinary protein atom's radius is byte-identical before/after" \
    [hole::radius_for $_rules_on CA ALA] [hole::radius_for $_rules_off CA ALA]
chk "...same for a generic-wildcard-only atom (O/ALA)" \
    [hole::radius_for $_rules_on O ALA] [hole::radius_for $_rules_off O ALA]

set ::VMDPathFinder::state(hole_fix_atom_names) 0
chk "ion_radius_fallback alone also triggers the atom-rename fix" \
    [::VMDPathFinder::_should_fix_atom_names] 1
set ::VMDPathFinder::state(ion_radius_fallback) 0
chk "...but not when both are off" [::VMDPathFinder::_should_fix_atom_names] 0

# A residue coincidentally named like a fallback ion, but with more than one
# atom, is not really that ion - warn rather than silently misapplying its
# radius. MN (manganese, 3 chars, in the table) with 2 atoms; SOD (sodium,
# a real single-atom ion) with 1 - only the first should warn.
set _ambpdb [file join $_iondir amb.pdb]
set _fh [open $_ambpdb w]
puts $_fh "ATOM      1  X1  MN  A   1       0.000   0.000   0.000  1.00  0.00           X"
puts $_fh "ATOM      2  X2  MN  A   1       1.500   0.000   0.000  1.00  0.00           X"
puts $_fh "ATOM      3  NA  SOD A   2       5.000   0.000   0.000  1.00  0.00          NA"
close $_fh
set _ambmol [mol new $_ambpdb]
set _sv_molid $::VMDPathFinder::state(molid)
set ::VMDPathFinder::state(molid) $_ambmol
set ::VMDPathFinder::state(selection) "all"
set ::VMDPathFinder::state(ion_radius_fallback) 1
set _ambwarns [::VMDPathFinder::_ion_fallback_ambiguity_warnings]
chk "a 2-atom residue coincidentally named MN (Mn2+'s fallback resname) warns" \
    [expr {[llength $_ambwarns] == 1 && [string match {*"MN"*} [lindex $_ambwarns 0]]}] 1
set ::VMDPathFinder::state(ion_radius_fallback) 0
chk "...and the same scan is skipped entirely with the knob off" \
    [llength [::VMDPathFinder::_ion_fallback_ambiguity_warnings]] 0
catch {mol delete $_ambmol}
set ::VMDPathFinder::state(molid) $_sv_molid

array unset ::VMDPathFinder::state
array set ::VMDPathFinder::state $_sv_state
file delete -force $_iondir
catch {file delete -force $_eff}

# --- Connolly per-lobe property coloring: color-passthrough + gating -----------
set _lpdir [file join [::VMDPathFinder::get_temp_base] "vmdpathfinder_lobeprop_[pid]"]
file mkdir $_lpdir
set _partA [file join $_lpdir a.vmd_plot]
set _fh [open $_partA w]
puts $_fh "draw delete all"
puts $_fh "draw color 7"
puts $_fh "draw trinorm {0 0 0} {1 0 0} {0 1 0} {0 0 1} {0 0 1} {0 0 1}"
puts $_fh "draw color 12"
puts $_fh "draw trinorm {1 1 1} {2 1 1} {1 2 1} {0 0 1} {0 0 1} {0 0 1}"
close $_fh
set _partB [file join $_lpdir b.vmd_plot]
set _fh [open $_partB w]
puts $_fh "draw delete all"
puts $_fh "draw trinorm {5 5 5} {6 5 5} {5 6 5} {0 0 1} {0 0 1} {0 0 1}"
close $_fh
set _outp [file join $_lpdir out.vmd_plot]

::VMDPathFinder::_write_conn_multi_plot [list $_partA "" $_partB blue] $_outp
set _outtxt [split [exec cat $_outp] "\n"]
chk "color=\"\" keeps a part's own per-triangle draw-color lines verbatim" \
    [expr {[lsearch -exact $_outtxt "draw color 7"] >= 0 && [lsearch -exact $_outtxt "draw color 12"] >= 0}] 1
chk "...while a real color still overrides the OTHER part's (color-less) geometry" \
    [expr {[lsearch -glob $_outtxt "draw color blue"] >= 0}] 1
chk "...and a real color still strips whatever draw-color WAS in that part (none here, so just geometry)" \
    [llength [lsearch -all -glob $_outtxt "draw color*"]] 3

set _sv_state2 [array get ::VMDPathFinder::state]
set ::VMDPathFinder::state(surface_color) pore_lat
set ::VMDPathFinder::state(display_mode) triangulated
set ::VMDPathFinder::state(pore_method) connolly
set ::VMDPathFinder::state(extra_cards) {}
foreach _k [array names ::VMDPathFinder::state conn_site_colormode,*] {
    unset ::VMDPathFinder::state($_k)
}
set ::VMDPathFinder::state(conn_site_colormode,2) property
chk "property coloring is OFF when the panel isn't even in per-lobe mode (pore_lat, not pore_lobes)" \
    [::VMDPathFinder::_conn_lobe_property_active] 0
set ::VMDPathFinder::state(surface_color) pore_lobes
chk "...and ON once per-lobe mode is on AND some region chose property" \
    [::VMDPathFinder::_conn_lobe_property_active] 1

# Per-REGION, not global: the whole point of the row menu is that one opening
# can be property-colored while its neighbours stay flat.
chk "the region that chose property reports property" \
    [::VMDPathFinder::_conn_site_property_active 2] 1
chk "...and a region that did NOT does not" \
    [::VMDPathFinder::_conn_site_property_active 3] 0
set ::VMDPathFinder::state(conn_site_colormode,3) red
chk "...a flat color is not property either" \
    [::VMDPathFinder::_conn_site_property_active 3] 0
chk "...and that flat color is what the renderer gets for it" \
    [::VMDPathFinder::_conn_site_color 3] red
set ::VMDPathFinder::state(conn_site_colormode,4) ""
chk "auto falls back to the palette, not to empty" \
    [expr {[::VMDPathFinder::_conn_site_color 4] ne "" ? 1 : 0}] 1
# "Property" must never leak into the store as if it were a color name -
# that would emit `draw color Property` into the plot file.
chk "a property region's color resolves to a real color, never the word Property" \
    [expr {[::VMDPathFinder::_conn_site_color 2] ne "property" \
        && [::VMDPathFinder::_conn_site_color 2] ne "Property" ? 1 : 0}] 1
# The label mapping the row menu displays, both directions.
chk "menu label for property" [::VMDPathFinder::_conn_site_colormode_label 2] "Property"
chk "menu label for a flat color" [::VMDPathFinder::_conn_site_colormode_label 3] red
chk "menu label for auto" [::VMDPathFinder::_conn_site_colormode_label 4] auto
# The cache tag MUST move when a region's color mode changes, or the stale
# plot is re-rendered and the pick appears to do nothing.
set _tag_before [::VMDPathFinder::_conn_lobes_tag]
set ::VMDPathFinder::state(conn_site_colormode,3) property
chk "changing a region's color mode changes the plot cache tag" \
    [expr {[::VMDPathFinder::_conn_lobes_tag] ne $_tag_before ? 1 : 0}] 1
array unset ::VMDPathFinder::state
array set ::VMDPathFinder::state $_sv_state2
file delete -force $_lpdir

# --- Lobe neck and stretch ------------------------------------------------
# The split leaves the neck blank (nm_search fills it) and reports stretch: how
# far the furthest dot reaches past the margin band. Synthetic lat_zt: 25 dots,
# one cluster, wall a constant 3.0, rr 6.0 except one at 5.3.
set _zt {}
for {set _i 0} {$_i < 25} {incr _i} {
    set _t [expr {2.0 + 0.2*$_i}]
    set _rr [expr {$_i == 12 ? 5.3 : 6.0}]
    lappend _zt [list $_t 0.05 $_rr 3.0]
}
set _synthcls [dict create lat_zt $_zt n_lat [llength $_zt] escaped_ranges {}]
set _sv_mg [expr {[info exists ::VMDPathFinder::state(conn_pore_margin)] ? $::VMDPathFinder::state(conn_pore_margin) : 2.0}]
set ::VMDPathFinder::state(conn_pore_margin) 2.0
set _necklobes [::VMDPathFinder::_conn_split_lobes $_synthcls]
chk "one lobe found in the synthetic cluster" [llength $_necklobes] 1
lassign [lindex $_necklobes 0] _nz _na _nn _nidx _nef _neck _stretch
chk "the split leaves the neck for the route search" $_neck ""
chk "stretch is the furthest dot beyond the margin band (6.0-3.0-2.0)" [format %.1f $_stretch] 1.0
set ::VMDPathFinder::state(conn_pore_margin) 1.0
chk "...and tracks the margin (6.0-3.0-1.0)" \
    [format %.1f [lindex [lindex [::VMDPathFinder::_conn_split_lobes $_synthcls] 0] 6]] 2.0
set ::VMDPathFinder::state(conn_pore_margin) $_sv_mg
chk "_conn_frame_lobes reads the lobes the classifier stored" \
    [llength [::VMDPathFinder::_conn_frame_lobes [dict create lobes $_necklobes n_lat 25]]] 1
chk "...and has nothing to say for a cloud without them" \
    [::VMDPathFinder::_conn_frame_lobes [dict create lat_zt $_zt]] ""
# The engine's answer becomes the stored neck: blank when it had none, the
# end radius when the route is wider than the search looks ("open").
chk "a fitted neck is stored as it is" [::VMDPathFinder::_conn_neck_value 1.72 22.0] 1.72
chk "a route wider than the end radius reads open (= endrad)" [::VMDPathFinder::_conn_neck_value 31.5 22.0] 22.0
chk "no answer leaves the neck blank" [list [::VMDPathFinder::_conn_neck_value - 22.0] [::VMDPathFinder::_conn_neck_value "" 22.0] [::VMDPathFinder::_conn_neck_value -1 22.0]] {{} {} {}}
# Opening traffic: a sample counts only in an opening's own cell AND out past
# the opening's nearest dot there - a lumen ion in the same sector does not.
set _c2s [dict create "3,5" 2]
set _cmin [dict create "3,5" 9.0]
set _cmax [dict create "3,5" 14.0]
chk "a sample out in the opening is attributed to it" [::VMDPathFinder::_conn_sample_site $_c2s $_cmin $_cmax "3,5" 10.2] 2
chk "...a lumen sample in the same sector is not" [::VMDPathFinder::_conn_sample_site $_c2s $_cmin $_cmax "3,5" 4.0] ""
chk "...and a sample in another cell is not" [::VMDPathFinder::_conn_sample_site $_c2s $_cmin $_cmax "3,6" 10.2] ""
chk "...nor one that has left through it into bulk" [::VMDPathFinder::_conn_sample_site $_c2s $_cmin $_cmax "3,5" 32.0] ""
chk "...while one just outside the last dot still counts" [::VMDPathFinder::_conn_sample_site $_c2s $_cmin $_cmax "3,5" 16.0] 2
chk "cell keys follow the lobe grid (azimuth wraps)" \
    [list [::VMDPathFinder::_conn_cell_key 7.9 0.0 3.0 24] [::VMDPathFinder::_conn_cell_key -0.1 3.14159 3.0 24]] {2,12 -1,23}
chk "_conn_nearest_t picks the closest sorted position" \
    [list [::VMDPathFinder::_conn_nearest_t {0 1 2 3} 2.4] [::VMDPathFinder::_conn_nearest_t {0 1 2 3} -5] [::VMDPathFinder::_conn_nearest_t {0 1 2 3} 9]] {2 0 3}
chk "_conn_lobe_necks hands the lobes back untouched without a centreline" \
    [::VMDPathFinder::_conn_lobe_necks /nonexistent.sph [dict create lobes $_necklobes lateral {}] {0 0 1} {0 0 0}] $_necklobes
chk "the neck cell reads open at the search's end radius" \
    [expr {[string first {? "open" :} [info body ::VMDPathFinder::_refresh_conn_lobes_panel]] >= 0}] 1

# _conn_pool_lobe_sites must carry neck/stretch through its instance tuples.
# Named nka/nkb rather than na/nb deliberately - this proc already has azimuth-
# mean locals called na/nb; checked by sabotage that reusing those names does
# NOT actually corrupt anything (lassign refreshes them before the later
# reassignment consumes them), but the naming stays distinct for clarity.
# Two frames, same lobe shape/position (so they pool into one site), different
# neck values each frame - the row shown must be the MEAN across frames,
# matching Escaped%'s own averaging.
set _pf {}
lappend _pf 0 [list [list 0.0 0.0 25 {} 0.0 5.0 2.0]]
lappend _pf 1 [list [list 0.0 0.0 25 {} 0.0 7.0 4.0]]
set _pooled [::VMDPathFinder::_conn_pool_lobe_sites $_pf]
chk "pooling collapses same-position lobes into one site" \
    [llength [dict get $_pooled sites]] 1
set _site0 [lindex [dict get $_pooled sites] 0]
lassign $_site0 _sz _sa _sn _sinst
chk "...preserving azimuth 0.0 (not corrupted by a neck-radius variable name collision)" \
    [format %.4f $_sa] 0.0000
set _i1 [lindex $_sinst 0]; set _i2 [lindex $_sinst 1]
chk "...and both instances carry their own neck/stretch through unmodified" \
    [list [lindex $_i1 4] [lindex $_i1 5] [lindex $_i2 4] [lindex $_i2 5]] {5.0 2.0 7.0 4.0}

# --- Changing the pore method resets EVERY tab's property picker ----------------
# A scheme chosen under one method must not stay selected under the next: the
# user hit exactly this going spherical -> Connolly with Over Time still set to
# a property. Resetting only the surface's own hydro_scheme (which is all this
# used to do) left Over Time / Mean Profile / Pore Profile holding the stale
# choice. Also asserts the reset fires with NO results loaded - clearing DATA
# needs results to exist, resetting the VIEW does not.
set _sv_state3 [array get ::VMDPathFinder::state]
set _sv_rf3 $::VMDPathFinder::result_frames
set ::VMDPathFinder::result_frames {}
set ::VMDPathFinder::state(pore_method) circular
foreach {_k _v} {hydro_scheme ww surface_color property heatmap_color_by property
                 hm_prop_scheme ww profile_color_scheme ww mean_hydro_scheme ww
                 mean_surface_color property mean_profile_fill 1
                 conn_pore_gate 1 conn_site_colormode,1 property} {
    set ::VMDPathFinder::state($_k) $_v
}
catch {::VMDPathFinder::_set_pore_method connolly Connolly}
chk "method change resets the surface property scheme" $::VMDPathFinder::state(hydro_scheme) kd
chk "...and Over Time's color-by drops back to radius" $::VMDPathFinder::state(heatmap_color_by) radius
chk "...and Over Time's own property scheme" $::VMDPathFinder::state(hm_prop_scheme) kd
chk "...and Pore Profile's fill scheme" $::VMDPathFinder::state(profile_color_scheme) kd
chk "...and Mean Profile's property scheme" $::VMDPathFinder::state(mean_hydro_scheme) kd
chk "...and Mean Profile's fill goes off" $::VMDPathFinder::state(mean_profile_fill) 0
chk "...and the Connolly-only sideways-spill gate" $::VMDPathFinder::state(conn_pore_gate) 0
chk "...and every per-region color mode is cleared" [llength [array names ::VMDPathFinder::state conn_site_colormode,*]] 0
chk "...with the method itself actually applied" $::VMDPathFinder::state(pore_method) connolly
array unset ::VMDPathFinder::state
array set ::VMDPathFinder::state $_sv_state3
set ::VMDPathFinder::result_frames $_sv_rf3

# --- Ion Flow parity: spherical vs CONNOLLY ------------------------------------
# 1. ONE definition of "the radius a centerline record reports", per method.
#    _asym_gather used to hardcode beta while the Ion Flow wall loop branched,
#    so the two halves of the same plot could describe the pore with different
#    quantities. These radii set rmin_hole and zc - zc being the axial plane the
#    permeation counter counts crossings of.
set _sv_pm6 $::VMDPathFinder::state(pore_method)
set _sv_ec6 [expr {[info exists ::VMDPathFinder::state(extra_cards)] ? $::VMDPathFinder::state(extra_cards) : ""}]
set ::VMDPathFinder::state(extra_cards) {}
# occupancy cols 55-60 = 2.50, beta cols 61-66 = 7.75 - deliberately different
# so the column actually used is unambiguous.
set _rl "ATOM      1  QSS SPH S   1      10.000  20.000  30.000  2.50  7.75"
set ::VMDPathFinder::state(pore_method) circular
chk "spherical reads the spherical-probe column" \
    [::VMDPathFinder::_sph_centerline_radius $_rl] 2.50
set ::VMDPathFinder::state(pore_method) connolly
chk "CONNOLLY reads the Connolly (equal-area) column" \
    [::VMDPathFinder::_sph_centerline_radius $_rl] 7.75
# An escaped Connolly slice (beta ~999.99) must fall back to the probe column,
# never be reported as a 999 A pore.
set _re "ATOM      1  QSS SPH S   1      10.000  20.000  30.000  2.50 999.99"
chk "an escaped CONNOLLY slice falls back to the probe radius" \
    [::VMDPathFinder::_sph_centerline_radius $_re] 2.50
set ::VMDPathFinder::state(pore_method) circular
chk "...and spherical is unaffected by the escape sentinel" \
    [::VMDPathFinder::_sph_centerline_radius $_re] 2.50
# 2. Both ion-flow .sph readers must agree on the column - assert they route
#    through the one helper rather than re-deriving it.
set _ag [info body ::VMDPathFinder::_asym_gather]
chk "_asym_gather uses the shared radius helper" \
    [expr {[string first {_sph_centerline_radius} $_ag] >= 0}] 1
chk "...and no longer hardcodes a column range for the radius" \
    [expr {[string first {set r  [string trim [string range $line 60 65]]} $_ag] >= 0}] 0
set _ifs [info body ::VMDPathFinder::_ion_flow_scan]
chk "the Ion Flow wall loop uses it too" \
    [expr {[string first {_sph_centerline_radius} $_ifs] >= 0}] 1
# 3. bulk_lo/bulk_hi must come from the escaped-INCLUSIVE pooled extent. Escaped
#    centerline rows are real axial samples under CONNOLLY; dropping them pulled
#    both bulk planes ~19/12 A inside the pore and inflated the permeation count.
chk "bulk_lo/bulk_hi are emitted from the pooled extent, not the truncated one" \
    [expr {[string first {bulk_lo $_blo bulk_hi $_bhi} $_ifs] >= 0}] 1
set ::VMDPathFinder::state(pore_method) $_sv_pm6
set ::VMDPathFinder::state(extra_cards) $_sv_ec6

# --- pore/lateral split must not eat the vestibules ----------------------------
# HOLE stops tracing its centerline well before the flood fill stops (measured:
# 100 A traced vs a 126 A cloud). _conn_centreline_at CLAMPS past that range, so
# a full 3-D distance to the clamped endpoint grows with AXIAL distance: a dot
# sitting dead centre in the pore mouth, well beyond the last traced sphere,
# measured as far off-centre and got classified as lateral spill. That is why
# the pore mesh lost its ends. The distance must be purely RADIAL.
set _cb [info body ::VMDPathFinder::_conn_classify_tcl]
chk "the classifier strips the axial component before measuring distance" \
    [expr {[string first {set _axc [expr {$dx*$ux + $dy*$uy + $dz*$uz}]} $_cb] >= 0}] 1
chk "...and no longer takes a raw 3-D distance to the clamped centre" \
    [expr {[regexp {set dx \[expr \{\$x-\$cx\}\][^\n]*\n\s*set rr} $_cb] ? 1 : 0}] 0
# Numeric proof of the mechanism, independent of the .sph: a point ON the axis
# but 12 A past the clamped centre must read radius 0, not 12.
set _ux 0.0; set _uy 0.0; set _uz 1.0
set _dx 0.0; set _dy 0.0; set _dz 12.0
set _axc [expr {$_dx*$_ux + $_dy*$_uy + $_dz*$_uz}]
set _rdx [expr {$_dx - $_axc*$_ux}]; set _rdy [expr {$_dy - $_axc*$_uy}]; set _rdz [expr {$_dz - $_axc*$_uz}]
chk "a dot 12 A past the traced end but ON the axis is 0 A off-centre, not 12" \
    [format %.3f [expr {sqrt($_rdx*$_rdx+$_rdy*$_rdy+$_rdz*$_rdz)}]] 0.000
# A genuinely off-axis dot is unaffected by the change.
set _dx 5.0; set _dy 0.0; set _dz 12.0
set _axc [expr {$_dx*$_ux + $_dy*$_uy + $_dz*$_uz}]
set _rdx [expr {$_dx - $_axc*$_ux}]; set _rdy [expr {$_dy - $_axc*$_uy}]; set _rdz [expr {$_dz - $_axc*$_uz}]
chk "...while a genuinely off-axis dot still measures its real radial offset" \
    [format %.3f [expr {sqrt($_rdx*$_rdx+$_rdy*$_rdy+$_rdz*$_rdz)}]] 5.000

# --- Mean Profile must not plot bins carried by one frame ----------------------
# zmin/zmax are the POOLED extremes, so a single frame whose pore traced further
# than the rest stretched the axis across a region nothing else reached.
# Measured on a real 100-frame run: 66.8 A axis, but only -22.6..23.5 A had half
# the frames in it - the outer 17 A (a quarter of the plot) was ONE frame, where
# the "mean" is that frame's value and the SD is 0. That tail also fed the
# derived energy plot.
set _cbr [info body ::VMDPathFinder::collect_binned_radii]
chk "collect_binned_radii reports a well-sampled span" \
    [expr {[string first {cov_lo $cov_lo cov_hi $cov_hi} $_cbr] >= 0}] 1
chk "...with a floor of at least 2 frames per bin" \
    [expr {[string first {if {$_covmin < 2} { set _covmin 2 }} $_cbr] >= 0}] 1
chk "...and it does NOT replace the pooled zmin/zmax (other consumers unchanged)" \
    [expr {[string first {dict create zmin $zmin zmax $zmax zstep $zstep} $_cbr] >= 0}] 1
set _dmp [info body ::VMDPathFinder::_draw_mean_profile_body]
chk "the Mean Profile skips bins under that floor" \
    [expr {[string first {< $_covmin} $_dmp] >= 0}] 1
chk "...and says how many it trimmed rather than narrowing silently" \
    [expr {[string first {thin bin(s) trimmed} $_dmp] >= 0}] 1

# --- "one surface at a time" must hold when the PORE arrives second ------------
# _solo_surface only hides what exists when it runs. A pore surface built
# afterwards (mol new is displayed by default) came up over a mean that was
# already showing - the "first time I check Show 3D it doesn't hide the pore"
# case, where on the first show there is no pore mol yet for the solo to hide.
set _lsf [info body ::VMDPathFinder::load_surface_for_frame]
chk "loading a pore surface re-asserts an active mean solo" \
    [expr {[string first {_solo_surface mean} $_lsf] >= 0}] 1
chk "...only while the mean is actually shown" \
    [expr {[string first {$state(show_mean_surface) && } $_lsf] >= 0}] 1
chk "...and only when its mol really exists" \
    [expr {[string first {molinfo $mean_surface_mol get name} $_lsf] >= 0}] 1

# --- Mean Profile follows MDAnalysis bin_radii semantics ----------------------
# The reference (HoleAnalysis.plot_mean_profile) pools EVERY radius sample from
# every frame into the bin, then takes mean/std over that pooled set. We used to
# return the frame-weighted stats (one value per frame per bin), which answers a
# different question. Measured on a real run the two agree closely (mean 0.040 A,
# SD 0.037 A apart) - this is a definition fix, not a visible jump.
set _bsm [info body ::VMDPathFinder::binned_stats_for_mean]
chk "Mean Profile uses the raw-pooled stats, like the reference" \
    [expr {[string first {dict get $data stats_raw} $_bsm] >= 0}] 1
chk "...not the frame-weighted ones" \
    [expr {[regexp {return \[dict get \$data stats\]} $_bsm] ? 1 : 0}] 0
chk "bin count matches the reference default of 100" [::VMDPathFinder::_mean_profile_nbins] 100
# Coverage floor: 5% of frames, still floored at 2.
foreach {_nf _want} {100 5.0 40 2.0 20 2 4 2} {
    set _cm [expr {$_nf * 0.05}]
    if {$_cm < 2} { set _cm 2 }
    chk "coverage floor for $_nf frames" $_cm $_want
}
# Nothing is dropped from the CSV - only from the picture.
set _emc [info body ::VMDPathFinder::export_mean_profile_csv]
chk "the CSV exports every populated bin, thin ones included" \
    [expr {[string first {plotted_in_gui} $_emc] >= 0}] 1
chk "...and records how many frames backed each bin" \
    [expr {[string first {n_frames} $_emc] >= 0}] 1
chk "...and bins exactly like the plot (no hardcoded second bin count)" \
    [expr {[string first {collect_binned_radii [_mean_profile_nbins]} $_emc] >= 0}] 1
chk "...including in tunnel mode" \
    [expr {[string first {_tunnel_collect_binned_radii [_mean_profile_nbins]} $_emc] >= 0}] 1

# --- Ion Flow's wall IS the Mean Profile, not a second calculation ------------
# It used to bin the .sph itself (0.5 A bins, projection axis) while Mean Profile
# binned the profile TSV (range/nbins, HOLE coord) - same pore, two estimators,
# two origins, so the two plots disagreed on where the constriction was AND how
# deep. Now one source feeds both.
set _ifs2 [info body ::VMDPathFinder::_ion_flow_scan]
chk "the Ion Flow wall is built from collect_binned_radii" \
    [expr {[string first {[collect_binned_radii [_mean_profile_nbins]]} $_ifs2] >= 0}] 1
chk "...including in tunnel mode, off the SELECTED tunnel's own profile" \
    [expr {[string first {[_tunnel_collect_binned_radii [_mean_profile_nbins]]} $_ifs2] >= 0}] 1
chk "...through the same stats accessor the Mean Profile uses" \
    [expr {[string first {binned_stats_for_mean $_mpd} $_ifs2] >= 0}] 1
chk "...and is therefore already in HOLE coord, so it is not shifted twice" \
    [expr {[string first {_rprof_is_coord} $_ifs2] >= 0}] 1
chk "...while the projection-space fallback still IS shifted" \
    [expr {[string first {set _rprof_is_coord 0} $_ifs2] >= 0}] 1

# --- Hydration is HIDDEN as a TAB under CONNOLLY/CAPSULE, not greyed ----------
# Greying left a dead label in the tab bar for a measurement the method cannot
# make; `hide` takes it out of the bar, and ttk::notebook's `add` puts it back
# in its original position rather than appending it.
set _umb [info body ::VMDPathFinder::_update_method_dependent_controls]
chk "the Hydration notebook TAB is hidden, not only its Compute button" \
    [expr {[string first {nb hide $w.plotframe.nb.hydration} $_umb] >= 0}] 1
chk "...and comes back when the method supports it" \
    [expr {[string first {nb add $w.plotframe.nb.hydration} $_umb] >= 0}] 1
chk "...and the tab is stepped off BEFORE being hidden" \
    [expr {[string first {nb select $w.plotframe.nb.profile} $_umb] < \
           [string first {nb hide $w.plotframe.nb.hydration} $_umb]}] 1
chk "...for CAPSULE as well as CONNOLLY" \
    [expr {[string first {set _hyd_off [expr {$capsule || $connolly}]} $_umb] >= 0}] 1

# --- Ion Flow per-slice shell (CONNOLLY escaped slices) ------------------------
# The shell compensates for an INSCRIBED radius understating a non-circular
# cross-section. CONNOLLY sets it to 0 because Requiv already spans the real
# area - true except at escaped slices (beta~999.99), where the wall falls back
# to the inscribed radius and so needs the margin after all. The shell is
# therefore per-slice, not per-run.
set _rp3 {{0.0 5.0 0} {1.0 6.0 1} {2.0 7.0 0}}
chk "a Requiv slice is not flagged fell-back" [::VMDPathFinder::_ionflow_fellback_at $_rp3 0.0] 0
chk "an escaped slice is" [::VMDPathFinder::_ionflow_fellback_at $_rp3 1.0] 1
chk "below the profile clamps to the first bin" [::VMDPathFinder::_ionflow_fellback_at $_rp3 -99.0] 0
chk "above it clamps to the last" [::VMDPathFinder::_ionflow_fellback_at $_rp3 99.0] 0
# A flag cannot be interpolated - a segment spanning both is treated as
# fell-back, so the margin is applied where it might be needed.
chk "a segment spanning a fell-back bin counts as fell-back" \
    [::VMDPathFinder::_ionflow_fellback_at $_rp3 0.5] 1
# BACKWARD COMPAT: an aggregate cached before the flag existed has 2-element
# entries and must behave exactly as before (no per-slice margin).
chk "a 2-element rprof reports no fell-back slices" \
    [::VMDPathFinder::_ionflow_fellback_at {{0.0 5.0} {1.0 6.0}} 0.5] 0
# The shell itself: base everywhere, base+user only at fell-back slices.
chk "a Requiv slice keeps the run-wide shell" \
    [::VMDPathFinder::_ionflow_shell_at $_rp3 0.0 0.0 3.0] 0.0
chk "an escaped slice gets the user's shell on top" \
    [::VMDPathFinder::_ionflow_shell_at $_rp3 1.0 0.0 3.0] 3.0
# CONTAINMENT: off CONNOLLY nothing is ever fell-back, so every slice returns
# the run-wide shell - identical to the single-shell behaviour this replaced.
set _rp2 {{0.0 5.0 0} {1.0 6.0 0}}
chk "spherical: every slice gets exactly the run-wide shell" \
    [list [::VMDPathFinder::_ionflow_shell_at $_rp2 0.0 3.0 3.0] \
          [::VMDPathFinder::_ionflow_shell_at $_rp2 1.0 3.0 3.0]] {3.0 3.0}
# The run-wide value keeps the method policy; the raw user value does not.
set _sv_pm7 $::VMDPathFinder::state(pore_method)
set _sv_ec7 [expr {[info exists ::VMDPathFinder::state(extra_cards)] ? $::VMDPathFinder::state(extra_cards) : ""}]
set _sv_sh7 [expr {[info exists ::VMDPathFinder::state(ion_flow_shell)] ? $::VMDPathFinder::state(ion_flow_shell) : 3.0}]
set ::VMDPathFinder::state(extra_cards) {}
set ::VMDPathFinder::state(ion_flow_shell) 3.0
set ::VMDPathFinder::state(pore_method) connolly
chk "CONNOLLY's run-wide shell is still 0 (grid sizing unchanged)" \
    [::VMDPathFinder::_ion_flow_shell_value] 0.0
chk "...but the user's configured shell is still readable for per-slice use" \
    [::VMDPathFinder::_ion_flow_user_shell] 3.0
set ::VMDPathFinder::state(pore_method) circular
chk "spherical's run-wide shell is the user's" [::VMDPathFinder::_ion_flow_shell_value] 3.0
set ::VMDPathFinder::state(pore_method) $_sv_pm7
set ::VMDPathFinder::state(extra_cards) $_sv_ec7
set ::VMDPathFinder::state(ion_flow_shell) $_sv_sh7

# --- Importing a run restores the pore method it was computed with -------------
# state(pore_method) is not persisted to the config, so a fresh VMD starts at
# "circular"; importing a CONNOLLY run without restoring it made every
# `_run_uses_card conn` gate read the run as spherical (wrong radius column, a
# shell that should be 0, blank lateral-opening views) - and the only apparent
# fix, moving the picker, calls _set_pore_method and CLEARS the import.
set _imp [info body ::VMDPathFinder::import_results_from_folder]
chk "import parses pore_method out of the manifest" \
    [expr {[regexp {\^pore_method} $_imp] ? 1 : 0}] 1
chk "...and assigns it directly, NOT via _set_pore_method (which clears results)" \
    [expr {[string first {set state(pore_method) $_pm} $_imp] >= 0}] 1
chk "...and re-gates the method-dependent controls afterwards" \
    [expr {[string first {_update_method_dependent_controls} $_imp] >= 0}] 1

# --- close_gui must stop a live playback watchdog, not just cancel the idle -----
# afters. start_play_watchdog reschedules itself every 400 ms while `playing` is
# set, independent of the ::vmd_frame trace close_gui otherwise tears down - so
# closing mid-playback used to leave it polling forever against a destroyed
# window. The rest of close_gui touches winfo/destroy (undefined under
# -dispdev text - see _have_tk), so it errors past this point here; the
# watchdog cancellation runs BEFORE that, so its effect is still checkable.
set ::VMDPathFinder::playing 1
set ::VMDPathFinder::vmd_last_frame_ms [clock milliseconds]
::VMDPathFinder::start_play_watchdog
set _wd_before $::VMDPathFinder::play_watchdog_after
catch {::VMDPathFinder::close_gui}
chk "a scheduled play_watchdog_after existed before close" \
    [expr {$_wd_before ne ""}] 1
chk "close_gui clears playing" $::VMDPathFinder::playing 0
chk "...and cancels the pending watchdog" $::VMDPathFinder::play_watchdog_after ""

# --- CONNOLLY openings list: cached to disk, filtered by persistence ----------
# The per-frame classification is ~170 ms per cloud, so a 100-frame run cost
# 20.8 s EVERY time the panel opened. The lobes are now written next to the
# run and re-pooled on load; measured 21.5 s cold, 12 ms off disk.
set _cst [info body ::VMDPathFinder::_conn_site_table]
chk "the openings table tries the disk cache first" \
    [expr {[string first {_load_conn_lobe_cache} $_cst] >= 0}] 1
chk "...and writes it after a complete pass" \
    [expr {[string first {_save_conn_lobe_cache} $_cst] >= 0}] 1
# Needle built with ESCAPED braces in a quoted word: an unescaped one inside
# expr {...} still counts toward that outer brace, which silently swallowed the
# rest of this file the first time.
set _needle "if \{!\$_aborted\} \{"
set _ai [string first $_needle $_cst]
chk "...but never after an aborted one" \
    [expr {$_ai >= 0 && [string first {_save_conn_lobe_cache} \
        [string range $_cst $_ai [expr {$_ai+200}]]] >= 0}] 1
chk "...and reports progress while it reads the clouds" \
    [expr {[string first {Finding lateral openings - frame} $_cst] >= 0}] 1
# An internal error must NOT be reported as "no openings" - that is a
# scientific answer standing in for a failure.
chk "a failed build reports failed, not empty" \
    [expr {[string first {dict create status failed reason $_err} $_cst] >= 0}] 1
chk "...and `failed` has its own message" \
    [expr {[string first {Could not find the openings} \
        [info body ::VMDPathFinder::_conn_site_status_note]] >= 0}] 1
# The pooling TOLERANCES are not in the cache signature: they combine cached
# per-frame lobes, so changing them must not re-read 100 clouds.
set _sig [info body ::VMDPathFinder::_conn_lobe_cache_sig]
chk "the cache signature covers the margin" \
    [expr {[string first {_conn_margin_tag} $_sig] >= 0}] 1
chk "...and the axis" [expr {[string first {state(cvect)} $_sig] >= 0}] 1
chk "...but NOT the pooling tolerances" \
    [expr {[string first {conn_lobe_tol} $_sig] < 0}] 1
# Persistence filter: 20 pooled sites on the real run, 3 of them seen once.
set ::VMDPathFinder::state(conn_lobe_minseen) 25
set _tbl [dict create frames {a b c d e f g h i j} \
    sites [list [list 0.0 0.0 9 {}] [list 1.0 0.0 3 {}] [list 2.0 0.0 1 {}]]]
chk "a site seen in 90% of frames is kept"  [::VMDPathFinder::_conn_site_persistent $_tbl 1] 1
chk "a site seen in 30% is kept"            [::VMDPathFinder::_conn_site_persistent $_tbl 2] 1
chk "a site seen in 10% is dropped"         [::VMDPathFinder::_conn_site_persistent $_tbl 3] 0
set ::VMDPathFinder::state(conn_lobe_minseen) 0
chk "a 0% threshold keeps everything"       [::VMDPathFinder::_conn_site_persistent $_tbl 3] 1
set ::VMDPathFinder::state(conn_lobe_minseen) 25
# The RENDER has to honour it too - a hidden site has no checkbox to switch off.
chk "the lobe render honours the persistence threshold" \
    [expr {[string first {_conn_site_persistent $table $sid} \
        [info body ::VMDPathFinder::_build_conn_lobes_plot]] >= 0}] 1
chk "...and so does the any-shown test" \
    [expr {[string first {_conn_site_persistent $table $sid} \
        [info body ::VMDPathFinder::_conn_any_site_shown]] >= 0}] 1
chk "...and it is part of the plot cache key" \
    [expr {[string first {_conn_lobe_min_seen} \
        [info body ::VMDPathFinder::_conn_lobes_tag]] >= 0}] 1
# An opening present in the shown frame but under the floor is drawn in its
# own grey region, never in the pore's colour - painted as pore, a fenestration
# open in few frames vanished into the pore on every frame it was open.
foreach _p {_conn_site_table _conn_frame_axis _conn_classify_cached _conn_frame_lobes
            _conn_lobe_site_map _build_conn_region_meshes _write_conn_multi_plot} {
    rename ::VMDPathFinder::$_p ::VMDPathFinder::_orig_$_p
}
namespace eval ::VMDPathFinder {
    proc _conn_site_table {} { return [dict create status ok frames {a b c d e f g h i j} \
        sites [list [list 0.0 0.0 9 {}] [list 1.0 0.0 1 {}]]] }
    proc _conn_frame_axis {f} { return [list {0 0 1} {0 0 0} {1 0 0 0 1 0}] }
    proc _conn_classify_cached {args} { return [dict create pore {P1 P2 P3 P4} \
        lateral {L1 L2 L3 L4 L5 L6 L7 L8 L9} keep {}] }
    proc _conn_frame_lobes {cls} { return [list [list 0.0 0.0 4 {0 1 2 3}] [list 1.0 0.0 4 {4 5 6 7}]] }
    proc _conn_lobe_site_map {table frame lobes} { return [dict create 0 1 1 2] }
    proc _build_conn_region_meshes {run_dir cls regions args} { set ::_regions $regions; return {} }
    proc _write_conn_multi_plot {parts out} { return 1 }
}
set ::_regions {}
set ::VMDPathFinder::state(conn_lobe_minseen) 25
catch {::VMDPathFinder::_build_conn_lobes_plot /tmp/x /tmp/x.sph 0 15 /tmp/x.vmd_plot -1}
set _rn {}; set _other_lines {}; set _pore_lines {}
foreach _r $::_regions {
    lappend _rn [lindex $_r 0]
    if {[lindex $_r 0] eq "other"} { set _other_lines [lindex $_r 1]; set _other_col [lindex $_r 2] }
    if {[lindex $_r 0] eq "pore"}  { set _pore_lines [lindex $_r 1] }
}
chk "a lobe whose site is under the floor becomes the grey `other` region" \
    [expr {"other" in $_rn && [info exists _other_col] && $_other_col eq "gray"}] 1
chk "...holding that lobe's dots" [lsort $_other_lines] {L5 L6 L7 L8}
chk "...which are NOT in the pore region" \
    [expr {[lsearch $_pore_lines L5] < 0 && [lsearch $_pore_lines L6] < 0}] 1
chk "...while lateral dots in no lobe at all still join the pore" \
    [expr {[lsearch $_pore_lines L9] >= 0}] 1
chk "...and the listed site keeps its own region" [expr {"site1" in $_rn}] 1
foreach _p {_conn_site_table _conn_frame_axis _conn_classify_cached _conn_frame_lobes
            _conn_lobe_site_map _build_conn_region_meshes _write_conn_multi_plot} {
    rename ::VMDPathFinder::$_p {}
    rename ::VMDPathFinder::_orig_$_p ::VMDPathFinder::$_p
}
# FocusOut fires on window-manager focus changes, so an unchanged commit must
# not wipe a 20 s table.
chk "an unchanged tolerance commit is a no-op" \
    [expr {[string first {_conn_lobe_tol_last eq $now} \
        [info body ::VMDPathFinder::_commit_conn_lobe_tol]] >= 0}] 1

# --- Per-region dot density: dot spacing scales with SPHERE RADIUS ------------
# ptgen.f puts 2*dotden dots on the great circle of a UNIT sphere, so one
# density samples a big sphere far more coarsely. Measured on a real frame:
# lobe spheres median 5.25 A against the pore's 1.34 A, giving 4289 triangles
# for the lobe against 82741 for the pore. Scaled, the same lobe rebuilds at
# 63190.
chk "a region of pore-sized spheres keeps the user's density" \
    [::VMDPathFinder::_conn_region_dotden 15 1.34 1.34] 15
chk "a region of smaller spheres is never scaled DOWN" \
    [::VMDPathFinder::_conn_region_dotden 15 0.5 1.34] 15
# Capped at 2x: a boundary-edge sweep on the worst lobe shows closure is
# reached by density 20-25 and does not improve above it, so the uncapped 59
# was 5x the build time and 5x the geometry for nothing.
chk "a 4x-radius region is capped at 2x the density" \
    [::VMDPathFinder::_conn_region_dotden 15 5.25 1.34] 30
chk "a 1.5x-radius region scales normally, under the cap" \
    [::VMDPathFinder::_conn_region_dotden 15 2.0 1.34] 22
chk "...and the cap tracks the user's own density" \
    [::VMDPathFinder::_conn_region_dotden 20 500.0 1.34] 40
chk "...still clamped at sph_process's own 100 limit" \
    [::VMDPathFinder::_conn_region_dotden 60 500.0 1.34] 100
chk "a missing reference radius changes nothing" \
    [::VMDPathFinder::_conn_region_dotden 15 5.25 0] 15
# Median must come from the GEOMETRIC radius column (55-60). Column 61-66 is
# 999.99 on 90% of lateral dots, which would peg every region at 100.
set _l1 "ATOM      1  QSS SPH S-999      -0.265   5.779 -16.606  1.15  4.57"
set _l2 "ATOM      1  QSS SPH S-999      -0.002   6.320 -16.626  5.25999.99"
chk "the median radius reads columns 55-60" \
    [::VMDPathFinder::_conn_median_sprad [list $_l1 $_l2 $_l2]] 5.25
chk "...not the 999.99 effective-radius column" \
    [expr {[::VMDPathFinder::_conn_median_sprad [list $_l1 $_l2 $_l2]] < 900}] 1
# The per-region density is in the mesh filename, or a rebuild reuses the
# coarse cached plot.
chk "the region mesh filename carries its density" \
    [expr {[string first {_d${_rdd}} \
        [info body ::VMDPathFinder::_build_conn_region_meshes]] >= 0}] 1
# colorize_by_sphere_values sizes its lookup grid as max_r + 2, so a 999.99
# radius collapsed the whole region into one cell.
chk "the region recolor reads the geometric radius, not 999.99" \
    [expr {[string first {string range $line 54 59} \
        [info body ::VMDPathFinder::_colorize_conn_region]] >= 0}] 1

# --- Property coloring follows PLAYBACK on a CONNOLLY draft mesh -------------
# It used to return {} for every draft frame, so the geometry moved and the
# colors did not until playback stopped.
set _bht [info body ::VMDPathFinder::build_hydro_trinorm]
chk "a draft frame with a mesh in hand still recolors" \
    [expr {[string first {$draft && [_is_large_conn_sph $sph_file] && ![surface_has_geometry $plot0]} \
        $_bht] >= 0}] 1
chk "...and writes to a draft-named file so the settle pass rebuilds" \
    [expr {[string first {append msuffix "_draft"} $_bht] >= 0}] 1
chk "...keyed on the BASE mesh, so no other method's filenames move" \
    [expr {[string first {string match "*_draft*.vmd_plot" $plot0} $_bht] >= 0}] 1

# --- The margin moved to the right of "Show nearby" --------------------------
set _brp [info body ::VMDPathFinder::build_run_panel]
chk "the margin entry is built on the Show nearby row" \
    [expr {[string first {entry $parent.showlining_box.mge} $_brp] >= 0}] 1
chk "...and no longer on the Color row" \
    [expr {[string first {hs_box.mge} $_brp] < 0}] 1
chk "the openings list is built AFTER Show nearby" \
    [expr {[string first {showlining_box.mb} $_brp] < \
           [string first {_build_conn_lobe_panel} $_brp]}] 1
chk "the openings panel spans the panel width, so its scrollbar reaches the edge" \
    [expr {[string first {-columnspan 3 -sticky ew -padx {8 2} -pady 2} \
        [info body ::VMDPathFinder::_build_conn_lobe_panel]] >= 0}] 1
# The canvas width is computed as "runpanel right - N - scrollbar", where N MUST
# equal the grid's right -padx above, or the canvas and the panel edge disagree.
chk "...and the width sizer subtracts that same right pad" \
    [expr {[string first {- 2 - $_sbw} \
        [info body ::VMDPathFinder::_sync_conn_lobe_width]] >= 0}] 1
chk "the margin's visibility follows its new parent" \
    [expr {[string first {showlining_box.mgl} \
        [info body ::VMDPathFinder::update_color_row_visibility]] >= 0}] 1

# --- Each opening picks its OWN property ------------------------------------
set ::VMDPathFinder::state(hydro_scheme) kd
catch {unset ::VMDPathFinder::state(conn_site_scheme,4)}
chk "an untouched row tracks the main Color row's scheme" \
    [::VMDPathFinder::_conn_site_scheme 4] kd
set ::VMDPathFinder::state(conn_site_scheme,4) ww
chk "...and its own once chosen" [::VMDPathFinder::_conn_site_scheme 4] ww
chk "...without disturbing its neighbour" [::VMDPathFinder::_conn_site_scheme 5] kd
catch {unset ::VMDPathFinder::state(conn_site_scheme,4)}
chk "the per-row scheme is in the plot cache key" \
    [expr {[string first {conn_site_scheme,*} \
        [info body ::VMDPathFinder::_conn_lobes_tag]] >= 0}] 1
chk "the region builder swaps that scheme in and restores it" \
    [expr {[string first {set state(hydro_scheme) $_sch_save} \
        [info body ::VMDPathFinder::_build_conn_region_meshes]] >= 0}] 1
chk "the panel no longer has one shared Property picker" \
    [expr {[string first {colormode.pm} \
        [info body ::VMDPathFinder::_build_conn_lobe_panel]] < 0}] 1

# --- The profile counts AXIAL stretches, and now says so ---------------------
# 3-4 axial stretches per frame against 4-8 lateral lobes on the same data:
# both right, different quantities. The old wording implied they should agree.
chk "the profile annotation says axial stretch, not opening" \
    [expr {[string first {axial stretch} [info body ::VMDPathFinder::draw_profile_tab]] >= 0}] 1
chk "...and so does the mean profile's" \
    [expr {[string first {axial stretch} [info body ::VMDPathFinder::_draw_mean_profile_body]] >= 0}] 1

# --- Mean Profile says it is working ----------------------------------------
# The cue belongs INSIDE the loop that takes the time. A cue wrapped around
# draw_mean_profile has to pump the event loop to paint, and it did so on the
# cached, instant draws too - where servicing a <Configure> cancels and
# reschedules other tabs' pending redraws (measured: it turned the tunnel-mode
# placeholder assertion red, and disabling the cue turned it green again).
set _cbr [info body ::VMDPathFinder::collect_binned_radii]
# A cue on the CANVAS, not only the status bar: the first pass for a run reads
# every frame's TSV and the tab otherwise sits on an empty axis box. It adds no
# update of its own - collect_binned_radii already pumps inside its per-frame
# loop, and that loop only runs on a cache MISS, so the cue appears exactly when
# there is something to wait for. An earlier version pumped here unconditionally
# and broke the tunnel-mode placeholder.
set _dmb2 [info body ::VMDPathFinder::_draw_mean_profile_body]
chk "the mean profile paints a calculating note on the canvas" \
    [expr {[string first {-tags meancalc} $_dmb2] >= 0}] 1
chk "...before the data call, not after" \
    [expr {[string first {-tags meancalc} $_dmb2] < \
           [string first {collect_binned_radii $nbins} $_dmb2]}] 1
chk "...and clears it once the data is in hand" \
    [expr {[llength [regexp -all -inline {delete meancalc} $_dmb2]] >= 2}] 1
# It must reach BOTH carriers and re-grid NEITHER. Arriving on the tab the
# placeholder is the gridded one; revisiting with a plot drawn, the canvas is.
# Re-gridding to make room resizes the notebook, and the <Configure> that fires
# on the sibling shared tabs re-arms their deferred redraws, which then land
# mid-mode-switch and mislabel those tabs' placeholders.
set _cuehead [string range $_dmb2 0 [string first {-tags meancalc} $_dmb2]]
chk "...on the placeholder too, so a cold tab switch shows it" \
    [expr {[string first {$tab.placeholder configure -text "Calculating} $_cuehead] >= 0}] 1
chk "...and the cue re-grids nothing" \
    [expr {[string first {grid $tab.cv} $_cuehead] < 0 \
        && [string first {grid remove $tab.placeholder} $_cuehead] < 0}] 1
# The progress line names the panel that ASKED, not this proc: collect_binned_radii
# is shared by the Mean Profile, the Radius Histogram and Over Time, and the old
# hard-coded "Mean profile:" made an Over Time compute announce the wrong panel in
# the one shared status line. It must also CLEAR when the pass ends, or it dangles
# over every tab afterwards.
chk "the binner reports progress while reading frames" \
    [expr {[string first {$_label: frame $_seen of $_nuf} $_cbr] >= 0}] 1
chk "...labelled with the panel that asked, not a fixed name" \
    [expr {[string first {_binned_radii_caller_label} $_cbr] >= 0}] 1
chk "...and cleared when the pass finishes, so it cannot dangle" \
    [expr {[string first {set state(status) ""} $_cbr] >= 0}] 1
chk "...on an ordinary run, not only a very long one" \
    [expr {[string first {set _prog [expr {$_nuf >= 25}]} $_cbr] >= 0}] 1
chk "...and draw_mean_profile does NOT pump the event loop itself" \
    [expr {[string first {update} [info body ::VMDPathFinder::draw_mean_profile]] < 0}] 1
# The "Calculating the mean profile..." cue must not DANGLE. The body sets it and
# deletes its canvas cue when done, but never touched the status bar - one shared
# line for the whole plugin, so it sat there over every tab afterwards. The
# wrapper saves the previous text and puts it back: a plain clear would blank a
# run summary the user still needed, because the body overwrites the line
# unconditionally and the old text is already gone by then.
set _dmp [info body ::VMDPathFinder::draw_mean_profile]
chk "draw_mean_profile saves the status line before drawing" \
    [expr {[string first {set _sv_status} $_dmp] >= 0}] 1
chk "...and restores it, rather than blanking whatever was there" \
    [expr {[string first {set state(status) $_sv_status} $_dmp] >= 0}] 1
chk "draw_mean_profile refuses to re-enter itself" \
    [expr {[string first {_mean_profile_drawing} \
        [info body ::VMDPathFinder::draw_mean_profile]] >= 0}] 1

# --- Mean Profile: fallback flags are per-BIN, the plotted points are a subset -
# `fallback` has one flag per bin over the whole grid; the plot skips empty bins
# and, since the coverage floor landed, thin ones too. Lining the two up
# positionally misaligned them, and the length guard then cleared the list
# outright - so one skipped bin silently removed BOTH the grey
# spherical-fallback segments and the sideways-opening marks from the plot.
set _dmp [info body ::VMDPathFinder::_draw_mean_profile_body]
set _needle2 "foreach _b \$bins \{ lappend _fb"
chk "the fallback flags are re-indexed through the plotted bins" \
    [expr {[string first $_needle2 $_dmp] >= 0}] 1
chk "...and the length guard that hid them is gone" \
    [expr {[string first {if {[llength $_fb] == $npt}} $_dmp] < 0}] 1

# --- colorize_by_sphere_values: small sphere counts skip the grid ------------
# The partition only pays when it can EXCLUDE spheres. Every caller thins to a
# few hundred, and at that size the search expands through hundreds of EMPTY
# cells. Measured on a 12k-triangle mesh with 300 spheres, output byte-identical
# at every cell size: 3.0 A 167.1 s | 3.4 A 108.8 s | 8.1 A (the old max_r+2)
# 9.0 s | 13.5 A 3.7 s | one cell 1.9 s.
set _cbs [info body ::VMDPathFinder::colorize_by_sphere_values]
chk "a small sphere set collapses to a single cell" \
    [expr {[string first {llength $spheres] <= 2000} $_cbs] >= 0}] 1
chk "...sized from the sphere spread, not from max_r alone" \
    [expr {[string first {set _one [expr {$_span + 2.0*$max_r + 1.0}]} $_cbs] >= 0}] 1
chk "...and never SHRINKS the cell below the original rule" \
    [expr {[string first {if {$_one > $scell} { set scell $_one }} $_cbs] >= 0}] 1

# --- Openings list rebuild: tunnel-mode shape --------------------------------
# Unticking every region used to fall back to the PLAIN Connolly surface, so
# turning the last box off appeared to switch the whole surface ON.
set _cpb [info body ::VMDPathFinder::_create_plot_asset_body]
chk "every region unticked draws nothing, not the full surface" \
    [expr {[string first {dict create kind lobes_none} $_cpb] >= 0}] 1
chk "...and so does 'the ticked openings are not on this frame'" \
    [expr {[llength [regexp -all -inline {kind lobes_none} $_cpb]] == 2}] 1
chk "...and the old 'showing the plain surface' wording is gone" \
    [expr {[string first {showing the plain surface} $_cpb] < 0}] 1
chk "the no-surface asset clears the surface mol" \
    [expr {[string first {lobes_none} [info body ::VMDPathFinder::load_surface_for_frame]] >= 0}] 1

# Presence in the displayed frame, from the site's own instance list.
set _inst {{7 0 100 0.5 6.0 2.0} {9 1 80 0.4 5.0 1.0}}
chk "a site instanced on this frame is present"     [::VMDPathFinder::_conn_lobe_present $_inst 7] 1
chk "...and one that is not, is not"                [::VMDPathFinder::_conn_lobe_present $_inst 8] 0
chk "no displayed frame means not present"          [::VMDPathFinder::_conn_lobe_present $_inst ""] 0

# Sort comparator: missing data sinks whichever way the column is sorted.
set _a [dict create sid 1 seen 90.0 esc 10.0 neck 5.0]
set _b [dict create sid 2 seen 20.0 esc 50.0 neck ""]
chk "descending puts the larger first"  [::VMDPathFinder::_conn_lobe_cmp seen -1 $_a $_b] -1
chk "ascending reverses it"             [::VMDPathFinder::_conn_lobe_cmp seen  1 $_a $_b]  1
chk "a blank neck sinks when descending" [::VMDPathFinder::_conn_lobe_cmp neck -1 $_a $_b] -1
chk "...and still sinks when ascending"  [::VMDPathFinder::_conn_lobe_cmp neck  1 $_a $_b] -1
chk "two blanks tie"                     [::VMDPathFinder::_conn_lobe_cmp neck  1 $_b $_b]  0
# Sort order must NOT reach the plot cache key: it changes row order only, not
# which regions are drawn or in what color.
chk "the sort key is absent from the plot tag" \
    [expr {[string first {conn_lobe_sort} [info body ::VMDPathFinder::_conn_lobes_tag]] < 0}] 1

# Select-all works on the DISPLAYED rows only - a sid hidden by the persistence
# floor has no row, so toggling it would change a region behind the user's back.
set _tga [info body ::VMDPathFinder::_conn_lobe_toggle_all]
chk "select-all walks the displayed row list" \
    [expr {[string first {_conn_lobe_rows $table} $_tga] >= 0}] 1
chk "...and includes the pore row" \
    [expr {[string first {state(conn_site_show,0) $want} $_tga] >= 0}] 1
chk "the select-all box is re-derived, not driven blindly" \
    [expr {[string first {_conn_lobe_sync_all_box} \
        [info body ::VMDPathFinder::_refresh_conn_lobes_panel]] >= 0}] 1
chk "...and its sync cannot re-fire its own command" \
    [expr {[string first {_conn_lobe_all_syncing} \
        [info body ::VMDPathFinder::_on_conn_lobe_all_clicked]] >= 0}] 1

# Row presentation
set _rp [info body ::VMDPathFinder::_conn_lobe_row_panel]
chk "Seen is colored green/red by presence" \
    [expr {[string first {$present ? "#2a9d3f" : "#c0392b"} $_rp] >= 0}] 1
chk "the region name is a color-filled swatch" \
    [expr {[string first {-background [_vmd_color_hex [_conn_site_color $sid]]} $_rp] >= 0}] 1
# FUNCTIONAL, not string-matched: the pore's row picker used to write
# conn_site_colormode,0 while the render read conn_color_pore, so changing the
# Pore row's color did nothing at all. One resolver now, and the render calls
# it too.
catch {unset ::VMDPathFinder::state(conn_site_colormode,0)}
catch {unset ::VMDPathFinder::state(conn_color_pore)}
chk "the pore's default color is the pore color, not palette index -1" \
    [::VMDPathFinder::_conn_site_color 0] "blue"
set ::VMDPathFinder::state(conn_site_colormode,0) red
chk "...and its row picker actually changes it" [::VMDPathFinder::_conn_site_color 0] "red"
catch {unset ::VMDPathFinder::state(conn_site_colormode,0)}
chk "the lobes render resolves the pore through that same accessor" \
    [expr {[string first {[list pore [dict get $cls pore] [_conn_site_color 0]} \
        [info body ::VMDPathFinder::_build_conn_lobes_plot]] >= 0}] 1
chk "reset puts every region back to auto" \
    [expr {[string first {foreach k [array names state conn_site_colormode,*] { set state($k) "" }} \
        [info body ::VMDPathFinder::_conn_lobe_reset_colors]] >= 0}] 1
chk "...and clears the per-row property choice too" \
    [expr {[string first {conn_site_scheme,*} \
        [info body ::VMDPathFinder::_conn_lobe_reset_colors]] >= 0}] 1
# The gear must be the LAST column, whatever that number happens to be. The
# guards used to search for a literal "-column 7" and so failed the moment an
# Ions column was added between the data and the gear - even though the gear
# was still last, which is the property they exist to protect.
proc _max_col {body} {
    set m -1
    foreach {_all n} [regexp -all -inline {-column ([0-9]+)} $body] {
        if {$n > $m} { set m $n }
    }
    return $m
}
proc _col_of {body pat} {
    if {[regexp "$pat\\s+-row\\s+\\S+\\s+-column\\s+(\[0-9\]+)" $body -> n]} { return $n }
    return -1
}
chk "rows start with the show checkbox and END with their own gear" \
    [expr {[string first {grid $f.sh$sid -row $r -column 0} $_rp] >= 0 \
        && [_col_of $_rp {grid \$f\.gr\$sid}] == [_max_col $_rp]
        && [_col_of $_rp {grid \$f\.gr\$sid}] > 0}] 1
chk "openings are labelled OP<n>, not 'Opening <n>'" \
    [expr {[string first {"OP$sid"} \
        [info body ::VMDPathFinder::_refresh_conn_lobes_panel]] >= 0}] 1
chk "Seen is a percentage, with no n/nf ratio beside it" \
    [expr {[string first {format "%.0f%%" [dict get $row seen]} \
        [info body ::VMDPathFinder::_refresh_conn_lobes_panel]] >= 0}] 1
chk "the list canvas stretches to the panel edge" \
    [expr {[string first {_sync_conn_lobe_width} \
        [info body ::VMDPathFinder::_refresh_conn_lobes_panel]] >= 0}] 1
# Cells are gridded straight into the SHARED inner frame. A per-row sub-frame
# makes the body a one-column grid, so the header has nothing to line up
# against - that is what "the columns are gone practically" was.
chk "row cells are gridded into the shared frame, not a per-row sub-frame" \
    [expr {[string first {grid $f.se$sid -row $r -column 2} \
        [info body ::VMDPathFinder::_conn_lobe_row_panel]] >= 0}] 1
chk "...so the body grid really has multiple columns" \
    [expr {[string first {grid $f.st$sid -row $r -column 4} \
        [info body ::VMDPathFinder::_conn_lobe_row_panel]] >= 0}] 1
# Neck and Stretch are two measurements, so they get two columns now that the
# per-row dropdowns have moved into the gear and freed the width.
chk "Neck and Stretch are separate columns" \
    [expr {[string first {grid $f.nk$sid -row $r -column 3} \
        [info body ::VMDPathFinder::_conn_lobe_row_panel]] >= 0 \
        && [string first {grid $f.st$sid} \
        [info body ::VMDPathFinder::_conn_lobe_row_panel]] >= 0}] 1
chk "...and the row carries no color/property dropdown any more" \
    [expr {[string first {_color_menu $f.co$sid} \
        [info body ::VMDPathFinder::_conn_lobe_row_panel]] < 0}] 1
# One percentage column, not two: Escaped was 94-100% for every opening on a
# real run, so it never told two of them apart. It lives on hover now.
chk "Escaped is no longer a column" \
    [expr {[string first {$f.es$sid} \
        [info body ::VMDPathFinder::_conn_lobe_row_panel]] < 0}] 1
chk "...and is carried in the row tooltip instead" \
    [expr {[string first {ran out into open space} \
        [info body ::VMDPathFinder::_refresh_conn_lobes_panel]] >= 0}] 1
chk "the neck shows both figures again" \
    [expr {[string first {append necktxt [format " / %.1f" $nb]} \
        [info body ::VMDPathFinder::_refresh_conn_lobes_panel]] >= 0}] 1
chk "...and the second one is carried through the row dict" \
    [expr {[string first "neckb " [info body ::VMDPathFinder::_conn_lobe_rows]] >= 0}] 1
chk "the header columns are pinned to the body's" \
    [expr {[string first {_sync_conn_lobe_header_columns} \
        [info body ::VMDPathFinder::_refresh_conn_lobes_panel]] >= 0}] 1
# Row widgets are keyed on the SITE, so a re-sort re-grids rather than
# relabelling someone else's row.
chk "row trimming tracks sids, not row numbers" \
    [expr {[string first {_conn_lobe_pass_sids} \
        [info body ::VMDPathFinder::_conn_lobe_trim_rows]] >= 0}] 1

# --- Follow-ups on the openings list ----------------------------------------
# Margin only means anything while a coloring actually draws the pore/lateral
# boundary; under any other Color it changed nothing visible.
set _ucr [info body ::VMDPathFinder::update_color_row_visibility]
chk "the margin is tied to the split colorings, not just to CONNOLLY" \
    [expr {[string first {$state(surface_color) in {pore_lat pore_lobes}} $_ucr] >= 0}] 1
# auto is the default most rows keep, so it leads the row menu.
chk "the gear color menu lists auto before Property" \
    [expr {[string first {[list auto Property]} \
        [info body ::VMDPathFinder::_conn_gear_dialog]] >= 0}] 1
# Reset moved out of the header strip - which kept being pushed off the panel's
# right edge - into the global gear, where it cannot be displaced.
chk "reset lives in the global gear, not a header strip" \
    [expr {[string first {_conn_lobe_reset_colors} \
        [info body ::VMDPathFinder::_conn_gear_dialog]] >= 0}] 1
chk "the global gear sits in the list header's last column" \
    [expr {[set _bp [info body ::VMDPathFinder::_build_conn_lobe_panel]]
            [_col_of $_bp {grid \$d\.hdr\.gg}] == [_max_col $_bp]
            && [_col_of $_bp {grid \$d\.hdr\.gg}] > 0}] 1
chk "...and hosts the matching tolerance and persistence entries" \
    [expr {[string first {conn_lobe_tolz} [info body ::VMDPathFinder::_conn_gear_dialog]] >= 0 \
        && [string first {conn_lobe_minseen} [info body ::VMDPathFinder::_conn_gear_dialog]] >= 0}] 1
# --- Mean Profile occupancy VOLUME (Connolly, opt-in) -----------------------
# The volume is accumulated in a registered (axis+azimuth) frame; drawing it
# there puts it rotated and offset from the protein, so it must be mapped back
# to WORLD before it is meshed.
chk "the volume is mapped back to world coordinates before meshing" \
    [expr {[string first {_mean_vol_ref_axis} [info body ::VMDPathFinder::_mean_vol_build]] >= 0}] 1
chk "...using the placement axis, not the raw registered z" \
    [expr {[string first {$ox + $a*$e1x + $b*$e2x + $t*$ux} \
        [info body ::VMDPathFinder::_mean_vol_all_centers]] >= 0}] 1
chk "...so the axial lookups project onto that axis" \
    [expr {[string first {($px-$ox)*$ux} [info body ::VMDPathFinder::_mean_vol_band_prop_plot]] >= 0 \
        && [string first {($cx-$ox)*$ux} [info body ::VMDPathFinder::_mean_vol_holedef_plot_body]] >= 0}] 1
# The knobs describe a volume that is not built until the box is ticked.
chk "the volume knobs appear with the checkbox" \
    [expr {[string first {set _volon} [info body ::VMDPathFinder::_sync_mean_settings_lock]] >= 0}] 1
# One property, one colouring engine: the pore used the compiled hydro3d route
# and the openings a pure-Tcl per-sphere one, so a single surface carried two
# different colourings and neither matched plain "property".
# Targeted at the COLOURING branch: the surviving `$name eq "pore"` in this
# proc is a different decision (only the pore region gets the centreline
# spheres written into its .sph, so lobes do not each embed a copy of it).
# Built without braces in the needle - Tcl counts braces inside quoted strings
# too, so an unbalanced one in an expr body aborts the whole script.
set _brm [info body ::VMDPathFinder::_build_conn_region_meshes]
set _i0 [string first "set _done 0" $_brm]
# from _i0, or the mention in the comment ABOVE set _done 0 is found first
set _i1 [string first "build_hydro_trinorm" $_brm $_i0]
set _gap ""
if {$_i0 >= 0 && $_i1 > $_i0} { set _gap [string range $_brm $_i0 $_i1] }
chk "every Connolly region is coloured by the same engine" \
    [expr {$_i0 >= 0 && $_i1 > $_i0 && [string first "name eq" $_gap] < 0}] 1
# The volume section explains itself through its tooltips, not a grey paragraph.
chk "the volume section carries no explanatory grey label" \
    [expr {[string first {vnote} [info body ::VMDPathFinder::show_mean_profile_settings]] < 0}] 1
# Every region is LINED against the whole classified cloud, never its own
# sub-cloud. A region's .sph is the geometry its MESH came from; lining against
# it drops residues that reach the pore through a lateral opening, and the same
# property then paints a different colour than it does on the undivided
# surface. Measured on frame 5 against plain "property": 66.2% agreement with
# each region on its own cloud, 97.2% with this one (and 99.9% of the residual
# is a single colour bin, i.e. the different tessellation).
set _brm2 [info body ::VMDPathFinder::_build_conn_region_meshes]
# One colour change must render ONCE. Rendering pumps the event loop, which
# let a queued apply fire mid-render and render again: measured 3 renders and
# 1780 ms for one hole_def -> property switch, 1 render and 591 ms after.
set _adc [info body ::VMDPathFinder::apply_display_change]
chk "apply_display_change refuses to re-enter itself" \
    [expr {[string first {_display_applying} $_adc] >= 0}] 1
chk "...deferring a nested request instead of dropping it" \
    [expr {[string first {_display_apply_again} $_adc] >= 0}] 1
chk "...and running that deferred pass only if the state actually moved" \
    [expr {[string first {_display_state_sig} $_adc] >= 0}] 1
# The signature must cover flat colours too: two of them share a geometry key,
# so keying the deferred pass on the geometry alone would drop a green -> blue
# made mid-render.
chk "the display signature covers colour, not just geometry" \
    [expr {[string first {surface_color} [info body ::VMDPathFinder::_display_state_sig]] >= 0}] 1
chk "...and the real work moved to its own proc" \
    [expr {[llength [info procs ::VMDPathFinder::_apply_display_change_now]] == 1}] 1
# Priming the property for Over Time / the panels must warm the SAME per-frame
# atoms sidecar the surface recolour reads, not a scratch copy that is deleted.
set _pri [info body ::VMDPathFinder::_prime_hydro3d_props_impl]
chk "the property prime caches its sidecar where the surface looks" \
    [expr {[string first {hole_hydro_atoms3d_} $_pri] >= 0}] 1
chk "...in the frame's run_dir" \
    [expr {[string first {run_dir} $_pri] >= 0}] 1
chk "...reusing an existing one rather than rewriting it" \
    [expr {[string first {file mtime $_sc_shared} $_pri] >= 0}] 1
# The binary-free path must line against the same cloud. colorize_hydrophobic
# colours by nearest CENTRELINE sphere, and a region .sph carries none (they go
# to the pore alone), so it was handed an empty sphere set, copied the base mesh
# through, and every lobe rendered ONE FLAT COLOUR. Measured with the binaries
# blanked: 8 of 8 lobes flat before, 6 of 8 with real gradients after.
# Needles carry no braces or backslashes: Tcl counts braces inside quoted
# strings, and a trailing backslash before a closing brace unbalances the whole
# expr - which aborts the script rather than failing the assertion.
set _bht2 [info body ::VMDPathFinder::build_hydro_trinorm]
set _ci [string first "colorize_hydrophobic" $_bht2]
set _li [expr {$_ci >= 0 ? [string first {$lsph $molid $frame} $_bht2 $_ci] : -1}]
chk "the Tcl colouring fallback uses the shared lining cloud too" \
    [expr {$_ci >= 0 && $_li > $_ci}] 1
# Both surface stages route through the ONE command builder that switches to
# the inlined Tcl engine, so no call site can miss the fallback.
chk "run_sph_process routes through the fallback builder" \
    [expr {[string first {_sph_process_cmd} [info body ::VMDPathFinder::run_sph_process]] >= 0}] 1
# --- Every cache is registered -------------------------------------------------
# cache_clear is the one place a cache is dropped; a cache variable the
# registry does not know cannot be cleared by any tag and rots.
set _src [read [set _fh [open [file join $here .. vmdpathfinder.tcl] r]]]; close $_fh
set _declared {}
foreach {_m _n} [regexp -all -inline {variable (_?[a-z_0-9]*cache[a-z_0-9]*|_[a-z_0-9]*_memo)\M} $_src] {
    if {$_n ne "_caches" && $_n ni $_declared} { lappend _declared $_n }
}
set _reg [dict keys $::VMDPathFinder::_caches]
set _unreg {}; foreach _n $_declared { if {$_n ni $_reg} { lappend _unreg $_n } }
set _ghost {}; foreach _n $_reg { if {![regexp "variable $_n\\M" $_src]} { lappend _ghost $_n } }
chk "every cache variable in the plugin is in the cache registry ($_unreg)" [llength $_unreg] 0
chk "every registered cache exists in the plugin ($_ghost)" [llength $_ghost] 0
chk "cache_clear refuses an unknown name" [catch {::VMDPathFinder::cache_clear no_such_cache}] 1
set ::VMDPathFinder::plot_cache_order {a b}; ::VMDPathFinder::cache_clear plot
chk "cache_clear plot empties the plot trio" [llength $::VMDPathFinder::plot_cache_order] 0

chk "run_sos_triangle routes through the fallback builder" \
    [expr {[string first {_sos_triangle_cmd} [info body ::VMDPathFinder::run_sos_triangle]] >= 0}] 1
# ...and the newest features use those entry points rather than their own exec.
chk "the mean occupancy volume goes through the one surface pipeline" \
    [expr {[string first {surface_mesh $sph $raw draw} [info body ::VMDPathFinder::_mean_vol_mesh]] >= 0}] 1
chk "regions are lined against one shared whole-cloud reference" \
    [expr {[string first {hole_conn_lining_} $_brm2] >= 0}] 1
chk "...built from keep + pore + lateral, not one region" \
    [expr {[string first {foreach _k {keep pore lateral}} $_brm2] >= 0}] 1
chk "...and handed to every region's recolour" \
    [expr {[string first {"_rgn$name" $rlin} $_brm2] >= 0}] 1
chk "...via a reference that is separate from the mesh's own cloud" \
    [expr {[lsearch -exact [info args ::VMDPathFinder::build_hydro_trinorm] lining_sph] >= 0}] 1
chk "...which is the compiled route the main surface uses" \
    [expr {[string first {build_hydro_trinorm} \
        [info body ::VMDPathFinder::_build_conn_region_meshes]] >= 0}] 1
# Openings present in a frame but filtered by the pooled list must be reported,
# not silently missing next to the per-frame pore+lateral colouring.
chk "openings dropped for this frame are counted" \
    [expr {[string first {_conn_lobe_frame_drops} \
        [info body ::VMDPathFinder::_build_conn_lobes_plot]] >= 0}] 1
chk "...and said out loud in the openings panel" \
    [expr {[string first {_conn_lobe_frame_drop_note} \
        [info body ::VMDPathFinder::_refresh_conn_lobes_panel]] >= 0}] 1

# The CPOINT cue must follow the field even with Track/Stabilize on, and the
# CVECT arrow with Stabilize-CVECT on. All three derive the per-frame value
# from refs _stab_init captured from CPOINT/CVECT-def-p1/p2/the molecule in
# force at the time, so a later edit to ANY of the four left the cue drawing
# a stale one - CVECT-def and the molecule are independently editable from
# CPOINT, so tracking CPOINT drift alone missed both.
set _ear [info body ::VMDPathFinder::_ensure_axis_refs]
chk "the axis refs remember which CPOINT they were built from" \
    [expr {[string first {_axis_refs_cp} $_ear] >= 0}] 1
chk "...and are rebuilt when the field no longer matches" \
    [expr {[string first {$_axis_refs_cp ne $_cp_now} $_ear] >= 0}] 1
chk "...tracking CVECT-Stabilize's def points too" \
    [expr {[string first {_axis_refs_p1} $_ear] >= 0 \
        && [string first {_axis_refs_p2} $_ear] >= 0}] 1
chk "...and the molecule the refs were resolved against" \
    [expr {[string first {_axis_refs_molid} $_ear] >= 0}] 1
chk "...debounced, since a keystroke trace reaches this" \
    [expr {[string first {after 150} $_ear] >= 0 \
        && [string first {after cancel} $_ear] >= 0}] 1
set _sti [info body ::VMDPathFinder::_stab_init]
chk "...with _stab_init stamping all four values it captured" \
    [expr {[string first {_axis_refs_cp} $_sti] >= 0 \
        && [string first {_axis_refs_molid} $_sti] >= 0 \
        && [string first {_axis_refs_p1} $_sti] >= 0 \
        && [string first {_axis_refs_p2} $_sti] >= 0}] 1

# The per-frame trace must not outlive both the panel AND the surface it draws
# - but must also not die BEFORE any surface has ever existed (display_mode
# none, or headless with no run yet): those are the same "no live surface"
# state but need opposite outcomes, so a THIRD check (was one ever assigned
# at all) has to separate them. "Keep visualization on close" leaves the
# trace installed on purpose so a kept surface still follows frames; once the
# user deletes that surface, load_surface_for_frame would recreate the
# molecule and rebuild a surface every frame forever.
set _fc [info body ::VMDPathFinder::frame_changed]
chk "the frame trace stops when the panel is shut and no surface is left" \
    [expr {[string first {![_panel_is_open] && [_any_surface_ever_assigned] && ![_any_live_surface_mol]} $_fc] >= 0 \
        && [string first {remove_frame_trace; return} $_fc] >= 0}] 1
chk "...and a withdrawn panel counts as shut, not merely destroyed" \
    [expr {[string first {winfo ismapped} [info body ::VMDPathFinder::_panel_is_open]] >= 0}] 1
chk "...checking tunnel tracks too, not just the HOLE one" \
    [expr {[string first {tunnel_surface_mols} [info body ::VMDPathFinder::_any_live_surface_mol]] >= 0}] 1
chk "...and the reshaped-ellipse surface, a fourth independent track" \
    [expr {[string first {ellipse_surface_mol} [info body ::VMDPathFinder::_any_live_surface_mol]] >= 0}] 1
chk "...distinguishing 'never had one' from 'had one, now gone'" \
    [expr {[string first {ellipse_surface_mol} \
        [info body ::VMDPathFinder::_any_surface_ever_assigned]] >= 0}] 1

# The mixed-pore-method badge has to be true at DRAW time, not trusted from
# whatever a caller last wrote - an import or a dropped frame left it stale
# (or unset) over a curve that really did average two methods together.
# Matched against the actual assignment statements, not a bare mention of
# either proc name: both names also appear in this proc's own comments, so
# a weaker [string first] here would still pass with the assignments deleted.
set _mmn [info body ::VMDPathFinder::_draw_method_mismatch_note]
chk "the mixed-method badge computes itself when it draws" \
    [expr {[string first {set _method_mismatch_summary [_result_frames_method_summary]} $_mmn] >= 0}] 1
chk "...memoised on plot_data_version, not recomputed per redraw" \
    [expr {[string first {set _method_mismatch_ver $plot_data_version} $_mmn] >= 0}] 1
chk "...and _redisplay_results_list no longer duplicates that work" \
    [expr {[string first {set _method_mismatch_summary} \
        [info body ::VMDPathFinder::_redisplay_results_list]] < 0}] 1

# An UNTICKED opening must still be MESHED. _split_conn_mesh_by_region assigns
# every triangle to its nearest classified dot among the regions it is handed,
# so omitting a region does not remove its geometry - it redistributes it into
# whatever is left. Measured on Nav frame 0 before this: an opening drawn beside
# the pore and its four neighbours is 168 triangles; drawn alone it took 7122,
# the whole surface, and the pore took the other openings' triangles (86183 ->
# 94466). The user-visible form is an opening's colour bleeding across the main
# pore, and only while playing - stopping, ticking everything, then re-ticking
# the one opening re-split the full set and cached the right meshes back.
set _bclp [info body ::VMDPathFinder::_build_conn_lobes_plot]
chk "an unticked opening is still meshed, not skipped" \
    [expr {[string first {![_conn_site_shown $sid] ||} $_bclp] < 0}] 1
chk "...and so is the pore, carrying a shown flag rather than being left out" \
    [expr {[string first {[_conn_site_shown 0] ? 1 : 0} $_bclp] >= 0}] 1
chk "...as does every opening" \
    [expr {[string first {[_conn_site_shown $sid] ? 1 : 0} $_bclp] >= 0}] 1
chk "...with nothing ticked still drawing nothing" \
    [expr {[string first {_anyshown} $_bclp] >= 0}] 1
set _brm3 [info body ::VMDPathFinder::_build_conn_region_meshes]
chk "the mesh builder tracks which regions are drawn" \
    [expr {[string first {shown_of} $_brm3] >= 0}] 1
chk "...and emits only those" \
    [expr {[string first {![dict get $shown_of $name]} $_brm3] >= 0}] 1
# Ion Flow's 3D membership test must cover all three pore methods.
set _ifs [info body ::VMDPathFinder::_ion_flow_scan]
chk "Ion Flow builds its 3D sphere set for capsule" \
    [expr {[string first {_capsule_surface_spheres} $_ifs] >= 0}] 1
chk "...for Connolly" [expr {[string first {_conn_ionflow_spheres_fast} $_ifs] >= 0}] 1
chk "...and for spherical" [expr {[string first {parse_sph_centerline} $_ifs] >= 0}] 1
chk "the occupancy volume is OFF by default" $::VMDPathFinder::state(mean_vol_enabled) 0
chk "...and refuses to claim a non-Connolly run" \
    [expr {[string first {_run_uses_card conn} \
        [info body ::VMDPathFinder::_mean_vol_enabled]] >= 0}] 1
# REGIONS, not global persistence bands. A single threshold across everything
# cannot separate a lateral opening from the lumen breathing - measured, 74.8%
# of a 60-90% band was pore interior sitting 1.5 A outside the core's own
# median radius. Each region is averaged against its own frames instead.
chk "regions come from the SAME pooled openings the Openings list shows" \
    [expr {[string first {_conn_site_persistent} [info body ::VMDPathFinder::_mean_vol_sites]] >= 0}] 1
# Regions are an AVERAGING unit, not a colouring scheme: they merge into one
# surface driven by the Mean Profile's own Colour/Material, so the volume must
# NOT reach into the openings list's per-region colour or show/hide.
chk "the volume does not borrow the openings list's colours" \
    [expr {[string first {_conn_site_color} [info body ::VMDPathFinder::_mean_vol_build]] < 0}] 1
chk "...nor its show/hide" \
    [expr {[string first {_conn_site_shown} [info body ::VMDPathFinder::_mean_vol_build]] < 0}] 1
chk "...and every region's voxels go into one surface" \
    [expr {[string first {_mean_vol_all_centers} [info body ::VMDPathFinder::_mean_vol_build]] >= 0}] 1
chk "each region is normalised by the frames IT appears in" \
    [expr {[string first {seen($sid)} [info body ::VMDPathFinder::_mean_vol_fields]] >= 0}] 1
chk "...and smoothed on its own field, so one region cannot bleed into another" \
    [expr {[string first {_mean_vol_smooth $norm} [info body ::VMDPathFinder::_mean_vol_fields]] >= 0}] 1
# The pore and an opening carry SEPARATE floors - they are different kinds of
# component, and one number cannot serve both.
set _svt  $::VMDPathFinder::state(mean_vol_thresh)
set _svto $::VMDPathFinder::state(mean_vol_thresh_open)
chk "the pore floor and the opening floor are separate" \
    [expr {[::VMDPathFinder::_mean_vol_thresh 0] != [::VMDPathFinder::_mean_vol_thresh 1]}] 1
chk "the pore floor defaults to 0.5" [::VMDPathFinder::_mean_vol_thresh 0] 0.5
chk "the opening floor defaults to the 30% detection floor" [::VMDPathFinder::_mean_vol_thresh 1] 0.3
set ::VMDPathFinder::state(mean_vol_thresh) 99
chk "a floor outside 0-1 is clamped" [expr {[::VMDPathFinder::_mean_vol_thresh 0] <= 0.95}] 1
set ::VMDPathFinder::state(mean_vol_thresh) abc
chk "a non-numeric floor falls back to the default" [::VMDPathFinder::_mean_vol_thresh 0] 0.5
set ::VMDPathFinder::state(mean_vol_thresh) $_svt
set ::VMDPathFinder::state(mean_vol_thresh_open) $_svto
# Params clamped - a stray entry must not build an unbounded grid.
set _svv $::VMDPathFinder::state(mean_vol_voxel)
set _svs $::VMDPathFinder::state(mean_vol_sigma)
set ::VMDPathFinder::state(mean_vol_voxel) 0.01
set ::VMDPathFinder::state(mean_vol_sigma) 99
lassign [::VMDPathFinder::_mean_vol_params] _ph _ps
chk "a tiny voxel size is clamped up" [expr {$_ph >= 0.5}] 1
chk "a huge smoothing width is clamped down" [expr {$_ps <= 4.0}] 1
set ::VMDPathFinder::state(mean_vol_voxel) abc
lassign [::VMDPathFinder::_mean_vol_params] _ph2 _ps2
chk "a non-numeric voxel size falls back to the default" $_ph2 1.5
set ::VMDPathFinder::state(mean_vol_voxel) $_svv
set ::VMDPathFinder::state(mean_vol_sigma) $_svs
# Occupancy is BINARY per frame - a densely sampled frame must not outvote a
# sparse one, which is the whole reason this is not a point-count average.
set _mvf [info body ::VMDPathFinder::_mean_vol_frame_regions]
chk "a voxel is counted at most once per frame" \
    [expr {[string first {if {[info exists occ($k)]} { continue }} $_mvf] >= 0}] 1
chk "lateral voxels must be connected to the core" \
    [expr {[string first {seen($nk)} $_mvf] >= 0}] 1
chk "...and are matched to an opening by the SAME axial+azimuth tolerances" \
    [expr {[string first {tolz} $_mvf] >= 0 && [string first {tola} $_mvf] >= 0}] 1
chk "a lateral voxel matching no opening is dropped, not invented as a region" \
    [expr {[string first {if {$bestsid eq ""} { continue }} $_mvf] >= 0}] 1
# A separable Gaussian must not rescale the field: three unit-sum passes.
set _fld [list 0,0,0 1.0]
set _sm [::VMDPathFinder::_mean_vol_smooth $_fld 1.0]
set _tot 0.0
foreach {_k _v} $_sm { set _tot [expr {$_tot + $_v}] }
chk "smoothing conserves total occupancy" [expr {abs($_tot-1.0) < 0.02}] 1
chk "...and spreads it beyond the single voxel" [expr {[llength $_sm]/2 > 1}] 1
chk "...while sigma 0 leaves the field untouched" [::VMDPathFinder::_mean_vol_smooth $_fld 0] $_fld
# Region membership is a floor, and the centres come back as {x y z r}.
set _dens [list 0,0,0 0.95 1,0,0 0.75 2,0,0 0.45 3,0,0 0.10]
chk "only voxels at or above the floor are meshed" \
    [llength [::VMDPathFinder::_mean_vol_region_centers $_dens 1.0 0.60]] 2
chk "...and nothing below it is" \
    [llength [::VMDPathFinder::_mean_vol_region_centers $_dens 1.0 0.99]] 0
# Voxel spheres must OVERLAP or a region renders as separated beads: the
# half-diagonal of a cube of side h is 0.866h.
chk "region spheres are half-diagonal, so neighbours overlap" \
    [expr {[lindex [lindex [::VMDPathFinder::_mean_vol_region_centers $_dens 2.0 0.90] 0] 3] > 1.0}] 1
# It reuses the ordinary surface pipeline, which is what gives it Display /
# Colour / Material / Property for free.
chk "the volume goes through the same surface pipeline as the pore" \
    [expr {[string first {surface_mesh $sph $raw draw} [info body ::VMDPathFinder::_mean_vol_mesh]] >= 0}] 1
# ...and NOTHING else runs the legacy pair: every mesh is built by surface_mesh.
set _direct 0
foreach _p [info procs ::VMDPathFinder::*] {
    if {$_p in {::VMDPathFinder::surface_mesh ::VMDPathFinder::_legacy_sos ::VMDPathFinder::run_sph_process ::VMDPathFinder::run_sos_triangle
                ::VMDPathFinder::run_sos_triangle_points ::VMDPathFinder::build_hydro_trinorm}} continue
    set _b [info body $_p]
    regsub -all {(?m)^\s*#.*$} $_b {} _b
    if {[regexp {run_sos_triangle(_points)? |run_sph_process } $_b]} { incr _direct; note "  direct tool run in $_p" }
}
chk "no proc but the surface pipeline runs sph_process or sos_triangle for a mesh" $_direct 0
# A voxel union is ridged by construction - measured 32.9 deg between the
# normals of triangles sharing a vertex, against 8.1 after 8 smoothing passes.
# hole_def on the volume must band by the PORE radius. The volume's .sph
# radius is the voxel half-diagonal - ONE artificial value for every sphere -
# so sph_process's own -color paints the whole mesh a single band chosen by the
# voxel-size knob (h=1.5 -> 1.30 A -> green, h=1.0 -> 0.87 A -> red), which says
# nothing about the pore.
chk "hole_def is rebanded from the mean profile's own radius" \
    [expr {[string first {_hole_radius_band} \
        [info body ::VMDPathFinder::_mean_vol_holedef_plot_body]] >= 0}] 1
chk "...and the artificial per-sphere colours are dropped, not kept" \
    [expr {[string first {if {$kind eq "color"} { continue }} \
        [info body ::VMDPathFinder::_mean_vol_holedef_plot_body]] >= 0}] 1
chk "...banded per triangle by its own axial coordinate" \
    [expr {[string first {zc} [info body ::VMDPathFinder::_mean_vol_holedef_plot_body]] >= 0}] 1
chk "...and the build routes hole_def through it" \
    [expr {[string first {_mean_vol_holedef_plot} [info body ::VMDPathFinder::_mean_vol_build]] >= 0}] 1
# The band boundaries are HOLE's own, so a wide pore really is blue.
chk "a sub-1.15 A radius still bands red" [::VMDPathFinder::_hole_radius_band 0.87] red
chk "...1.15-2.30 green" [::VMDPathFinder::_hole_radius_band 1.30] green
chk "...and >2.30 blue" [::VMDPathFinder::_hole_radius_band 4.0] blue
chk "the voxel union is Laplacian-smoothed, never shown raw" \
    [expr {[string first {smooth_mesh_plot} [info body ::VMDPathFinder::_mean_vol_mesh]] >= 0}] 1
set _svsm $::VMDPathFinder::state(mean_smooth_mesh)
set ::VMDPathFinder::state(mean_smooth_mesh) 0
chk "...smoothed even with Render smoothly OFF" \
    [expr {[::VMDPathFinder::_mean_vol_smooth_iters] >= 4}] 1
set ::VMDPathFinder::state(mean_smooth_mesh) 1
chk "...and harder with it on" \
    [expr {[::VMDPathFinder::_mean_vol_smooth_iters] > 8}] 1
set ::VMDPathFinder::state(mean_smooth_mesh) $_svsm
# Pore lining measures against whatever mean surface is on screen, so the
# volume has to publish its own geometry there.
chk "lining sees the volume, not a stale tube" \
    [expr {[string first {set mean_surface_sph $sph} [info body ::VMDPathFinder::_mean_vol_build]] >= 0}] 1
# Display modes: Dots derives its cloud from this mesh the way the tube's does.
chk "Dots derives from the volume mesh" \
    [expr {[string first {dots_from_trinorm} [info body ::VMDPathFinder::_mean_vol_render]] >= 0}] 1
chk "...and the Mean Profile's own Colour drives the render" \
    [expr {[string first {mean_surface_color} [info body ::VMDPathFinder::_mean_vol_render]] >= 0}] 1
chk "...with its own Material" \
    [expr {[string first {mean_surface_material} [info body ::VMDPathFinder::_mean_vol_render]] >= 0}] 1
# The volume is a voxel field with no centreline, so that entry must go.
set _svve $::VMDPathFinder::state(mean_vol_enabled)
set _svpm7 $::VMDPathFinder::state(pore_method)
set _svsc7 $::VMDPathFinder::state(mean_surface_color)
set ::VMDPathFinder::state(pore_method) connolly
set ::VMDPathFinder::state(mean_surface_color) green
set ::VMDPathFinder::state(mean_vol_enabled) 0
chk "Centerline is offered for the mean tube" \
    [expr {[string first {centerline} [::VMDPathFinder::_mean_dispmode_pore_choices]] >= 0}] 1
set ::VMDPathFinder::state(mean_vol_enabled) 1
chk "...and withdrawn for the occupancy volume, which has none" \
    [expr {[string first {centerline} [::VMDPathFinder::_mean_dispmode_pore_choices]] < 0}] 1
set ::VMDPathFinder::state(mean_vol_enabled) $_svve
set ::VMDPathFinder::state(pore_method) $_svpm7
set ::VMDPathFinder::state(mean_surface_color) $_svsc7
chk "...and property colouring reuses the values-recolour path" \
    [expr {[string first {run_sos_triangle_values_recolor} \
        [info body ::VMDPathFinder::_mean_vol_band_prop_plot]] >= 0}] 1
chk "...reading the SAME binned-property grid Fill and the tube read" \
    [expr {[string first {collect_binned_property $nbins $scheme $mframes $mkey} \
        [info body ::VMDPathFinder::_mean_vol_band_prop_plot]] >= 0}] 1
chk "the wireframe choice still reaches the volume render" \
    [expr {[string first {mean_display_mode} [info body ::VMDPathFinder::_mean_vol_render]] >= 0}] 1
chk "frames ineligible for cross-frame identity are excluded" \
    [expr {[string first {_conn_lobe_eligible_frames} \
        [info body ::VMDPathFinder::_mean_vol_cached_fields]] >= 0}] 1
chk "the build logs a volume sanity check against the 1-D profile" \
    [expr {[string first {_mean_vol_profile_volume} \
        [info body ::VMDPathFinder::_mean_vol_build]] >= 0}] 1
# A COLOUR or a SHOW/HIDE must never re-read the trajectory: the occupancy
# field does not depend on either.
# Editing a gear entry must NOT start a trajectory-wide pass. Only the
# dialog's own Apply commits the volume settings.
chk "the volume settings are committed by the gear's Apply" \
    [expr {[string first {_mean_vol_invalidate} \
        [info body ::VMDPathFinder::_apply_mean_settings]] >= 0}] 1
chk "...which is the dialog's ONE Apply, not a second button" \
    [expr {[string first {_settings_btn_row $d ::VMDPathFinder::_apply_mean_settings} \
        [info body ::VMDPathFinder::show_mean_profile_settings]] >= 0 \
        && [string first {vapply} [info body ::VMDPathFinder::show_mean_profile_settings]] < 0}] 1
chk "no volume entry recalculates on every keystroke or focus change" \
    [expr {[string first {_mean_vol_settings_changed} \
        [info body ::VMDPathFinder::show_mean_profile_settings]] < 0}] 1
chk "a redraw never drops the cached field" \
    [expr {[string first {_mean_vol_invalidate} [info body ::VMDPathFinder::_mean_vol_redraw]] < 0}] 1
chk "the fields are cached, so a second ask is free" \
    [expr {[string first {_mean_vol_fields_cache} \
        [info body ::VMDPathFinder::_mean_vol_cached_fields]] >= 0}] 1

chk "material is part of the plot cache key, so a pick actually rebuilds" \
    [expr {[string first {conn_site_material,*} [info body ::VMDPathFinder::_conn_lobes_tag]] >= 0}] 1
# --- Wireframe draws each shared edge ONCE ----------------------------------
# Two triangles sharing edge v2-v3: 4 distinct edges, not 6. Drawing all three
# edges of every triangle doubles most of them, and the overdraw is what made a
# dense mesh (47793 lines for the 15931-triangle mean tube) read as solid.
set _wtmp [file join /tmp "vmdpathfinder_wire_dedup_[pid].vmd_plot"]
set _wfh [open $_wtmp w]
puts $_wfh "draw delete all"
puts $_wfh "draw color blue"
puts $_wfh "draw trinorm {0 0 0} {1 0 0} {0 1 0} {0 0 1} {0 0 1} {0 0 1}"
puts $_wfh "draw trinorm {1 0 0} {0 1 0} {1 1 0} {0 0 1} {0 0 1} {0 0 1}"
close $_wfh
set _wmol [mol new]
::VMDPathFinder::render_vmd_plot_to_mol $_wtmp $_wmol 1 "" green Opaque 1 1
set _wlines 0
foreach _g [graphics $_wmol list] {
    if {[lindex [graphics $_wmol info $_g] 0] eq "line"} { incr _wlines }
}
# 3 + 3 edges, one shared, so 5 distinct - not the 6 an undeduped pass draws.
chk "wireframe draws each shared edge once, not once per triangle" $_wlines 5
# ...and the dedup set must be per-render, or a second render of the same mesh
# would drop every edge as "already drawn" and paint nothing.
set _wmol2 [mol new]
::VMDPathFinder::render_vmd_plot_to_mol $_wtmp $_wmol2 1 "" green Opaque 1 1
set _wlines2 0
foreach _g [graphics $_wmol2 list] {
    if {[lindex [graphics $_wmol2 info $_g] 0] eq "line"} { incr _wlines2 }
}
chk "...and a second render of the same mesh still draws them" $_wlines2 5
# Solid mode is untouched by any of this.
set _wmol3 [mol new]
::VMDPathFinder::render_vmd_plot_to_mol $_wtmp $_wmol3 1 "" green Opaque 1 0
set _wtris 0
foreach _g [graphics $_wmol3 list] {
    if {[lindex [graphics $_wmol3 info $_g] 0] in {trinorm triangle}} { incr _wtris }
}
chk "...while solid mode still draws filled triangles" $_wtris 2
catch {mol delete $_wmol}; catch {mol delete $_wmol2}; catch {mol delete $_wmol3}
catch {file delete -force $_wtmp}
# --- Mean Profile settings: the 3D controls follow what actually drives them --
set _msl [info body ::VMDPathFinder::_sync_mean_settings_lock]
# The subsample defaults to every frame, and its control only appears on a
# trajectory long enough for it to decide anything.
chk "the Accurate-3D frame cap defaults to every frame" $::VMDPathFinder::state(mean_3d_frame_cap) 0
chk "...and the builder falls back to every frame when the key is missing" \
    [expr {[string first {state(mean_3d_frame_cap) : 0} \
        [info body ::VMDPathFinder::build_mean_hydro3d_average]] >= 0}] 1
chk "...with its row shown only above 1000 frames" \
    [expr {[string first {llength $result_frames] > 1000} \
        [info body ::VMDPathFinder::_sync_mean_settings_lock]] >= 0}] 1
chk "the Mean 3D frames cap is gated on Accurate 3D, not just the surface" \
    [expr {[string first {mean_hydro_3d_accurate} $_msl] >= 0 \
        && [string first {m3_row.e} $_msl] >= 0}] 1
chk "...and on the property coloring that produces the values it averages" \
    [expr {[string first {mean_surface_color} $_msl] >= 0}] 1
chk "Render smoothly is greyed for the modes that draw no mesh" \
    [expr {[string first {dots centerline} $_msl] >= 0 \
        && [string first {$d.smooth configure -state disabled} $_msl] >= 0}] 1
# Fill and the 3D surface must reach collect_binned_property with the SAME
# arguments, or each pays for its own trajectory-wide property pass.
chk "Fill and the 3D mean surface share one binned-property cache key" \
    [expr {[string first {collect_binned_property $nbins $_msch $mean_frames $mean_key} \
            [info body ::VMDPathFinder::_draw_mean_profile_body]] >= 0 \
        && [string first {collect_binned_property $nbins $state(mean_hydro_scheme) $mean_frames $mean_key} \
            [info body ::VMDPathFinder::build_and_show_mean_surface]] >= 0}] 1
# The PANEL's Material is resolved into the file at write time (every region set
# to "follow panel" takes it), so it moves the geometry key too...
set _svmat $::VMDPathFinder::state(surface_material)
set _svsc9 $::VMDPathFinder::state(surface_color)
set _svdm9 $::VMDPathFinder::state(display_mode)
set _svpm9 $::VMDPathFinder::state(pore_method)
set ::VMDPathFinder::state(pore_method) connolly
set ::VMDPathFinder::state(display_mode) triangulated
set ::VMDPathFinder::state(surface_color) pore_lobes
set ::VMDPathFinder::state(surface_material) Opaque
set _gk_op [::VMDPathFinder::surface_geom_key]
set ::VMDPathFinder::state(surface_material) Transparent
set _gk_tr [::VMDPathFinder::surface_geom_key]
chk "the panel material moves the geometry key under pore_lobes" \
    [expr {$_gk_op ne $_gk_tr}] 1
# ...so apply_material_now MUST fall back to apply_display_change, which is the
# only thing that drops the stale per-frame assets. Without it the panel's
# Material did nothing under pore_lobes (the gear's own pick worked, because it
# routes through on_display_setting_changed).
chk "...and the material handler defers to apply_display_change when it does" \
    [expr {[string first {apply_display_change} \
        [info body ::VMDPathFinder::apply_material_now]] >= 0 \
        && [string first {surface_geom_key} \
        [info body ::VMDPathFinder::apply_material_now]] >= 0}] 1
# A region with its OWN material must still outrank the panel.
chk "a region's own material still overrides the panel" \
    [expr {[string first {$_pmat eq ""} \
        [info body ::VMDPathFinder::_write_conn_multi_plot]] >= 0}] 1
set ::VMDPathFinder::state(surface_material) $_svmat
set ::VMDPathFinder::state(surface_color) $_svsc9
set ::VMDPathFinder::state(display_mode) $_svdm9
set ::VMDPathFinder::state(pore_method) $_svpm9
chk "the global gear targets the PERSISTENT sid list, not the cleared pass list" \
    [expr {[string first {_conn_lobe_known_sids} [info body ::VMDPathFinder::_conn_gear_targets]] >= 0}] 1
chk "the axis-straightness note is computed off the draw path" \
    [expr {[string first {after idle} [info body ::VMDPathFinder::_draw_axis_straightness_note]] >= 0}] 1
# Axial position and azimuth were computed and pooled per site, then discarded.
# Azimuth is what tells two openings at the same height apart.
chk "axial position and azimuth reach the row dicts" \
    [expr {[string first {axial $z azim} [info body ::VMDPathFinder::_conn_lobe_rows]] >= 0}] 1
chk "...and are their own columns, with the gear still last" \
    [expr {[string first {grid $f.ax$sid -row $r -column 5} [info body ::VMDPathFinder::_conn_lobe_row_panel]] >= 0 \
        && [string first {grid $f.az$sid -row $r -column 6} [info body ::VMDPathFinder::_conn_lobe_row_panel]] >= 0}] 1
chk "...and reach the CSV too" \
    [expr {[string first {_axial_A,} [info body ::VMDPathFinder::_conn_export_csv]] >= 0 \
        && [string first {_azimuth_deg} [info body ::VMDPathFinder::_conn_export_csv]] >= 0}] 1
# Capsule's 3D surface goes through the shared pipeline: the mesher reads the
# QC1/QC2 pairs as capsules and drops escaped slices by the axis rule. The
# private Tcl tube that stood in for it is gone.
chk "no private capsule tube remains" \
    [expr {[llength [info procs ::VMDPathFinder::_build_capsule_stadium*]] == 0 \
        && [llength [info procs ::VMDPathFinder::_capsule_slice_property]] == 0}] 1
# The Connolly ion-occupancy memo must key on the same discriminators
# _conn_site_table's own cache does (tolz/tola) - without them, changing the
# opening-match tolerance re-pooled the site table but left this memo
# returning occupancy computed under the OLD grouping, attributed to the
# NEW table's site ids.
chk "the occupancy memo keys on the lobe match tolerances" \
    [expr {[string first {_conn_lobe_tol} [info body ::VMDPathFinder::_conn_opening_occupancy]] >= 0}] 1
# traces is a LIST of per-ion dicts (see _ion_flow_scan's own callers), not a
# dict itself - `dict size` on a list silently halves an even-length count and
# throws (silently swallowed) on an odd one. llength is what is actually wanted.
chk "the occupancy memo key uses llength, not dict size, on the trace list" \
    [expr {[string first {llength [dict get $ion_flow_raw traces]} \
        [info body ::VMDPathFinder::_conn_opening_occupancy]] >= 0
        && [string first {dict size [dict get $ion_flow_raw traces]} \
        [info body ::VMDPathFinder::_conn_opening_occupancy]] < 0}] 1
set _dszchk [catch {dict size {a b c}}]
chk "...verified: dict size throws on an odd-length list" $_dszchk 1
chk "...and silently halves an even-length one" [dict size {a b c d}] 2

# _vmd_smooth_window must distinguish "no readable representation right now"
# from "VMD genuinely reports 0" - conflating them zeroed the user's chosen
# smoothing window (and rewrote every representation to match) the instant a
# molecule momentarily had none, e.g. before any structure is loaded.
chk "_vmd_smooth_window returns a distinguishable no-answer, not 0" \
    [expr {[string first {return ""} [info body ::VMDPathFinder::_vmd_smooth_window]] >= 0}] 1
chk "_smooth_watch_tick skips adoption on that no-answer" \
    [expr {[string first {if {$n ne ""}} [info body ::VMDPathFinder::_smooth_watch_tick]] >= 0}] 1
# The poll must not overwrite the spinbox display while it has keyboard focus -
# a plain -textvariable already echoes every keystroke live, and the 500 ms
# poll used to stomp on it mid-edit.
chk "the smoothing poll does not overwrite the spinbox while it has focus" \
    [expr {[string first {[focus] eq $_sm_spin_path} [info body ::VMDPathFinder::_smooth_watch_tick]] >= 0}] 1

# show_selected_surface's busy guard must COALESCE a re-entrant call for a
# different frame, not drop it - a plain "busy, do nothing" guard silently
# left the screen on whichever frame the in-flight build was for even after
# the user had moved on, because load_surface_for_frame's own full `update`
# on the non-draft path can dispatch a queued frame-change mid-build.
chk "show_selected_surface remembers a re-entrant request instead of dropping it" \
    [expr {[string first {_frame_render_pending_draft} [info body ::VMDPathFinder::show_selected_surface]] >= 0}] 1
chk "...and the pending check cannot throw on the empty-sentinel value" \
    [expr {[string first {$_frame_render_pending_draft eq ""} \
        [info body ::VMDPathFinder::show_selected_surface]] >= 0}] 1

# Cavities: closing the MAIN window withdraws every child dialog WITHOUT
# destroying them (_withdraw_child_dialogs), so re-opening Cavities afterward
# must re-deiconify it - checking only `winfo exists` treated "exists but
# withdrawn" the same as "already visible" and never showed it again.
chk "show_tunnel_cavities distinguishes exists-but-withdrawn from already-visible" \
    [expr {[string first {wm state $t} [info body ::VMDPathFinder::show_tunnel_cavities]] >= 0}] 1

# _cvect_stab_excl's non-protein-endpoint warning writes to $d.sb.note - the
# widget must actually exist, or the warning silently never displays (guarded
# by winfo exists, so no error - just a warning nobody sees).
chk "the CVECT non-protein-endpoint warning has a widget to write to" \
    [expr {[string first {label $d.sb.note} [info body ::VMDPathFinder::_build_vector_controls]] >= 0}] 1

# The native Connolly classifier returns a pre-built `lobes` key, which
# _conn_frame_lobes short-circuits on and returns immediately - the speck
# filter added for conn_lobe_minshare lived AFTER that short-circuit, so it
# was unreachable whenever the native classifier ran (the default path).
# Verified directly: at every share from 0% to 90%, the native path returned
# the identical 14 lobes before this fix. The filter is now a shared,
# separately-named step applied to the FINISHED lobes list from either source.
chk "_conn_frame_lobes applies the speck filter to native lobes too" \
    [expr {[string first {_conn_lobe_drop_specks} [info body ::VMDPathFinder::_conn_frame_lobes]] >= 0
        && [string first {dict exists $cls lobes} [info body ::VMDPathFinder::_conn_frame_lobes]] >= 0}] 1
chk "...and the Tcl fallback path funnels through the SAME helper" \
    [expr {[llength [info procs ::VMDPathFinder::_conn_lobe_drop_specks]] == 1}] 1

# The on-disk per-frame lobe cache signature must include conn_lobe_minshare -
# it changes what a per-frame lobe IS (drops candidates before pooling), the
# same category _conn_lobe_cache_sig's own comment states margin belongs to.
# Without it, _conn_site_table's disk-cache check matched on an unrelated
# signature and replayed lobes computed under whichever share was in effect
# when the file was written, ignoring a live change to the field entirely.
chk "the on-disk lobe cache signature includes conn_lobe_minshare" \
    [expr {[string first {_conn_lobe_min_share} [info body ::VMDPathFinder::_conn_lobe_cache_sig]] >= 0}] 1

# The PARALLEL lobe-classification path spawns fresh VMD worker processes that
# just sourced the plugin - state(conn_lobe_minshare) there is whatever the
# DEFAULT is, not the live GUI value, unless the job file carries it across
# and the worker applies it before classifying. Without this, every run of
# 8+ frames (the parallel path's own threshold) silently ignored the field.
chk "the parallel lobe worker receives and applies the live minshare setting" \
    [expr {[string first {_conn_lobe_min_share} [info body ::VMDPathFinder::_conn_lobes_parallel]] >= 0
        && [string first {state(conn_lobe_minshare)} [info body ::VMDPathFinder::_conn_lobes_parallel]] >= 0}] 1

# The tunnel Trends CSV export computed values under the SELECTED metric
# (_tunnel_trend_value already used it) but wrote a hardcoded "bottleneck"
# label into the filename, the header comment AND the CSV column name - so
# choosing Tube volume as the metric exported a column literally named
# bottleneck_radius_A holding volume numbers.
chk "the tunnel trends CSV column name follows the selected metric" \
    [expr {[string first {_tunnel_trend_export_column} [info body ::VMDPathFinder::export_tunnel_trends_csv]] >= 0}] 1
chk "...and the export column helper covers all three metrics distinctly" \
    [expr {[llength [lsort -unique [list \
        [::VMDPathFinder::_tunnel_trend_export_column]]]] == 1}] 1
foreach {_mk _mcol} {bott bottleneck_radius_A len length_A vol volume_A3} {
    set ::VMDPathFinder::state(tunnel_trend_metric) $_mk
    chk "export column for metric '$_mk' is '$_mcol'" [::VMDPathFinder::_tunnel_trend_export_column] $_mcol
}
set ::VMDPathFinder::state(tunnel_trend_metric) bott

# _run_axis_manifest recorded NOTHING for a CPOINT given as a selection - it
# only recognised a literal "x y z" triplet, so a selection-form CPOINT (or
# CVECT) reported as blank in both run_<id>.txt and the older manifest file,
# with no trace of what the run actually searched from.
chk "_run_axis_manifest resolves a selection-form CPOINT, not just a literal one" \
    [expr {[string first {_point_now $lit} [info body ::VMDPathFinder::_run_axis_manifest]] >= 0}] 1

# The parameter file must be written AFTER _run_axis_init resolves a blank
# CPOINT/CVECT - _run_axis_cp/_run_axis_cv are namespace variables that
# persist between runs, so writing it earlier recorded either a blank axis
# or literally the PREVIOUS run's guess.
set _rabody [info body ::VMDPathFinder::run_analysis]
set _axis_init_at [string first {_run_axis_init $molid} $_rabody]
set _write_params_at [string first {_write_run_parameters $root_dir} $_rabody]
chk "run_analysis writes the parameter file after resolving the axis, not before" \
    [expr {$_axis_init_at >= 0 && $_write_params_at >= 0 && $_write_params_at > $_axis_init_at}] 1

# _detect_pore_axis's memo key was molid+selection+atom/frame COUNT only, with
# no coordinate identity - aligning the trajectory (the panel's own "Align
# traj" button) modifies coordinates in place without changing any of those,
# so the memo kept returning the PRE-alignment axis forever. A pure centroid
# would still miss a rotation-dominant change, so a specific atom's absolute
# position is part of the key too.
chk "_detect_pore_axis's memo key includes atom-level coordinate identity" \
    [expr {[string first {measure center} [info body ::VMDPathFinder::_detect_pore_axis]] >= 0
        && [string first {index 0} [info body ::VMDPathFinder::_detect_pore_axis]] >= 0}] 1

# add_tooltip's Enter/Leave bindings are ADDITIVE ("+..."), so calling it
# twice on the same widget stacks a second scheduler that cancels the
# first's pending popup on every hover - the LAST-EXECUTED call always wins,
# and any call re-run over a widget's lifetime (a "sync"/"update" proc,
# called again on every mode switch) keeps growing the binding list forever.
# set_tooltip exists precisely to re-text a binding in place instead.
foreach _proc {_update_method_dependent_controls _sync_passability_buttons \
               _sync_profile_exportbar_for_mode} {
    chk "$_proc re-texts its persistent widget(s) with set_tooltip, not add_tooltip" \
        [expr {[string first {set_tooltip} [info body ::VMDPathFinder::$_proc]] >= 0}] 1
}

# Ion Flow's fast sphere path routed through the CACHED classifier, which
# calls _conn_classify_sph - and that falls back to a full pure-Tcl
# classification (computing azimuth-binned lat_zt for lobe clustering, which
# this proc never needs) whenever the native binary is unavailable. That made
# an install without conn_lobes pay for the EXPENSIVE fallback just to
# discover it could not use the result, then pay AGAIN for the cheap
# ion-flow-specific parser below it - strictly worse than never routing
# through the cache at all on that path.
chk "_conn_ionflow_spheres_fast checks the cache/native directly, not _conn_classify_cached" \
    [expr {[string first {[_conn_classify_cached} [info body ::VMDPathFinder::_conn_ionflow_spheres_fast]] < 0
        && [string first {_conn_classify_native} [info body ::VMDPathFinder::_conn_ionflow_spheres_fast]] >= 0}] 1
chk "...and only caches a result it confirmed came from native" \
    [expr {[string first {_conn_classify_cache_store} [info body ::VMDPathFinder::_conn_ionflow_spheres_fast]] >= 0}] 1

# Dots is meshed by marching cubes whenever _csg_can_mesh allows it (the SAME
# gate surface_mesh_tag itself uses for the file it writes), regardless of
# _csg_active - which excludes dots by definition. Keying dots-mode geometry
# on _csg_active's voxel spec left it unable to see a grid change at all,
# even though the file on disk was already correctly named differently.
set _sgkbody [info body ::VMDPathFinder::surface_geom_key]
chk "surface_geom_key's dots branch uses _csg_can_mesh, not _csg_active, for its voxel tag" \
    [expr {[string first {_dvx} $_sgkbody] >= 0
        && [string first {_csg_can_mesh} $_sgkbody] >= 0
        && [string first {dots$_dvx} $_sgkbody] >= 0}] 1

# Cavity lining reps were keyed "$molid|$which" - shared across EVERY pocket,
# not per pocket. With two pockets' linings toggled on at once, redrawing
# either on a frame settle repainted the SAME pair of reps, so only the
# most-recently-drawn pocket's lining was ever actually visible even though
# both toggle buttons showed "on". Verified directly: toggling two pockets on
# now produces four distinct rep-key entries (2 pockets x boundary/inner),
# all still present and shown after a simulated frame-settle refresh.
chk "cavity lining reps are keyed per pocket, not shared across all of them" \
    [expr {[string first {"$molid|$_key_tid|$which"} [info body ::VMDPathFinder::_cavity_redraw_lining]] >= 0
        && [string first {"$molid|$_key_tid|$which"} [info body ::VMDPathFinder::_cavity_show_lining]] >= 0}] 1
# The automatic per-frame redraw must not touch the status bar - it runs once
# per SHOWN pocket on every settled frame, and each call would overwrite
# whichever pocket's message a sibling call in that same pass had just set.
chk "the automatic per-frame lining redraw does not touch the status bar" \
    [expr {[string first {state(status)} [info body ::VMDPathFinder::_cavity_redraw_lining]] < 0}] 1
chk "...only the interactive toggle does" \
    [expr {[string first {state(status)} [info body ::VMDPathFinder::_cavity_show_lining]] >= 0}] 1

# _conn_cls_memo's eviction was a plain FIFO (drop the first key in insertion
# order), not an LRU - re-accessing a frame's cached entry via `dict set`
# updates its value in place WITHOUT moving it, so a walk over 8+ other
# frames (the openings occupancy pass) could evict the displayed frame's
# entry even though it was the most recently touched.
chk "_conn_classify_cached promotes a cache hit (unset then re-set), not a no-op dict set" \
    [expr {[string first {dict unset _conn_cls_memo $key} [info body ::VMDPathFinder::_conn_classify_cached]] >= 0}] 1

# The log's per-frame filter matched a braced pattern with a backslash line
# continuation, which Tcl does NOT honour inside braces - the continuation
# became literal characters and broke the branch that followed it.
# The rule is the SHAPE of a progress line - it ends in an ellipsis and names a
# frame or surface - not a word list, which missed most of them.
foreach _t {"Building surface for frame 3..." "Loading surface for frame 7..." \
            "HOLE: 3 / 100 frame(s) (8 parallel)..." "Hydration: binning frame 4 / 20 ..." \
            "Preparing surface 2 / 9 for batch\u2026" "Rendering frame 12..." \
            "Loaded triangulated surface for frame 3." "Showing HOLE results for frame 44."} {
    chk "log filter hides: $_t" [::VMDPathFinder::_frame_progress_line $_t] 1
}
foreach _t {"Run 20260909-120000 - 10 frame(s), sel protein" "HOLE complete (5 frame(s), 0 failed)." \
            "Surface pre-build complete for 10 frame(s)." "Mean surface: no centreline"} {
    chk "log filter keeps: $_t" [::VMDPathFinder::_frame_progress_line $_t] 0
}


# The capsule surface is the stack of its slices' stadium outlines, under
# either mesher. A union of the capsules bulged every wide slice into its
# neighbours and lost a slit-shaped constriction.
foreach _p {_create_plot_asset_body surface_cached_on_disk build_hydro_trinorm prebuild_surfaces_parallel} {
    chk "$_p routes a capsule surface through the stadium stack" \
        [expr {[string first {_capsule_stack_plot} [info body ::VMDPathFinder::$_p]] >= 0 \
            || [string first {_capsule_stack_path} [info body ::VMDPathFinder::$_p]] >= 0}] 1
}
set _cap_sph [file join $here fixtures capsule_1GRM.sph]
if {[file exists $_cap_sph]} {
    set _sv_axis [list $::VMDPathFinder::state(cpoint) $::VMDPathFinder::state(cvect)]
    set ::VMDPathFinder::state(cpoint) {0 0 0}; set ::VMDPathFinder::state(cvect) {0 0 1}
    set _sl [::VMDPathFinder::_capsule_stack_slices $_cap_sph {0 0 1} {0 0 0} 15]
    set _rg [::VMDPathFinder::_capsule_stack_rings $_sl {0 0 1}]
    chk "one ring per kept capsule slice" [expr {[llength $_rg] == [llength $_sl] && [llength $_rg] > 10}] 1
    chk "...of 48 outline points" [llength [lindex [lindex $_rg 0] 2]] 48
    # every outline point sits exactly R from the slice's segment: the stadium
    set _bad 0
    foreach _s $_sl _r $_rg {
        lassign $_s _t x1 y1 z1 x2 y2 z2 R
        foreach _pt [lindex $_r 2] {
            lassign $_pt px py pz
            set vx [expr {$x2-$x1}]; set vy [expr {$y2-$y1}]; set vz [expr {$z2-$z1}]
            set vv [expr {$vx*$vx+$vy*$vy+$vz*$vz}]
            set tt [expr {$vv > 1e-12 ? (($px-$x1)*$vx+($py-$y1)*$vy+($pz-$z1)*$vz)/$vv : 0.0}]
            if {$tt < 0} { set tt 0.0 }; if {$tt > 1} { set tt 1.0 }
            set dd [expr {sqrt(($px-$x1-$tt*$vx)**2+($py-$y1-$tt*$vy)**2+($pz-$z1-$tt*$vz)**2)}]
            if {abs($dd-$R) > 1e-3} { incr _bad }
        }
    }
    chk "...each exactly R from its slice's segment" $_bad 0
    set _tmp [file join [::VMDPathFinder::get_temp_base] "capstack_[pid].vmd_plot"]
    set _nr [::VMDPathFinder::_build_capsule_stack $_cap_sph $_tmp {0 0 1} {0 0 0} 15 draw]
    chk "the stack builds a triangle plot" [expr {$_nr == [llength $_rg] && [::VMDPathFinder::surface_has_geometry $_tmp]}] 1
    set _fh [open $_tmp r]; set _txt [read $_fh]; close $_fh
    chk "...in the draw form the recolourers read" [expr {[regexp -all {draw trinorm} $_txt] > 1000}] 1
    set _nd [::VMDPathFinder::_build_capsule_stack $_cap_sph $_tmp {0 0 1} {0 0 0} 15 dots]
    set _fh [open $_tmp r]; set _txt [read $_fh]; close $_fh
    chk "...and a dots plot with every ring point" [regexp -all {draw point} $_txt] [expr {48*[llength $_rg]}]
    # smoothing with a copy of the same frame, ends swapped, changes nothing
    set _sw [file join [::VMDPathFinder::get_temp_base] "capstack_sw_[pid].sph"]
    set _fo [open $_sw w]; set _fi [open $_cap_sph r]
    while {[gets $_fi _l] >= 0} {
        set _nm [string range $_l 12 15]
        if {$_nm eq " QC1"} { set _hold $_l; continue }
        if {$_nm eq " QC2" && [info exists _hold]} {
            puts $_fo "[string range $_l 0 11] QC1[string range $_l 16 end]"
            puts $_fo "[string range $_hold 0 11] QC2[string range $_hold 16 end]"
            unset _hold; continue
        }
        puts $_fo $_l
    }
    close $_fi; close $_fo
    set _av [::VMDPathFinder::_capsule_stack_average $_sl [list $_sw] 15]
    set _dmax 0.0
    foreach _a $_sl _b $_av {
        for {set _k 1} {$_k < 8} {incr _k} {
            set _d [expr {abs([lindex $_a $_k]-[lindex $_b $_k])}]
            if {$_d > $_dmax} { set _dmax $_d }
        }
    }
    chk "smoothing against a copy with QC1/QC2 swapped leaves every slice unchanged" [expr {$_dmax < 1e-6}] 1
    catch {file delete $_tmp $_sw}
    lassign $_sv_axis ::VMDPathFinder::state(cpoint) ::VMDPathFinder::state(cvect)
} else {
    chk "capsule fixture present" 0 1
}
foreach _p {surface_mesh surface_mesh_cmd _csg_recolor _csg_sph_extent} {
    chk "$_p hands the mesher the run's axis" \
        [expr {[string first {_csg_mesh_opts} [info body ::VMDPathFinder::$_p]] >= 0}] 1
}
set _sv_pm $::VMDPathFinder::state(pore_method)
array set ::VMDPathFinder::state {pore_method capsule cpoint {1 2 3} cvect {0 0 2} endrad 8}
chk "...as --axis CPOINT CVECT ENDRAD" [::VMDPathFinder::_csg_mesh_opts] {--axis 1 2 3 0 0 2 8}
set ::VMDPathFinder::state(pore_method) circular
chk "...and nothing for a spherical run" [::VMDPathFinder::_csg_mesh_opts] {}
set ::VMDPathFinder::state(pore_method) $_sv_pm
# Capsule's HOLE radius is sqrt((pi R^2 + 2 R L)/pi) - an equal-area equivalent,
# like Connolly's Requiv. Labelling it plain "R" implied an inscribed radius.
chk "capsule's profile radius is labelled equal-area, like Connolly's" \
    [expr {[string first {_run_uses_card capsule]) ? "R equiv-area} \
        [info body ::VMDPathFinder::_draw_mean_profile_body]] >= 0}] 1
# A capsule slice is a segment swept by a sphere, so it has TWO cap centres and
# no single centre. The pair is what the geometry actually is.
chk "capsule slices carry the QC pair and its radius" \
    [expr {[string first {list $x1 $y1 $z1 $x2 $y2 $z2 $R} \
        [info body ::VMDPathFinder::_capsule_rings]] >= 0}] 1
# HOLE writes QC1/QC2 per slice independently, so which end is "QC1" can flip -
# unoriented pairs make two tracks cross back and forth.
chk "...oriented against the previous slice so the tracks cannot cross" \
    [expr {[string first {if {$_d2 < $_d1}} [info body ::VMDPathFinder::_capsule_rings]] >= 0}] 1
chk "capsule draws TWO centreline tracks" \
    [expr {[llength [info procs ::VMDPathFinder::_build_capsule_centerlines]] == 1 \
        && [string first {_build_capsule_centerlines} \
            [info body ::VMDPathFinder::_create_plot_asset_body]] >= 0}] 1
chk "...and centerline is no longer withheld from capsule" \
    [expr {[string first {"centerline" [expr {!$connolly}]} \
        [info body ::VMDPathFinder::_update_method_dependent_controls]] >= 0}] 1
chk "the openings palette has ONE definition" \
    [expr {[string first {_conn_lobe_palette} [info body ::VMDPathFinder::_conn_site_color]] >= 0}] 1
chk "one gear dialog serves both a single region and all of them" \
    [expr {[string first {_conn_gear_dialog $sid} [info body ::VMDPathFinder::show_conn_site_gear]] >= 0 \
        && [string first {_conn_gear_dialog "*"} [info body ::VMDPathFinder::show_conn_lobes_global_gear]] >= 0}] 1
# An opening absent from a frame must still produce a row with present=0 - that
# absence is the closing event a user plots.
chk "the CSV export walks every analysed frame, not only the ones seen" \
    [expr {[string first {lsort -integer $result_frames} \
        [info body ::VMDPathFinder::_conn_export_csv]] >= 0}] 1
# The pad is "absent" + empty cells for every measured field. Matched on its
# shape, not a literal comma count, so adding a column does not fail this.
chk "...and leaves an absent opening's cells empty, never 0" \
    [expr {[regexp {append line ",0,+"} \
        [info body ::VMDPathFinder::_conn_export_csv]]}] 1
# The pore region is the size of the whole surface, so it takes the same
# C-accelerated, disk-cached coloring route the main surface does.
set _brm2 [info body ::VMDPathFinder::_build_conn_region_meshes]
chk "the pore region colors through the C path" \
    [expr {[string first {build_hydro_trinorm $run_dir $rsph $molid $frame 0} $_brm2] >= 0}] 1
chk "...with its own cache name, so it cannot clobber the main surface's" \
    [expr {[string first {"_rgn$name"} $_brm2] >= 0}] 1
chk "...and still falls back to the per-sphere path if that fails" \
    [expr {[string first {if {!$_done}} $_brm2] >= 0}] 1
chk "build_hydro_trinorm takes a per-region cache tag" \
    [expr {[lsearch -exact [info args ::VMDPathFinder::build_hydro_trinorm] name_tag] >= 0}] 1
chk "...and appends it to the cached filename" \
    [expr {[string first {append msuffix $name_tag} \
        [info body ::VMDPathFinder::build_hydro_trinorm]] >= 0}] 1

# --- Per-opening scene is cached like every other surface --------------------
# The two-tone branch always short-circuited an already-built plot; the
# per-opening branch did not, so every show/hide re-ran the region checks and
# rewrote the combined plot. Measured on a 7-region, 212k-triangle scene:
# 265 ms of pure concatenation on top of an otherwise 26 ms redraw.
set _cpb2 [info body ::VMDPathFinder::_create_plot_asset_body]
set _lp_at [string first {hole_conn_lobes_} $_cpb2]
set _bd_at [string first {_build_conn_lobes_plot $run_dir} $_cpb2]
set _gv_at [string first {geom_cache_valid $lp $sph_file} $_cpb2]
chk "the per-opening scene checks the geometry cache" [expr {$_gv_at >= 0}] 1
chk "...before building, not after" \
    [expr {$_gv_at > $_lp_at && $_gv_at < $_bd_at}] 1
# _conn_lobes_tag must stay the thing that makes the filename unique per scene,
# or the short-circuit above would serve one scene's mesh for another.
set _clt [info body ::VMDPathFinder::_conn_lobes_tag]
foreach _k {conn_site_show conn_site_colormode conn_site_scheme _conn_lobe_min_seen} {
    chk "the scene tag still covers $_k" \
        [expr {[string first $_k $_clt] >= 0}] 1
}
# The combined-plot writer must never go back to a bulk read + -line regsub:
# measured SLOWER (372 ms vs 224 ms) on the same 212k-triangle scene, for
# byte-identical output, because the regsub backtracks over the whole blob.
# The filtering itself stays line-by-line - it just happens ONCE per part now,
# in _conn_part_body, and the combined write fcopies those cached bodies
# (182 -> 35 ms, byte-identical old-vs-new on a scene with distinct per-region
# colours and a per-region material).
chk "the per-part fallback is still the line loop" \
    [expr {[string first {while {[gets $fh line] >= 0}} \
        [info body ::VMDPathFinder::_write_conn_multi_plot]] >= 0}] 1
chk "...and the combined write fcopy's the geometry instead of re-filtering" \
    [expr {[string first {fcopy} [info body ::VMDPathFinder::_write_conn_multi_plot]] >= 0}] 1

# --- First-open cost: per-frame lobes across worker processes ----------------
# Every frame is classified independently, so this is the one embarrassingly
# parallel part of the 21.9 s first open. Measured on the 100-frame Nav run,
# 15 workers: 21,370 ms serial -> 4,623 ms parallel (4.6x), and the pooled
# sites are IDENTICAL (20 both ways, worst |delta| in z/azimuth 0.0, zero
# per-frame lobe-count mismatches).
set _clp [info body ::VMDPathFinder::_conn_lobes_parallel]
chk "the worker pool runs through run_shell_pool" \
    [expr {[string first {run_shell_pool $jobs $nw} $_clp] >= 0}] 1
chk "...counted as workers, not frames" \
    [expr {[string first {"worker(s)"} $_clp] >= 0}] 1
chk "workers are this same VMD binary" \
    [expr {[string first {info nameofexecutable} $_clp] >= 0}] 1
# Frame ORDER is part of the answer: _conn_pool_lobe_sites is greedy over it.
chk "results are merged back in frame order" \
    [expr {[string first {foreach f $frames} $_clp] >= 0}] 1
# Every refusal path must fall back to the serial loop, never return partial data.
chk "it refuses on too few frames" \
    [expr {[string first {llength $frames] < 8} $_clp] >= 0}] 1
chk "...on a single worker" \
    [expr {[string first {if {$nw < 2} { return "" }} $_clp] >= 0}] 1
chk "...on a missing worker output" \
    [expr {[string first {if {![file exists $of]}} $_clp] >= 0}] 1
chk "...and on abort" \
    [expr {[string first {if {[_abort_requested]}} $_clp] >= 0}] 1
set _cst2 [info body ::VMDPathFinder::_conn_site_table]
# Each worker is handed the frame's coordinates, written from RAM as the
# packed record, so it can run the neck search; without them every neck it
# returned was blank and the main process redid the pass serially.
chk "workers are handed each frame's coordinates" \
    [expr {[string first {_conn_frame_coords $f} $_clp] >= 0 \
        && [string first {_conn_lobe_atoms $_atoms} $_clp] >= 0}] 1
chk "...and the neck settings" \
    [expr {[string first {state(endrad) [lindex $_spec 2]} $_clp] >= 0 \
        && [string first {state(radius_file)} $_clp] >= 0}] 1
chk "the neck atoms come from the handed path first" \
    [expr {[string first {_conn_lobe_atoms} [info body ::VMDPathFinder::_conn_lobe_neck_atoms]] >= 0}] 1
chk "the site table tries the pool before the serial loop" \
    [expr {[string first {_conn_lobes_parallel $_elig_frames} $_cst2] >= 0}] 1
chk "...and skips the serial loop when the pool answered" \
    [expr {[string first {$_par ne "" ? {} : $_elig_frames} $_cst2] >= 0}] 1

# --- Openings list: wheel, labels, stable widths ------------------------------
# Tk delivers a wheel event only to the widget under the pointer, so the canvas
# binding alone scrolled only over the empty space below the rows.
chk "the wheel is bound over the rows, not just the canvas" \
    [expr {[string first {_bind_wheel_subtree $d.rows.c} \
        [info body ::VMDPathFinder::_refresh_conn_lobes_panel]] >= 0}] 1
chk "the row menu uses short property names" [::VMDPathFinder::_conn_site_scheme_label kd] "KD"
chk "...for wimley-white too"                [::VMDPathFinder::_conn_site_scheme_label ww] "WW"
chk "...polarity keeps its own word"         [::VMDPathFinder::_conn_site_scheme_label polarity] "polarity"
chk "...and the MOLE prefix is dropped"      [::VMDPathFinder::_conn_site_scheme_label logp] "logP"
chk "the panel-wide picker keeps the full names" \
    [::VMDPathFinder::_surface_scheme_label kd] "kyte-doolittle"
# Column widths are a high-water mark: a sort moves the widest cell out of row
# 0, and re-measuring would reshuffle every column on each header click.
chk "column widths only ever grow, so a sort cannot reshuffle them" \
    [expr {[string first {_conn_lobe_colw} \
        [info body ::VMDPathFinder::_sync_conn_lobe_header_columns]] >= 0}] 1

# --- Lining/facing sees the CONNOLLY surface, not just the centreline --------
# The overlay measured against the axial centreline stack only, so a residue
# lining a lateral fenestration was invisible even though the surface it lines
# was on screen. Measured on frame 0 of the Nav run: 137 centreline spheres
# found 165 lining residues; the thinned Connolly surface (4,329 spheres) finds
# 420 - and 163 facing against 14.
set _pss [info body ::VMDPathFinder::_pore_surface_spheres]
chk "off CONNOLLY the lining source is still the centreline" \
    [expr {[string first {return [parse_sph_centerline $sph]} $_pss] >= 0}] 1
chk "under CONNOLLY it uses the classified cloud" \
    [expr {[string first {_conn_classify_cached $sph} $_pss] >= 0}] 1
chk "...restricted to the regions actually shown" \
    [expr {[string first {_conn_site_shown $sid} $_pss] >= 0}] 1
chk "...and to those clearing the persistence floor" \
    [expr {[string first {_conn_site_persistent $table $sid} $_pss] >= 0}] 1
chk "the centreline records are always included" \
    [expr {[string first {dict get $cls keep} $_pss] >= 0}] 1
chk "the Lining overlay reads the new accessor" \
    [expr {[string first {_pore_surface_spheres $frame} \
        [info body ::VMDPathFinder::update_pore_lining_rep]] >= 0}] 1
chk "...and so does the Facing overlay" \
    [expr {[string first {_pore_surface_spheres $frame} \
        [info body ::VMDPathFinder::update_pore_facing_rep]] >= 0}] 1
chk "the Lining overlay tests against the smoothing window's spheres" \
    [expr {[string first {_pore_surface_spheres $frame 1} \
        [info body ::VMDPathFinder::update_pore_lining_rep]] >= 0}] 1
chk "...and so does the Facing overlay" \
    [expr {[string first {_pore_surface_spheres $frame 1} \
        [info body ::VMDPathFinder::update_pore_facing_rep]] >= 0}] 1
chk "changing the smoothing window refreshes the lining" \
    [expr {[string first {update_pore_lining_rep} [info body ::VMDPathFinder::_set_smooth_window]] >= 0}] 1
# The window is one number driving two smoothings. Setting it must reach VMD's
# own per-rep window as well as the plugin's frame averaging, or the protein and
# the pore inside it drift apart.
chk "...and pushes the same window into every VMD representation" \
    [expr {[string first {mol smoothrep $molid $r $n} \
        [info body ::VMDPathFinder::_set_smooth_window]] >= 0}] 1
chk "...and a change made in VMD is adopted back" \
    [expr {[string first {_set_smooth_window $n} \
        [info body ::VMDPathFinder::_smooth_watch_tick]] >= 0}] 1
set _bht [info body ::VMDPathFinder::build_hydro_trinorm]
chk "property colouring lines against the smoothing window's spheres" \
    [expr {[string first {_smooth_union_sph $frame $sph_file} $_bht] >= 0}] 1
chk "...in the compiled recolour" [expr {[string first {run_sos_triangle_recolor $plot0 $plot $lsph} $_bht] >= 0}] 1
chk "...and the mesh itself stays the frame's own" [expr {[string first {surface_mesh $sph_file $plot0 draw} $_bht] >= 0}] 1
# Tunnel Ion Flow measures along the route: on a quarter-circle route of
# radius 20 A a point on the arc at 45 deg reads as arc length pi*20/4 and
# zero distance from the route; 1 A outward reads as 1 A from it. The old
# axis projection put that point far off-axis, i.e. in bulk.
set _qc {}; set _qr {}
for {set _k 0} {$_k <= 90} {incr _k} {
    set _a [expr {$_k*3.14159265358979/180}]
    lappend _qc [list [expr {20*cos($_a)}] [expr {20*sin($_a)}] 0.0]; lappend _qr 2.0
}
set _path [::VMDPathFinder::_ion_flow_path_spheres $_qc $_qr]
chk "path spheres: one entry of 8 fields per centre" [expr {[llength $_path] == 91 && [llength [lindex $_path 45]] == 8}] 1
chk "path spheres: arc length reaches a quarter circle" [expr {abs([lindex $_path 90 4] - 3.14159265358979*10) < 0.05}] 1
set _a45 [expr {45.5*3.14159265358979/180}]
lassign [::VMDPathFinder::_ion_flow_path_coord [expr {20*cos($_a45)}] [expr {20*sin($_a45)}] 0.0 $_path] _ps _pr
chk "path coord: a point on the arc at 45.5 deg has arc length ~15.9 A" [expr {abs($_ps - 20*$_a45) < 0.05}] 1
chk "path coord: ...and ~0 distance from the route" [expr {$_pr < 0.02}] 1
lassign [::VMDPathFinder::_ion_flow_path_coord [expr {21*cos($_a45)}] [expr {21*sin($_a45)}] 0.0 $_path] _ps _pr
chk "path coord: 1 A outward is 1 A from the route" [expr {abs($_pr - 1.0) < 0.02}] 1
if {[::VMDPathFinder::sos_triangle_has_feature ionflowpath]} {
    # the kernel's path mode against the Tcl reference on the same points
    set _pd [file join [::VMDPathFinder::_scratch_base] "smoke_ifpath_[pid]"]; file mkdir $_pd
    set _fh [open [file join $_pd in.txt] w]
    puts $_fh "scan_r 50"; puts $_fh "path 1"; puts $_fh "S 0 [llength $_path]"
    foreach _e $_path { puts $_fh $_e }
    set _pts {}
    foreach _deg {10.3 33.7 45.5 70.1} _off {0.0 1.0 -0.5 2.5} {
        set _a [expr {$_deg*3.14159265358979/180}]
        lappend _pts [list [expr {(20+$_off)*cos($_a)}] [expr {(20+$_off)*sin($_a)}] [expr {0.3*$_off}]]
    }
    puts $_fh "F 0 0 0 0 0 0 0 0 0 0 1 [llength $_pts]"
    set _i 0; foreach _p $_pts { puts $_fh "$_i $_p"; incr _i }
    close $_fh
    catch {exec [::VMDPathFinder::tool_path sos_triangle] --ionflow-project [file join $_pd in.txt] [file join $_pd out.txt]}
    set _ok 0; set _n 0
    if {![catch {open [file join $_pd out.txt] r} _oh]} {
        while {[gets $_oh _l] >= 0} {
            if {[string match "F *" $_l]} continue
            lassign $_l _ix _kz _kr _kd
            lassign [::VMDPathFinder::_ion_flow_path_coord {*}[lindex $_pts $_ix] $_path] _tz _tr
            incr _n
            if {abs($_kz-$_tz) < 1e-9 && abs($_kr-$_tr) < 1e-9} { incr _ok }
        }
        close $_oh
    }
    chk "kernel path mode agrees with the Tcl reference on every point" "$_ok/$_n" "4/4"
    file delete -force $_pd
} else {
    chk "kernel path mode (skipped: binary has no ionflowpath)" 1 1
}
# The CVECT stick places the two-point DEFINITION's endpoints, one at a
# time - it does not move CVECT itself. state(axis_stick_vec_pt) chooses
# which endpoint; CVECT is recomputed from the pair after every move, the
# same as pressing Compute.
chk "_axis_stick_key targets vec_p1 by default under CVECT" \
    [::VMDPathFinder::_axis_stick_key cvect] "vec_p1"
set ::VMDPathFinder::state(axis_stick_vec_pt) p2
chk "...and vec_p2 once Point 2 is selected" [::VMDPathFinder::_axis_stick_key cvect] "vec_p2"
set ::VMDPathFinder::state(axis_stick_vec_pt) p1
chk "_axis_stick_getvar/_axis_stick_setvar read/write vec_p1, not a state entry" \
    [expr {![info exists ::VMDPathFinder::state(vec_p1)]}] 1
::VMDPathFinder::_axis_stick_setvar vec_p1 "1.0000 2.0000 3.0000"
chk "...confirmed: setvar wrote the namespace variable" $::VMDPathFinder::vec_p1 "1.0000 2.0000 3.0000"
chk "...and getvar reads the same variable back" [::VMDPathFinder::_axis_stick_getvar vec_p1] "1.0000 2.0000 3.0000"

# _axis_stick_nudge resolves the view basis through a live molecule - give it
# one of its own rather than trust whatever the suite left state(molid) at.
set _svmid $::VMDPathFinder::state(molid)
set _stkmol [mol new]
set ::VMDPathFinder::state(molid) $_stkmol
molinfo $_stkmol set rotate_matrix {{{1 0 0 0} {0 1 0 0} {0 0 1 0} {0 0 0 1}}}
set ::VMDPathFinder::vec_p1 "1 2 3"; set ::VMDPathFinder::vec_p2 "10 2 3"
set ::VMDPathFinder::state(axis_stick_vec_pt) p1
set ::VMDPathFinder::state(axis_stick_step_cpoint) 1.0
::VMDPathFinder::_axis_stick_nudge cvect right
chk "moving Point 1 leaves Point 2 untouched" $::VMDPathFinder::vec_p2 "10 2 3"
chk "Point 1 moved one step (Å) right on screen" $::VMDPathFinder::vec_p1 "2.0000 2.0000 3.0000"
chk "CVECT recomputed live from the moved pair" $::VMDPathFinder::state(cvect) "1.0000 0.0000 0.0000"
set ::VMDPathFinder::state(axis_stick_vec_pt) p2
::VMDPathFinder::_axis_stick_nudge cvect up
chk "moving Point 2 leaves Point 1 untouched" $::VMDPathFinder::vec_p1 "2.0000 2.0000 3.0000"
chk "Point 2 moved one step (Å) up on screen" $::VMDPathFinder::vec_p2 "10.0000 3.0000 3.0000"
mol delete $_stkmol
set ::VMDPathFinder::state(molid) $_svmid
set ::VMDPathFinder::state(cvect) "0 0 1"
# Voxel thinning: 22,439 raw dots -> 4,329, 1,705 ms -> 346 ms (4.9x), and only
# 10 of 424 lining residues differ from the unthinned answer.
set _thin [info body ::VMDPathFinder::_thin_spheres_to_voxels]
chk "the cloud is voxel-thinned before the distance test" \
    [expr {[string first {_thin_spheres_to_voxels $lines 1.0} $_pss] >= 0}] 1
chk "...keeping the LARGEST radius per voxel, so the surface cannot shrink" \
    [expr {[string first {$r > [lindex $best($k) 3]} $_thin] >= 0}] 1
chk "...reading the geometric radius column, not the 999.99 one" \
    [expr {[string first {string range $l 54 59} $_thin] >= 0}] 1
# Functional: two dots in one voxel collapse, the larger radius survives.
set _l1 "ATOM      1  QSS SPH S-999       0.100   0.100   0.100  1.15  4.57"
set _l2 "ATOM      1  QSS SPH S-999       0.200   0.200   0.200  3.25  4.57"
set _l3 "ATOM      1  QSS SPH S-999       9.100   9.100   9.100  1.15  4.57"
set _tv [::VMDPathFinder::_thin_spheres_to_voxels [list $_l1 $_l2 $_l3] 1.0]
chk "two dots in one voxel collapse to one" [llength $_tv] 2
chk "...and the larger radius is the one kept" \
    [expr {[lsearch -index 3 -real -exact $_tv 3.25] >= 0}] 1
chk "the surface set is memoised across overlay switches" \
    [expr {[string first {_pore_surf_memo} $_pss] >= 0}] 1

# Per-region MATERIAL survives the renderer. Two regions, 10000 triangles, so
# both straddle the 4000-primitive chunk boundary. Measured before the fix:
# 3003 triangles drew under the panel material instead of their region's, and
# at a playback stride every single one did.
set _mp [file join [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}] \
         vmdpathfinder_matrender.vmd_plot]
set _oh [open $_mp w]
puts $_oh "draw delete all"
foreach {_col _mat _n} {blue AOChalky 5000 red Glass1 5000} {
    puts $_oh "draw color $_col"
    puts $_oh "draw material $_mat"
    for {set _i 0} {$_i < $_n} {incr _i} {
        puts $_oh "draw trinorm {0 0 $_i} {1 0 $_i} {0 1 $_i} {0 0 1} {0 0 1} {0 0 1}"
    }
}
close $_oh
proc _mat_tally {plot stride} {
    set ::_curmat ""; set ::_tally [dict create]
    ::VMDPathFinder::_plot_cache_forget $plot
    rename graphics _real_graphics
    proc graphics {mol args} {
        if {[lindex $args 0] eq "material"} { set ::_curmat [lindex $args 1]; return }
        if {[lindex $args 0] in {trinorm triangle line}} { dict incr ::_tally $::_curmat }
    }
    catch {::VMDPathFinder::render_vmd_plot_to_mol $plot 0 $stride}
    rename graphics {}
    rename _real_graphics graphics
    return $::_tally
}
set ::VMDPathFinder::state(surface_color) pore_lobes
set ::VMDPathFinder::state(surface_material) Opaque
set ::VMDPathFinder::state(display_mode) triangulated
set _t1 [_mat_tally $_mp 1]
chk "no triangle renders under the panel material instead of its region's" \
    [expr {![dict exists $_t1 Opaque]}] 1
chk "...each region gets exactly its own triangles" \
    [expr {[dict exists $_t1 AOChalky] && [dict get $_t1 AOChalky] == 5000 \
        && [dict exists $_t1 Glass1] && [dict get $_t1 Glass1] == 5000}] 1
set _t7 [_mat_tally $_mp 7]
chk "a playback stride keeps the material records too" \
    [expr {![dict exists $_t7 Opaque] && [dict exists $_t7 AOChalky] \
        && [dict exists $_t7 Glass1]}] 1
file delete -force $_mp

# A region set to "follow panel" must take the PANEL material, not whichever
# material the region written before it happened to use.
set _pd [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]
set _mparts {}
foreach {_nm _spec} {a {blue AOChalky} b {red {}} c {white Glass1}} {
    set _pf [file join $_pd vmdpathfinder_part_$_nm.vmd_plot]
    set _oh [open $_pf w]
    puts $_oh "draw delete all"
    puts $_oh "draw color green"
    puts $_oh "draw trinorm {0 0 0} {1 0 0} {0 1 0} {0 0 1} {0 0 1} {0 0 1}"
    close $_oh
    lappend _mparts $_pf $_spec
}
set _comb [file join $_pd vmdpathfinder_combined.vmd_plot]
::VMDPathFinder::_write_conn_multi_plot $_mparts $_comb
set _seen {}; set _cm ""
set _fh [open $_comb r]
while {[gets $_fh _line] >= 0} {
    if {[string match "draw material*" $_line]} { set _cm [lindex $_line 2] }
    if {[string match "draw trinorm*" $_line]} { lappend _seen $_cm }
}
close $_fh
chk "a follow-panel region takes the panel material, not its neighbour's" \
    [expr {$_seen eq {AOChalky Opaque Glass1}}] 1
foreach _f [concat [list $_comb] [lmap {_a _b} $_mparts {set _a}]] { file delete -force $_f }

# The all-regions color pick fans out over every region. The per-region
# helper it calls used to refresh the whole list and re-apply the display each
# time, so one pick rebuilt the list once per region.
set ::_nrefresh 0
set ::_napply 0
rename ::VMDPathFinder::_refresh_conn_lobes_panel ::VMDPathFinder::_real_refresh_lobes
proc ::VMDPathFinder::_refresh_conn_lobes_panel {} { incr ::_nrefresh }
rename ::VMDPathFinder::on_display_setting_changed ::VMDPathFinder::_real_on_display_changed
proc ::VMDPathFinder::on_display_setting_changed {args} { incr ::_napply }
# Stubbed only because it is a pure Tk widget query - it would abort the pick
# headless before the fan-out this block measures ever finishes.
rename ::VMDPathFinder::_conn_gear_sync_prop_row ::VMDPathFinder::_real_sync_prop_row
proc ::VMDPathFinder::_conn_gear_sync_prop_row {sid} {}
set ::VMDPathFinder::_conn_lobe_known_sids {1 2 3 4 5 6 7 8}
set _ntargets [llength [::VMDPathFinder::_conn_gear_targets *]]
catch {::VMDPathFinder::_conn_gear_color_pick * red}
rename ::VMDPathFinder::_refresh_conn_lobes_panel {}
rename ::VMDPathFinder::_real_refresh_lobes ::VMDPathFinder::_refresh_conn_lobes_panel
rename ::VMDPathFinder::on_display_setting_changed {}
rename ::VMDPathFinder::_real_on_display_changed ::VMDPathFinder::on_display_setting_changed
rename ::VMDPathFinder::_conn_gear_sync_prop_row {}
rename ::VMDPathFinder::_real_sync_prop_row ::VMDPathFinder::_conn_gear_sync_prop_row
chk "the all-regions color pick covers every region" [expr {$_ntargets == 9}] 1
chk "...and refreshes the list once, not once per region" $::_nrefresh 1
chk "...and applies the display once" $::_napply 1

# Ion PASSAGE and ion OCCUPANCY read two different shells. One ion walking up
# the axis with its distance from the pore surface (d3) sweeping -0.9 -> 3.0 A
# (r - 1.0, keeping r itself as a plausible cylindrical R for display/flux):
# tightening the passage shell must drop passage samples and leave occupancy
# alone. Membership is decided by d3 (see _ion_flow_min_surf_dist), not r, so
# the fixture must carry d3 - a trace with no d3 field has nothing to admit.
set _ifz {}; set _ifr {}; set _ifd3 {}; set _iff {}
for {set _i 0} {$_i < 40} {incr _i} {
    lappend _ifz [expr {-20.0 + $_i}]
    set _ifr_i [expr {0.1 + $_i*0.1}]
    lappend _ifr $_ifr_i
    lappend _ifd3 [expr {$_ifr_i - 1.0}]
    lappend _iff $_i
}
set _ifraw [dict create axis {0 0 1} origin {0 0 0} zmin -20.0 zmax 20.0 zc 0.0 \
    bulk_lo -25.0 bulk_hi 25.0 coord_offset 0.0 \
    rmin_hole 1.0 rmax_hole 1.0 scan_r 6.0 nframes 40 nions 1 \
    protein_wrapped 0 box_lz 80.0 rprof {} \
    traces [list [dict create idx 0 species POT z $_ifz r $_ifr d3 $_ifd3 frame $_iff]]]
proc _if_counts {raw rcut} {
    set d [::VMDPathFinder::_ion_flow_aggregate $raw __all__ $rcut 20 40 \
        [::VMDPathFinder::_ion_flow_resolve_rpass $raw $rcut]]
    if {$d eq "" || ![dict exists $d traces]} { return {-1 -1} }
    set n 0
    foreach t [dict get $d traces] { incr n [llength [dict get $t frame]] }
    set occ 0
    if {[dict exists $d dens]} { foreach v [dict get $d dens] { set occ [expr {$occ + $v}] } }
    return [list $n $occ]
}
set _sv_pm_if $::VMDPathFinder::state(pore_method)
set ::VMDPathFinder::state(pore_method) spherical
set ::VMDPathFinder::state(ion_flow_passage_shell) 3.0
lassign [_if_counts $_ifraw 6.0] _n_wide _occ_wide
set ::VMDPathFinder::state(ion_flow_passage_shell) 0.5
lassign [_if_counts $_ifraw 6.0] _n_tight _occ_tight
chk "a tighter passage shell keeps fewer passage samples" \
    [expr {$_n_tight > 0 && $_n_tight < $_n_wide}] 1
chk "...while occupancy is untouched by it" \
    [expr {$_occ_wide == $_occ_tight && $_occ_wide > 0}] 1
# The occupancy cutoff is the ceiling: the passage shell can never widen past it.
set ::VMDPathFinder::state(ion_flow_passage_shell) 99.0
chk "the passage shell never exceeds the occupancy cutoff" \
    [expr {[::VMDPathFinder::_ion_flow_resolve_rpass $_ifraw 2.5] <= 2.5}] 1
set ::VMDPathFinder::state(pore_method) connolly
set ::VMDPathFinder::state(ion_flow_passage_shell) 3.0
chk "CONNOLLY takes no passage margin at all" \
    [::VMDPathFinder::_ion_flow_passage_shell] 0.0
set ::VMDPathFinder::state(pore_method) $_sv_pm_if
set ::VMDPathFinder::state(ion_flow_passage_shell) 0.5

# Toggling an opening or picking a colour re-emits the WHOLE combined plot, and
# on a 6-region 28 MB scene that write was ~170 ms of the ~180 ms the operation
# took - the same cost whether one region changed or ten, because the region
# meshes themselves are already cached by name (~10 ms). The write now consumes
# each part's header with gets and fcopy's the rest: 180 -> 55 ms, output
# byte-identical (verified old-vs-new on a scene with distinct per-region
# colours AND a per-region material).
#
# fcopy is only safe for a part that is header-then-geometry. _conn_part_is_plain
# decides that ONCE per part (cached on mtime - the check costs a full read, and
# paying it per write is exactly what this avoids); anything else takes the line
# filter. NOT a tail scan per write: that measured 148 ms against the filter's
# 182, i.e. it reads the whole file to decide not to read the whole file.
set _pbdir [file join [::VMDPathFinder::get_temp_base] "vh_partbody_[pid]"]
file mkdir $_pbdir
proc _pb_write {path lines} {
    set h [open $path w]; foreach l $lines { puts $h $l }; close $h
}
set _plain [file join $_pbdir plain.vmd_plot]
_pb_write $_plain {
    "draw delete all"
    "draw color red"
    "draw trinorm {0 0 0} {1 0 0} {0 1 0} {0 0 1} {0 0 1} {0 0 1}"
    "draw trinorm {1 1 1} {2 1 1} {1 2 1} {0 0 1} {0 0 1} {0 0 1}"
}
chk "a header-then-geometry part takes the fcopy fast path" \
    [::VMDPathFinder::_conn_part_is_plain $_plain] 1
# A part with a colour record BETWEEN triangles must NOT be fcopy'd under a flat
# region colour - that record would survive and outrank the region's colour.
set _mixed [file join $_pbdir mixed.vmd_plot]
_pb_write $_mixed {
    "draw delete all"
    "draw color red"
    "draw trinorm {0 0 0} {1 0 0} {0 1 0} {0 0 1} {0 0 1} {0 0 1}"
    "draw color blue"
    "draw trinorm {1 1 1} {2 1 1} {1 2 1} {0 0 1} {0 0 1} {0 0 1}"
}
chk "...a part with interspersed records does NOT" \
    [::VMDPathFinder::_conn_part_is_plain $_mixed] 0
# And the combined write must actually produce the filtered result for it.
set _comb [file join $_pbdir combined.vmd_plot]
::VMDPathFinder::_write_conn_multi_plot [list $_mixed [list green Opaque]] $_comb
set _ch [open $_comb r]; set _ctext [read $_ch]; close $_ch
chk "...and the combined plot carries the REGION colour, not the part's" \
    [expr {[string first "draw color blue" $_ctext] < 0
        && [string first "draw color green" $_ctext] >= 0}] 1
chk "...while keeping both triangles" \
    [regexp -all {draw trinorm} $_ctext] 2
# A property-coloured part (colour "") keeps its own per-triangle colours - that
# gradient is the whole point of the region being property-coloured.
set _comb2 [file join $_pbdir combined2.vmd_plot]
::VMDPathFinder::_write_conn_multi_plot [list $_mixed [list "" Opaque]] $_comb2
set _c2h [open $_comb2 r]; set _c2text [read $_c2h]; close $_c2h
chk "a property-coloured part KEEPS its own colour records" \
    [expr {[string first "draw color blue" $_c2text] >= 0}] 1
# A re-meshed part must be re-judged, never approved from a stale answer.
after 1100
_pb_write $_plain {
    "draw delete all"
    "draw trinorm {0 0 0} {1 0 0} {0 1 0} {0 0 1} {0 0 1} {0 0 1}"
    "draw material Glossy"
    "draw trinorm {5 5 5} {6 5 5} {5 6 5} {0 0 1} {0 0 1} {0 0 1}"
}
chk "a part rewritten on disk is re-judged, not served from the cache" \
    [::VMDPathFinder::_conn_part_is_plain $_plain] 0
catch {file delete -force $_pbdir}

# The openings list's Seen traffic light must be re-stamped BEFORE the surface
# rebuild, not after: it is a per-row -foreground reconfigure (microseconds),
# but behind show_selected_surface it waited on a ~300 ms cold Connolly mesh, so
# the colour visibly lagged the frame it describes.
set _fcs [info body ::VMDPathFinder::frame_changed_settle]
set _at_light [string first {_conn_lobe_update_present} $_fcs]
set _at_surf  [string first {show_selected_surface 0} $_fcs]
chk "the Seen light is re-stamped before the surface rebuild" \
    [expr {$_at_light >= 0 && $_at_surf >= 0 && $_at_light < $_at_surf}] 1
# ...and only once - the old call after the rebuild had to go, or the win is
# halved and the cell is written twice per frame.
chk "...and not a second time after it" \
    [regexp -all {_conn_lobe_update_present} $_fcs] 1

# Mean Profile "S" (smooth) used to CLIP BOTH ENDS off the tube. The mean
# surface is cut flat at both ends, so each end is an OPEN rim whose vertices
# have neighbours only on the inward side - a plain Laplacian drags the rim
# down the axis, and the clip cannot restore it (it only ever removes
# triangles). Measured on a 10-frame spherical mean, same run:
#     smooth off  mesh -17.54 .. 19.07   (exactly the clip planes)
#     smooth on   mesh -17.14 .. 18.57   (0.40 A and 0.50 A of pore lost)
# with 24402 vertices BOTH times - proof it was the smoother moving them, not
# the cut removing them. Boundary vertices (on an edge used by exactly one
# triangle) are pinned now.
set _pindir [file join [::VMDPathFinder::get_temp_base] "vh_pin_[pid]"]
file mkdir $_pindir
set _pin_in [file join $_pindir tube.vmd_plot]
set _pfh [open $_pin_in w]
puts $_pfh "draw color green"
# An open-ended tube whose MIDDLE ring bulges, so there is both a rim to keep
# and a ridge to smooth.
proc _pin_ring {z r} {
    set out {}
    for {set i 0} {$i < 8} {incr i} {
        set a [expr {2*3.14159265358979*$i/8.0}]
        lappend out [list [expr {$r*cos($a)}] [expr {$r*sin($a)}] $z]
    }
    return $out
}
set _r0 [_pin_ring 0.0 5.0]; set _r1 [_pin_ring 1.0 5.9]; set _r2 [_pin_ring 2.0 5.0]
foreach {_ra _rb} [list $_r0 $_r1 $_r1 $_r2] {
    for {set _i 0} {$_i < 8} {incr _i} {
        set _j [expr {($_i+1)%8}]
        set _A [lindex $_ra $_i]; set _B [lindex $_ra $_j]
        set _C [lindex $_rb $_i]; set _D [lindex $_rb $_j]
        puts $_pfh "draw trinorm {$_A} {$_B} {$_D} {0 0 1} {0 0 1} {0 0 1}"
        puts $_pfh "draw trinorm {$_A} {$_D} {$_C} {0 0 1} {0 0 1} {0 0 1}"
    }
}
close $_pfh
proc _pin_zspan {p} {
    set lo 1e20; set hi -1e20
    foreach e [::VMDPathFinder::plot_cache_entries $p] {
        lassign $e _k _pay
        if {[lindex $_pay 0] ne "trinorm"} continue
        foreach _ix {1 2 3} {
            lassign [lindex $_pay $_ix] _x _y _z
            if {$_z < $lo} { set lo $_z }
            if {$_z > $hi} { set hi $_z }
        }
    }
    return [list $lo $hi]
}
proc _pin_midr {p} {
    set m 0
    foreach e [::VMDPathFinder::plot_cache_entries $p] {
        lassign $e _k _pay
        if {[lindex $_pay 0] ne "trinorm"} continue
        foreach _ix {1 2 3} {
            lassign [lindex $_pay $_ix] _x _y _z
            if {abs($_z-1.0) < 0.4} {
                set _r [expr {sqrt($_x*$_x+$_y*$_y)}]
                if {$_r > $m} { set m $_r }
            }
        }
    }
    return $m
}
set _pin_out [file join $_pindir tube_sm.vmd_plot]
::VMDPathFinder::smooth_mesh_plot $_pin_in $_pin_out
set _zs [_pin_zspan $_pin_out]
chk "smoothing does NOT shorten an open-ended tube" \
    [expr {abs([lindex $_zs 0]-0.0) < 1e-6 && abs([lindex $_zs 1]-2.0) < 1e-6}] 1
# ...and it must still be doing its job, or pinning everything would "pass".
chk "...but it still smooths the interior ridge" \
    [expr {[_pin_midr $_pin_out] < 5.0}] 1
catch {file delete -force $_pindir}

# A partial (aborted) openings pass must not be cached. It pooled FEWER frames,
# so every opening's seen-% is computed against a smaller denominator and the
# ones near the floor vanish from the list - which is the "6 rows, then 8 rows
# after I toggled something" report. The DISK cache already refused to write
# one; the in-memory cache did not, so the short answer was served for the rest
# of the session and re-asking could not fix it (the key had not changed).
set _cst [info body ::VMDPathFinder::_conn_site_table]
chk "an aborted openings pass is never cached in memory" \
    [expr {[string first {[dict get $_res status] ne "failed"} $_cst] >= 0}] 1
chk "...and the disk cache still refuses a partial pass too" \
    [expr {[string first {!$_aborted} $_cst] >= 0
        && [string first {_save_conn_lobe_cache $per_frame} $_cst] >= 0}] 1

# The three pore methods report three different ion counts off ONE trajectory,
# because the scan cutoff is the method's OWN measured pore radius plus the
# shell. That is real geometry (the ion INVENTORY is identical - 324 in all
# three on the Nav channel), but three unexplained numbers read as a bug, so the
# derivation is on screen next to the count.
chk "the ion views show where the R cutoff came from" \
    [::VMDPathFinder::_ion_flow_rcut_note {r_cut 9.83 rmax_hole 6.83}] \
    " \u00b7 R<9.8 \u00c5 (pore 6.8 + 3.0 shell)"
# ...and a different method's radius produces a different, self-consistent note -
# without this the check would pass against a hard-coded string.
chk "...and it tracks the method's own pore radius" \
    [::VMDPathFinder::_ion_flow_rcut_note {r_cut 7.72 rmax_hole 4.72}] \
    " \u00b7 R<7.7 \u00c5 (pore 4.7 + 3.0 shell)"
# Older cached bundles carry neither key; they must degrade, not raise.
chk "a bundle with no r_cut says nothing rather than raising" \
    [::VMDPathFinder::_ion_flow_rcut_note {rmax_hole 5.0}] ""

# The PASSAGE view is gated by r_pass, NOT the occupancy r_cut, and r_pass uses
# the tighter passage shell - forced to 0 under CONNOLLY. Measured on the Nav
# channel, one trajectory, only the method changed: spherical 5.22, capsule
# 5.40, Connolly 10.57. That is why three probes draw three different passage
# plots off an identical 324-ion inventory, so the title states the cutoff that
# actually gated it (it used to show the occupancy one - a real mismatch).
chk "the passage view reports its OWN cutoff, not the occupancy one" \
    [::VMDPathFinder::_ion_flow_rpass_note {r_cut 7.72 r_pass 5.22 rmax_hole 4.72}] \
    " \u00b7 R<5.2 \u00c5 (pore 4.7 + 0.5 passage shell)"
# CONNOLLY's zero passage shell is deliberate; it must be visible, not silent.
chk "...and CONNOLLY's zero passage shell is stated outright" \
    [::VMDPathFinder::_ion_flow_rpass_note {r_cut 10.57 r_pass 10.57 rmax_hole 10.57}] \
    " \u00b7 R<10.6 \u00c5 (pore 10.6 + 0.0 passage shell)"
# A bundle cached before r_pass existed must degrade to the old note, not raise.
chk "a pre-r_pass bundle falls back instead of raising" \
    [::VMDPathFinder::_ion_flow_rpass_note {r_cut 7.72 rmax_hole 4.72}] \
    " \u00b7 R<7.7 \u00c5 (pore 4.7 + 3.0 shell)"
# And the aggregate must actually publish r_pass, or the note above can never
# fire in the product no matter how right it is.
chk "the display bundle carries r_pass" \
    [expr {[string first {r_pass $r_pass} [info body ::VMDPathFinder::_ion_flow_aggregate]] >= 0}] 1

# CAPSULE writes its border radius into the OCCUPANCY column and leaves beta at
# 0.00; spherical writes the radius into both. Every consumer that built a
# centerline sphere list read beta directly and rejected <= 0.005, so under
# CAPSULE it kept nothing and the residue property path died with "no
# centerline spheres parsed" - which is why lining/facing did not work and
# every property landed on one flat colour.
proc _sph_cl_count {f} {
    set n 0
    set fh [open $f r]
    while {[gets $fh line] >= 0} {
        if {![string match {ATOM  *} $line] && ![string match {HETATM*} $line]} { continue }
        set r [::VMDPathFinder::_sph_centerline_radius $line]
        if {[string is double -strict $r] && $r > 0.005 \
                && ![::VMDPathFinder::_sph_line_is_flood_fill $line]} { incr n }
    }
    close $fh
    return $n
}
set _capf [file join $here fixtures capsule_1GRM.sph]
set _sphf [file join $here fixtures spherical_1GRM.sph]
set _sv_pm_cap $::VMDPathFinder::state(pore_method)
if {[file readable $_capf] && [file readable $_sphf]} {
    # Frozen full runs of the same structure at the same parameters: 134
    # capsule records (67 QC1/QC2 pairs) against 82 spherical ones, with the
    # escaped (-888) rows dropped from both.
    set ::VMDPathFinder::state(pore_method) capsule
    chk "CAPSULE keeps every real centerline record" [_sph_cl_count $_capf] 134
    set ::VMDPathFinder::state(pore_method) spherical
    chk "spherical keeps its real records and drops the escaped ones" \
        [_sph_cl_count $_sphf] 82
    # The column each method reports, stated outright.
    set _capline [lindex [split [read [set _f [open $_capf r]]] \n] 3]
    close $_f
    set ::VMDPathFinder::state(pore_method) capsule
    chk "CAPSULE reads the occupancy column, not the 0.00 beta" \
        [expr {[::VMDPathFinder::_sph_centerline_radius $_capline] > 0.005}] 1
    set ::VMDPathFinder::state(pore_method) connolly
    chk "...while CONNOLLY still reads beta" \
        [expr {[string trim [::VMDPathFinder::_sph_centerline_radius \
            "ATOM      1  QSS SPH S   0       0.000   0.000   0.000  1.11  2.22"]] == 2.22}] 1
    set ::VMDPathFinder::state(pore_method) $_sv_pm_cap
    # No consumer may go back to hardcoding beta for a centerline list: the
    # tell is a beta read on the line before a flood-fill guard.
    set _raw 0
    set _pl [split [read [set _f [open [file join $here .. vmdpathfinder.tcl] r]]] \n]
    close $_f
    for {set _i 0} {$_i < [llength $_pl]-4} {incr _i} {
        if {[string first {string range $line 60 65} [lindex $_pl $_i]] < 0} { continue }
        set _win [join [lrange $_pl $_i [expr {$_i+4}]] \n]
        if {[string first "_sph_line_is_flood_fill" $_win] >= 0 \
                && [string first "_sph_centerline_radius" $_win] < 0} { incr _raw }
    }
    chk "no centerline sphere list reads beta directly any more" $_raw 0
    # Behavioural half: drive the proc that actually died. Before the fix this
    # raised "no centerline spheres parsed" under CAPSULE and worked under
    # spherical; the two must now agree.
    set _grm [file join $here .. 1GRM.pdb]
    if {[file readable $_grm]} {
        set _gm [mol new $_grm type pdb waitfor all]
        set _sv_sel $::VMDPathFinder::state(selection)
        set _sv_sch $::VMDPathFinder::state(hydro_scheme)
        set ::VMDPathFinder::state(selection) "protein"
        set ::VMDPathFinder::state(hydro_scheme) kd
        # LINING, not facing. Facing additionally asks whether the residue
        # centroid is nearer the centerline than its CA, and a capsule has two
        # centerline tracks rather than one, so the two methods legitimately
        # disagree there (measured 6 against 8 on this structure).
        set _sv_fac $::VMDPathFinder::state(hydro_facing)
        set ::VMDPathFinder::state(hydro_facing) 0
        proc _sidecar_n {molid sphf method} {
            set ::VMDPathFinder::state(pore_method) $method
            set ::VMDPathFinder::results [dict create 0 [dict create sph_file $sphf]]
            set out [file join [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}] \
                vmdpathfinder_side_$method.txt]
            file delete -force $out
            if {[catch {::VMDPathFinder::write_hydro3d_residue_sidecar $molid 0 $out}]} { return -1 }
            set n 0
            if {[file exists $out]} {
                set fh [open $out r]
                while {[gets $fh l] >= 0} {
                    if {[string is double -strict [lindex $l end]]} { incr n }
                }
                close $fh
            }
            file delete -force $out
            return $n
        }
        set _ncap [_sidecar_n $_gm $_capf capsule]
        set _nsph [_sidecar_n $_gm $_sphf spherical]
        chk "the residue property sidecar builds under CAPSULE" \
            [expr {$_ncap > 0}] 1
        chk "...and finds the same residues spherical does" \
            [expr {$_ncap == $_nsph && $_nsph > 0}] 1
        # The 3D surface half: under property colouring every method routes
        # through colorize_hydrophobic (frame_color_plot -> build_hydro_trinorm).
        # Under CAPSULE it used to emit no colour records at all, so the mesh
        # kept whatever single flat colour the base had.
        set _sv_sc_cap $::VMDPathFinder::state(surface_color)
        set ::VMDPathFinder::state(surface_color) property
        proc _recolor_distinct {molid sphf method} {
            set ::VMDPathFinder::state(pore_method) $method
            set d [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]
            set base [file join $d vmdpathfinder_base_$method.vmd_plot]
            set oh [open $base w]
            puts $oh "draw delete all"
            puts $oh "draw color blue"
            set fh [open $sphf r]
            while {[gets $fh l] >= 0} {
                if {![string match {ATOM  *} $l]} { continue }
                set x [string trim [string range $l 30 37]]
                set y [string trim [string range $l 38 45]]
                set z [string trim [string range $l 46 53]]
                if {![string is double -strict $x]} { continue }
                puts $oh "draw trinorm {$x $y $z} {[expr {$x+0.3}] $y $z}\
 {$x [expr {$y+0.3}] $z} {0 0 1} {0 0 1} {0 0 1}"
            }
            close $fh
            close $oh
            set out [file join $d vmdpathfinder_col_$method.vmd_plot]
            file delete -force $out
            if {[catch {::VMDPathFinder::colorize_hydrophobic $base $out $sphf $molid 0}]} {
                file delete -force $base; return -1
            }
            set cols {}
            set fh [open $out r]
            while {[gets $fh l] >= 0} {
                if {[string match "draw color*" $l]} { lappend cols [lindex $l 2] }
            }
            close $fh
            file delete -force $base $out
            return [llength [lsort -unique $cols]]
        }
        chk "the property recolour gives CAPSULE more than one colour" \
            [expr {[_recolor_distinct $_gm $_capf capsule] > 1}] 1
        chk "...and spherical is unchanged by that" \
            [_recolor_distinct $_gm $_sphf spherical] 3
        set ::VMDPathFinder::state(surface_color) $_sv_sc_cap
        # Lining/facing must measure against the surface the method reports.
        # A capsule slice is every point within R of the QC1-QC2 segment, and
        # on this fixture that segment runs to 8.97 R, so its two cap centres
        # do not represent it. _pore_surface_spheres samples the segment, the
        # same way it hands CONNOLLY the classified cloud.
        set ::VMDPathFinder::state(pore_method) capsule
        set ::VMDPathFinder::results [dict create 0 [dict create sph_file $_capf]]
        set _capsurf [::VMDPathFinder::_pore_surface_spheres 0]
        set _capraw [::VMDPathFinder::parse_sph_centerline $_capf]
        set _capfull0 [::VMDPathFinder::_capsule_surface_spheres $_capf]
        # The capped lining search must give the SAME verdict as the exact
        # nearest-sphere test it replaces - the cap is only sound because past
        # gmaxr+thresh no sphere can satisfy |d-r|<=thresh.
        set _lt [::VMDPathFinder::lining_dist_thresh_value]
        set _gm2 0.0
        foreach _s $_capfull0 { if {[lindex $_s 3] > $_gm2} { set _gm2 [lindex $_s 3] } }
        set _cap2 [expr {($_gm2+$_lt)**2}]
        lassign [::VMDPathFinder::_zsort_spheres $_capfull0] _zx _zy _zz _zr
        set _nsp [llength $_zx]
        set _mismatch 0
        foreach _probe {{0 0 0} {5 5 5} {-8 2 11} {30 30 30} {0 0 12} {2 -3 4}} {
            lassign $_probe _px _py _pz
            lassign [::VMDPathFinder::_nearest_sphere_dist2_and_r $_zx $_zy $_zz $_zr $_nsp $_px $_py $_pz] _d2 _rl
            set _exact [expr {abs(sqrt($_d2)-$_rl) <= $_lt}]
            set _fast [::VMDPathFinder::_lining_atom_hits $_zx $_zy $_zz $_zr $_nsp $_px $_py $_pz $_lt $_cap2]
            if {$_exact != $_fast} { incr _mismatch }
        }
        chk "the capped lining search agrees with the exact nearest-sphere test" $_mismatch 0
        # Lining and facing come from ONE pass; each rep asked separately and
        # threw the other half away, so the sweep ran twice per settle.
        chk "both reps share one lining/facing pass" \
            [expr {[string first {_lining_facing_sets_cached} \
                [info body ::VMDPathFinder::update_pore_lining_rep]] >= 0 \
                && [string first {_lining_facing_sets_cached} \
                [info body ::VMDPathFinder::update_pore_facing_rep]] >= 0}] 1
        # ...keyed on the FRAME and the file, not on sphere-count statistics:
        # two frames can share a count and the spheres come back in hash order.
        chk "...cached on the frame and the .sph it came from" \
            [expr {[string first {file mtime} \
                [info body ::VMDPathFinder::_lining_facing_sets_cached]] >= 0 \
                && [string first {selected_result_frame} \
                [info body ::VMDPathFinder::_lining_facing_sets_cached]] >= 0}] 1
        chk "CAPSULE lining measures against the swept surface, not the cap centres" \
            [expr {[llength $_capsurf] > [llength $_capraw]}] 1
        # The union handed to the lining test is voxel-THINNED (same 1 A grid
        # the Connolly branch uses): sampling every segment at 0.25 A gives
        # ~5000 spheres on a real run and _lining_facing_sets is O(atoms x
        # spheres). Thinning is only safe if it leaves no hole the 3 A lining
        # test falls through, so assert the COVERAGE directly rather than a
        # sample count: every full-density sample must still have a kept sphere
        # within one voxel diagonal (1.74 A), which is far inside 3 A.
        set _capfull [::VMDPathFinder::_capsule_surface_spheres $_capf]
        chk "the thinned union is strictly smaller than the raw sampling" \
            [expr {[llength $_capsurf] < [llength $_capfull]}] 1
        set _maxgap 0.0
        foreach _fs $_capfull {
            lassign $_fs _fx _fy _fz _fr
            set _bd 1e30
            foreach _ts $_capsurf {
                lassign $_ts _tx _ty _tz _tr
                set _dd [expr {($_tx-$_fx)**2 + ($_ty-$_fy)**2 + ($_tz-$_fz)**2}]
                if {$_dd < $_bd} { set _bd $_dd }
            }
            set _bd [expr {sqrt($_bd)}]
            if {$_bd > $_maxgap} { set _maxgap $_bd }
        }
        chk "...and no sampled point is left further than a voxel diagonal from a kept sphere" \
            [expr {$_maxgap <= 1.74}] 1
        # The kept spheres must still span the segment, not collapse onto the
        # slices: more kept spheres than there are QC slices.
        chk "...with the swept middle still represented" \
            [expr {[llength $_capsurf] > [llength $_capraw]}] 1
        set ::VMDPathFinder::state(pore_method) spherical
        set ::VMDPathFinder::results [dict create 0 [dict create sph_file $_sphf]]
        chk "spherical still measures against its centreline stack" \
            [expr {[llength [::VMDPathFinder::_pore_surface_spheres 0]] \
                == [llength [::VMDPathFinder::parse_sph_centerline $_sphf]]}] 1
        set ::VMDPathFinder::state(selection) $_sv_sel
        set ::VMDPathFinder::state(hydro_scheme) $_sv_sch
        set ::VMDPathFinder::state(hydro_facing) $_sv_fac
        set ::VMDPathFinder::state(pore_method) $_sv_pm_cap
        catch {mol delete $_gm}
    } else {
        chk "the residue property sidecar builds under CAPSULE" SKIP SKIP
        chk "...and finds the same residues spherical does" SKIP SKIP
    }
} else {
    chk "capsule/spherical .sph fixtures present" 0 1
    chk "the residue property sidecar builds under CAPSULE" 0 1
    chk "...and finds the same residues spherical does" 0 1
}

# A whole block can die on an undefined variable and every `chk` in it still
# report PASS: VMD prints the error, keeps going, and the comparison variable
# keeps whatever it was initialised to. That happened twice while writing the
# Stabilize tests, and a RED check stayed green because of it. `chk` cannot
# catch an error in its own ARGUMENTS - they are evaluated before it is called
# - so guard the total instead: if a block stops running, the count drops.
# Bump this deliberately when adding assertions; a surprise drop is a bug.
#
# (This guard was itself silently deleted once by a region replacement that
# spanned it - which is exactly the failure it exists to catch, so it is now
# pinned by the check below that it exists at all.)
set _expect_min 803
if {$pass + $fail < $_expect_min} {
    incr fail
    puts "  FAIL  only [expr {$pass+$fail}] assertions ran, expected at least\
$_expect_min - a block died silently (look for \"can't read\" above)"
}
# CAPSULE conductance: HOLE splits its profile into two record blocks and
# RESTARTS integ.s/(area) in the second, so the geometric factor F is the two
# blocks' finals ADDED. Taking the last row alone dropped the -ve half and
# over-reported the conductance by ~10% on this very structure.
set _capf [file join $here fixtures capsule_profile_1GRM.txt]
if {[file exists $_capf]} {
    set _captsv [file join [::VMDPathFinder::get_temp_base] "smoke_caps_[pid].tsv"]
    set _capp [::VMDPathFinder::parse_profile $_capf $_captsv]
    set _capF [::VMDPathFinder::profile_cond_F $_capp]
    chk "CAPSULE F is the two blocks summed, matching HOLE's printed 8.954" \
        [expr {$_capF ne "" && abs($_capF - 8.954) < 0.005 ? 1 : 0}] 1
    # The +ve block alone is 8.16561 - the number this used to report.
    chk "...and not the +ve block alone (8.166)" \
        [expr {$_capF ne "" && abs($_capF - 8.16561) > 0.5 ? 1 : 0}] 1
    # Both halves of the channel must survive the parse, not just one block.
    set _capn [llength [dict get $_capp yvalues]]
    chk "CAPSULE keeps both record blocks" [expr {$_capn > 60 ? 1 : 0}] 1
    set _capx [dict get $_capp xvalues]
    chk "...spanning negative and positive coordinates" \
        [expr {[lindex $_capx 0] < -1.0 && [lindex $_capx end] > 1.0 ? 1 : 0}] 1
    catch {file delete -force $_captsv}
}

# The job pool's awk must produce the SAME TSV as parse_profile for a capsule
# table. It emitted nothing at all before - measured on one file, spherical 79
# rows and capsule 0 - because its header pattern only matched "radius".
# The command is LIFTED OUT OF vmdpathfinder.tcl rather than copied here, so the test
# cannot pass against a stale duplicate of it.
if {[file exists $_capf]} {
    set _src [file join [file dirname $_capf] .. .. vmdpathfinder.tcl]
    set _awkline ""
    if {![catch {open $_src r} _sh]} {
        while {[gets $_sh _l] >= 0} {
            if {[string match "*cenxyz*eff*rad*" $_l] && [string match "*sort -s -n*" $_l]} {
                set _awkline $_l; break
            }
        }
        catch {close $_sh}
    }
    chk "the job pool has a capsule awk branch at all" \
        [expr {$_awkline ne "" ? 1 : 0}] 1
    if {$_awkline ne ""} {
        # puts $fh {<command>}  ->  <command>
        set _cmd [string range $_awkline [expr {[string first "\{" $_awkline] + 1}] \
                                         [expr {[string last "\}" $_awkline] - 1}]]
        set _cmd [string map [list hole_out.txt $_capf] $_cmd]
        set _at [file join [::VMDPathFinder::get_temp_base] "smoke_awk_[pid].tsv"]
        set _cmd [string map [list hole_profile.tsv $_at] $_cmd]
        # The shipped script writes the header on its own line and the awk
        # APPENDS, so the header has to exist before the command runs.
        set _hh [open $_at w]
        puts $_hh "coord\tradius\tcen_line_d\tsum_s_over_area\trequiv\tconn_s_over_area\trequiv_estim\tcap_rad"
        close $_hh
        set _rc [catch {exec sh -c $_cmd} _err]
        chk "the capsule awk runs" [expr {$_rc == 0 ? 1 : 0}] 1
        set _an 0
        if {[file exists $_at] && ![catch {open $_at r} _ah]} {
            set _atxt [read $_ah]; close $_ah
            set _an [expr {[llength [split [string trim $_atxt] "\n"]] - 1}]
        }
        chk "...and reads the capsule table instead of emitting 0 rows" \
            [expr {$_an > 60 ? 1 : 0}] 1
        # Byte-identical to the Tcl parser's TSV for the same file: three
        # writers producing three different profiles is the failure mode.
        set _pt [file join [::VMDPathFinder::get_temp_base] "smoke_pp_[pid].tsv"]
        catch {::VMDPathFinder::parse_profile $_capf $_pt}
        set _same 0
        if {[file exists $_at] && [file exists $_pt]} {
            set _same [expr {![catch {exec cmp -s $_at $_pt}] ? 1 : 0}]
        }
        chk "...byte-identical to parse_profile's TSV" $_same 1
        catch {file delete -force $_at $_pt}
    }
}

# Importing 100 tunnel frames took 12.7 s with the status bar silent until the
# end, which reads as whatever the user clicks NEXT being slow. Assert the cue
# fires DURING the loop and that the calc depth comes back to 0 even on the
# failure path - a leaked depth leaves the abort flag raised for the session.
set _itmp [file join [::VMDPathFinder::get_temp_base] "smoke_timp_[pid]"]
file mkdir $_itmp
for {set _i 0} {$_i < 30} {incr _i} {
    set _d [file join $_itmp [format "tunnel_%05d" $_i]]
    file mkdir $_d
    set _fh [open [file join $_d out.dat] w]; puts $_fh "#"; close $_fh
}
set ::_IMP_SAW {}
trace add variable ::VMDPathFinder::state(status) write {apply {{a b c} {
    if {[string match "Importing tunnel results:*" $::VMDPathFinder::state(status)]} {
        lappend ::_IMP_SAW $::VMDPathFinder::state(status)
    }
}}}
catch {::VMDPathFinder::import_tunnel_results_from_folder $_itmp}
trace remove variable ::VMDPathFinder::state(status) write {apply {{a b c} {
    if {[string match "Importing tunnel results:*" $::VMDPathFinder::state(status)]} {
        lappend ::_IMP_SAW $::VMDPathFinder::state(status)
    }
}}}
chk "the tunnel import reports progress while it runs" \
    [expr {[llength $::_IMP_SAW] >= 2 ? 1 : 0}] 1
chk "...and the calc depth returns to 0 on the failure path" \
    [expr {$::VMDPathFinder::_calc_depth == 0 ? 1 : 0}] 1
catch {file delete -force $_itmp}


# ---------------------------------------------------------------------------
# CAPSULE steric radius: HOLE's capsule table prints TWO radii and only one of
# them is a clearance. eff.rad (col 2) is sqrt(area/pi) for an area of
# pi*r^2 + 2*r*d, so it is ALWAYS >= the capsule half-width r (col 5) and grows
# with the capsule's length. Pass/block has to read col 5; conductance, volume
# and the s/area factor are defined on the area and keep col 2. On a real Nav
# frame the two read 1.008 A and 0.191 A at the same bottleneck - a 428% gap
# that called Na+, Ca2+, Mg2+ and Li+ passable through a gap none can enter.
set _cap_dir [file join [::VMDPathFinder::get_temp_base] "vh_captsv_[pid]"]
file delete -force $_cap_dir; file mkdir $_cap_dir
# A real fragment of HOLE's capsule table, columns as printed.
set _cap_out [file join $_cap_dir hole_out.txt]
set _fh [open $_cap_out w]
puts $_fh " cenxyz.cvec     eff.rad        area     CAP.LEN     cap.rad angle.X-axi cen.line.di integ.s/(ar point sourc"
puts $_fh "    -0.01225     1.54932     7.54103     0.44356     1.29246   179.26731     0.00000     0.06630  (sampled) "
puts $_fh "    -0.26225     1.51419     7.20299     0.35909     1.30275   176.61985    -0.25454     0.06630 (mid-point)"
puts $_fh "    -0.51225     1.50570     7.12236     0.27758     1.33931     9.96099    -0.50908     0.13651  (sampled) "
close $_fh
# Run the SHIPPED awk, lifted out of run_analysis rather than retyped - a copy
# here would go on passing after the real one drifted.
set _ra [info body ::VMDPathFinder::run_analysis]
set _a0 [string first {awk '!intab{if($0 ~ /cenxyz\.cvec.*eff\.rad/){intab=1}next} $0 ~ /ve records/} $_ra]
set _a1 [string first {' hole_out.txt | sort -s -n -k1,1} $_ra]
chk "the capsule awk fast path is still findable in run_analysis" \
    [expr {$_a0 >= 0 && $_a1 > $_a0 ? 1 : 0}] 1
set _awk [string range $_ra [expr {$_a0 + 5}] [expr {$_a1 - 1}]]
set _rows {}
catch {set _rows [split [string trim [exec awk $_awk $_cap_out]] "\n"]}
chk "...and it emits one row per data line" [llength $_rows] 3
set _nf {}
foreach _r $_rows { lappend _nf [llength [split $_r "\t"]] }
chk "...each with all 8 columns, so cap_rad lands in the last one" \
    [expr {[lsort -unique $_nf] eq {8} ? 1 : 0}] 1
chk "...carrying HOLE's cap.rad, not its eff.rad" \
    [lindex [split [lindex $_rows 0] "\t"] 7] 1.29246
# Column 4 is HOLE's cumulative Sum ds/area - the conductance factor F. A
# miscounted tab in that printf would move it and read as a physics change.
chk "...with sum_s_over_area still in column 4" \
    [lindex [split [lindex $_rows 0] "\t"] 3] 0.06630
chk "...and columns 5-7 left empty for a capsule run" \
    [lrange [split [lindex $_rows 0] "\t"] 4 6] [list {} {} {}]

# The readers have to carry it through, or the writers above are wasted.
set _cap_tsv [file join $_cap_dir hole_profile.tsv]
set _fh [open $_cap_tsv w]
puts $_fh "coord\tradius\tcen_line_d\tsum_s_over_area\trequiv\tconn_s_over_area\trequiv_estim\tcap_rad"
puts $_fh "-1.00000\t2.00000\t-1.00000\t0.10000\t\t\t\t1.50000"
puts $_fh "0.00000\t1.00000\t0.00000\t0.20000\t\t\t\t0.30000"
puts $_fh "1.00000\t2.00000\t1.00000\t0.30000\t\t\t\t1.60000"
close $_fh
set _cp [::VMDPathFinder::parse_profile_from_tsv $_cap_tsv 1]
chk "parse_profile_from_tsv reports the capsule half-width minimum" \
    [dict get $_cp min_caprad] 0.30000
chk "...separately from the equal-area minimum the area terms use" \
    [dict get $_cp min_radius] 1.00000
chk "...with the two series the same length, so they cannot desync" \
    [expr {[llength [dict get $_cp caprvalues]] == [llength [dict get $_cp yvalues]] ? 1 : 0}] 1
# The guarantee itself: the half-width blocks an ion the equal-area radius passes.
set _pass_eff [::VMDPathFinder::species_passability [dict get $_cp min_radius] \
    [dict get $_cp xvalues] [dict get $_cp yvalues]]
set _pass_cap [::VMDPathFinder::species_passability [dict get $_cp min_caprad] \
    [dict get $_cp xvalues] [dict get $_cp caprvalues]]
chk "an ion smaller than the equal-area radius reads passable on it" \
    [dict get $_pass_eff Na pass_bare] 1
chk "...and blocked on the half-width it actually has to fit through" \
    [dict get $_pass_cap Na pass_bare] 0
# A summary-only read must not hand back a half-length series: the alignment
# check compares lengths, and {} against {} would pass while meaning nothing.
set _cs [::VMDPathFinder::parse_profile_from_tsv $_cap_tsv 0]
chk "a summary-only read builds neither series" \
    [expr {[llength [dict get $_cs caprvalues]] == 0 \
        && [llength [dict get $_cs yvalues]] == 0 ? 1 : 0}] 1
# A pre-v4 TSV has seven columns. It must still parse, and must leave the
# half-width EMPTY rather than inventing one from the equal-area radius.
set _old_tsv [file join $_cap_dir old.tsv]
set _fh [open $_old_tsv w]
puts $_fh "coord\tradius\tcen_line_d\tsum_s_over_area\trequiv\tconn_s_over_area\trequiv_estim"
puts $_fh "0.00000\t1.00000\t0.00000\t0.20000\t\t\t"
puts $_fh "1.00000\t2.00000\t1.00000\t0.30000\t\t\t"
close $_fh
set _op [::VMDPathFinder::parse_profile_from_tsv $_old_tsv 1]
chk "a pre-v4 seven-column TSV still parses" [dict get $_op points] 2
chk "...and reports no capsule half-width rather than a made-up one" \
    [dict get $_op min_caprad] {}
# Both the batch reader and the threaded parser have their own copies of this
# logic, inside a thread init script no test can call directly.
set _ti [::VMDPathFinder::_thread_parse_initscript]
chk "the batch TSV reader takes column 8 too" \
    [expr {[string first {if {[llength $f] >= 8} { set cr [string trim [lindex $f 7]] }} $_ti] >= 0}] 1
chk "...and returns it, so an imported frame keeps its half-width" \
    [expr {[string first {caprvalues $caprvalues min_caprad $min_caprad tsv_file} $_ti] >= 0}] 1
# The threaded parser resolves Connolly radii first, which returns 4-field rows -
# so cap.rad has to come from the ORIGINAL row at that index, not a loop variable.
chk "...and reads cap.rad from the original row, not a stale loop variable" \
    [expr {[string first {set _cr [lindex [lindex $rows $_ri] 7]} $_ti] >= 0}] 1
# The pure-Tcl engine is the fallback when HOLE is not installed; it computes
# the same half-width and used to drop it on the floor.
chk "the pure-Tcl capsule writer emits the half-width as column 8" \
    [expr {[string first {%.5f\t%.5f\t%.5f\t%.5f\t\t\t\t%.5f} \
        [info body ::vmdpathfinder_fb_tsv_capsule]] >= 0}] 1
# Silent reversion to eff.rad is the failure this whole change exists to stop.
chk "a capsule run with no half-width column says so instead of falling back quietly" \
    [expr {[string first {no cap.rad column} [info body ::VMDPathFinder::metrics_for_frame]] >= 0}] 1
catch {file delete -force $_cap_dir}


# ---------------------------------------------------------------------------
# HYDRATION: the dry-bin density floor must not carry the frame count, and the
# KDE must not be truncated.
#
# CHAP takes -ln(density) PER FRAME and averages the energies, which this plugin
# matches. CHAP applies no density floor at all: its Gaussian KDE has infinite
# support, so the density stays strictly positive - measured on real CHAP output,
# 0 of 1000 bins were exactly zero and mendInfinities never fired. This plugin
# truncated its own kernel at +/-3 sigma, which MANUFACTURED exact zeros at
# precisely the dry gates the tool exists to find, and then floored them with the
# ensemble rule of three 3/(N*V) - applied per frame, so N landed in the averaged
# energy. Measured on a real Nav trajectory over one fixed physical interval,
# 20 frames vs 39: the eight driest bins moved +0.344 kcal/mol (kT*ln(39/20) is
# 0.411), and the dry gate at z=-17.5 moved +0.275. After the fix the same bins
# move -0.0002, while the eight WETTEST bins keep their genuine sampling
# variation (+0.0074 before, +0.0061 after).
set _hyd [info body ::VMDPathFinder::compute_hydration]
# The floor must never overwrite a density that was MEASURED. min(3/V, bulk)
# did: in a narrow bin (r ~ 2 A) the bound 3/V is seven times bulk, so min()
# returned bulk and a dewetted gate was replaced by bulk water. Measured on a
# real Nav gate - occupancy 0.001-0.31 over 15 bins, every frame floored, energy
# a flat -0.024 kcal/mol on the WET side. With the floor confined to true zeros
# the same bins read +0.87 to +7.95 kcal/mol and nothing is floored at all.
chk "a measured density is never overwritten by the floor" \
    [expr {[string first {if {$rc <= 0.0}} $_hyd] >= 0}] 1
chk "...so the bulk cap that erased dry gates is gone" \
    [expr {[string first {min(3.0 / $_vol_e, $bulk)} $_hyd] >= 0}] 0
# Where there is genuinely nothing to take a log of, the rule of three bounds
# what N frames could have hidden. That bound IS legitimately frame-dependent -
# it is a confidence statement, not a measurement - and floored_frac marks it.
chk "a true zero falls back to the ensemble rule-of-three bound" \
    [expr {[string first {3.0/($nfdata*$_vol_e)} $_hyd] >= 0}] 1
# The floor has to sit on the SAME volume the density it floors was computed
# with, or the comparison is between two different quantities.
chk "...the same volume the per-frame density itself uses" \
    [expr {[string first {set rho  [expr {($_vol_e > 0) ? $cnt / $_vol_e : 0.0}]} $_hyd] >= 0}] 1
chk "the KDE sums over every bin the profile covers, not a 3-sigma window" \
    [expr {[string first {for {set bi $kde_lo} {$bi <= $kde_hi} {incr bi}} $_hyd] >= 0}] 1
chk "...so the old truncated window is gone" \
    [expr {[string first {$co - 3.0*$fbw} $_hyd] >= 0}] 0
# CHAP's own convention, which the plugin deliberately keeps: the log is taken
# per frame and the ENERGIES are averaged, not the densities.
chk "energy is still a per-frame log, averaged afterwards (CHAP's convention)" \
    [expr {[string first {set gv [expr {-1.0 * $kT * log($rc)}]} $_hyd] >= 0}] 1


# ---------------------------------------------------------------------------
# BLANK CHANNEL AXIS: guessed ONCE per run, not once per frame.
#
# The plugin's CPOINT and CVECT fields both default to EMPTY, so a control file
# with neither card is the ordinary case and HOLE guesses both (hole.f:623 ->
# cguess.f). The CVECT half picks the best of the three CARDINAL axes by summed
# pore radius, and that argmax moves between frames: measured on a real Nav
# trajectory with a fixed CPOINT, 10 frames sampled across 100 gave
# Z Y Y Y Y X X Y Y Y, the winner beating the runner-up by as little as 1.7%.
# Frames profiled along different axes are not comparable, and nothing on disk
# recorded which axis any frame used.
#
# cguess_cvect is a genuine behavioural test here, not a string match: a tube
# built along Y must come back as the Y axis.
set _ax {}; set _ay {}; set _az {}; set _ar {}
for {set _t -12} {$_t <= 12} {incr _t 2} {
    for {set _k 0} {$_k < 12} {incr _k} {
        set _th [expr {$_k * 3.14159265358979 / 6.0}]
        lappend _ax [expr {6.0*cos($_th)}]
        lappend _ay [expr {double($_t)}]
        lappend _az [expr {6.0*sin($_th)}]
        lappend _ar 1.5
    }
}
chk "cguess_cvect finds the axis of a tube built along Y" \
    [hole::cguess_cvect 0.0 0.0 0.0 [llength $_ax] $_ax $_ay $_az $_ar] {0.0 1.0 0.0}
# HOLE's guess is only ever a cardinal direction - cguess.f sets one component
# to 1 and the others to 0. Anything else would mean the port invented a method.
set _cvg [hole::cguess_cvect 0.0 0.0 0.0 [llength $_ax] $_ax $_ay $_az $_ar]
chk "...and returns a CARDINAL axis, as cguess.f does" \
    [expr {[llength [lsearch -all -exact $_cvg 1.0]] == 1 \
        && [llength [lsearch -all -exact $_cvg 0.0]] == 2}] 1
# The pinning itself: resolved once before the manifest is written, consulted by
# frame_axis so it reaches write_control_file and _frame_axis_persisted too.
chk "a blank axis is resolved once per RUN" \
    [expr {[string first {catch {_run_axis_init $molid [lindex $frames 0] $seltext}} \
        [info body ::VMDPathFinder::run_analysis]] >= 0}] 1
chk "...before the manifest records it" \
    [expr {[string first {catch {_run_axis_init $molid [lindex $frames 0] $seltext}} \
        [info body ::VMDPathFinder::run_analysis]] < \
            [string first {_run_axis_manifest cpoint} [info body ::VMDPathFinder::run_analysis]]}] 1
chk "...and frame_axis falls back to it when the field is blank" \
    [expr {[string first {set cp $_run_axis_cp} [info body ::VMDPathFinder::frame_axis]] >= 0}] 1
# A guessed axis must be labelled as guessed, or the manifest reads as if the
# user had chosen it.
set ::VMDPathFinder::_run_axis_cv "0.0000 1.0000 0.0000"
set _sv $::VMDPathFinder::state(cvect); set ::VMDPathFinder::state(cvect) ""
chk "the manifest marks a guessed axis as guessed" \
    [::VMDPathFinder::_run_axis_manifest cvect] "0.0000 1.0000 0.0000 (guessed)"
set ::VMDPathFinder::state(cvect) "0 0 1"
chk "...and reports the user's own value plainly when it is set" \
    [::VMDPathFinder::_run_axis_manifest cvect] "0 0 1"
set ::VMDPathFinder::state(cvect) $_sv
::VMDPathFinder::_run_axis_reset


# ---------------------------------------------------------------------------
# MEAN OCCUPANCY VOLUME: counted from the FILLED lumen, not the boundary shell.
#
# HOLE's -999 records are the solvent-accessible SURFACE - measured on 1GRM their
# distance from the centreline has median 1.016x the local pore radius. Counting
# those voxels and multiplying by h^3 measures a shell, and a shell count is
# PROPORTIONAL TO h (N ~ area/h^2, times h^3 = area*h). Measured on an 8-frame
# Connolly run before the fix: 4607 / 3411 / 2388 A^3 at h = 1.5 / 1.0 / 0.75,
# i.e. almost exactly linear in h. After filling: 13298 / 12006 / 11112, and the
# ratio against the 1-D profile's own volume moved 0.29 -> 0.83.
set _mvr [info body ::VMDPathFinder::_mean_vol_frame_regions]
chk "the region builder fills the lumen, not just the boundary" \
    [expr {[string first {dict set out interior $interior} $_mvr] >= 0}] 1
# Using only the CORE region's own dots is what keeps the fill off the far tail:
# lateral spill and search-escape dots sit at 3-12x the local radius, and a global
# per-sector maximum would fill a cone of empty space.
chk "...from the core's OWN dots, capped at the core's own wall+margin" \
    [expr {[string first {if {$_r > $_wl + $margin} { set _r [expr {$_wl + $margin}] }} $_mvr] >= 0}] 1
chk "the reported volume counts the filled set" \
    [expr {[string first {dict exists $fields interior} \
        [info body ::VMDPathFinder::_mean_vol_build]] >= 0}] 1
# Filling must not reach the mesh: the surface spheres would be buried inside a
# solid for no visual gain and a large triangulation cost.
chk "...but the filled set never reaches the mesh" \
    [expr {[string first {if {$sid eq "interior"} { continue }} \
        [info body ::VMDPathFinder::_mean_vol_all_centers]] >= 0}] 1
chk "the filled lumen shares the CORE's persistence floor, not an opening's" \
    [::VMDPathFinder::_mean_vol_thresh interior] [::VMDPathFinder::_mean_vol_thresh 0]

# ---------------------------------------------------------------------------
# HYDRATION UNCERTAINTY: SD is spread and stays as it is; what is added is the
# error of the MEAN, corrected for the fact that consecutive MD frames are not
# independent samples, plus the censoring fraction the SD cannot express.
set _hyd2 [info body ::VMDPathFinder::compute_hydration]
chk "the per-bin autocorrelation pairs samples by ORDINAL distance" \
    [expr {[string first {set _lag [expr {$_acf_ord - $_po}]} $_hyd2] >= 0}] 1
# A bin only receives a frame whose own centerline reached it, so its series has
# GAPS. Pairing by buffer position instead of ordinal would file a lag-3 product
# under lag 1 and return a confident, wrong correlation time.
chk "...so a coverage gap cannot be mistaken for a shorter lag" \
    [expr {[string first {if {$_lag < 1 || $_lag > $_acf_L} { continue }} $_hyd2] >= 0}] 1
chk "the initial-positive-sequence truncation is applied" \
    [expr {[string first {if {$_rho <= 0.0} break} $_hyd2] >= 0}] 1
chk "SEM divides by the EFFECTIVE sample size, not the frame count" \
    [expr {[string first {set _sem [expr {$_gsd/sqrt($_ne)}]} $_hyd2] >= 0}] 1
# Every frame pinned at the dry floor carries the identical energy, so it adds no
# variance: a mostly-dry bin reports a small SD for a censoring reason, not a
# precision one. Counted so it can be reported beside the SD.
chk "frames pinned at the density floor are counted per bin" \
    [expr {[string first {lset g_floored $bi2} $_hyd2] >= 0}] 1
chk "the profile carries SEM, n_eff and the floored fraction" \
    [expr {[string first {energy_sem $energy_sem n_eff $n_eff floored_frac $floored_frac} $_hyd2] >= 0}] 1
# The ACF needs a time index, and Welford does not care about order.
chk "frames are put in chronological order before the series is built" \
    [expr {[string first {set perframe_raw [lsort -integer -index 1 $perframe_raw]} $_hyd2] >= 0}] 1
# The on-plot text was shortened (author feedback: too verbose) but the
# invariant stands: the band must LABEL ITSELF as spread, or it reads as a
# confidence interval. The full rationale lives in the comment above the
# annotation in draw_hydration_tab.
chk "the plot band says it is spread, not the error of the mean" \
    [expr {[string first {spread} \
        [info body ::VMDPathFinder::draw_hydration_tab]] >= 0}] 1


# ---------------------------------------------------------------------------
# A CONNOLLY profile is three different quantities in one column, and the CSV
# has to say which row is which. HOLE evaluates only some slices (equal-area
# Requiv); the "(mid-point)" rows it skips are interpolated from their
# neighbours; and where the pore opens out to bulk there is no Connolly radius
# at all, so the spherical probe stands in. On one real Nav frame that split was
# 76 measured / 73 interpolated / 168 spherical of 317 rows - a reader given only
# z and radius would treat a quarter-measured profile as fully measured.
set _pex [info body ::VMDPathFinder::export_profile_csv]
chk "the profile CSV names each row's radius source" \
    [expr {[string first {,radius_source} $_pex] >= 0}] 1
foreach _lbl {connolly_requiv interpolated spherical_probe} {
    chk "...with a distinct label for '$_lbl'" \
        [expr {[string first $_lbl $_pex] >= 0}] 1
}
# Methods with a single radius must not gain a column that would always read
# the same - the flag is keyed on the profile actually carrying mixed sources.
chk "...only when the profile really is mixed" \
    [expr {[string first {[lsearch -exact $_rsrc 1] >= 0 || [lsearch -exact $_rsrc 2] >= 0} $_pex] >= 0}] 1


# ---------------------------------------------------------------------------
# The mouth-zero energy shift defaults ON and was silently doing NOTHING.
#
# It anchored on bin floor(extreme_coverage/dz) and collected that bin's
# per-frame values inside the energy loop. But the bin is chosen from the extreme
# coverage COORDINATE, so its CENTRE can sit up to half a bin OUTSIDE the coverage
# range - and the loop's own coverage gate then skips it for every frame.
# Measured: lo_extreme -45.0005 selects bin -46, whose centre -45.5 is outside
# [-45.0005, ...], so the collected list came back empty and the shift stayed 0.0.
# The whole profile was left on the absolute -kT*ln(rho) scale, where bulk water
# sits near +2.1 kcal/mol instead of at zero, which makes the far end of a profile
# read as a large barrier when it is ordinary bulk.
set _hyd3 [info body ::VMDPathFinder::compute_hydration]
chk "the mouth shift anchors on the outermost MEASURED bins" \
    [expr {[string first {set alo [lindex $energy 0]} $_hyd3] >= 0}] 1
chk "...so it no longer depends on a bin the coverage gate rejects" \
    [expr {[string first {lappend anchor_lo_gvals $gv} $_hyd3] >= 0}] 0
# The trim above it removes exactly the zero-coverage bins, so after it every
# remaining bin has data and the two ends ARE the mouths - the shift has to stay
# downstream of the trim for that to hold.
chk "...and it still runs after the vacuous-bin trim" \
    [expr {[string first {set _keep {}} $_hyd3] < [string first {set alo [lindex $energy 0]} $_hyd3]}] 1


# ---------------------------------------------------------------------------
# KDE BOUNDARY BIAS: the water sample must extend PAST the profile's ends.
#
# Restricting the sample to [cmin,cmax] cuts each boundary bin's Gaussian in
# half, so the density there reads ~half of bulk as a pure edge artifact - and
# that deficit is then reported as a large free-energy barrier at both mouths.
# Validated against CHAP 0.9.1 on CHAP's OWN example-02 (4pirtm, 11 frames):
# our boundary bins read 0.501 and 0.507 of bulk where CHAP reads 1.04 and 1.08,
# while the interior already agreed to within 1%. After padding the sample by
# four bandwidths, on the same comparison:
#     chap-exact mode   density r 0.811 -> 0.979, ends -0.489 -> -0.122,
#                       energy  r 0.940 -> 0.986 (residual MAD 0.054 kcal/mol)
#     plugin defaults   density r 0.861 -> 0.918, ends -0.297 -> -0.118
set _hyd4 [info body ::VMDPathFinder::compute_hydration]
chk "the water sample is padded past the profile ends" \
    [expr {[string first {set _qlo [expr {$cmin - $_qpad}]} $_hyd4] >= 0}] 1
# There are TWO implementations of this selection - a C accelerator and the Tcl
# reference - and a fix applied to only one is silently a no-op whenever the
# other is the path actually taken. It was: the first attempt patched only the
# Tcl branch and changed nothing at all, because the C path runs by default.
chk "...for the ACCELERATED path" \
    [expr {[string first {_hydro_qco_c $wres $wpos $mx $my $mz $ux $uy $uz $_qlo $_qhi} $_hyd4] >= 0}] 1
chk "...and for the Tcl reference path" \
    [expr {[string first {if {$co < $_qlo || $co > $_qhi} { continue }} $_hyd4] >= 0}] 1
# Widening the SAMPLE must not widen what is REPORTED: frame_range still carries
# the true coverage, which is what the energy loop's own gate uses.
chk "...but the reported coverage range is untouched" \
    [expr {[string first {dict set frame_range $frame [list $cmin $cmax]} $_hyd4] >= 0}] 1
# No pad when the density is a plain histogram - there is no kernel to truncate.
chk "...and there is no pad without a kernel" \
    [expr {[string first {set _qpad 0.0} $_hyd4] >= 0}] 1


# ---------------------------------------------------------------------------
# CONNOLLY regions are slices of ONE mesh, not a mesh each.
#
# sph_process keeps a sphere's dots wherever no neighbour buries them, so a
# lateral lobe meshed on its own retains the face the pore's own spheres would
# have covered, and renders as a sealed blob instead of an open flare. That is
# why pore_lat / pore_lobes grew blobs the plain CONNOLLY surface does not have.
# Meshing the whole cloud once and dividing the triangles afterwards gives
# exactly the surface plain CONNOLLY draws. Measured on a real Nav frame: one
# 100198-triangle surface, split into 6 regions totalling 100190 (pore 86526,
# five openings 1618-3372).
set _rm [info body ::VMDPathFinder::_build_conn_region_meshes]
chk "the regions are cut from one whole-cloud mesh" \
    [expr {[string first {_split_conn_mesh_by_region $_uni_plot $cls $regions $_outof} $_rm] >= 0}] 1
# Each region must still land in its OWN plot file, or per-region colour,
# material, property and show/hide all break.
chk "...but each region still gets its own plot file" \
    [expr {[string first {dict set _outof $name $rplot} $_rm] >= 0}] 1
# A run directory from before this change holds sealed-lobe plots whose mtime is
# already newer than the .sph, so the reuse check would serve them forever.
chk "...and the cache tag carries the recipe version" \
    [regexp {_d\$\{_rdd\}_u[0-9]+} $_rm] 1
chk "...with a fallback if the union mesh or the split fails" \
    [expr {[string first {falling back to a mesh per region} $_rm] >= 0}] 1
# A triangle inherits its region from the nearest CLASSIFIED DOT, so it is never
# re-derived against a centreline it may sit far from.
chk "a triangle takes its region from the nearest classified dot" \
    [expr {[string first {set best $nm} [info body ::VMDPathFinder::_split_conn_mesh_by_region]] >= 0}] 1


# ---------------------------------------------------------------------------
# The union mesh must be built from the SAME .sph plain CONNOLLY meshes, not a
# copy reconstructed from the classifier's keep/pore/lateral lists.
#
# _conn_classify_sph drops residue -888 while collecting keep/pore/lateral -
# HOLE's own escaped/off-axis search spheres, real spheres with real radii (see
# _trim_conn_escaped_sph). Reconstructing the union .sph from the classifier's
# output therefore silently lost them even when the axial trim itself was off
# and plain CONNOLLY's own input still had them. Measured on a real Nav frame:
# -999 dot count identical (11131 = 11131) between hole_out.sph and the
# reconstructed union .sph, but 69 -888 records were missing, and the resulting
# mesh differed by 6% of its triangles (94844 vs 100652) - visually, pore_lat
# and pore_lobes rendered the lateral regions as sealed balls on a stick, while
# plain CONNOLLY (same underlying dot cloud, same viewport) did not. Rendered
# and compared directly (offscreen VMD snapshots): after using src_sph verbatim,
# the union mesh triangle count matches plain CONNOLLY's own EXACTLY (94844 =
# 94844), and pore_lat/pore_lobes no longer show sealed lobes.
set _rm2 [info body ::VMDPathFinder::_build_conn_region_meshes]
chk "the union mesh is built from src_sph itself, not a copy" \
    [expr {[string first {set _mesh_src $src_sph} $_rm2] >= 0}] 1
chk "...so it is never reconstructed from cls(keep) any more" \
    [expr {[string first {dict exists $cls keep} $_rm2] >= 0}] 0
# A large cloud must reduce the SAME way plain CONNOLLY's own display path
# does, or the two would still mesh clouds of different sizes.
chk "...and a large cloud is reduced with the SAME call plain CONNOLLY uses" \
    [expr {[string first {_reduce_conn_sph $_mesh_src $_uni_sph 0 $_target} $_rm2] >= 0}] 1

# --- A memory hidden with P stays hidden across a memory switch ---------------
# The row refresh turned every other memory's track back on; now only the
# tracks the plugin itself hid (leaving spherical) come back.
set _sv_mem [list [array get ::VMDPathFinder::mem_surface_mols] $::VMDPathFinder::pore_memories \
                  $::VMDPathFinder::pore_memory_active]
array unset ::VMDPathFinder::mem_surface_mols
set _ma [mol new]; set _mb [mol new]
set ::VMDPathFinder::mem_surface_mols(0|1) $_ma
set ::VMDPathFinder::mem_surface_mols(0|2) $_mb
set ::VMDPathFinder::pore_memories [dict create 1 {} 2 {}]
set ::VMDPathFinder::pore_memory_active 3
mol off $_ma
::VMDPathFinder::_mem_show_tracks 0
chk "leaving spherical hides the shown track" [molinfo $_mb get displayed] 0
::VMDPathFinder::_mem_show_tracks 1
chk "...and coming back shows it again" [molinfo $_mb get displayed] 1
chk "...but not the one the user had hidden" [molinfo $_ma get displayed] 0
::VMDPathFinder::_mem_show_tracks 1
chk "a second refresh still leaves it hidden" [molinfo $_ma get displayed] 0
catch {mol delete $_ma}; catch {mol delete $_mb}
array unset ::VMDPathFinder::mem_surface_mols
array set ::VMDPathFinder::mem_surface_mols [lindex $_sv_mem 0]
set ::VMDPathFinder::pore_memories [lindex $_sv_mem 1]
set ::VMDPathFinder::pore_memory_active [lindex $_sv_mem 2]

# --- The lining follows the frame, and a hidden tunnel track is not meshed ---
chk "the lining is updated on the per-frame render path, not only on settle" \
    [expr {[string first {update_pore_lining_rep} [info body ::VMDPathFinder::_draft_render_frame]] >= 0 \
        && [string first {update_pore_facing_rep} [info body ::VMDPathFinder::_draft_render_frame]] >= 0}] 1
chk "...but not while playing" \
    [expr {[string first {!$playing} [info body ::VMDPathFinder::_draft_render_frame]] >= 0}] 1
chk "the plugin's own transport honours the hidden tunnel track" \
    [expr {[string first {tunnel_surface_is_hidden} [info body ::VMDPathFinder::goto_trajectory_frame]] >= 0}] 1
chk "...and showing the track again re-renders the landed frame" \
    [expr {[string first {render_tunnels_for_frame $_landed} \
        [info body ::VMDPathFinder::_tunnel_hide_geometry_for_mean]] >= 0}] 1

# --- A wide capsule mouth is clipped to the end radius, not thrown away -----
# The probe lies flat there and its far end runs tens of Angstroms out along
# the surface; dropping the slice cut the drawn pore short of HOLE's profile.
lassign [::VMDPathFinder::_capsule_clip_segment 0 0 0 40 0 0  0 0 0  0 0 1  12.0] _cx1 _cy1 _cz1 _cx2 _cy2 _cz2
chk "a slice reaching past the end radius keeps the part inside it" \
    [expr {$_cx1 == 0 && abs($_cx2 - 12.0) < 1e-6}] 1
lassign [::VMDPathFinder::_capsule_clip_segment 20 0 0 40 0 0  0 0 0  0 0 1  12.0] _cx1
chk "...and one entirely outside is dropped" [expr {$_cx1 eq ""}] 1
lassign [::VMDPathFinder::_capsule_clip_segment 0 0 -5 0 0 5  0 0 0  0 0 1  12.0] _cx1 _cy1 _cz1 _cx2 _cy2 _cz2
chk "...while one inside is untouched" [expr {$_cz1 == -5 && $_cz2 == 5}] 1
chk "the ring builder clips rather than dropping" \
    [expr {[string first {_capsule_clip_segment} [info body ::VMDPathFinder::_capsule_rings]] >= 0}] 1

# --- The Mean Profile tube belongs to one analysis ---------------------------
# It is built from one memory's frames, so a memory switch, a new memory or a
# delete drops it. Left standing it also came back on its own, because a later
# surface redraw re-solos the mean while show_mean_surface is still set.
foreach _p {_mem_activate _mem_new _mem_delete} {
    chk "$_p drops the mean surface" \
        [expr {[string first {_mem_drop_mean_surface} [info body ::VMDPathFinder::$_p]] >= 0}] 1
}
chk "...by the same call that removes it everywhere else" \
    [expr {[string first {remove_mean_surface} \
        [info body ::VMDPathFinder::_mem_drop_mean_surface]] >= 0}] 1

# --- The cavity gear has ONE colour control, and quitting stops the helpers --
chk "the pocket gear offers a single Color by" \
    [expr {[string first {cavgear_by "Color by"} [info body ::VMDPathFinder::show_cavity_gear_settings]] >= 0
        && [string first {cavgear_color "Color"} [info body ::VMDPathFinder::show_cavity_gear_settings]] < 0}] 1
chk "...whose properties are named in full" \
    [expr {[string first {_tunnel_prop_label $o} [info body ::VMDPathFinder::show_cavity_gear_settings]] >= 0}] 1
chk "...and a property choice clears the flat colour" \
    [expr {[string first {dict remove $cavity_gear_color $tid} [info body ::VMDPathFinder::_cavity_gear_set]] >= 0}] 1
chk "quitting VMD stops the helper processes, not just closing the panel" \
    [expr {[string first {_csg_server_close} [info body ::VMDPathFinder::_stop_background_work]] >= 0
        && [string first {_pw_shutdown} [info body ::VMDPathFinder::_stop_background_work]] >= 0}] 1
chk "...and closing the panel stops the per-frame workers too" \
    [expr {[string first {_pw_shutdown} [info body ::VMDPathFinder::close_gui]] >= 0}] 1
chk "Show all keeps the cavities window where it is" \
    [expr {[string first {wm geometry $t $_geom} [info body ::VMDPathFinder::_cavity_show_all_tracks]] >= 0}] 1

puts "SMOKE-RESULT pass=$pass fail=$fail"
quit
