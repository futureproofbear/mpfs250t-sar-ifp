#!/usr/bin/env bash
# Dump the OUT band (rows 0:256, 4 MB) from DDR over JTAG for correlation vs golden.
# Attach-only (no reset) so the pipeline's OUT result persists. Clean shutdown (no taskkill /F).
set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/sar_env.sh"   # SAR_ROOT / tool paths (see config.yaml)
NEW="$SAR_OPENOCD"
SC="$SAR_SOFTCONSOLE"
GDB="$SC/riscv-unknown-elf-gcc/bin/riscv64-unknown-elf-gdb.exe"
ELF="$SAR_ROOT/mpfs/fpga/libero_sar/softconsole/mpfs-hal-ddr-demo/Icicle-Kit-DDR-666MHz-eNVM-Scratchpad-Release/mpfs-hal-ddr-demo.elf"
LOG="$SAR_SCRATCH/dump_out.log"
cd "$SAR_ROOT/mpfs/host/jtag_full"
if tasklist 2>/dev/null | grep -qi openocd.exe; then
  echo ">>> WARNING: openocd.exe already running (stale). Close it cleanly; NOT force-killing." >&2; exit 1
fi
: > "$LOG"
"$NEW/bin/openocd.exe" -s "$NEW/openocd/scripts" --command "set DEVICE MPFS" -f board/microchip_riscv_efp6.cfg -l "$LOG" >/dev/null 2>&1 &
sleep 16   # let openocd examine all harts before gdb connects
"$GDB" "$ELF" -x status_probe.gdb 2>&1 | tr -d '\r' | grep -avE '^Reading|warranty|GPL|free soft|GNU gdb|Copyright|documentation|bug report|configured as|^Type |sifive|For help|apropos'
echo ">>> done (openocd shut down via monitor shutdown)"
