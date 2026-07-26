#!/usr/bin/env bash
# Roll the board back to an ARCHIVED bitstream + firmware, without a ~50-minute rebuild.
#
# WHY THIS EXISTS. A fresh-project build deletes mpfs/fpga/libero_ffv/ wholesale, export/ included,
# and the .job is gitignored (11.6 MB against a 6.9 MB repo history). On 2026-07-26 a build whose
# bitstream turned out to be BAD on silicon had already destroyed the known-good one, and getting a
# working board back cost a full rebuild. run_build_safe.sh now snapshots every successful build to
# mpfs/fpga/bitstreams/<stamp>_<commit>/; this programs one back.
#
# Usage:
#   bash restore_bitstream.sh              # list the archive, newest first
#   bash restore_bitstream.sh <dir>        # program that snapshot (fabric + firmware)
#   bash restore_bitstream.sh latest       # program the newest snapshot
#
# Board must be powered and the FlashPro6 connected.
set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/sar_env.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
FPGA="$(cd "$HERE/../fpga" && pwd)"
ARCHDIR="$FPGA/bitstreams"

if [ ! -d "$ARCHDIR" ] || [ -z "$(ls -A "$ARCHDIR" 2>/dev/null)" ]; then
    echo "no snapshots in $ARCHDIR -- run_build_safe.sh populates it on every successful build"
    exit 1
fi

SEL="${1:-}"
if [ -z "$SEL" ]; then
    echo "=== archived bitstreams (newest first) ==="
    for d in $(ls -1dt "$ARCHDIR"/*/ 2>/dev/null); do
        echo "--- $(basename "$d")"
        sed 's/^/      /' "$d/manifest.txt" 2>/dev/null | head -6
    done
    echo
    echo "program one with:  bash restore_bitstream.sh <dir-name>   (or 'latest')"
    exit 0
fi

[ "$SEL" = "latest" ] && SNAP="$(ls -1dt "$ARCHDIR"/*/ 2>/dev/null | head -1)" || SNAP="$ARCHDIR/$SEL"
SNAP="${SNAP%/}"
[ -d "$SNAP" ] || { echo "no such snapshot: $SNAP"; exit 1; }
JOB_SRC="$SNAP/SAR_TOP_ffv.job"
[ -f "$JOB_SRC" ] || { echo "snapshot has no .job: $SNAP"; exit 1; }

echo "=== restoring $(basename "$SNAP") ==="
cat "$SNAP/manifest.txt" 2>/dev/null | sed 's/^/    /'
echo

## Put the .job back where program_ffv.tcl expects it. The export dir may not exist if the project
## tree was wiped -- that is the whole scenario this script is for.
mkdir -p "$FPGA/libero_ffv/export"
cp "$JOB_SRC" "$FPGA/libero_ffv/export/SAR_TOP_ffv.job" || exit 1

## Same JTAG hygiene as every other board script. NOTE: `cmd //c`, not `cmd /c` -- under git-bash a
## bare /c is path-converted to C:/ and the command silently never runs (fixed repo-wide in e76622d).
cmd //c "taskkill /F /IM openocd.exe" >/dev/null 2>&1
cmd //c "taskkill /F /IM riscv64-unknown-elf-gdb.exe" >/dev/null 2>&1
sleep 2

echo ">>> programming fabric ..."
LIB="$SAR_LIBERO/Libero_SoC/Designer/bin/libero.exe"
( cd "$FPGA" && "$LIB" SCRIPT:program_ffv.tcl ) 2>&1 | tr -d '\r' \
    | grep -aiE "PROGRAM PASSED|PROGRAM FAILED|No programmer|PROG_OK|PROG_ERR" | tail -3

## The firmware is half of the restore point: a bitstream paired with the wrong ELF is not the
## configuration that was validated.
if [ -f "$SNAP/mpfs-hal-ddr-demo.elf" ]; then
    DST="$SAR_ROOT/mpfs/fpga/libero_sar/softconsole/mpfs-hal-ddr-demo/Icicle-Kit-DDR-666MHz-eNVM-Scratchpad-Release/mpfs-hal-ddr-demo.elf"
    cp "$SNAP/mpfs-hal-ddr-demo.elf" "$DST" && echo ">>> restored firmware ELF from the snapshot"
    echo ">>> flashing firmware ..."
    bash "$HERE/run_program.sh" 2>&1 | grep -aiE "completed successfully|ERROR" | tail -1
else
    echo ">>> NOTE: snapshot has no ELF -- fabric restored, firmware left as-is"
fi

echo
echo ">>> restored. Verify before trusting it:  ELOD, then PIPE, crop CRC must read 0x319037b2"
echo ">>> (one ELOD per PIPE run -- a run overwrites SIG)"
