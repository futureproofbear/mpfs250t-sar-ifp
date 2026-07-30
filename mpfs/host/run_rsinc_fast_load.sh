#!/usr/bin/env bash
# run_rsinc_fast_load.sh -- stage the RANGE 32-tap sinc coefficients in DDR and arm
# SAR_SINCMODE, so sar_resample_v runs 32-tap instead of 2-tap lerp.
#
# REPLACES run_sinc_table_load.sh, which took ~15 MINUTES every power cycle. That script pushed the
# table one AXI4-Lite `set` at a time: 8192 gdb round trips, each gdb -> OpenOCD -> JTAG -> ack. The
# payload is only 16 KB, which at the 6 MHz JTAG ceiling is ~22 ms of actual bits -- so over 99% of
# that quarter hour was per-transaction LATENCY, not data.
#
# The firmware now does those same 8192 register writes itself (sar_sinc_load_range), reading the
# table from DDR at SAR_SINC_TAB_ADDR = 0xB0064000, on-chip, in microseconds. The host only has to
# land 16 KB, which one `restore ... binary` does in a single transfer. This is the same trick the
# azimuth table already used; the asymmetry was historical, not necessary.
#
# The firmware reads back the table write pointer and FAILS THE RUN if it has not wrapped to 0,
# so a partial load cannot silently focus a line against half a kernel.
#
# PER POWER CYCLE, not once. The table ends up in FABRIC RAM (one copy per chain) and the mode word
# is in DDR, so a power-cycle or a fabric reprogram wipes both. The DDR blob must also be re-staged
# after any power-cycle, since DDR does not survive one either.
#
# ORDER: this must run BEFORE the PIPE that should use it. The firmware pushes the table at the top
# of the pass, reading whatever is at 0xB0060000 -- an unstaged blob is whatever DDR powered up as,
# and the image would be wrong in a way that looks like an interpolation bug, not a missing load.
#
# JTAG hygiene per docs/USER_GUIDE.md 3.3: never taskkill openocd; tear down via telnet 4444.
#
# Usage:  bash mpfs/host/run_rsinc_fast_load.sh          # stage table + arm SAR_SINCMODE
#         bash mpfs/host/run_rsinc_fast_load.sh --off    # disarm (back to the 2-tap lerp)
set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/sar_env.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
MODE="${1:-on}"

BIN="$HERE/jtag_full/sinc_table.bin"
if [ ! -f "$BIN" ]; then
    echo ">>> generating $BIN"
    "$SAR_PYTHON" "$HERE/gen_azsinc_table_bin.py" -o "$BIN" || exit 2
fi
SZ=$(wc -c < "$BIN")
if [ "$SZ" -ne 16384 ]; then echo ">>> ABORT: $BIN is $SZ bytes, expected 16384"; exit 2; fi

TAB_ADDR=0xB0064000
MODE_ADDR=0xB0059164
MODE_ON=0x534E4331            # 'SNC1'

G="$HERE/jtag_full/rsinc_load.gen.gdb"
L="$HERE/jtag_full/rsinc_load.log"
O="${L%.log}.openocd.log"
NEW="$SAR_OPENOCD"; SC="$SAR_SOFTCONSOLE"
GDB="$SC/riscv-unknown-elf-gcc/bin/riscv64-unknown-elf-gdb.exe"
ELF="$HERE/../fpga/libero_sar/softconsole/mpfs-hal-ddr-demo/Icicle-Kit-DDR-666MHz-eNVM-Scratchpad-Release/mpfs-hal-ddr-demo.elf"

{
  echo "set pagination off"
  echo "set confirm off"
  echo "set architecture riscv:rv64"
  echo "set mem inaccessible-by-default off"
  echo "shell $SAR_PYTHON $HERE/jtag_full/wait_port.py"
  echo "target extended-remote localhost:3333"
  echo "monitor mpfs.hart1_u54_1 arp_halt"
  echo "thread 2"
  if [ "$MODE" = "--off" ]; then
      echo "set *(unsigned int*)$MODE_ADDR = 0"
      echo 'echo >>> SAR_SINCMODE cleared -- azimuth gather back to the 2-tap lerp\n'
  else
      # RELATIVE path: gdb runs with cwd = jtag_full, and gdb on Windows cannot open a
      # git-bash "/c/Users/..." path -- it fails the sourced script at that line and every
      # later command, INCLUDING the mode-word write, is skipped.
      echo "restore $(basename "$BIN") binary $TAB_ADDR"
      # Read back three taps. Phase 0 is the sharpest one-word check there is: at mu = 0 the kernel
      # is sinc(n-15), exactly zero at every integer offset except n = 15. So tap 0 must be ~0 (it
      # is 1 -- the Q15 rounding residual) and tap 15 must be the peak, 32767. A table loaded in the
      # wrong tap order, or byte-swapped, fails this immediately.
      echo "printf \">>> tab[0] = %d (expect 1)   tab[15] = %d (expect 32767, the peak)\\n\", *(short*)$TAB_ADDR, *(short*)($TAB_ADDR + 30)"
      echo "printf \">>> tab[8191] = %d (expect -9, last tap of phase 255)\\n\", *(short*)($TAB_ADDR + 16382)"
      echo "set *(unsigned int*)$MODE_ADDR = $MODE_ON"
      echo 'echo >>> SAR_SINCMODE armed (ASN1) -- GATHER_CTRL[2] set per row, table pushed to BOTH chains\n'
  fi
  echo "monitor resume"
  echo "monitor shutdown"
  echo "quit"
} > "$G"

if tasklist 2>/dev/null | grep -qi openocd.exe; then
  echo ">>> ABORT: openocd.exe already running -- NOT force-killing."; exit 2
fi
: > "$O"; : > "$L"
"$NEW/bin/openocd.exe" -s "$NEW/openocd/scripts" --command "set DEVICE MPFS" \
  -c "telnet_port 4444" -f board/microchip_riscv_efp6.cfg -l "$O" >/dev/null 2>&1 &
sleep 14
(cd "$HERE/jtag_full" && "$GDB" -batch "$ELF" -x "$G" </dev/null > "$L" 2>&1)
"$SAR_PYTHON" - <<'PYEOF' 2>/dev/null || true
import socket, time
try:
    s = socket.create_connection(('127.0.0.1', 4444), timeout=3); time.sleep(0.3)
    try: s.recv(4096)
    except Exception: pass
    s.sendall(b"shutdown\n"); time.sleep(0.5); s.close()
except Exception:
    pass
PYEOF
OUT=$(grep -aE ">>>" "$L" | tr -d '\r')
echo "$OUT"
# A SILENT RUN IS A FAILED RUN. Without this the script printed nothing, returned 0, and the next
# PIPE quietly used the 2-tap lerp -- which presents as "sinc did not help" rather than "sinc never
# ran". That exact failure happened on 2026-07-30 (gdb could not open a git-bash /c/... path, so the
# sourced script aborted at `restore` and never reached the mode write). Gate on the arming line
# that the success path always prints.
if [ "$MODE" != "--off" ] && ! printf '%s' "$OUT" | grep -q "SAR_SINCMODE armed"; then
    echo ">>> FAILED -- table not staged / mode not armed. gdb reported:"
    grep -aiE "error|no such file|cannot|failed" "$L" | tr -d '\r' | head -5
    exit 3
fi
