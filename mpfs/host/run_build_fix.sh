#!/usr/bin/env bash
# Headless data-plane fix build: drives Libero to reconfigure AXIIC_C0 (ID_WIDTH=3),
# regenerate, synth/P&R/bitstream, export a programming job -- NO GUI.
# Verifies the regenerated wrapper actually dropped the ID truncation.
set -u
LIB="/c/Microchip/Libero_SoC_2025.2/Libero_SoC/Designer/bin/libero.exe"
ROOT="/c/Users/lkwangsi/Documents/github/mpfs250t-sar-ifp/mpfs/fpga"
TCL="$ROOT/build_dataplane_fix.tcl"
LOG="/c/Users/lkwangsi/Tools/openocd-new/build_fix.log"
SARTOP="$ROOT/libero_sar/component/work/SAR_TOP/SAR_TOP.v"
JOB="$ROOT/libero_sar/designer/SAR_TOP/export/SAR_TOP_idfix.job"

[ -x "$LIB" ] || { echo "libero.exe not found at $LIB"; exit 1; }
echo ">>> launching headless Libero build (reconfig + synth + P&R + bitstream)..."
echo ">>> this takes ~15-40 min; full log: $LOG"
"$LIB" "SCRIPT:$(cygpath -w "$TCL" 2>/dev/null || echo "$TCL")" "LOGFILE:$(cygpath -w "$LOG" 2>/dev/null || echo "$LOG")"
RC=$?
echo ">>> libero exit: $RC"

echo "=== GATE 1: did the regenerated wrapper drop the 9->4 ID truncation? ==="
if grep -qE 'wire +\[3:0\] *DIC_AXI4mslave0_ARID *;' "$SARTOP" 2>/dev/null; then
  echo "PASS: DIC_AXI4mslave0_ARID is now 4-bit"
  grep -nE 'DIC_AXI4mslave0_ARID_0_8to4|DIC_AXI4mslave0_RID_0_8to4|= *5.h0|= *6.h0' "$SARTOP" 2>/dev/null \
    | head && echo "   (^ any remaining truncation/pad lines -- expect NONE for ARID/RID)"
else
  echo "WARN: ARID still not 4-bit -- reconfigure may not have taken. Check $LOG for"
  echo "      create_and_configure_core errors (a rejected read-only param? remove it from"
  echo "      axiic_c0_params.tcl and re-run). Do NOT program this bitstream."
fi

echo "=== GATE 2: programming job exported? ==="
if [ -f "$JOB" ]; then
  echo "PASS: $JOB ($(stat -c%s "$JOB") bytes)"
  echo ">>> NEXT: program this fabric job your usual way (FlashPro Express / fpgenprog PROGRAM),"
  echo ">>>       then power-cycle and run:  bash mpfs/host/run_m2.sh"
  echo ">>>       (set M2_PROBE_MON=1 + rebuild firmware first if you also added sar_fic0s_mon)"
else
  echo "MISSING: $JOB -- check $LOG tail:"; tail -15 "$LOG" 2>/dev/null | tr -d '\r'
fi
