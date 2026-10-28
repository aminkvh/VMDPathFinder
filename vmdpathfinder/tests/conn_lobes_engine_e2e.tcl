# End-to-end check of the native conn_lobes engine (classify + cluster +
# triangle-to-region split) against the pure-Tcl reference it replaces, on a
# real Connolly run's own output.
set pass 0; set fail 0
proc chk {name got want} {
    global pass fail
    if {$got eq $want} { incr pass; puts "  PASS  $name = $got" } \
    else { incr fail; puts "  FAIL  $name = $got (expected $want)" }
}
proc note {msg} { puts "  ....  $msg" }
proc done {} { global pass fail; puts "CL-RESULT pass=$pass fail=$fail"; quit }
set here [expr {[info exists ::env(VMDPATHFINDER_TEST_DIR)] && $::env(VMDPATHFINDER_TEST_DIR) ne ""
                ? $::env(VMDPATHFINDER_TEST_DIR) : [pwd]}]
set root [file normalize [file join $here .. ..]]
set PDB  [file join $root vmdpathfinder 1GRM.pdb]
set RAD  [file join $root native stock_build hole2 rad simple.rad]
cd [file join $here ..]
source vmdpathfinder.tcl
::VMDPathFinder::init_executables
if {[info exists ::env(VMDPATHFINDER_TEST_HOLE)] && $::env(VMDPATHFINDER_TEST_HOLE) ne ""} {
    set ::VMDPathFinder::state(hole_exec) $::env(VMDPATHFINDER_TEST_HOLE)
}
set exe [::VMDPathFinder::tool_path conn_lobes]
if {$exe eq ""} {
    set cand [file join $root native conn_lobes]
    if {[file executable $cand]} { set ::VMDPathFinder::state(conn_lobes_exec) $cand; set exe $cand }
}
if {$exe eq ""} { puts "SKIP: conn_lobes_engine - no conn_lobes binary (sh native/build.sh)"; done }
# Its subcommand with it: the fallback run below switches the engine off, and
# a later tool_args would then return nothing for this binary.
set exe_args [::VMDPathFinder::tool_args conn_lobes]
note "conn_lobes = $exe $exe_args"
if {![file readable $PDB] || ![file readable $RAD]} { puts "SKIP: conn_lobes_engine - no 1GRM fixture"; done }
if {![file executable $::VMDPathFinder::state(hole_exec)]} { puts "SKIP: conn_lobes_engine - no HOLE binary"; done }

# Produce one real Connolly hole_out.sph to classify against.
set mid [mol new $PDB waitfor all]
set work [file join [::VMDPathFinder::get_temp_base] "vmdpathfinder_cl_[pid]"]
file delete -force $work; file mkdir $work
array set ::VMDPathFinder::state [list molid $mid frame_spec 0 selection all radius_file $RAD \
    cpoint {0 0 0} cvect {0 0 1} sample 0.5 endrad 12.0 random_seed 1 pore_method connolly \
    display_mode triangulated surface_color pore_lobes dot_density 8 work_dir $work keep_input_pdb 0 \
    save_results 1 extra_cards {} ignore {} hole_fix_atom_names 0 hole_tcl_fallback 0 \
    search_engine mc conn_engine hole prebuild_surfaces 0]
::VMDPathFinder::validate_inputs
if {[catch {::VMDPathFinder::run_analysis} err]} { chk "Connolly run completes" "error: $err" "no error"; done }
chk "one result frame" [llength $::VMDPathFinder::result_frames] 1
if {![llength $::VMDPathFinder::result_frames]} { done }
set f [lindex $::VMDPathFinder::result_frames 0]
set rd [dict get $::VMDPathFinder::results $f run_dir]
set sph [file join $rd hole_out.sph]
chk "hole_out.sph produced" [file exists $sph] 1
if {![file exists $sph]} { done }

set cv {0 0 1}; set cp {0 0 0}; set margin 2.0
set cls_native [::VMDPathFinder::_conn_classify_sph $sph $cv $cp $margin]
chk "native classify ran" [dict exists $cls_native lobes] 1
set lobes_native [::VMDPathFinder::_conn_frame_lobes $cls_native]

rename ::VMDPathFinder::tool_path ::VMDPathFinder::_real_tool_path
proc ::VMDPathFinder::tool_path {name} { if {$name eq "conn_lobes"} { return "" }; ::VMDPathFinder::_real_tool_path $name }
set cls_tcl [::VMDPathFinder::_conn_classify_sph $sph $cv $cp $margin]
set lobes_tcl [::VMDPathFinder::_conn_frame_lobes $cls_tcl]
rename ::VMDPathFinder::tool_path {}
rename ::VMDPathFinder::_real_tool_path ::VMDPathFinder::tool_path

# The Ion & Water scan's sphere list: native `ionspheres` (classify + voxel
# thinning + escaped filter in one pass, cached beside the .sph) must give the
# Tcl path's set.
proc _sph_set {lst} {
    set o {}
    foreach s $lst { lassign $s x y z r; lappend o [format "%.3f %.3f %.3f %.3f" $x $y $z $r] }
    return [lsort $o]
}
set sp_native [::VMDPathFinder::_conn_ionflow_spheres_fast $sph $cv $cp $margin]
rename ::VMDPathFinder::tool_path ::VMDPathFinder::_real_tool_path
proc ::VMDPathFinder::tool_path {name} { if {$name eq "conn_lobes"} { return "" }; ::VMDPathFinder::_real_tool_path $name }
set sp_tcl [::VMDPathFinder::_conn_ionflow_spheres_fast $sph $cv $cp $margin]
rename ::VMDPathFinder::tool_path {}
rename ::VMDPathFinder::_real_tool_path ::VMDPathFinder::tool_path
chk "ion-scan sphere list: native ran" [expr {[llength $sp_native] > 0}] 1
chk "ion-scan sphere list: native matches Tcl" [expr {[_sph_set $sp_native] eq [_sph_set $sp_tcl]}] 1
chk "ion-scan sphere list is cached beside the .sph" [llength [glob -nocomplain [file join $rd hole_out_ionsph_*.dat]]] 1
set sp_cached [::VMDPathFinder::_conn_ionflow_spheres_fast $sph $cv $cp $margin]
chk "...and the cache reads back the same set" [expr {[_sph_set $sp_cached] eq [_sph_set $sp_native]}] 1

note "n_pore=[dict get $cls_native n_pore] n_lat=[dict get $cls_native n_lat] lobes=[llength $lobes_native]"
chk "pore dot count matches Tcl" [dict get $cls_native n_pore] [dict get $cls_tcl n_pore]
chk "lateral dot count matches Tcl" [dict get $cls_native n_lat] [dict get $cls_tcl n_lat]
chk "pore dot SET matches Tcl" [expr {[lsort [dict get $cls_native pore]] eq [lsort [dict get $cls_tcl pore]]}] 1
chk "lateral dot SET matches Tcl" [expr {[lsort [dict get $cls_native lateral]] eq [lsort [dict get $cls_tcl lateral]]}] 1
chk "keep line SET matches Tcl" [expr {[lsort [dict get $cls_native keep]] eq [lsort [dict get $cls_tcl keep]]}] 1
set _esc_ok 1
foreach rn [dict get $cls_native escaped_ranges] rt [dict get $cls_tcl escaped_ranges] {
    lassign $rn lon hin; lassign $rt lot hit
    if {abs($lon-$lot) > 1e-6 || abs($hin-$hit) > 1e-6} { set _esc_ok 0 }
}
if {[llength [dict get $cls_native escaped_ranges]] != [llength [dict get $cls_tcl escaped_ranges]]} { set _esc_ok 0 }
chk "escaped ranges match Tcl (numerically)" $_esc_ok 1
chk "lobe count matches Tcl" [llength $lobes_native] [llength $lobes_tcl]
set lobe_mismatch 0
foreach ln $lobes_native lt $lobes_tcl {
    lassign $ln zn an nn idxn efn kan kbn
    lassign $lt zt at nt idxt eft kat kbt
    if {$nn != $nt} { incr lobe_mismatch; continue }
    if {abs($zn-$zt) > 1e-6 || abs($an-$at) > 1e-6} { incr lobe_mismatch; continue }
    if {[lsort -integer $idxn] ne [lsort -integer $idxt]} { incr lobe_mismatch }
}
chk "every lobe's stats and membership match Tcl" $lobe_mismatch 0

# HOLE's LAST-REC-END clip markers: both classifiers must report the same set,
# every writer must put them back, and the point-cloud reducer must keep them -
# a clip sphere written without its marker is drawn as a smooth ball.
set src_markers 0
set fh [open $sph r]
while {[gets $fh l] >= 0} { if {[string range $l 0 11] eq "LAST-REC-END"} { incr src_markers } }
close $fh
note "source sph carries $src_markers LAST-REC-END markers"
chk "native and Tcl agree on the marked-record set" \
    [expr {[lsort [dict keys [dict get $cls_native marked]]] eq [lsort [dict keys [dict get $cls_tcl marked]]]}] 1
chk "some records are marked when the source has markers" \
    [expr {$src_markers == 0 || [dict size [dict get $cls_native marked]] > 0}] 1
proc _count_markers {f} { set n 0; set fh [open $f r]; while {[gets $fh l] >= 0} { if {[string range $l 0 11] eq "LAST-REC-END"} { incr n } }; close $fh; return $n }
set _rs [file join $work region_check.sph]
::VMDPathFinder::_write_conn_region_sph $cls_native pore $_rs
set _expect 0
foreach l [concat [dict get $cls_native keep] [dict get $cls_native pore]] { if {[dict exists [dict get $cls_native marked] $l]} { incr _expect } }
chk "region sph restores every marker of its records" [_count_markers $_rs] $_expect
set _red [file join $work reduced_check.sph]
set _nr [::VMDPathFinder::_reduce_conn_sph $sph $_red 0 50]
set _clip 0; set _clipkept 0
set fh [open $sph r]; while {[gets $fh l] >= 0} { if {[string match "ATOM*" $l] && [string trim [string range $l 22 26]] ne "-999"} { incr _clip } }; close $fh
set fh [open $_red r]; while {[gets $fh l] >= 0} { if {[string match "ATOM*" $l] && [string trim [string range $l 22 26]] ne "-999"} { incr _clipkept } }; close $fh
chk "reducer keeps every non-dot (centre/escape/clip) record" $_clipkept $_clip
chk "reducer keeps the markers of what it keeps" [expr {$src_markers == 0 || [_count_markers $_red] > 0}] 1

# region-mesh pipeline: native split vs Tcl split, through the real builder.
proc run_pipeline {label force_tcl} {
    global sph work mid
    if {$force_tcl} {
        rename ::VMDPathFinder::tool_path __saved_engine_path
        proc ::VMDPathFinder::tool_path {name} { if {$name eq "conn_lobes"} { return "" }; __saved_engine_path $name }
    }
    set rundir [file join $work $label]; file delete -force $rundir; file mkdir $rundir
    set cls [::VMDPathFinder::_conn_classify_sph $sph {0 0 1} {0 0 0} 2.0]
    set lobes [::VMDPathFinder::_conn_frame_lobes $cls]
    set regions [list [list pore [dict get $cls pore] red 1]]
    set li 0
    foreach lb $lobes {
        lassign $lb z a n idx ef ka kb
        set lines {}
        foreach i $idx { lappend lines [lindex [dict get $cls lateral] $i] }
        lappend regions [list "lobe$li" $lines blue 1]
        incr li
    }
    set t0 [clock milliseconds]
    set parts [::VMDPathFinder::_build_conn_region_meshes $rundir $cls $regions 8 $sph $mid]
    set ms [expr {[clock milliseconds]-$t0}]
    if {$force_tcl} {
        rename ::VMDPathFinder::tool_path {}
        rename __saved_engine_path ::VMDPathFinder::tool_path
    }
    # parts alternates plot-path, {color material} - key by basename (same
    # tag/dotden naming rule in both runs, only the run dir differs) so the
    # two runs' outputs line up.
    set tris {}
    foreach {plot color} $parts {
        set b [file tail $plot]
        set lines {}
        if {[file exists $plot]} {
            set fh [open $plot r]
            foreach l [split [read $fh] "\n"] { if {[string match "draw trinorm *" $l]} { lappend lines $l } }
            close $fh
        }
        dict set tris $b $lines
    }
    note "$label: [llength $parts] part(s), [expr {$ms}] ms, [dict size $tris] surface(s)"
    return $tris
}
set tris_native [run_pipeline native 0]
set tris_tcl [run_pipeline tclfallback 1]
chk "same surfaces built, native vs Tcl" [lsort [dict keys $tris_native]] [lsort [dict keys $tris_tcl]]
set tri_mismatch 0
dict for {b lines} $tris_native {
    set tl [expr {[dict exists $tris_tcl $b] ? [dict get $tris_tcl $b] : "-missing-"}]
    if {[lsort $lines] ne [lsort $tl]} { incr tri_mismatch; note "  triangle set differs for $b: native=[llength $lines] tcl=[llength $tl]" }
}
chk "every surface's triangle set is BYTE-IDENTICAL to Tcl" $tri_mismatch 0

# --- two mouths on different sides must not come back as one opening -------
# A synthetic cloud: a straight pore along z, plus two side mouths 90 deg
# apart at the same height, joined by a thin collar of dots hugging the wall.
# Plain flood fill walks the collar and reports one lobe.
set synth [file join $work synth.sph]
set fh [open $synth w]
set _n 0
proc _sph_atom {fh resid x y z r b} {
    puts $fh [format "ATOM  %5d  Q%s SPH S%4d    %8.3f%8.3f%8.3f%6.2f%6.2f" \
        1 [expr {$resid < 0 ? "SS" : "SS"}] $resid $x $y $z $r $b]
}
# centreline spheres, radius 3, z -20..20
for {set z -20} {$z <= 20} {incr z} { _sph_atom $fh 1 0 0 $z 3.0 1.0 }
# pore dots on the wall of that tube
for {set z -20} {$z <= 20} {incr z} {
    for {set k 0} {$k < 36} {incr k} {
        set th [expr {$k*10.0*acos(-1.0)/180.0}]
        _sph_atom $fh -999 [expr {3.0*cos($th)}] [expr {3.0*sin($th)}] $z 1.15 0.0
    }
}
# mouth A at azimuth 0, mouth B at azimuth 90 deg, both at z 0, out to r 14
foreach {ax ay} {1.0 0.0 0.0 1.0} {
    for {set rr 6} {$rr <= 14} {incr rr} {
        for {set dz -2} {$dz <= 2} {incr dz} {
            for {set s -2} {$s <= 2} {incr s} {
                _sph_atom $fh -999 [expr {$rr*$ax - 0.6*$s*$ay}] [expr {$rr*$ay + 0.6*$s*$ax}] \
                    [expr {0.8*$dz}] 1.15 0.0
            }
        }
    }
}
# the collar: a sparse arc at r 6 joining them
for {set k 1} {$k < 9} {incr k} {
    set th [expr {$k*10.0*acos(-1.0)/180.0}]
    for {set dz -1} {$dz <= 1} {incr dz} {
        _sph_atom $fh -999 [expr {6.0*cos($th)}] [expr {6.0*sin($th)}] [expr {1.0*$dz}] 1.15 0.0
    }
}
close $fh
# The binary and subcommand resolved at the top: the fallback run above swapped tool_path out.
set _nl 0
set _azs {}
if {[catch {exec $exe {*}$exe_args classify $synth 0 0 0 0 0 1 2.0} _out]} {
    note "classify failed: [lindex [split $_out \n] 0]"
} else {
    set _ls [split $_out "\n"]
    for {set _i 0} {$_i < [llength $_ls]} {incr _i} {
        if {![string match "LOBE *" [lindex $_ls $_i]]} continue
        set _n [lindex [lindex $_ls $_i] 1]
        for {set _k 1} {$_k <= $_n} {incr _k} {
            set _f [lindex $_ls [expr {$_i+$_k}]]
            if {[lindex $_f 2] < 50} continue
            incr _nl
            lappend _azs [format %.0f [expr {[lindex $_f 1]*57.29578}]]
        }
        break
    }
}
note "synthetic two-mouth cloud: $_nl lobe(s) at azimuth [lsort -real $_azs] deg"
chk "two mouths joined by a thin collar are two openings, not one" $_nl 2
set _sep 0
if {[llength $_azs] == 2} {
    set _d [expr {abs([lindex $_azs 0] - [lindex $_azs 1])}]
    if {$_d > 180} { set _d [expr {360 - $_d}] }
    set _sep [expr {$_d > 60 && $_d < 120}]
}
chk "...about 90 degrees apart" $_sep 1

catch {file delete -force $work}
done
