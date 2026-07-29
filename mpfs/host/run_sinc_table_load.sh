#!/usr/bin/env bash
# run_sinc_table_load.sh -- push the 32-tap polyphase sinc coefficients into sar_resample_v over
# JTAG, and arm SAR_SINCMODE.
#
# WHY THE HOST DOES THIS. 256 phases x 32 taps x int16 = 16 KB and it does not fit in the firmware
# image: the app's .rodata lives in the 256 KB L2 scratchpad, which is full -- linking the table
# overflowed the region by 15,584 bytes. Recomputing it on the U54 is not possible either (it needs
# sin(); this firmware links without libm). It does not belong in the image regardless: the table is
# SCENE-INDEPENDENT, a pure function of fractional delay, so this is a ONE-TIME push that survives
# until the fabric is reprogrammed or the board is power-cycled.
#
# ORDER MATTERS: load the table BEFORE the first PIPE. sar_resample_v reads it per query; an unloaded
# table is all zeros, every query then maps to the same place, and the image is wrong in a way that
# looks like an interpolation bug rather than a missing load.
#
# The generated script ends by reading TAB_DATA back, which returns tab_wptr. After exactly 8192
# writes it must have wrapped to 0 -- a cheap proof that every write landed rather than a prefix.
#
# JTAG hygiene per docs/USER_GUIDE.md §3.3: never taskkill openocd, tear down via telnet 4444.
#
# Usage:  bash mpfs/host/run_sinc_table_load.sh          # load table + arm SAR_SINCMODE
#         bash mpfs/host/run_sinc_table_load.sh --off    # disarm (back to the 2-tap lerp)
set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/sar_env.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
MODE="${1:-on}"

TAB="$HERE/jtag_full/sinc_table.gdb"
if [ ! -f "$TAB" ]; then
    echo ">>> generating $TAB"
    "$SAR_PYTHON" "$HERE/gen_sinc_table_gdb.py" || exit 2
fi

SINCMODE_ADDR=0xB0059164
SINCMODE_ON=0x534E4331          # 'SNC1'

G="$HERE/jtag_full/sinc_load.gen.gdb"
L="$HERE/jtag_full/sinc_load.log"
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
      echo "set *(unsigned int*)$SINCMODE_ADDR = 0"
      echo 'echo >>> SAR_SINCMODE cleared -- back to the 2-tap lerp\n'
  else
      cat "$TAB"
      echo "set *(unsigned int*)$SINCMODE_ADDR = $SINCMODE_ON"
      echo 'echo >>> SAR_SINCMODE armed (SNC1) -- LCFG[17] will be set per line\n'
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
