#!/usr/bin/env bash
# run_pipeline_probe.sh -- FAST (~40 s) pre-flight probe of the whole SAR pipeline chain,
# in ONE attach-in-place JTAG session. No mailbox command is armed, nothing is modified;
# this is purely "is the machine in a state where a run can succeed?".
#
# WHY THIS EXISTS: on 2026-07-20 a LOAD failed with ERR_INIT/OP_COND_ERR and it took a
# multi-step dig to find the real cause -- the FPGA fabric was not programmed. DDR probes
# passed (they only exercise the MSS), which masked it. P0 below catches that in seconds.
#
# Usage: bash run_pipeline_probe.sh
set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/sar_env.sh"   # SAR_ROOT / tool paths (config.yaml)
HERE="$(cd "$(dirname "$0")" && pwd)"
GDBSCRIPT="$HERE/jtag_full/pipeline_probe.gen.gdb"
GDBLOG="$HERE/jtag_full/pipeline_probe.log"
OOLOG="${GDBLOG%.log}.openocd.log"
NEW="$SAR_OPENOCD"; SC="$SAR_SOFTCONSOLE"
GDB="$SC/riscv-unknown-elf-gcc/bin/riscv64-unknown-elf-gdb.exe"
ELF="$HERE/../fpga/libero_sar/softconsole/mpfs-hal-ddr-demo/Icicle-Kit-DDR-666MHz-eNVM-Scratchpad-Release/mpfs-hal-ddr-demo.elf"

cat > "$GDBSCRIPT" <<'GDBEOF'
set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
target extended-remote localhost:3333
monitor mpfs.hart1_u54_1 arp_halt
thread 2

printf "\n===== P0  FABRIC ALIVE -- DELIBERATELY NOT PROBED BY RAW JTAG READ =====\n"
printf "  DO NOT add `x/ 0x6000xxxx` here. A raw FIC0 read against a fabric that is not\n"
printf "  programmed/clocked NEVER RETURNS: it stalls the AXI txn, freezes the hart, and\n"
printf "  openocd then dies with 'Timed out waiting for busy to go low' -- requiring a board\n"
printf "  power-cycle. (Learned the hard way 2026-07-20: this exact probe wedged the board.)\n"
printf "  Infer fabric health SAFELY instead, from firmware-side bounded operations:\n"
printf "    - LOAD verdict/init_status below (OP_COND_ERR=9 => eMMC mux dead => fabric likely dark)\n"
printf "    - PIPE returning SAR_SEQ_TIMEOUT_* rather than hanging\n"
printf "    - or SmartDebug (reads fabric nets out-of-band, cannot stall the hart)\n"

printf "\n===== P1  SCENE IN DDR (SIG @0x88000000) =====\n"
printf "  expect SARI magic 0x53415249 if a scene was LOADed this power-cycle\n"
x/4xw 0x88000000

printf "\n===== P2  FFT ENGINE SELECT (0xB0059110) =====\n"
printf "  fft_mode=%u  (1 = fabric CoreFFT chain, 0 = legacy CPU FFT)\n", *(unsigned int*)0xB0059110
printf "  detect_mode=%u  headroom=%u\n", *(unsigned int*)0xB0059118, *(unsigned int*)0xB0059114

printf "\n===== P3  HART1 STATE =====\n"
printf "  pc = %p  (should sit in the u54_1 mailbox loop)\n", $pc
printf "  mbx @0xB0058000: cmd=%08x result=%08x status=%08x seq=%u\n", \
  *(unsigned int*)0xB0058000, *(unsigned int*)0xB005800C, \
  *(unsigned int*)0xB0058010, *(unsigned int*)0xB0058014

printf "\n===== P4  LAST RUN RESULT RECORDS =====\n"
printf "  LOAD  @0xB005E000 (magic e3c0ff30, +8 verdict 0=PASS, +C nseg=10):\n"
x/8xw 0xB005E000
printf "  ROI   @0xB005E200 (magic e3c0ff50, +4 verdict):\n"
x/4xw 0xB005E200
printf "  SAVE  @0xB005E100 (magic e3c0ff40, +8 verdict):\n"
x/4xw 0xB005E100

printf "\n===== P5  PER-STAGE TIMING (previous PIPE, sar_stage_ts, 1 us/tick) =====\n"
if sar_stage_ts[6] >= sar_stage_ts[0] && sar_stage_ts[0] != 0
  printf "  resample   = %12llu us\n", (unsigned long long)(sar_stage_ts[1]-sar_stage_ts[0])
  printf "  window     = %12llu us\n", (unsigned long long)(sar_stage_ts[2]-sar_stage_ts[1])
  printf "  rangeFFT   = %12llu us\n", (unsigned long long)(sar_stage_ts[3]-sar_stage_ts[2])
  printf "  cornerturn = %12llu us\n", (unsigned long long)(sar_stage_ts[4]-sar_stage_ts[3])
  printf "  azimuthFFT = %12llu us\n", (unsigned long long)(sar_stage_ts[5]-sar_stage_ts[4])
  printf "  detect     = %12llu us\n", (unsigned long long)(sar_stage_ts[6]-sar_stage_ts[5])
  printf "  TOTAL      = %12llu us\n", (unsigned long long)(sar_stage_ts[6]-sar_stage_ts[0])
else
  printf "  (no timing yet -- no PIPE has completed since power-on)\n"
end

printf "\n>>> probe complete\n"
monitor shutdown
quit
GDBEOF

if tasklist 2>/dev/null | grep -qi openocd.exe; then
  echo ">>> WARNING: openocd.exe already running (stale). Close it cleanly; NOT force-killing." >&2; exit 1
fi
: > "$OOLOG"
"$NEW/bin/openocd.exe" -s "$NEW/openocd/scripts" --command "set DEVICE MPFS" \
  -f board/microchip_riscv_efp6.cfg -l "$OOLOG" >/dev/null 2>&1 &
sleep 12
cd "$HERE/jtag_full"      # .gdb paths are relative to jtag_full
"$GDB" -batch "$ELF" -x "$GDBSCRIPT" </dev/null > "$GDBLOG" 2>&1
grep -avE '^Reading|warranty|GPL|free soft|GNU gdb|Copyright|documentation|bug report|configured as|^Type |sifive|For help|apropos|Disabling abstract' "$GDBLOG"
echo ">>> probe log: $GDBLOG"
