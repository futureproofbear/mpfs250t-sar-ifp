#!/usr/bin/env bash
# OpenOCD-only SAR flow. OpenOCD runs efp6_flow.cfg start-to-finish (examine ->
# halt -> stage -> call sar_form_image -> dump OUT -> shutdown) with no idle gap,
# so the FlashPro HID never crashes. No GDB. OpenOCD exits itself via `shutdown`.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/sar_env.sh" \
  || { echo "FATAL: cannot load lib/sar_env.sh -- is it present? (see README / config.yaml)"; exit 3; }
: "${SAR_ROOT:?sar_env.sh did not set SAR_ROOT -- refusing to run with empty paths}"   # no set -u here; guard rm/exec off empty vars
NEW="$SAR_OPENOCD"
CFG="$SAR_ROOT/mpfs/fpga/efp6_flow.cfg"
LOG="$SAR_SCRATCH/flow.log"
cmd /c "taskkill /F /IM openocd.exe" >/dev/null 2>&1
: > "$LOG"
rm -f $SAR_ROOT/mpfs/host/jtag_full/out.bin
"$NEW/bin/openocd.exe" -s "$NEW/openocd/scripts" -f "$CFG" -l "$LOG" >/dev/null 2>&1
echo "=== flow log ==="
cat "$LOG" | tr -d '\r' | tail -45
echo "=== out.bin ==="
ls -la $SAR_ROOT/mpfs/host/jtag_full/out.bin 2>/dev/null | awk '{print $5}' || echo "no out.bin"
