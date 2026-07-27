#!/usr/bin/env bash
# Vectorless SmartPower estimate for the CURRENT placed-and-routed libero_ffv design.
#
# OPT-IN BY DESIGN. This is NOT wired into run_build_safe.sh -- power analysis runs only when
# asked for, per build. It is also read-only with respect to the design: it opens the project,
# runs the power tool, exports a report. It does not synthesise, place, route or re-export a
# bitstream, so it cannot change what gets programmed.
#
# Board-free. Needs a design that has already been placed and routed.
#
# Usage:  bash run_power_report.sh
set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/sar_env.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
FPGA="$(cd "$HERE/../fpga" && pwd)"
sar_require SAR_LIBERO || exit 2
LIB="$SAR_LIBERO/Libero_SoC/Designer/bin/libero.exe"
TCL="$FPGA/power_report_ffv.tcl"
LOG="$HERE/run_power_report.libero.log"

[ -x "$LIB" ] || { echo "ERROR: libero.exe not found: $LIB"; exit 2; }
[ -d "$FPGA/libero_ffv/designer/SAR_TOP" ] || {
    echo "ERROR: no placed-and-routed design in libero_ffv/ -- build first"; exit 2; }

## Refuse to run on top of a live build. Libero would contend for the same project, and this
## project has already lost a ~50-minute build to two things touching one flow at once.
if tasklist 2>/dev/null | grep -qiE "libero|synplify|designer"; then
    echo "ERROR: a Libero/synthesis process is already running -- refusing to contend for the project"
    exit 2
fi

echo ">>> vectorless power estimate (fabric only; excludes U54s, DDR controller and PHY)"
"$LIB" "SCRIPT:$(cygpath -w "$TCL" 2>/dev/null || echo "$TCL")" >"$LOG" 2>&1
tr -d '\r' < "$LOG" | grep -aiE "POWER_OK|POWER_RC|POWER_ERR|POWER_DONE" | tail -4

RPT="$FPGA/libero_ffv/designer/SAR_TOP/SAR_TOP_power.rpt"
if [ -f "$RPT" ]; then
    echo
    echo "=== summary ($RPT) ==="
    tr -d '\r' < "$RPT" | grep -aiE "total power|static|dynamic|junction temp|thermal|mW|Watt" | head -20
    ## Fold the headline into the bitstream snapshot, so power travels with the build it belongs to
    ## rather than being a loose file nobody can attribute later.
    SNAP="$(ls -1dt "$FPGA"/bitstreams/*/ 2>/dev/null | head -1)"
    if [ -n "$SNAP" ]; then
        cp "$RPT" "${SNAP}SAR_TOP_power.rpt" 2>/dev/null
        echo "  (copied into $(basename "${SNAP%/}"))"
    fi
else
    echo "no power report produced -- see $LOG"
fi
