#!/usr/bin/env bash
# FULL headless data-plane fix loop: Libero build (AXIIC_C0 ID_WIDTH=3) -> gate ->
# FlashPro Express program the new fabric job. Then power-cycle + run_m2.sh to verify.
# FlashPro must be connected + board powered (program phase needs it).
set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/sar_env.sh"   # SAR_ROOT / tool paths (see config.yaml)
LIB="$SAR_LIBERO/Libero_SoC/Designer/bin/libero.exe"
FPX="$SAR_LIBERO/Libero_SoC/Designer/bin/FPExpress.exe"
ROOT="$SAR_ROOT/mpfs/fpga"
HOST="$SAR_ROOT/mpfs/host"
SARTOP="$ROOT/libero_sar/component/work/SAR_TOP/SAR_TOP.v"
JOB="$ROOT/libero_sar/export/SAR_TOP_idfix.job"
BLOG="$SAR_SCRATCH/build_fix.log"
PLOG="$SAR_SCRATCH/program_fabric.log"
win() { cygpath -w "$1" 2>/dev/null || echo "$1"; }

echo "===== PHASE 1/3: headless Libero build (reconfig + synth + P&R + bitstream, ~15-40 min) ====="
"$LIB" "SCRIPT:$(win "$ROOT/build_dataplane_fix.tcl")" "LOGFILE:$(win "$BLOG")"; echo "libero exit $?"

echo "===== GATE: did the 9->4 ID truncation actually go away + job export? ====="
if ! grep -qE 'wire +\[3:0\] *DIC_AXI4mslave0_ARID *;' "$SARTOP" 2>/dev/null; then
  echo "ABORT: DIC_AXI4mslave0_ARID still not 4-bit -> reconfigure didn't take. NOT programming."
  echo "       Check $BLOG for a create_and_configure_core param error; prune it from"
  echo "       fpga/axiic_c0_params.tcl and re-run."; exit 1
fi
grep -nE '_ARID_0_8to4|_RID_0_8to4|= *5.h0' "$SARTOP" 2>/dev/null | head && echo "(^ expect NO ARID/RID truncation lines)"
[ -f "$JOB" ] || { echo "ABORT: $JOB not exported. Tail of build log:"; tail -15 "$BLOG" 2>/dev/null | tr -d '\r'; exit 1; }
echo "PASS: ARID is 4-bit + job exported ($(stat -c%s "$JOB") bytes)"

echo "===== PHASE 2/3: FlashPro Express program the fabric (board/FlashPro must be connected) ====="
"$FPX" "SCRIPT:$(win "$ROOT/program_fabric.tcl")" "LOGFILE:$(win "$PLOG")"; echo "FPExpress exit $?"
if grep -qiE 'PROGRAM PASSED|programmer.*passed|FABRIC PROGRAM DONE|Chain Programming.*PASS' "$PLOG" 2>/dev/null; then
  echo "PASS: fabric programmed"
else
  echo "WARN: couldn't confirm PROGRAM PASSED -- check $PLOG:"; tail -18 "$PLOG" 2>/dev/null | tr -d '\r'
fi

echo "===== PHASE 3/3: verify ====="
echo ">>> POWER-CYCLE the board, then tell me 'done' and I'll run run_m2.sh."
echo ">>> SUCCESS = M2 T3 (rec tag=0x30) flips from HANG (st=3) to PASS (st=0):"
echo ">>>          the resample kernel's DDR read now completes through FIC0_S."
