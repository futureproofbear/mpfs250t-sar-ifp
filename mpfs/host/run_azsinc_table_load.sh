#!/usr/bin/env bash
# run_azsinc_table_load.sh -- stage the AZIMUTH 32-tap sinc coefficients in DDR and arm
# SAR_AZSINCMODE, so the fused azimuth gather in fft_feeder_v runs 32-tap instead of 2-tap lerp.
#
# WHY THIS IS FAST AND run_sinc_table_load.sh IS NOT. The RANGE table has to be pushed one
# AXI4-Lite `set` at a time, because sar_resample_v's table sits behind a CIC register with no
# other way in -- 8192 writes, ~15 min at the 6 MHz JTAG ceiling. The AZIMUTH table does not:
# sar_sequencer.c reads it from DDR (SAR_AZSINC_TAB_ADDR = 0xB0059200) and pushes it into BOTH
# feeders itself, on-chip at CPU speed. The host only has to land 16 KB, which `restore ... binary`
# does in one transfer.
#
# PER POWER CYCLE, not once. The table ends up in FABRIC RAM (one copy per chain) and the mode word
# is in DDR, so a power-cycle or a fabric reprogram wipes both. The DDR blob must also be re-staged
# after any power-cycle, since DDR does not survive one either.
#
# ORDER: this must run BEFORE the PIPE that should use it. The firmware pushes the table at the top
# of the pass, reading whatever is at 0xB0059200 -- an unstaged blob is whatever DDR powered up as,
# and the image would be wrong in a way that looks like an interpolation bug, not a missing load.
#
# JTAG hygiene per docs/USER_GUIDE.md 3.3: never taskkill openocd; tear down via telnet 4444.
#
# Usage:  bash mpfs/host/run_azsinc_table_load.sh          # stage table + arm SAR_AZSINCMODE
#         bash mpfs/host/run_azsinc_table_load.sh --off    # disarm (back to the 2-tap lerp)
set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/sar_env.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
MODE="${1:-on}"

BIN="$HERE/jtag_full/azsinc_table.bin"
if [ ! -f "$BIN" ]; then
    echo ">>> generating $BIN"
    "$SAR_PYTHON" "$HERE/gen_azsinc_table_bin.py" || exit 2
fi
SZ=$(wc -c < "$BIN")
if [ "$SZ" -ne 16384 ]; then echo ">>> ABORT: $BIN is $SZ bytes, expected 16384"; exit 2; fi

TAB_ADDR=0xB0059200
MODE_ADDR=0xB0059168
MODE_ON=0x41534E31            # 'ASN1'

G="$HERE/jtag_full/azsinc_load.gen.gdb"
L="$HERE/jtag_full/azsinc_load.log"
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
      echo 'echo >>> SAR_AZSINCMODE cleared -- azimuth gather back to the 2-tap lerp\n'
  else
      echo "restore $BIN binary $TAB_ADDR"
      # Read back three taps. Phase 0 is the sharpest one-word check there is: at mu = 0 the kernel
      # is sinc(n-15), exactly zero at every integer offset except n = 15. So tap 0 must be ~0 (it
      # is 1 -- the Q15 rounding residual) and tap 15 must be the peak, 32767. A table loaded in the
      # wrong tap order, or byte-swapped, fails this immediately.
      echo "printf \">>> tab[0] = %d (expect 1)   tab[15] = %d (expect 32767, the peak)\\n\", *(short*)$TAB_ADDR, *(short*)($TAB_ADDR + 30)"
      echo "printf \">>> tab[8191] = %d (expect -9, last tap of phase 255)\\n\", *(short*)($TAB_ADDR + 16382)"
      echo "set *(unsigned int*)$MODE_ADDR = $MODE_ON"
      echo 'echo >>> SAR_AZSINCMODE armed (ASN1) -- GATHER_CTRL[2] set per row, table pushed to BOTH chains\n'
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
grep -aE ">>>" "$L" | tr -d '\r'
