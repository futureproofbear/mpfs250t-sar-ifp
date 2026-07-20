#!/usr/bin/env bash
# Quick (~30 s) DDR peek: read a few words at the restored-image region so we can
# confirm the JTAG restore landed WITHOUT a slow full read-back. Compares the head
# to the packed image's superblock magic 0x53415249 ('SARI'). Attach-in-place, no
# reset, telnet-4444 shutdown, never taskkill.  Usage: run_ddr_peek.sh [ADDR]
set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/sar_env.sh"   # SAR_ROOT / tool paths (see config.yaml)
ADDR="${1:-0x88000000}"
HERE="$(cd "$(dirname "$0")" && pwd)"
GDBSCRIPT="$HERE/jtag_full/ddr_peek.gen.gdb"
GDBLOG="$HERE/jtag_full/ddr_peek.log"
OOLOG="${GDBLOG%.log}.openocd.log"
NEW="$SAR_OPENOCD"
SC="$SAR_SOFTCONSOLE"
GDB="$SC/riscv-unknown-elf-gcc/bin/riscv64-unknown-elf-gdb.exe"
ELF="$HERE/../fpga/libero_sar/softconsole/mpfs-hal-ddr-demo/Icicle-Kit-DDR-666MHz-eNVM-Scratchpad-Release/mpfs-hal-ddr-demo.elf"
PY="$SAR_PYTHON"

cat > "$GDBSCRIPT" <<GDBEOF
set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
shell $PY $HERE/jtag_full/wait_port.py
target extended-remote localhost:3333
monitor mpfs.hart1_u54_1 arp_halt
thread 2
printf ">>> head  @$ADDR (expect 53415249 00000001 00000001 00000000):\n"
x/8xw $ADDR
printf ">>> mid   @0x8ac00000:\n"
x/4xw 0x8ac00000
printf ">>> near-end @0x8dd00000-0x40:\n"
x/4xw (0x8dd00000-0x40)
set \$m = *(unsigned int*)$ADDR
if \$m == 0x53415249
  echo >>> RESTORE LANDED: SARI superblock present at load address.\n
else
  printf ">>> NO SARI at load addr (got 0x%08x) -- restore did not land.\n", \$m
end
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
echo ">>> peek done:"
grep -aE "head|mid|near-end|RESTORE LANDED|NO SARI|0x8" "$GDBLOG" | tail -14
