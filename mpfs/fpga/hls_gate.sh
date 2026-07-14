#!/usr/bin/env bash
# hls_gate.sh -- HLS pre-Libero firebreak: Gate 0 (anti-pattern) + Gate 1 (II report).
#
# The SmartHLS analog of lint_netlist.sh. Run AFTER `shls hw` (the pipelining report exists)
# and BEFORE the Libero build: a 1-second check vs a ~30-min synth on RTL that SmartHLS
# silently degraded (the II=2->21 class) or mis-synthesised (a catalogued anti-pattern).
# Exits 1 on any FAIL so a build wrapper aborts early.
#
#   Gate 0  source vs docs/fpga/SMARTHLS_ANTIPATTERNS.md   (mpfs/host/hls_antipattern_lint.py)
#   Gate 1  achieved II vs requested II in the report      (mpfs/host/hls_report_lint.py)
#
# Usage:  bash hls_gate.sh [kernel_dir ...]      # default: hls_resample
#         PYTHON=python3 bash hls_gate.sh hls_resample hls_window
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"      # mpfs/fpga
HOST="$(cd "$HERE/../host" && pwd)"
PY="${PYTHON:-python}"
KDIRS=("$@"); [ ${#KDIRS[@]} -eq 0 ] && KDIRS=("hls_resample")

fail=0
echo "=== HLS GATE 0: anti-pattern pre-screen (source-wide) ==="
"$PY" "$HOST/hls_antipattern_lint.py" || fail=1

for k in "${KDIRS[@]}"; do
    KD="$HERE/$k"
    RPT="$KD/hls_output/reports/pipelining.hls.rpt"
    # source file from the kernel Makefile's SRCS=, else the first .cpp
    SRC=""
    if [ -f "$KD/Makefile" ]; then
        S=$(grep -aE '^SRCS' "$KD/Makefile" | head -1 | sed 's/.*=//; s/[[:space:]]//g')
        [ -n "$S" ] && SRC="$KD/$S"
    fi
    [ -z "$SRC" ] && SRC=$(ls "$KD"/*.cpp 2>/dev/null | head -1)
    echo
    echo "=== HLS GATE 1: II report -- $k ==="
    if [ ! -f "$RPT" ]; then
        echo "  report not found: $RPT  (run 'shls hw' first)"; fail=1; continue
    fi
    "$PY" "$HOST/hls_report_lint.py" --report "$RPT" --src "$SRC" || fail=1
done

echo
if [ "$fail" -ne 0 ]; then
    echo ">>> ============================================================"
    echo ">>> HLS GATE FAIL -- do NOT hand this RTL to Libero."
    echo ">>> Fix the anti-pattern / II degradation above, re-run 'shls hw'."
    echo ">>> (saved a ~30-min synth+P&R on silently-degraded RTL)"
    echo ">>> ============================================================"
    exit 1
fi
echo ">>> HLS GATE PASS -- RTL ok to build."
