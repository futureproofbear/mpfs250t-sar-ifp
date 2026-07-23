#!/usr/bin/env bash
# Isolation test runner: OpenOCD runs efp6_test.cfg (halt -> stage geometry+job ->
# call sar_form_image -> read status -> dump 1MB OUT -> shutdown). Skips big xfers.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/sar_env.sh" \
  || { echo "FATAL: cannot load lib/sar_env.sh -- is it present? (see README / config.yaml)"; exit 3; }
: "${SAR_ROOT:?sar_env.sh did not set SAR_ROOT -- refusing to run with empty paths}"   # no set -u here; guard rm/exec off empty vars
NEW="$SAR_OPENOCD"
CFG="$SAR_ROOT/mpfs/fpga/efp6_test.cfg"
LOG="$SAR_SCRATCH/test.log"
cmd /c "taskkill /F /IM openocd.exe" >/dev/null 2>&1
: > "$LOG"
rm -f $SAR_ROOT/mpfs/host/jtag_full/out_1mb.bin
"$NEW/bin/openocd.exe" -s "$NEW/openocd/scripts" -f "$CFG" -l "$LOG" >/dev/null 2>&1
echo "=== test log ==="
cat "$LOG" | tr -d '\r' | grep -aiE '>>>|0x|status|STATUS|BFP|error|Overlapped|fail|timed|halted|staged' | tail -40
echo "=== out_1mb.bin ==="
ls -la $SAR_ROOT/mpfs/host/jtag_full/out_1mb.bin 2>/dev/null | awk '{print $5}' || echo "none"
