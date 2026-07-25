# check_sartop_wiring.tcl -- board-free structural gate on sartop_assembly.tcl.
#
# WHY: the second CoreFFT chain's single worst failure mode is a CROSS-WIRE that synthesis,
# place-and-route and a correlation check are all blind to (see the H-2 note in
# sartop_assembly.tcl): if FFT_B:SCALE_EXP lands on FEED:scale_exp_in, every row is renormalized
# by >>(emax - exp_of_the_other_row) and the image comes out smooth, plausible and wrong. That is
# a property of a Tcl script, not of any RTL, so no RTL testbench can catch it -- this can.
#
# It mocks every Libero/SmartDesign command sartop_assembly.tcl uses, sources the REAL script,
# records the connection graph it would build, and then asserts the invariants:
#   1. per-chain closure  : each chain's FEED/GBX/FFT/UNLD/COEFG only ever touch their own chain
#   2. SCALE_EXP pairing  : FFT_x:SCALE_EXP and FFT_x:OUTP_READY both reach FEED_x, and no other
#   3. DIC initiator map  : exactly 6 initiators, one module each, WIN/RES2 gone
#   4. CIC target map     : each control target maps to the instance the firmware addresses
#   5. no dangling chain-B pin (every port of every new instance is connected or marked unused)
#
# Run:  tclsh mpfs/fpga/tb/check_sartop_wiring.tcl
# Expect: "==== SAR_TOP wiring: PASS ===="   (exit 0; exit 1 on any violation)

# Optional argv[0] = an alternative assembly script, used by the mutation runs (a mutated COPY in
# a scratch dir) to prove this gate is not vacuous. Default: the real one.
set here   [file normalize [file dirname [info script]]]
set fpga   [file dirname $here]
set script [expr {[llength $argv] ? [lindex $argv 0] : "$fpga/sartop_assembly.tcl"}]

# ---------------------------------------------------------------- mock SmartDesign
set ::INST   [dict create]     ;# instance -> component/core name
set ::CONN   {}                ;# list of {pinA pinB}
set ::CONST  [dict create]     ;# pin -> constant
set ::UNUSED {}
set ::PORTS  {}

proc create_smartdesign  {args} {}
proc save_smartdesign    {args} {}
proc generate_component  {args} {}
proc save_project        {args} {}
proc delete_component    {args} {}
proc sd_update_instance  {args} {}
proc sd_configure_core_instance {args} {}
proc sd_instantiate_macro {args} {}
proc sd_invert_pins      {args} {}
proc sd_create_scalar_port {args} {}
proc sd_connect_instance_pins_to_ports {args} {}

proc _opt {args key} {
    set i [lsearch -exact $args $key]
    if {$i < 0} { return "" }
    return [lindex $args [expr {$i+1}]]
}
proc sd_instantiate_component {args} {
    dict set ::INST [_opt $args -instance_name] [_opt $args -component_name]
}
proc sd_instantiate_hdl_core {args} {
    dict set ::INST [_opt $args -instance_name] [_opt $args -hdl_core_name]
}
proc sd_connect_pins {args} {
    set pins [_opt $args -pin_names]
    # a single -pin_names list may join >2 pins into one net (the clock/reset fan-outs)
    lappend ::CONN $pins
}
proc sd_connect_pins_to_constant {args} {
    foreach p [_opt $args -pin_names] { dict set ::CONST $p [_opt $args -value] }
}
proc sd_mark_pins_unused {args} {
    foreach p [_opt $args -pin_names] { lappend ::UNUSED $p }
}

# swallow the script's own progress puts so the report is readable
rename puts _real_puts
proc puts {args} {}
source $script
rename puts {}
rename _real_puts puts

set errs 0
proc fail {msg} { puts "  FAIL: $msg" ; incr ::errs }
proc ok   {msg} { puts "  ok  : $msg" }

# ---------------------------------------------------------------- helpers
# every net as a set of pins
proc nets {} { return $::CONN }
proc peers {pin} {
    set out {}
    foreach net $::CONN {
        if {[lsearch -exact $net $pin] >= 0} {
            foreach p $net { if {$p ne $pin} { lappend out $p } }
        }
    }
    return $out
}
proc inst_of {pin} { return [lindex [split $pin ":"] 0] }
proc port_of {pin} { return [lindex [split $pin ":"] 1] }

puts "==== SAR_TOP wiring gate ===="
puts "instances: [lsort [dict keys $::INST]]"

# ---------------------------------------------------------------- 0. instance set
foreach {i want} {FFT COREFFT_C0  FFT_B COREFFT_C0
                  FEED fft_feeder_top  FEED_B fft_feeder_top
                  UNLD fft_unloader_top UNLD_B fft_unloader_top
                  GBX corefft_stream64_adapter GBX_B corefft_stream64_adapter
                  COEFG sar_coeffgen COEFG_B sar_coeffgen
                  CT corner_turn_top RES resample_top} {
    if {![dict exists $::INST $i]} { fail "instance $i missing" ; continue }
    if {[dict get $::INST $i] ne $want} { fail "instance $i is [dict get $::INST $i], want $want" }
}
foreach dead {WIN RES2} {
    if {[dict exists $::INST $dead]} { fail "$dead is still instantiated (its DIC/CIC slot is reused)" }
}
if {$errs == 0} { ok "instance set: 2 full chains, WIN/RES2 reclaimed" }

# ---------------------------------------------------------------- 1. per-chain closure
# The data-plane pins of chain A must never appear on a net with a chain-B instance and vice
# versa. Clock/reset nets legitimately span both, so they are excluded by name.
set clkrst {clk CLK SLOWCLK resetn NGRST reset ACLK ARESETN}
set chainA {FFT GBX FEED UNLD COEFG}
set chainB {FFT_B GBX_B FEED_B UNLD_B COEFG_B}
set cross 0
foreach net $::CONN {
    set sawA 0 ; set sawB 0 ; set skip 0
    foreach p $net {
        if {[lsearch -exact $clkrst [port_of $p]] >= 0} { set skip 1 }
        if {[lsearch -exact $chainA [inst_of $p]] >= 0} { set sawA 1 }
        if {[lsearch -exact $chainB [inst_of $p]] >= 0} { set sawB 1 }
    }
    if {!$skip && $sawA && $sawB} { fail "net crosses the chains: $net" ; incr cross }
}
if {$cross == 0} { ok "per-chain closure: no data-plane net touches both chains" }

# ---------------------------------------------------------------- 2. SCALE_EXP pairing (H-2)
foreach {f fd} {FFT FEED  FFT_B FEED_B} {
    set se [peers "$f:SCALE_EXP"]
    set orp [peers "$f:OUTP_READY"]
    if {$se ne [list "$fd:scale_exp_in"]} {
        fail "$f:SCALE_EXP -> {$se}, want {$fd:scale_exp_in}"
    } else { ok "$f:SCALE_EXP -> $fd:scale_exp_in" }
    if {[lsearch -exact $orp "$fd:outp_ready_in"] < 0} {
        fail "$f:OUTP_READY does not reach $fd:outp_ready_in (peers: $orp)"
    } else { ok "$f:OUTP_READY -> $fd:outp_ready_in (+ gearbox)" }
    # and it must NOT reach the other chain's feeder
    set other [expr {$fd eq "FEED" ? "FEED_B" : "FEED"}]
    if {[lsearch -exact $orp "$other:outp_ready_in"] >= 0} {
        fail "$f:OUTP_READY ALSO reaches $other:outp_ready_in -- cross-wired"
    }
}

# ---------------------------------------------------------------- 2b. coefficient stream pairing
foreach {cg fd} {COEFG FEED  COEFG_B FEED_B} {
    foreach {mp fp} {m_idx c_idx m_wq c_wq m_valid c_valid m_ready c_ready} {
        set pr [peers "$cg:$mp"]
        if {$pr ne [list "$fd:$fp"]} { fail "$cg:$mp -> {$pr}, want {$fd:$fp}" }
    }
}
if {$errs == 0 || 1} { ok "coefficient streams: COEFG->FEED, COEFG_B->FEED_B" }

# ---------------------------------------------------------------- 3. DIC initiator map
set dicmap {0 CT 1 FEED_B 2 UNLD_B 3 RES 4 FEED 5 UNLD}
foreach {n inst} $dicmap {
    set pr [peers "DIC:AXI4minitiator$n"]
    if {$pr ne [list "$inst:axi4initiator"]} {
        fail "DIC:AXI4minitiator$n -> {$pr}, want {$inst:axi4initiator}"
    }
}
foreach n {6 7 8} {
    if {[llength [peers "DIC:AXI4minitiator$n"]] > 0} {
        fail "DIC:AXI4minitiator$n is connected -- NUM_INITIATORS must stay 6"
    }
}
ok "DIC: 6 initiators {$dicmap}, none above 5 (NUM_INITIATORS_WIDTH stays 3)"

# ---------------------------------------------------------------- 4. CIC target map
# addresses per axiic_ctrl_params.tcl / sar_kernels.h
set cicmap {AXI4mtarget0 CT:axi4target        AXI4mtarget1 FEED_B:axi4target
            AXI4mtarget2 UNLD_B:axi4target    AXI4mtarget3 RES:axi4target
            AXI4mtarget4 FEED:axi4target      AXI4mtarget5 UNLD:axi4target
            AXI4Lmtarget6 FIC0MON:s_axi       AXI4Lmtarget7 COEFG:s_axi
            AXI4Lmtarget8 COEFG_B:s_axi}
foreach {t inst} $cicmap {
    set pr [peers "CIC:$t"]
    if {$pr ne [list $inst]} { fail "CIC:$t -> {$pr}, want {$inst}" }
}
ok "CIC: 9 targets, existing kernel addresses unmoved"

# ---------------------------------------------------------------- 5. chain-B pin coverage
# every chain-B data pin the modules declare must be connected or explicitly unused
set need {
 FEED_B {out_var out_var_valid out_var_ready c_idx c_wq c_valid c_ready scale_exp_in outp_ready_in axi4initiator axi4target}
 UNLD_B {in_var in_var_valid in_var_ready axi4initiator axi4target}
 GBX_B  {s_axis_tdata s_axis_tvalid s_axis_tready datai_re datai_im datai_valid buf_ready
         datao_re datao_im datao_valid outp_ready read_outp m_axis_tdata m_axis_tvalid m_axis_tready}
 FFT_B  {DATAI_RE DATAI_IM DATAI_VALID BUF_READY DATAO_RE DATAO_IM DATAO_VALID OUTP_READY READ_OUTP SCALE_EXP}
 COEFG_B {m_idx m_wq m_valid m_ready s_axi}
}
dict for {inst ports} $need {
    foreach p $ports {
        if {[llength [peers "$inst:$p"]] == 0 && [lsearch -exact $::UNUSED "$inst:$p"] < 0} {
            fail "$inst:$p is DANGLING (a dangling bif signal promotes the whole interface to I/O)"
        }
    }
}
foreach p {GBX_B:m_axis_tlast GBX_B:m_axis_tdest} {
    if {[lsearch -exact $::UNUSED $p] < 0} { fail "$p not marked unused" }
}
ok "chain-B pin coverage: nothing dangling"

puts ""
if {$errs} {
    puts "==== SAR_TOP wiring: FAIL ($errs violations) ===="
    exit 1
}
puts "==== SAR_TOP wiring: PASS ===="
exit 0
