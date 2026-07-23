#!/usr/bin/env bash
# Short JTAG read of the M2 register-verification results: summary globals (addrs
# patched from nm by the caller) + the 24-record table at 0xB0050000.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/sar_env.sh" \
  || { echo "FATAL: cannot load lib/sar_env.sh -- is it present? (see README / config.yaml)"; exit 3; }
: "${SAR_ROOT:?sar_env.sh did not set SAR_ROOT -- refusing to run with empty paths}"   # no set -u here; guard rm/exec off empty vars
NEW="$SAR_OPENOCD"
CFG="$SAR_ROOT/mpfs/fpga/efp6_m2.cfg"
LOG="$SAR_SCRATCH/m2.log"
cmd /c "taskkill /F /IM openocd.exe" >/dev/null 2>&1
: > "$LOG"
"$NEW/bin/openocd.exe" -s "$NEW/openocd/scripts" -f "$CFG" -l "$LOG" >/dev/null 2>&1
echo "=== m2.log ==="
cat "$LOG" | tr -d '\r' | grep -aiE '>>>|rec |tag|error|Overlapped|fail' | tail -45
