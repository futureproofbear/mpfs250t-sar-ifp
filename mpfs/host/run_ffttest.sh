#!/usr/bin/env bash
set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/sar_env.sh"   # SAR_ROOT / tool paths (see config.yaml)
NEW="$SAR_OPENOCD"
SC="$SAR_SOFTCONSOLE"
GDB="$SC/riscv-unknown-elf-gcc/bin/riscv64-unknown-elf-gdb.exe"
ELF="$SAR_ROOT/mpfs/fpga/libero_sar/softconsole/mpfs-hal-ddr-demo/Icicle-Kit-DDR-666MHz-eNVM-Scratchpad-Release/mpfs-hal-ddr-demo.elf"
LOG="$SAR_SCRATCH/ffttest.log"
cd "$SAR_ROOT/mpfs/host/jtag_full"
cmd //c "taskkill /F /IM openocd.exe" >/dev/null 2>&1
: > "$LOG"
"$NEW/bin/openocd.exe" -s "$NEW/openocd/scripts" --command "set DEVICE MPFS" -f board/microchip_riscv_efp6.cfg -l "$LOG" >/dev/null 2>&1 &
echo ">>> openocd launching; arming FFT + sampling..."
"$GDB" "$ELF" -x flow_ffttest.gdb 2>&1 | tr -d '\r' | grep -avE '^Reading|warranty|GPL|free soft|GNU gdb|Copyright|documentation|bug report|configured as|^Type |sifive|For help|apropos'
cmd //c "taskkill /F /IM openocd.exe" >/dev/null 2>&1
echo ">>> done"
