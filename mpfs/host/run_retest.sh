#!/usr/bin/env bash
# Silicon re-test after the FFT gearbox fix: launch OpenOCD + GDB, load geometry+job,
# run sar_form_image(0), report the stage result. (~10 min: resample dominates.)
set -u
NEW="/c/Users/lkwangsi/Tools/openocd-new/xpack-openocd-0.12.0-4"
SC="/c/Microchip/SoftConsole-v2022.2-RISC-V-747"
GDB="$SC/riscv-unknown-elf-gcc/bin/riscv64-unknown-elf-gdb.exe"
ELF="/c/Users/lkwangsi/Documents/github/mpfs250t-sar-ifp/mpfs/fpga/libero_sar/softconsole/mpfs-hal-ddr-demo/Icicle-Kit-DDR-666MHz-eNVM-Scratchpad-Release/mpfs-hal-ddr-demo.elf"
LOG="/c/Users/lkwangsi/Tools/openocd-new/retest.log"
cd /c/Users/lkwangsi/Documents/github/mpfs250t-sar-ifp/mpfs/host/jtag_full

cmd //c "taskkill /F /IM openocd.exe" >/dev/null 2>&1
: > "$LOG"
"$NEW/bin/openocd.exe" -s "$NEW/openocd/scripts" --command "set DEVICE MPFS" -f board/microchip_riscv_efp6.cfg -l "$LOG" >/dev/null 2>&1 &
echo ">>> openocd launching; gdb loading geometry + running pipeline..."
"$GDB" "$ELF" -x flow_retest.gdb 2>&1 | tr -d '\r' | grep -avE '^Reading|warranty|GPL|free soft|GNU gdb|Copyright|documentation|bug report|configured as|^Type |sifive|For help|apropos'
echo ">>> gdb session ended"
cmd //c "taskkill /F /IM openocd.exe" >/dev/null 2>&1
echo ">>> done"
