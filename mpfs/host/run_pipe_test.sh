#!/usr/bin/env bash
# Race-the-window: launch OpenOCD 0.12 (build 4) and GDB in parallel. GDB pre-loads
# the ELF and Python-waits for port 3333, attaching the instant it binds so the
# FlashPro HID never idles into a crash. Runs the full SAR flow on U54_1.
set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/sar_env.sh"   # SAR_ROOT / tool paths (see config.yaml)
NEW="$SAR_OPENOCD"
SC="$SAR_SOFTCONSOLE"
GDB="$SC/riscv-unknown-elf-gcc/bin/riscv64-unknown-elf-gdb.exe"
ELF="$SAR_ROOT/mpfs/fpga/libero_sar/softconsole/mpfs-hal-ddr-demo/Icicle-Kit-DDR-666MHz-eNVM-Scratchpad-Release/mpfs-hal-ddr-demo.elf"
LOG="$SAR_SCRATCH/combined.log"
cd "$SAR_ROOT/mpfs/host/jtag_full"
cmd /c "taskkill /F /IM openocd.exe" >/dev/null 2>&1
: > "$LOG"
# start OpenOCD (background) and GDB (parallel) at the same time
"$NEW/bin/openocd.exe" -s "$NEW/openocd/scripts" --command "set DEVICE MPFS" -f board/microchip_riscv_efp6.cfg -l "$LOG" >/dev/null 2>&1 &
echo ">>> openocd launching; gdb pre-loading + waiting for port..."
"$GDB" "$ELF" -x flow_test.gdb 2>&1 | tr -d '\r' | grep -avE '^Reading|warranty|GPL|free soft|GNU gdb|Copyright|documentation|bug report|configured as|^Type |sifive|For help|apropos'
echo ">>> gdb session ended"
echo "=== openocd log tail ==="
tail -8 "$LOG" | tr -d '\r'
