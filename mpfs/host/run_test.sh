#!/usr/bin/env bash
# Isolation test runner: OpenOCD runs efp6_test.cfg (halt -> stage geometry+job ->
# call sar_form_image -> read status -> dump 1MB OUT -> shutdown). Skips big xfers.
NEW="/c/Users/lkwangsi/Tools/openocd-new/xpack-openocd-0.12.0-4"
CFG="C:/Users/lkwangsi/Documents/github/sarProcessor/mpfs/fpga/efp6_test.cfg"
LOG="/c/Users/lkwangsi/Tools/openocd-new/test.log"
cmd /c "taskkill /F /IM openocd.exe" >/dev/null 2>&1
: > "$LOG"
rm -f /c/Users/lkwangsi/Documents/github/sarProcessor/mpfs/host/jtag_full/out_1mb.bin
"$NEW/bin/openocd.exe" -s "$NEW/openocd/scripts" -f "$CFG" -l "$LOG" >/dev/null 2>&1
echo "=== test log ==="
cat "$LOG" | tr -d '\r' | grep -aiE '>>>|0x|status|STATUS|BFP|error|Overlapped|fail|timed|halted|staged' | tail -40
echo "=== out_1mb.bin ==="
ls -la /c/Users/lkwangsi/Documents/github/sarProcessor/mpfs/host/jtag_full/out_1mb.bin 2>/dev/null | awk '{print $5}' || echo "none"
