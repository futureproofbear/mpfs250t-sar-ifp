#!/usr/bin/env bash
# Short JTAG read of the autonomous self-test results (g_sar_done / g_sar_status).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/sar_env.sh"   # SAR_ROOT / tool paths (see config.yaml)
NEW="$SAR_OPENOCD"
CFG="$SAR_ROOT/mpfs/fpga/efp6_read.cfg"
LOG="$SAR_SCRATCH/read.log"
cmd /c "taskkill /F /IM openocd.exe" >/dev/null 2>&1
: > "$LOG"
"$NEW/bin/openocd.exe" -s "$NEW/openocd/scripts" -f "$CFG" -l "$LOG" > "$LOG.stdout" 2>&1
echo "=== read log ==="
cat "$LOG" | tr -d '\r' | grep -aiE '>>>|0x[0-9a-f]{8}|pc |error|Overlapped|fail|halted' | tail -30
echo "=== stdout (mdw/reg fallback) ==="
cat "$LOG.stdout" 2>/dev/null | tr -d '\r' | grep -aiE 'pc|0x[0-9a-f]{8}|0x[0-9a-f]{8}:' | tail -10
