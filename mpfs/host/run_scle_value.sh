#!/usr/bin/env bash
# SCLE value-test: fabric range-FFT on the on-chip 2-DC-row known input, dump SCRATCH + sar_row_exp
# for a bit-exact value diff vs fabric_scale_value.py. Race-the-window launch; NO taskkill /F.
set -u
NEW="/c/Users/lkwangsi/Tools/openocd-new/xpack-openocd-0.12.0-4"
SC="/c/Microchip/SoftConsole-v2022.2-RISC-V-747"
GDB="$SC/riscv-unknown-elf-gcc/bin/riscv64-unknown-elf-gdb.exe"
ELF="/c/Users/lkwangsi/Documents/github/sarProcessor/mpfs/fpga/libero_sar/softconsole/mpfs-hal-ddr-demo/Icicle-Kit-DDR-666MHz-eNVM-Scratchpad-Release/mpfs-hal-ddr-demo.elf"
LOG="/c/Users/lkwangsi/Tools/openocd-new/scle_value.log"
cd /c/Users/lkwangsi/Documents/github/sarProcessor/mpfs/host/jtag_full
if tasklist 2>/dev/null | grep -qi openocd.exe; then
  echo ">>> WARNING: openocd.exe already running (stale). Close it cleanly; NOT force-killing." >&2; exit 1
fi
: > "$LOG"
"$NEW/bin/openocd.exe" -s "$NEW/openocd/scripts" --command "set DEVICE MPFS" -f board/microchip_riscv_efp6.cfg -l "$LOG" >/dev/null 2>&1 &
echo ">>> openocd launching; gdb pre-loading + waiting for port..."
"$GDB" "$ELF" -x scle_value.gdb 2>&1 | tr -d '\r' | grep -avE '^Reading|warranty|GPL|free soft|GNU gdb|Copyright|documentation|bug report|configured as|^Type |sifive|For help|apropos'
echo ">>> gdb session ended (openocd shut down via monitor shutdown)"
