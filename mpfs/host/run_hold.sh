#!/usr/bin/env bash
# Arm the FFT feeder-hold over JTAG (calls sar_fft_hold), then release the FlashPro6
# so SmartDebug can read active probes while the feeder stalls live in fabric.
set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/sar_env.sh"   # SAR_ROOT / tool paths (see config.yaml)
NEW="$SAR_OPENOCD"
SC="$SAR_SOFTCONSOLE"
GDB="$SC/riscv-unknown-elf-gcc/bin/riscv64-unknown-elf-gdb.exe"
ELF="$SAR_ROOT/mpfs/fpga/libero_sar/softconsole/mpfs-hal-ddr-demo/Icicle-Kit-DDR-666MHz-eNVM-Scratchpad-Release/mpfs-hal-ddr-demo.elf"
LOG="$SAR_SCRATCH/hold.log"
cd "$SAR_ROOT/mpfs/host/jtag_full"
cmd /c "taskkill /F /IM openocd.exe" >/dev/null 2>&1
: > "$LOG"
"$NEW/bin/openocd.exe" -s "$NEW/openocd/scripts" --command "set DEVICE MPFS" -f board/microchip_riscv_efp6.cfg -l "$LOG" >/dev/null 2>&1 &
echo ">>> openocd launching; gdb arming feeder-hold..."
"$GDB" "$ELF" -x flow_hold.gdb 2>&1 | tr -d '\r' | grep -avE '^Reading|warranty|GPL|free soft|GNU gdb|Copyright|documentation|bug report|configured as|^Type |sifive|For help|apropos'
echo ">>> gdb session ended; killing openocd to RELEASE FlashPro6"
cmd /c "taskkill /F /IM openocd.exe" >/dev/null 2>&1
echo ">>> FlashPro6 released -> reconnect SmartDebug and Read Active Probes"
