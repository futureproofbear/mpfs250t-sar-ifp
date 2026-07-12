#!/usr/bin/env bash
# OpenOCD-only SAR flow. OpenOCD runs efp6_flow.cfg start-to-finish (examine ->
# halt -> stage -> call sar_form_image -> dump OUT -> shutdown) with no idle gap,
# so the FlashPro HID never crashes. No GDB. OpenOCD exits itself via `shutdown`.
NEW="/c/Users/lkwangsi/Tools/openocd-new/xpack-openocd-0.12.0-4"
CFG="C:/Users/lkwangsi/Documents/github/mpfs250t-sar-ifp/mpfs/fpga/efp6_flow.cfg"
LOG="/c/Users/lkwangsi/Tools/openocd-new/flow.log"
cmd /c "taskkill /F /IM openocd.exe" >/dev/null 2>&1
: > "$LOG"
rm -f /c/Users/lkwangsi/Documents/github/mpfs250t-sar-ifp/mpfs/host/jtag_full/out.bin
"$NEW/bin/openocd.exe" -s "$NEW/openocd/scripts" -f "$CFG" -l "$LOG" >/dev/null 2>&1
echo "=== flow log ==="
cat "$LOG" | tr -d '\r' | tail -45
echo "=== out.bin ==="
ls -la /c/Users/lkwangsi/Documents/github/mpfs250t-sar-ifp/mpfs/host/jtag_full/out.bin 2>/dev/null | awk '{print $5}' || echo "no out.bin"
