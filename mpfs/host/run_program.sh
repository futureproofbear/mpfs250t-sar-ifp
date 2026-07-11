#!/usr/bin/env bash
# Reprogram eNVM (boot mode 1) with the self-test firmware via fpgenprog
# (reliable Microchip programmer -- NOT the buggy OpenOCD HID). Needs FlashPro
# connected + board powered.
SC="/c/Microchip/SoftConsole-v2022.2-RISC-V-747"
BM1="/c/Users/lkwangsi/Documents/github/sarProcessor/mpfs/fpga/bm1"
NEWELF="/c/Users/lkwangsi/Documents/github/sarProcessor/mpfs/fpga/libero_sar/softconsole/mpfs-hal-ddr-demo/Icicle-Kit-DDR-666MHz-eNVM-Scratchpad-Release/mpfs-hal-ddr-demo.elf"
export SC_INSTALL_DIR="$SC"
export FPGENPROG="/c/Microchip/Libero_SoC_2025.2/Libero_SoC/Designer/bin64/fpgenprog.exe"
JAVA="$SC/eclipse/jre/bin/java.exe"
[ -x "$JAVA" ] || JAVA="java"

cmd /c "taskkill /F /IM openocd.exe" >/dev/null 2>&1
cp "$NEWELF" "$BM1/app.elf" && echo "copied new app.elf ($(stat -c%s "$BM1/app.elf") bytes)"
cd "$BM1"
"$JAVA" -jar "$SC/extras/mpfs/mpfsBootmodeProgrammer.jar" --bootmode 1 --die MPFS250T_ES --package FCVG484 app.elf 2>&1 | tr -d '\r' | grep -aiE 'bootmode|program|success|error|fail|envm|complete|PASS|exception' | tail -30
