#!/usr/bin/env bash
set -u
NEW="/c/Users/lkwangsi/Tools/openocd-new/xpack-openocd-0.12.0-4"
SC="/c/Microchip/SoftConsole-v2022.2-RISC-V-747"
GDB="$SC/riscv-unknown-elf-gcc/bin/riscv64-unknown-elf-gdb.exe"
ELF="/c/Users/lkwangsi/Documents/github/mpfs250t-sar-ifp/mpfs/fpga/libero_sar/softconsole/mpfs-hal-ddr-demo/Icicle-Kit-DDR-666MHz-eNVM-Scratchpad-Release/mpfs-hal-ddr-demo.elf"
LOG="/c/Users/lkwangsi/Tools/openocd-new/ffttest2.log"
cd /c/Users/lkwangsi/Documents/github/mpfs250t-sar-ifp/mpfs/host/jtag_full
cmd //c "taskkill /F /IM openocd.exe" >/dev/null 2>&1
: > "$LOG"
"$NEW/bin/openocd.exe" -s "$NEW/openocd/scripts" --command "set DEVICE MPFS" -f board/microchip_riscv_efp6.cfg -l "$LOG" >/dev/null 2>&1 &
"$GDB" "$ELF" -x flow_ffttest2.gdb 2>&1 | tr -d '\r' | grep -avE '^Reading|warranty|GPL|free soft|GNU gdb|Copyright|documentation|bug report|configured as|^Type |sifive|For help|apropos'
cmd //c "taskkill /F /IM openocd.exe" >/dev/null 2>&1
