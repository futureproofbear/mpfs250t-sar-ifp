## sar_env.tcl -- single source of truth for paths in the Libero (TCL) build scripts.
##
## Source it from any build script under mpfs/fpga:
##     source [file join [file dirname [info script]] lib sar_env.tcl]
##
## It defines:
##   SAR_ROOT   absolute repo root, DERIVED from this file's location (never hard-coded)
##   SAR_FPGA   $SAR_ROOT/mpfs/fpga        (the old `set here {C:/...}` replacement)
##   SAR_HOST   $SAR_ROOT/mpfs/host
##   SAR_LIBERO / SAR_SOFTCONSOLE / SAR_VAULT / SAR_LICENSE  (external installs)
##
## EXTERNAL tool locations come from <root>/config.yaml (toolchain:). Nothing here is
## user-specific: move or rename the checkout and every path still resolves.

# --- repo root, derived from this script's own location (mpfs/fpga/lib -> ../../..) ---
set SAR_FPGA [file normalize [file join [file dirname [info script]] ..]]
set SAR_ROOT [file normalize [file join $SAR_FPGA .. ..]]
set SAR_HOST [file join $SAR_ROOT mpfs host]

# --- minimal flat "key: value" reader for a top-level yaml section (no yaml dep) ---
proc sar_cfg1 {path section key} {
    if {![file exists $path]} { return "" }
    set fh [open $path r]; set inside 0; set val ""
    while {[gets $fh line] >= 0} {
        if {[regexp "^${section}:\\s*$" $line]} { set inside 1; continue }
        if {$inside && [regexp {^[^\s#]} $line]} { set inside 0 }
        if {$inside && [regexp "^\\s+${key}:\\s*(.*?)\\s*(#.*)?$" $line -> v]} { set val $v; break }
    }
    close $fh
    return $val
}

## config.local.yaml (git-ignored) wins over config.yaml, so machine-specific paths
## never get committed. Keep only the keys you override in the local file.
proc sar_cfg {section key} {
    global SAR_ROOT
    set main $SAR_ROOT/config.yaml
    if {[info exists ::env(SAR_CONFIG)]} { set main $::env(SAR_CONFIG) }
    set v [sar_cfg1 $SAR_ROOT/config.local.yaml $section $key]
    if {$v ne ""} { return $v }
    return [sar_cfg1 $main $section $key]
}

set SAR_LIBERO      [sar_cfg toolchain libero]
set SAR_SOFTCONSOLE [sar_cfg toolchain softconsole]
set SAR_VAULT       [sar_cfg toolchain vault]
set SAR_LICENSE     [sar_cfg toolchain license_file]

## Fail early + loudly if an external path is still a placeholder (rather than letting
## Libero fail 20 minutes into a build with an opaque error).
proc sar_require {args} {
    foreach v $args {
        upvar #0 $v val
        if {![info exists val] || $val eq "" || [string match "*<you>*" $val]} {
            error "$v is unset/placeholder -- edit toolchain: in config.yaml"
        }
    }
}
