#!/usr/bin/env bash
# Short JTAG read of the M2 register-verification results: summary globals (addrs
# patched from nm by the caller) + the 24-record table at 0xB0050000.
NEW="/c/Users/lkwangsi/Tools/openocd-new/xpack-openocd-0.12.0-4"
CFG="C:/Users/lkwangsi/Documents/github/mpfs250t-sar-ifp/mpfs/fpga/efp6_m2.cfg"
LOG="/c/Users/lkwangsi/Tools/openocd-new/m2.log"
cmd /c "taskkill /F /IM openocd.exe" >/dev/null 2>&1
: > "$LOG"
"$NEW/bin/openocd.exe" -s "$NEW/openocd/scripts" -f "$CFG" -l "$LOG" >/dev/null 2>&1
echo "=== m2.log ==="
cat "$LOG" | tr -d '\r' | grep -aiE '>>>|rec |tag|error|Overlapped|fail' | tail -45
