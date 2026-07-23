#!/usr/bin/env bash
# Safe headless FPGA build with a PRE-SYNTH LINT GATE and an HONEST pass/fail verdict.
#
# Flow:  [optional prep .tcl] -> lint_netlist.sh (GATE) -> synth/P&R/VERIFYTIMING/export
#
# The lint gate scans the just-generated SmartDesign netlist for the silent-failure classes that
# cost us many build cycles (slave address/data tied to const, protocol-type mismatch). If it finds
# a CRITICAL it ABORTS *before* the ~30-min synthesis -- so a broken connection never burns a P&R run.
#
# This BUILDS AND EXPORTS a bitstream (build_full_prog_ffv.tcl: synth -> P&R -> setup+hold timing
# gate -> export SAR_TOP_ffv.job). It does NOT program the device -- programming is a separate,
# deliberate step (board must be on):   cd mpfs/fpga && libero SCRIPT:program_ffv.tcl
#
# Usage:
#   bash run_build_safe.sh                              # lint + rebuild the EXISTING ffv project
#   bash run_build_safe.sh ../fpga/create_fresh_project_ffv.tcl   # create a fresh project first, then gate+build
set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/sar_env.sh"   # SAR_ROOT / tool paths (see config.yaml)
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"          # mpfs/host
FPGA="$(cd "$HERE/../fpga" && pwd)"                            # mpfs/fpga
sar_require SAR_LIBERO || exit 2                               # fail loudly if the toolchain path is a placeholder
LIB="$SAR_LIBERO/Libero_SoC/Designer/bin/libero.exe"
BUILD_TCL="$FPGA/build_full_prog_ffv.tcl"   # open ffv project -> synth -> P&R -> VERIFYTIMING (setup+hold) -> export
JOB="$FPGA/libero_ffv/export/SAR_TOP_ffv.job"
PREP="${1:-}"
[ -x "$LIB" ]       || { echo "ERROR: libero.exe not found: $LIB (edit toolchain: libero in config.yaml/config.local.yaml)"; exit 2; }
[ -f "$BUILD_TCL" ] || { echo "ERROR: build tcl not found: $BUILD_TCL"; exit 2; }

if [ -n "$PREP" ]; then
    [ -f "$PREP" ] || { echo "ERROR: prep tcl not found: $PREP"; exit 2; }
    echo ">>> [1/3] prep (edit + generate): $PREP"
    "$LIB" "SCRIPT:$(cygpath -w "$PREP" 2>/dev/null || echo "$PREP")" 2>&1 | tr -d '\r' | grep -aiE "ERR|DONE|Successfully generated|not consistent" | tail -8
fi

echo ">>> [2/3] LINT GATE (pre-synth firebreak)"
if ! bash "$FPGA/lint_netlist.sh"; then
    echo ">>> ========================================================"
    echo ">>> BUILD ABORTED by lint gate -- fix the CRITICAL(s) above"
    echo ">>> (saved a ~30-min synth+P&R cycle on a broken netlist)."
    echo ">>> ========================================================"
    exit 1
fi

echo ">>> [3/3] synth -> P&R -> timing gate -> export"
BUILD_LOG="$HERE/run_build_safe.libero.log"
"$LIB" "SCRIPT:$(cygpath -w "$BUILD_TCL" 2>/dev/null || echo "$BUILD_TCL")" >"$BUILD_LOG" 2>&1
LRC=$?
tr -d '\r' < "$BUILD_LOG" | grep -aiE "SETUP nviol|HOLD nviol|VIOLRPT|TIMING_(MET|NOT_MET)|BITSTREAM_DONE|FFV_BUILD_DONE|Error:|Synthesis failed" | tail -15

# HONEST verdict -- decide on REAL signals, never on a pipe's exit status:
#   libero.exe exited 0  AND  the tcl reached BITSTREAM_DONE (success-only marker, printed AFTER export)
#   AND the timing gate did not reject it (TIMING_NOT_MET*)  AND the .job actually exists on disk.
ok=1
[ "$LRC" -eq 0 ]                             || { echo ">>> FAIL: libero.exe exited $LRC";                              ok=0; }
grep -aq "BITSTREAM_DONE" "$BUILD_LOG"       || { echo ">>> FAIL: no BITSTREAM_DONE marker (build never reached export)"; ok=0; }
grep -aqiE "TIMING_NOT_MET" "$BUILD_LOG"     && { echo ">>> FAIL: timing gate rejected the design (setup/hold not met)"; ok=0; }
[ -f "$JOB" ]                                || { echo ">>> FAIL: no exported bitstream at $JOB";                       ok=0; }

if [ "$ok" -ne 1 ]; then
    echo ">>> ==================================================================="
    echo ">>> BUILD FAILED -- no usable bitstream. Full Libero log: $BUILD_LOG"
    echo ">>> Do NOT program. (A fresh project needs the create_fresh_project_ffv.tcl prep arg.)"
    echo ">>> ==================================================================="
    exit 1
fi
echo ">>> run_build_safe OK -- bitstream exported: $JOB"
echo ">>> To program (board on):  cd mpfs/fpga && \"$LIB\" SCRIPT:program_ffv.tcl"
