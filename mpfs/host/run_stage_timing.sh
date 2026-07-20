#!/usr/bin/env bash
# run_stage_timing.sh -- read the per-stage pipeline timing (sar_stage_ts) left in DDR by the
# last completed PIPE, WITHOUT re-running anything. Attach-in-place, read-only, clean shutdown.
#
# sar_stage_ts[0..6] = start / resample / window / rangeFFT / cornerturn / azimuthFFT / detect,
# MTIME ticks at 1 us/tick. Also prints the mailbox (result 0 = SAR_SEQ_OK) and the FFT engine
# select so the timing is always reported together with WHICH engine produced it.
set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/sar_env.sh"   # SAR_ROOT / tool paths
HERE="$(cd "$(dirname "$0")" && pwd)"
GDBSCRIPT="$HERE/jtag_full/stage_timing.gen.gdb"
GDBLOG="$HERE/jtag_full/stage_timing.log"
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

printf "\n===== ENGINE + VERDICT =====\n"
printf "  fft_mode    = %u   (1 = fabric CoreFFT chain, 0 = legacy CPU FFT)\n", *(unsigned int*)0xB0059110
printf "  detect_mode = %u\n", *(unsigned int*)0xB0059118
printf "  mbx result  = 0x%08x  (0 = SAR_SEQ_OK)   status = 0x%08x   seq = %u\n", \
   *(unsigned int*)0xB005800C, *(unsigned int*)0xB0058010, *(unsigned int*)0xB0058014

printf "\n===== PER-STAGE TIMING (sar_stage_ts, MTIME 1 us/tick) =====\n"
if sar_stage_ts[6] >= sar_stage_ts[0] && sar_stage_ts[0] != 0
  printf "  resample    = %12llu us  (%6llu ms)\n", (unsigned long long)(sar_stage_ts[1]-sar_stage_ts[0]), (unsigned long long)((sar_stage_ts[1]-sar_stage_ts[0])/1000)
  printf "  window      = %12llu us  (%6llu ms)\n", (unsigned long long)(sar_stage_ts[2]-sar_stage_ts[1]), (unsigned long long)((sar_stage_ts[2]-sar_stage_ts[1])/1000)
  printf "  rangeFFT    = %12llu us  (%6llu ms)\n", (unsigned long long)(sar_stage_ts[3]-sar_stage_ts[2]), (unsigned long long)((sar_stage_ts[3]-sar_stage_ts[2])/1000)
  printf "  cornerturn  = %12llu us  (%6llu ms)\n", (unsigned long long)(sar_stage_ts[4]-sar_stage_ts[3]), (unsigned long long)((sar_stage_ts[4]-sar_stage_ts[3])/1000)
  printf "  azimuthFFT  = %12llu us  (%6llu ms)\n", (unsigned long long)(sar_stage_ts[5]-sar_stage_ts[4]), (unsigned long long)((sar_stage_ts[5]-sar_stage_ts[4])/1000)
  printf "  detect      = %12llu us  (%6llu ms)\n", (unsigned long long)(sar_stage_ts[6]-sar_stage_ts[5]), (unsigned long long)((sar_stage_ts[6]-sar_stage_ts[5])/1000)
  printf "  ---------------------------------------------\n"
  printf "  TOTAL       = %12llu us  (%6llu s)\n", (unsigned long long)(sar_stage_ts[6]-sar_stage_ts[0]), (unsigned long long)((sar_stage_ts[6]-sar_stage_ts[0])/1000000)
else
  printf "  (no timing: sar_stage_ts not populated -- no PIPE completed since power-on)\n"
end
printf "\n"
monitor shutdown
quit
GDBEOF

if tasklist 2>/dev/null | grep -qi openocd.exe; then
  echo ">>> WARNING: openocd.exe already running (stale). Close it cleanly; NOT force-killing." >&2; exit 1
fi
: > "$OOLOG"
"$NEW/bin/openocd.exe" -s "$NEW/openocd/scripts" --command "set DEVICE MPFS" -c "telnet_port 4444" \
  -f board/microchip_riscv_efp6.cfg -l "$OOLOG" >/dev/null 2>&1 &
sleep 12
cd "$HERE/jtag_full"
"$GDB" -batch "$ELF" -x "$GDBSCRIPT" </dev/null > "$GDBLOG" 2>&1
grep -avE '^Reading|warranty|GPL|free soft|GNU gdb|Copyright|documentation|bug report|configured as|^Type |sifive|For help|apropos|Disabling abstract' "$GDBLOG"
