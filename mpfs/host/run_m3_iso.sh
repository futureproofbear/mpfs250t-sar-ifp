#!/usr/bin/env bash
# Generic M3 mailbox runner: arm a command, resume, wait, read the mailbox + a
# result record, and (optionally) dump a DDR region to a file over JTAG.
# Same FP6 hygiene as the other iso-runs (efp6, telnet 4444, graceful shutdown,
# attach-in-place, never taskkill).
#
# Usage: run_m3_iso.sh CMD BASE LEN SLEEP_MS REC_ADDR [DUMP_ADDR DUMP_BYTES DUMP_FILE]
#   CMD/BASE/LEN : mailbox cmd + args (hex ok). REC_ADDR : result record base (16 words dumped).
#   DUMP_*       : optional -- `dump binary memory` of [DUMP_ADDR, +DUMP_BYTES) to DUMP_FILE.
set -u
CMD="$1"; BASE="$2"; LEN="$3"; SLEEP_MS="$4"; REC="$5"
DADDR="${6:-}"; DBYTES="${7:-}"; DFILE="${8:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
GDBSCRIPT="$HERE/jtag_full/m3_iso.gen.gdb"
GDBLOG="$HERE/jtag_full/m3_iso.log"
OOLOG="${GDBLOG%.log}.openocd.log"
NEW="/c/Users/lkwangsi/Tools/openocd-new/xpack-openocd-0.12.0-4"
SC="/c/Microchip/SoftConsole-v2022.2-RISC-V-747"
GDB="$SC/riscv-unknown-elf-gcc/bin/riscv64-unknown-elf-gdb.exe"
ELF="$HERE/../fpga/libero_sar/softconsole/mpfs-hal-ddr-demo/Icicle-Kit-DDR-666MHz-eNVM-Scratchpad-Release/mpfs-hal-ddr-demo.elf"
PY="C:/ProgramData/Anaconda3-2025.12-1/python.exe"

DUMPCMD=""
if [ -n "$DADDR" ]; then
  DFILE_WIN="$(cygpath -m "$DFILE" 2>/dev/null || echo "$DFILE")"
  DUMPCMD="dump binary memory $DFILE_WIN $DADDR ($DADDR + $DBYTES)"
fi

# PIPE ('PIPE'=0x50495045): select the FABRIC CoreFFT chain (FFTMODE @0xB0059110 = 1) -- the
# shipping FFT path (feeder->gearbox->CoreFFT->unloader). Without this the pipeline silently runs
# the LEGACY CPU-FFT fallback (mode 0). Detect stays CPU (default; detect_mode @0xB0059118 != 2).
FFTSET=""; FFTECHO=""
if [ "$CMD" = "0x50495045" ]; then
  FFTSET='set {unsigned int}0xB0059110 = 1'
  FFTECHO='printf ">>> fft_mode=%u (1=fabric CoreFFT) detect_mode=%u\\n", *(unsigned int*)0xB0059110, *(unsigned int*)0xB0059118'
fi

cat > "$GDBSCRIPT" <<GDBEOF
set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
shell $PY $HERE/jtag_full/wait_port.py
target extended-remote localhost:3333
monitor mpfs.hart1_u54_1 arp_halt
thread 2
printf ">>> hart1 pc = 0x%016lx\n", \$pc
$FFTSET
$FFTECHO
set {unsigned int}0xB0058004 = $BASE
set {unsigned int}0xB0058008 = $LEN
set {unsigned int}0xB005800C = 0
set {unsigned int}0xB0058010 = 0
set {unsigned int}0xB0058000 = $CMD
echo >>> armed cmd; resume + wait...\n
monitor resume
monitor sleep $SLEEP_MS
monitor mpfs.hart1_u54_1 arp_halt
thread 2
printf ">>> post pc = 0x%016lx\n", \$pc
printf ">>> mbx: cmd=0x%08x result=0x%08x status=0x%08x seq=%u\n", \
  *(unsigned int*)0xB0058000, *(unsigned int*)0xB005800C, *(unsigned int*)0xB0058010, *(unsigned int*)0xB0058014
echo >>> result record @REC (16 words):\n
x/16xw $REC
$DUMPCMD
GDBEOF

# PIPE ('PIPE'=0x50495045): also read the per-stage wall-clock from the sar_stage_ts
# symbol (gdb resolves it from the ELF; it lives in L2 scratchpad, no L2 flush needed).
# sar_stage_ts[0..6] = start/resample/window/rangeFFT/cornerturn/azimuthFFT/detect, MTIME 1 us/tick.
if [ "$CMD" = "0x50495045" ]; then
cat >> "$GDBSCRIPT" <<'STGEOF'
echo >>> per-stage timing (sar_stage_ts, MTIME 1 us/tick):\n
if sar_stage_ts[6] >= sar_stage_ts[0] && sar_stage_ts[0] != 0
  printf ">>>   resample    = %12llu us\n", (unsigned long long)(sar_stage_ts[1]-sar_stage_ts[0])
  printf ">>>   window      = %12llu us\n", (unsigned long long)(sar_stage_ts[2]-sar_stage_ts[1])
  printf ">>>   range-FFT   = %12llu us\n", (unsigned long long)(sar_stage_ts[3]-sar_stage_ts[2])
  printf ">>>   corner-turn = %12llu us\n", (unsigned long long)(sar_stage_ts[4]-sar_stage_ts[3])
  printf ">>>   azimuth-FFT = %12llu us\n", (unsigned long long)(sar_stage_ts[5]-sar_stage_ts[4])
  printf ">>>   detect      = %12llu us\n", (unsigned long long)(sar_stage_ts[6]-sar_stage_ts[5])
  printf ">>>   TOTAL       = %12llu us\n", (unsigned long long)(sar_stage_ts[6]-sar_stage_ts[0])
else
  echo >>> stage timing not valid (pipeline did not complete this run)\n
end
STGEOF
fi

cat >> "$GDBSCRIPT" <<GDBEOF
echo >>> teardown\n
monitor resume
monitor shutdown
quit
GDBEOF

if tasklist 2>/dev/null | grep -qi openocd.exe; then
  echo ">>> ABORT: openocd.exe already running -- NOT force-killing." ; exit 2
fi
: > "$OOLOG"; : > "$GDBLOG"
"$NEW/bin/openocd.exe" -s "$NEW/openocd/scripts" --command "set DEVICE MPFS" \
  -c "telnet_port 4444" -f board/microchip_riscv_efp6.cfg -l "$OOLOG" >/dev/null 2>&1 &
OO_PID=$!
sleep 14
"$GDB" -batch "$ELF" -x "$GDBSCRIPT" </dev/null > "$GDBLOG" 2>&1
echo "GDB_RC=$?" >> "$GDBLOG"
"$PY" - <<'PYEOF' 2>/dev/null || true
import socket,time
try:
    s=socket.create_connection(('127.0.0.1',4444),timeout=3); time.sleep(0.3)
    try: s.recv(4096)
    except Exception: pass
    s.sendall(b'shutdown\n'); time.sleep(0.5); s.close()
except Exception: pass
PYEOF
wait "$OO_PID" 2>/dev/null
echo ">>> m3 run done (cmd=$CMD). log: $GDBLOG"
grep -aE "mbx:|result record|0x[bB]005|pc =|>>>" "$GDBLOG" | tail -20