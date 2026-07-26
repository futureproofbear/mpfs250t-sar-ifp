#!/usr/bin/env bash
# Safe headless FPGA build with a PRE-SYNTH LINT GATE and an HONEST pass/fail verdict.
#
# Flow:  [optional prep .tcl] -> lint_netlist.sh (GATE) -> synth/P&R/VERIFYTIMING/export
#
# The lint gate scans the just-generated SmartDesign netlist for the silent-failure classes that
# cost us many build cycles (slave address/data tied to const, protocol-type mismatch). If it finds
# a CRITICAL it ABORTS *before* the ~30-min synthesis -- so a broken connection never burns a P&R run.
#
# This BUILDS AND EXPORTS a bitstream (build_full_prog_ffv.tcl: synth -> P&R -> setup+hold timing
# gate -> export SAR_TOP_ffv.job). It does NOT program the device -- programming is a separate,
# deliberate step (board must be on):   cd mpfs/fpga && libero SCRIPT:program_ffv.tcl
#
# Usage:
#   bash run_build_safe.sh                              # lint + rebuild the EXISTING ffv project
#   bash run_build_safe.sh ../fpga/create_fresh_project_ffv.tcl   # create a fresh project first, then gate+build
set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/sar_env.sh"   # SAR_ROOT / tool paths (see config.yaml)
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"          # mpfs/host
FPGA="$(cd "$HERE/../fpga" && pwd)"                            # mpfs/fpga
sar_require SAR_LIBERO || exit 2                               # fail loudly if the toolchain path is a placeholder
LIB="$SAR_LIBERO/Libero_SoC/Designer/bin/libero.exe"
BUILD_TCL="$FPGA/build_full_prog_ffv.tcl"   # open ffv project -> synth -> P&R -> VERIFYTIMING (setup+hold) -> export
JOB="$FPGA/libero_ffv/export/SAR_TOP_ffv.job"
PREP="${1:-}"
[ -x "$LIB" ]       || { echo "ERROR: libero.exe not found: $LIB (edit toolchain: libero in config.yaml/config.local.yaml)"; exit 2; }
[ -f "$BUILD_TCL" ] || { echo "ERROR: build tcl not found: $BUILD_TCL"; exit 2; }

if [ -n "$PREP" ]; then
    [ -f "$PREP" ] || { echo "ERROR: prep tcl not found: $PREP"; exit 2; }
    echo ">>> [1/3] prep (edit + generate): $PREP"
    "$LIB" "SCRIPT:$(cygpath -w "$PREP" 2>/dev/null || echo "$PREP")" 2>&1 | tr -d '\r' | grep -aiE "ERR|DONE|Successfully generated|not consistent" | tail -8
fi

echo ">>> [2/3] LINT GATE (pre-synth firebreak)"
# lint_netlist.sh defaults to the libero_sar project; THIS wrapper is the ffv flow throughout
# (build_full_prog_ffv.tcl, libero_ffv/export/...), so point it at the netlist this build just
# generated. Without it the gate aborts on "netlist not found" -- and worse, if a stale
# libero_sar/ netlist ever exists it would gate the WRONG file and pass vacuously.
NETLIST="$FPGA/libero_ffv/component/work/SAR_TOP/SAR_TOP.v"
if ! bash "$FPGA/lint_netlist.sh" "$NETLIST"; then
    echo ">>> ========================================================"
    echo ">>> BUILD ABORTED by lint gate -- fix the CRITICAL(s) above"
    echo ">>> (saved a ~30-min synth+P&R cycle on a broken netlist)."
    echo ">>> ========================================================"
    exit 1
fi

echo ">>> [3/3] synth -> P&R -> timing gate -> export"
BUILD_LOG="$HERE/run_build_safe.libero.log"
"$LIB" "SCRIPT:$(cygpath -w "$BUILD_TCL" 2>/dev/null || echo "$BUILD_TCL")" >"$BUILD_LOG" 2>&1
LRC=$?
tr -d '\r' < "$BUILD_LOG" | grep -aiE "SETUP nviol|HOLD nviol|VIOLRPT|TIMING_(MET|NOT_MET)|BITSTREAM_DONE|FFV_BUILD_DONE|Error:|Synthesis failed" | tail -15

# HONEST verdict -- decide on REAL signals, never on a pipe's exit status:
#   libero.exe exited 0  AND  the tcl reached BITSTREAM_DONE (success-only marker, printed AFTER export)
#   AND the timing gate did not reject it (TIMING_NOT_MET*)  AND the .job actually exists on disk.
ok=1
[ "$LRC" -eq 0 ]                             || { echo ">>> FAIL: libero.exe exited $LRC";                              ok=0; }
grep -aq "BITSTREAM_DONE" "$BUILD_LOG"       || { echo ">>> FAIL: no BITSTREAM_DONE marker (build never reached export)"; ok=0; }
grep -aqiE "TIMING_NOT_MET" "$BUILD_LOG"     && { echo ">>> FAIL: timing gate rejected the design (setup/hold not met)"; ok=0; }
[ -f "$JOB" ]                                || { echo ">>> FAIL: no exported bitstream at $JOB";                       ok=0; }

if [ "$ok" -ne 1 ]; then
    echo ">>> ==================================================================="
    echo ">>> BUILD FAILED -- no usable bitstream. Full Libero log: $BUILD_LOG"
    echo ">>> Do NOT program. (A fresh project needs the create_fresh_project_ffv.tcl prep arg.)"
    echo ">>> ==================================================================="
    exit 1
fi

## ---- ARCHIVE THE BITSTREAM -------------------------------------------------------------------
## A fresh-project build DELETES mpfs/fpga/libero_ffv/ wholesale, export/ included, and the .job is
## gitignored (it is 11.6 MB against a 6.9 MB repo history, so committing every build would bury
## the repo in incompressible binaries). Consequence, learned the hard way on 2026-07-26: a build
## whose bitstream turned out to be BAD on silicon had already destroyed the known-good one, and
## recovering a working board cost a full ~50-minute rebuild.
##
## So: keep the last few OUTSIDE the project tree, keyed by the commit they were built from. The
## firmware ELF goes with it -- a bitstream alone is not a restore point, the pair is.
ARCHDIR="$FPGA/bitstreams"
SHA="$(git -C "$SAR_ROOT" rev-parse --short HEAD 2>/dev/null || echo nogit)"
DIRTY=""; git -C "$SAR_ROOT" diff --quiet 2>/dev/null || DIRTY="-dirty"
SNAP="$ARCHDIR/$(date +%Y%m%d-%H%M%S)_${SHA}${DIRTY}"
mkdir -p "$SNAP"
cp "$JOB" "$SNAP/" 2>/dev/null
ELF_SRC="$SAR_ROOT/mpfs/fpga/libero_sar/softconsole/mpfs-hal-ddr-demo/Icicle-Kit-DDR-666MHz-eNVM-Scratchpad-Release/mpfs-hal-ddr-demo.elf"
[ -f "$ELF_SRC" ] && cp "$ELF_SRC" "$SNAP/"
{
  echo "commit   : $SHA$DIRTY"
  echo "built    : $(date -Iseconds)"
  echo "VERIFIED : NO   <- set to the CRC + config once silicon confirms it"
  tr -d '\r' < "$BUILD_LOG" | grep -aiE "SETUP nviol|VIOLRPT|TIMING_MET" | tail -4
} > "$SNAP/manifest.txt"
echo ">>> archived bitstream + ELF -> $SNAP"

## Keep the newest 4 snapshots (~66 MB); older ones are reproducible from their commit.
ls -1dt "$ARCHDIR"/*/ 2>/dev/null | tail -n +5 | while read -r old; do rm -rf "$old"; done
echo ">>> run_build_safe OK -- bitstream exported: $JOB"
echo ">>> To program (board on):  cd mpfs/fpga && \"$LIB\" SCRIPT:program_ffv.tcl"
