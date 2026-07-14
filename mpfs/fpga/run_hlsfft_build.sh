#!/bin/bash
# run_hlsfft_build.sh -- chained board-free Libero build for the HLS-FFT variant.
# Stage 1 create project (+assembly) -> Stage 2 stage constraints -> Stage 3 synth/PnR/timing/bitstream.
# Each stage gates on its DONE marker in the log; stops on first failure. NO PROGRAMDEVICE (board-free).
FPGA="/c/Users/lkwangsi/Documents/github/mpfs250t-sar-ifp/mpfs/fpga"
cd "$FPGA" || exit 2
LIBERO="/c/Microchip/Libero_SoC_2025.2/Libero_SoC/Designer/bin/libero.exe"
export LM_LICENSE_FILE='C:\Users\lkwangsi\Documents\github\polarfire-soc\License.dat'
run() { "$LIBERO" "SCRIPT:$1" "LOGFILE:$2" >/dev/null 2>&1; }

echo "[$(date +%H:%M:%S)] STAGE 0/3: HLS pre-build gate (anti-pattern + II report firebreak)"
if ! bash "$FPGA/hls_gate.sh" hls_resample; then
  echo "[$(date +%H:%M:%S)] STAGE 0 ABORTED build -- fix the HLS gate failure above, re-run 'shls hw'."; exit 1
fi
echo "[$(date +%H:%M:%S)] STAGE 0 OK"

echo "[$(date +%H:%M:%S)] STAGE 1/3: create_fresh_project_hlsfft (cores + MSS + HDL+ + assembly)"
run create_fresh_project_hlsfft.tcl create_fresh_project_hlsfft.log
if ! grep -q "FRESH_HLSFFT_PROJECT_DONE" create_fresh_project_hlsfft.log 2>/dev/null; then
  echo "[$(date +%H:%M:%S)] STAGE 1 FAILED -- no FRESH_HLSFFT_PROJECT_DONE. tail:"; tail -25 create_fresh_project_hlsfft.log; exit 1
fi
if ! grep -q "SARTOP_HLSFFT_DONE" create_fresh_project_hlsfft.log 2>/dev/null; then
  echo "[$(date +%H:%M:%S)] STAGE 1 assembly FAILED -- no SARTOP_HLSFFT_DONE. tail:"; tail -25 create_fresh_project_hlsfft.log; exit 1
fi
echo "[$(date +%H:%M:%S)] STAGE 1 OK"

echo "[$(date +%H:%M:%S)] STAGE 2/3: stage_constraints_hlsfft"
run stage_constraints_hlsfft.tcl stage_constraints_hlsfft.log
if ! grep -q "STAGE_CONSTRAINTS_HLSFFT_DONE" stage_constraints_hlsfft.log 2>/dev/null; then
  echo "[$(date +%H:%M:%S)] STAGE 2 FAILED. tail:"; tail -25 stage_constraints_hlsfft.log; exit 1
fi
echo "[$(date +%H:%M:%S)] STAGE 2 OK: $(grep -E 'clocks in derived' stage_constraints_hlsfft.log)"

echo "[$(date +%H:%M:%S)] STAGE 3/3: build_full_prog_hlsfft (SYNTH -> PnR -> VERIFYTIMING -> bitstream)"
run build_full_prog_hlsfft.tcl build_full_prog_hlsfft.log
if ! grep -q "BUILD_HLSFFT_DONE" build_full_prog_hlsfft.log 2>/dev/null; then
  echo "[$(date +%H:%M:%S)] STAGE 3 did not finish cleanly. tail:"; tail -30 build_full_prog_hlsfft.log; exit 1
fi
echo "[$(date +%H:%M:%S)] STAGE 3 done. Timing/bitstream result:"
grep -E "SETUP nviol|HOLD nviol|TIMING_MET|TIMING_NOT_MET|BITSTREAM_READY" build_full_prog_hlsfft.log
echo "[$(date +%H:%M:%S)] === run_hlsfft_build.sh COMPLETE ==="
