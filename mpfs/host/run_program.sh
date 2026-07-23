#!/usr/bin/env bash
# Reprogram eNVM (boot mode 1) with the self-test firmware via fpgenprog
# (reliable Microchip programmer -- NOT the buggy OpenOCD HID). Needs FlashPro
# connected + board powered.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/sar_env.sh" \
  || { echo "FATAL: cannot load lib/sar_env.sh -- is it present? (see README / config.yaml)"; exit 3; }
: "${SAR_ROOT:?sar_env.sh did not set SAR_ROOT -- refusing to run with empty paths}"   # no set -u here; guard rm/exec off empty vars
SC="$SAR_SOFTCONSOLE"
BM1="$SAR_ROOT/mpfs/fpga/bm1"
NEWELF="$SAR_ROOT/mpfs/fpga/libero_sar/softconsole/mpfs-hal-ddr-demo/Icicle-Kit-DDR-666MHz-eNVM-Scratchpad-Release/mpfs-hal-ddr-demo.elf"
export SC_INSTALL_DIR="$SC"
export FPGENPROG="$SAR_LIBERO/Libero_SoC/Designer/bin64/fpgenprog.exe"
JAVA="$SC/eclipse/jre/bin/java.exe"
[ -x "$JAVA" ] || JAVA="java"

cmd /c "taskkill /F /IM openocd.exe" >/dev/null 2>&1
cp "$NEWELF" "$BM1/app.elf" && echo "copied new app.elf ($(stat -c%s "$BM1/app.elf") bytes)"
cd "$BM1"
"$JAVA" -jar "$SC/extras/mpfs/mpfsBootmodeProgrammer.jar" --bootmode 1 --die MPFS250T_ES --package FCVG484 app.elf 2>&1 | tr -d '\r' | grep -aiE 'bootmode|program|success|error|fail|envm|complete|PASS|exception' | tail -30
