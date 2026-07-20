#!/usr/bin/env bash
# Verify the range-FFT completes with the fft_unloader (replaces the deadlocking DMA).
# Clean shutdown only -- NO `taskkill /F` (force-killing openocd/gdb wedges the FlashPro6 HID).
# The gdb script ends with `monitor shutdown`, which exits openocd cleanly.
set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/sar_env.sh"   # SAR_ROOT / tool paths (see config.yaml)
NEW="$SAR_OPENOCD"
SC="$SAR_SOFTCONSOLE"
GDB="$SC/riscv-unknown-elf-gcc/bin/riscv64-unknown-elf-gdb.exe"
ELF="$SAR_ROOT/mpfs/fpga/libero_sar/softconsole/mpfs-hal-ddr-demo/Icicle-Kit-DDR-666MHz-eNVM-Scratchpad-Release/mpfs-hal-ddr-demo.elf"
LOG="$SAR_SCRATCH/ffttest_unld.log"
cd "$SAR_ROOT/mpfs/host/jtag_full"
if tasklist 2>/dev/null | grep -qi openocd.exe; then
  echo ">>> WARNING: an openocd.exe is already running (stale session). Close it cleanly before re-running; NOT force-killing." >&2
  exit 1
fi
: > "$LOG"
"$NEW/bin/openocd.exe" -s "$NEW/openocd/scripts" --command "set DEVICE MPFS" -f board/microchip_riscv_efp6.cfg -l "$LOG" >/dev/null 2>&1 &
echo ">>> openocd launching; arming FFT + sampling feeder/unloader over ~90s..."
"$GDB" "$ELF" -x flow_ffttest_unld.gdb 2>&1 | tr -d '\r' | grep -avE '^Reading|warranty|GPL|free soft|GNU gdb|Copyright|documentation|bug report|configured as|^Type |sifive|For help|apropos'
echo ">>> done (openocd shut down via monitor shutdown)"
