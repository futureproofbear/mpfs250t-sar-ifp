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

## VERIFYPOWER writes SAR_TOP_power_report.xml itself; export_report -type {POWER} does NOT
## produce a .rpt here (verified 2026-07-27), so read the XML the tool actually emits.
RPT="$FPGA/libero_ffv/designer/SAR_TOP/SAR_TOP_power_report.xml"
if [ -f "$RPT" ]; then
    echo
    echo "=== summary ($RPT) ==="
    "${SAR_PYTHON:-python}" - "$RPT" <<'PYEOF'
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
txt = lambda e: ''.join(e.itertext()).strip()
for tbl in root.iter('table'):
    for row in tbl:
        c = [txt(x) for x in row]
        if not any(c):
            continue
        head = c[0].lower()
        if head.startswith(('total power', 'static power', 'dynamic power', 'rail ', 'type ')):
            print('  ' + ' | '.join(c))
PYEOF
    ## Fold the headline into the bitstream snapshot, so power travels with the build it belongs to
    ## rather than being a loose file nobody can attribute later.
    SNAP="$(ls -1dt "$FPGA"/bitstreams/*/ 2>/dev/null | head -1)"
    if [ -n "$SNAP" ]; then
        cp "$RPT" "${SNAP}SAR_TOP_power_report.xml" 2>/dev/null
        echo "  (copied into $(basename "${SNAP%/}"))"
    fi
else
    echo "no power report produced -- see $LOG"
fi
