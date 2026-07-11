#!/usr/bin/env bash
# Short JTAG read of the autonomous self-test results (g_sar_done / g_sar_status).
NEW="/c/Users/lkwangsi/Tools/openocd-new/xpack-openocd-0.12.0-4"
CFG="C:/Users/lkwangsi/Documents/github/sarProcessor/mpfs/fpga/efp6_read.cfg"
LOG="/c/Users/lkwangsi/Tools/openocd-new/read.log"
cmd /c "taskkill /F /IM openocd.exe" >/dev/null 2>&1
: > "$LOG"
"$NEW/bin/openocd.exe" -s "$NEW/openocd/scripts" -f "$CFG" -l "$LOG" > "$LOG.stdout" 2>&1
echo "=== read log ==="
cat "$LOG" | tr -d '\r' | grep -aiE '>>>|0x[0-9a-f]{8}|pc |error|Overlapped|fail|halted' | tail -30
echo "=== stdout (mdw/reg fallback) ==="
cat "$LOG.stdout" 2>/dev/null | tr -d '\r' | grep -aiE 'pc|0x[0-9a-f]{8}|0x[0-9a-f]{8}:' | tail -10
