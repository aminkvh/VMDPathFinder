# The ellipse probe's C accelerator must agree with its Tcl reference.
#
# The last of the four engine pairs to get parity coverage. HOLE, MOLE and the
# hydration projection each had a C-vs-Tcl test; the ellipse had both paths
# wired and live (_asym_ellipse_c returns "" -> _asym_ellipse_tcl) with nothing
# asserting they produce the same numbers. test_accel_parity.sh does NOT cover
# this: it compares the accelerated binary against STOCK C, never against Tcl.
#
# Only the first few slices are compared. The Tcl fit is ~60 ms/slice here and
# far worse on a real channel, and what is under test is agreement per slice,
# not throughput - the C path is checked over the whole profile by its own
# length assertion.

set pass 0; set fail 0
proc chk {name got want} {
    global pass fail
    if {$got eq $want} { incr pass; puts "  PASS  $name = $got" } \
    else { incr fail; puts "  FAIL  $name = $got (expected $want)" }
}
proc note {msg} { puts "  ....  $msg" }
proc done {} {
    global pass fail
    puts "ELLIPSE-RESULT pass=$pass fail=$fail"
    quit
}

set here [expr {[info exists ::env(VMDPATHFINDER_TEST_DIR)] && $::env(VMDPATHFINDER_TEST_DIR) ne ""
                ? $::env(VMDPATHFINDER_TEST_DIR) : [pwd]}]
set root [file normalize [file join $here .. ..]]
set PDB  [file join $root vmdpathfinder 1GRM.pdb]
set RAD  [file join $root native stock_build hole2 rad simple.rad]

cd [file join $here ..]
source vmdpathfinder.tcl
# Point the plugin at the engines the suite built before letting it discover.
# find_hole_exe only searches four fixed install paths, so on a tree that builds
# into native/build this group skipped for "no sos_triangle with --asym-ellipse"
# while a perfectly capable one sat in $VMDPATHFINDER_HOLE_EXE_DIR.
if {[info exists ::env(VMDPATHFINDER_HOLE_EXE_DIR)] && $::env(VMDPATHFINDER_HOLE_EXE_DIR) ne ""} {
    foreach {_k _n} {hole_exec hole sph_process_exec sph_process
                     sos_triangle_exec sos_triangle mole_engine_exec mole_tunnel_engine} {
        set _p [file join $::env(VMDPATHFINDER_HOLE_EXE_DIR) $_n]
        if {[file executable $_p]} { set ::VMDPathFinder::state($_k) $_p }
    }
}
::VMDPathFinder::init_executables

if {![file readable $PDB] || ![file readable $RAD]} { puts "SKIP: ellipse_parity - no 1GRM fixture"; done }
if {![::VMDPathFinder::asymmetry_c_available] || ![::VMDPathFinder::sos_triangle_has_feature asymellipse]} {
    puts "SKIP: ellipse_parity - no sos_triangle with --asym-ellipse"
    done
}

set work [file join [::VMDPathFinder::get_temp_base] "vmdpathfinder_ell_[pid]"]
file mkdir $work
set mid [mol new $PDB waitfor all]
array set ::VMDPathFinder::state [list molid $mid frame_spec 0 selection all \
    radius_file $RAD cpoint {0 0 0} cvect {0 0 1} sample 0.5 endrad 8.0 \
    random_seed 1 pore_method circular display_mode none work_dir $work \
    save_results 1 extra_cards {} ignore {}]

if {[catch {::VMDPathFinder::run_analysis} rerr]} {
    chk "the HOLE run needed for a .sph completes" "error: $rerr" "no error"
    catch {file delete -force $work}
    done
}

set g [::VMDPathFinder::_asym_gather $mid 0]
if {$g eq ""} {
    # Not a skip: _asym_gather returning "" is how the missing-.sph bug looked,
    # and quietly skipping here is what let it sit unnoticed.
    chk "the run produced a usable .sph centerline" 0 1
    catch {file delete -force $work}
    done
}
lassign $g centers radii atoms u sph
chk "gathered a centerline" [expr {[llength $centers] > 5 ? 1 : 0}] 1

# Both paths take the neighbour box from state(ellipse_box): the default 1.6
# (PoreAnalyser's) and the 3.0 the older binaries fixed.
foreach box {1.6 3.0} {
    set ::VMDPathFinder::state(ellipse_box) $box
    set N 32
    set c [::VMDPathFinder::_asym_ellipse_c $atoms $sph $N]
    chk "box $box: C returns one row per slice" [llength $c] [llength $centers]

    set k 3
    set t0 [clock milliseconds]
    set t [::VMDPathFinder::_asym_ellipse_tcl $atoms [lrange $centers 0 [expr {$k-1}]] \
               [lrange $radii 0 [expr {$k-1}]] $N]
    note "box $box: Tcl fitted $k slices in [expr {[clock milliseconds]-$t0}] ms"
    chk "box $box: Tcl returns one row per requested slice" [llength $t] $k

    # The C writes its sidecar at float precision, so agreement is ~1e-6, not exact.
    set worst_b 0.0
    set worst_a 0.0
    for {set i 0} {$i < $k} {incr i} {
        lassign [lindex $c $i] cb ca
        lassign [lindex $t $i] tb ta
        # A missing C row must fail here, not compare as 0.
        if {$cb eq "" || $tb eq ""} { set worst_b 1e9; set worst_a 1e9; break }
        set db [expr {abs($cb - $tb)}]
        set da [expr {abs($ca - $ta)}]
        if {$db > $worst_b} { set worst_b $db }
        if {$da > $worst_a} { set worst_a $da }
    }
    note "worst |db| [format %.3g $worst_b], worst |da| [format %.3g $worst_a]"
    chk "box $box: minor axis agrees (|d| < 1e-5)" [expr {$worst_b < 1e-5 ? 1 : 0}] 1
    chk "box $box: major axis agrees (|d| < 1e-5)" [expr {$worst_a < 1e-5 ? 1 : 0}] 1
}

catch {mol delete $mid}
catch {file delete -force $work}
done
