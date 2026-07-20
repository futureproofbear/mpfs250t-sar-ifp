#!/usr/bin/env bash
# Safe headless FPGA build with a PRE-SYNTH LINT GATE.
#
# Flow:  [optional prep .tcl] -> lint_netlist.sh (GATE) -> synth/P&R/bitstream/program
#
# The lint gate scans the just-generated SmartDesign netlist for the silent-failure classes that
# cost us many build cycles (slave address/data tied to const, protocol-type mismatch). If it finds
# a CRITICAL it ABORTS *before* the ~30-min synthesis -- so a broken connection never burns a P&R run.
#
# Usage:
#   bash run_build_safe.sh                       # lint current generated netlist, then build+program
#   bash run_build_safe.sh ../fpga/build_addrfix.tcl   # run a prep/edit+generate tcl first, then gate+build
set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/sar_env.sh"   # SAR_ROOT / tool paths (see config.yaml)
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"          # mpfs/host
FPGA="$(cd "$HERE/../fpga" && pwd)"                            # mpfs/fpga
LIB="$SAR_LIBERO/Libero_SoC/Designer/bin/libero.exe"
BUILD_TCL="$FPGA/build_dmafix.tcl"        # open -> build_design_hierarchy -> synth/P&R/bitstream/export/PROGRAMDEVICE
PREP="${1:-}"
[ -x "$LIB" ] || { echo "libero.exe not found: $LIB"; exit 2; }

if [ -n "$PREP" ]; then
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

echo ">>> [3/3] synth -> P&R -> bitstream -> program"
"$LIB" "SCRIPT:$(cygpath -w "$BUILD_TCL" 2>/dev/null || echo "$BUILD_TCL")" \
    "LOGFILE:$(cygpath -w "$FPGA/../host/run_build_safe.libero.log" 2>/dev/null)" 2>&1 \
    | tr -d '\r' | grep -aiE "PROGRAM PASSED|Chain Programming|BUILD\+PROGRAM DONE|Synthesis failed|Error:.*run_tool|libero exit" | tail -12
echo ">>> run_build_safe complete."
