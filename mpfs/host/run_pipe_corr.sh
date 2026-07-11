#!/usr/bin/env bash
# Run the full SAR pipeline in FABRIC FFT mode + dump the OUT band for a corr re-measure on the
# current SCALE_EXP+renorm build. Race-the-window openocd+gdb launch; NO taskkill /F (JTAG hygiene).
# Usage: ./run_pipe_corr.sh [HEADROOM]   (default 0). Then: python correlate_cpufft.py
set -u
HR="${1:-0}"
NEW="/c/Users/lkwangsi/Tools/openocd-new/xpack-openocd-0.12.0-4"
SC="/c/Microchip/SoftConsole-v2022.2-RISC-V-747"
GDB="$SC/riscv-unknown-elf-gcc/bin/riscv64-unknown-elf-gdb.exe"
ELF="/c/Users/lkwangsi/Documents/github/sarProcessor/mpfs/fpga/libero_sar/softconsole/mpfs-hal-ddr-demo/Icicle-Kit-DDR-666MHz-eNVM-Scratchpad-Release/mpfs-hal-ddr-demo.elf"
LOG="/c/Users/lkwangsi/Tools/openocd-new/pipe_corr.log"
cd /c/Users/lkwangsi/Documents/github/sarProcessor/mpfs/host/jtag_full
if tasklist 2>/dev/null | grep -qi openocd.exe; then
  echo ">>> WARNING: openocd.exe already running (stale). Close it cleanly; NOT force-killing." >&2; exit 1
fi
sed "s/@HR@/$HR/g" flow_pipe_corr.gdb > flow_pipe_corr.run.gdb
: > "$LOG"
"$NEW/bin/openocd.exe" -s "$NEW/openocd/scripts" --command "set DEVICE MPFS" -f board/microchip_riscv_efp6.cfg -l "$LOG" >/dev/null 2>&1 &
echo ">>> openocd launching; gdb pre-loading + waiting for port (headroom=$HR)..."
"$GDB" "$ELF" -x flow_pipe_corr.run.gdb 2>&1 | tr -d '\r' | grep -avE '^Reading|warranty|GPL|free soft|GNU gdb|Copyright|documentation|bug report|configured as|^Type |sifive|For help|apropos'
echo ">>> gdb session ended (openocd shut down via monitor shutdown)"
