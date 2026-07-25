#!/usr/bin/env bash
# run_dual_chain_gate.sh -- board-free acceptance gate for the SECOND CoreFFT chain.
#
# Two independent checks, both of which must pass before this change goes near a build:
#
#   GATE W (structural, tclsh)  check_sartop_wiring.tcl
#       Mocks SmartDesign, sources the REAL sartop_assembly.tcl, and asserts the connection
#       graph: per-chain closure, FFT_x:SCALE_EXP -> FEED_x only, COEFG_x -> FEED_x only,
#       6 DIC initiators, the CIC target map, no dangling chain-B pin. This catches the
#       cross-wire class that synthesis, timing and a correlation check are ALL blind to.
#       Also runs 5 mutated COPIES of the assembly script and requires every one to FAIL.
#
#   GATE S (simulation, ModelSim) tb_fft_dual_chain.v
#       Two full chains (feeder -> gearbox -> CoreFFT-contract model -> unloader) sharing one
#       DDR through a single-outstanding-read (SASD) arbiter, vs ONE chain over the same rows.
#       Requires byte-identical DDR, identical per-row exponents, 100% destination mutation
#       coverage, and every one of 5 mutations to FAIL.
#
# Usage:  bash run_dual_chain_gate.sh
#         MSIM=/path/to/modelsim/win32acoem bash run_dual_chain_gate.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"       # mpfs/fpga/tb
FPGA="$(cd "$HERE/.." && pwd)"
MSIM="${MSIM:-/c/Microchip/Libero_SoC_2025.2/Libero_SoC/ModelSim_Pro/win32acoem}"
SCRATCH="${SCRATCH:-$HERE/dcscratch}"
fail=0

echo "=== GATE W: SAR_TOP wiring (structural) ==="
tclsh "$HERE/check_sartop_wiring.tcl" || fail=1

echo
echo "=== GATE W mutations (each MUST fail) ==="
mkdir -p "$SCRATCH"
SRC="$FPGA/sartop_assembly.tcl"
mutate () {   # $1 = label, $2 = sed expression
    sed "$2" "$SRC" > "$SCRATCH/mut.tcl"
    if tclsh "$HERE/check_sartop_wiring.tcl" "$SCRATCH/mut.tcl" >/dev/null 2>&1; then
        echo "  W-MUT $1: NOT DETECTED  <-- the gate is weak"; fail=1
    else
        echo "  W-MUT $1: detected"
    fi
}
mutate "scale_exp cross-wire"   's|"\$F:SCALE_EXP"  "\$FD:scale_exp_in"|"$F:SCALE_EXP"  "FEED:scale_exp_in"|'
mutate "coeff stream cross-wire" 's|"\$CG:m_idx"   "\$FD:c_idx"|"$CG:m_idx"   "FEED:c_idx"|'
mutate "DIC initiator > 5"      's|{"FEED_B:axi4initiator"    "DIC:AXI4minitiator1"}|{"FEED_B:axi4initiator"    "DIC:AXI4minitiator6"}|'
mutate "dangling gearbox TLAST" 's|catch { sd_mark_pins_unused -sd_name \$sd -pin_names "\$G:m_axis_tlast" }||'
mutate "CIC target1 misrouted"  's|{"CIC:AXI4mtarget1" "FEED_B:axi4target"}|{"CIC:AXI4mtarget1" "CT:axi4target"}|'

echo
echo "=== GATE S: two chains vs one (ModelSim) ==="
if [ ! -x "$MSIM/vlog.exe" ] && [ ! -f "$MSIM/vlog.exe" ]; then
    echo "  SKIP: no ModelSim at $MSIM (set MSIM=)"; fail=1
else
    cd "$HERE"
    rm -rf dcwork
    "$MSIM/vlib" dcwork >/dev/null
    "$MSIM/vlog" -work dcwork tb_fft_dual_chain.v "$FPGA/fft_feeder_v.v" \
        "$FPGA/fft_unloader_v.v" "$FPGA/corefft_stream64_adapter.v" > "$SCRATCH/vlog.log" 2>&1 \
        || { echo "  COMPILE FAILED (see $SCRATCH/vlog.log)"; fail=1; }
    for m in 0 1 2 3 4 5; do
        "$MSIM/vsim" -c -do "run -all; quit -f" dcwork.tb_fft_dual_chain +MUT=$m \
            > "$SCRATCH/mut$m.log" 2>&1
        if [ "$m" = "0" ]; then
            if grep -q "dual-chain FFT: PASS" "$SCRATCH/mut$m.log"; then
                grep -E "\[ref \]|\[dual\]" "$SCRATCH/mut$m.log"
                echo "  S-MUT 0 (clean): PASS"
            else
                echo "  S-MUT 0 (clean): FAIL  <-- two chains are NOT byte-identical to one"
                grep -E "^# " "$SCRATCH/mut$m.log" | tail -20; fail=1
            fi
        else
            if grep -q "mutation detected" "$SCRATCH/mut$m.log"; then
                echo "  S-MUT $m: detected ($(grep -oE 'FAIL \([0-9]+ errors' "$SCRATCH/mut$m.log" | head -1))"
            else
                echo "  S-MUT $m: NOT DETECTED  <-- the check is weak"; fail=1
            fi
        fi
    done
fi

echo
if [ $fail -ne 0 ]; then echo "==== DUAL-CHAIN GATE: FAIL ===="; exit 1; fi
echo "==== DUAL-CHAIN GATE: PASS ===="
