#!/usr/bin/env bash
# run_rsv_alias_test.sh -- does the sar_resample_v control port decode SIX address bits?
#
# WHY. sar_resample_v needs 6 bits: its table registers sit at 0x2c (TAB_CTRL) and 0x30
# (TAB_DATA), while the SmartHLS core it replaced needed only 5. If the CIC target or the HDL+
# core registration kept 5, then 0x2c aliases onto 0x0c (IN_BASE) and 0x30 onto 0x10 (OUT_BASE).
# The query table would then NEVER load -- every entry stays zero, every query maps to the same
# place, and the image is structurally wrong -- while a register readback still looks perfectly
# healthy, because sar_rsv_arm_line() rewrites IN_BASE/OUT_BASE immediately afterwards. That is
# exactly the state observed on 2026-07-29: 0x0c..0x24 all read back correct, image corr -0.04.
#
# THE TEST. Park markers in IN_BASE/OUT_BASE, then write the two table registers and read the
# markers back. No scene, no pipeline run, no DDR -- so it works straight after a power cycle.
#   6-bit decode (correct): markers survive; 0x30 reads back tab_wptr == 1 after one push.
#   5-bit decode (aliased): IN_BASE becomes the TAB_CTRL payload and OUT_BASE the TAB_DATA word.
#
# Read-mostly and self-contained: it leaves the kernel idle with junk in IN_BASE/OUT_BASE, which
# the next arm_line overwrites before it starts. Safe to run any time the kernel is not busy.
# JTAG hygiene per docs/USER_GUIDE.md §3.3: never taskkill openocd, tear down via telnet 4444.
set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/sar_env.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
K=0x60003000                        # K_RESAMPLE (sar_kernels.h: FIC0_CTRL_BASE + 0x3000)
GDBSCRIPT="$HERE/jtag_full/rsv_alias.gen.gdb"
GDBLOG="$HERE/jtag_full/rsv_alias.log"
OOLOG="${GDBLOG%.log}.openocd.log"
NEW="$SAR_OPENOCD"; SC="$SAR_SOFTCONSOLE"
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

echo >>> park markers in IN_BASE(0x0c) and OUT_BASE(0x10)\n
set *(unsigned int*)($K + 0x0c) = 0x11110000
set *(unsigned int*)($K + 0x10) = 0x22220000
printf ">>> before: IN_BASE=%08x OUT_BASE=%08x\n", *(unsigned int*)($K+0x0c), *(unsigned int*)($K+0x10)

echo >>> write TAB_CTRL(0x2c)=4 (rewind, sel KR) then one TAB_DATA(0x30) word\n
set *(unsigned int*)($K + 0x2c) = 0x00000004
set *(unsigned int*)($K + 0x30) = 0xaaaa5555

printf ">>> after : IN_BASE=%08x OUT_BASE=%08x  TAB_DATA_rd(=tab_wptr)=%08x\n", *(unsigned int*)($K+0x0c), *(unsigned int*)($K+0x10), *(unsigned int*)($K+0x30)

set \$in = *(unsigned int*)($K+0x0c)
set \$out = *(unsigned int*)($K+0x10)
if \$in == 0x11110000 && \$out == 0x22220000
  echo >>> VERDICT: 6-BIT DECODE OK -- table registers are distinct; aliasing is NOT the fault.\n
else
  echo >>> VERDICT: ALIASED -- the control port decodes only 5 bits.\n
  echo >>>          0x2c hit IN_BASE and/or 0x30 hit OUT_BASE, so the query table never loads.\n
  echo >>>          Fix the HDL+ core registration / CIC target width, NOT the RTL.\n
end
monitor resume
monitor shutdown
quit
GDBEOF

if tasklist 2>/dev/null | grep -qi openocd.exe; then
  echo ">>> ABORT: openocd.exe already running -- NOT force-killing."; exit 2
fi
: > "$OOLOG"; : > "$GDBLOG"
"$NEW/bin/openocd.exe" -s "$NEW/openocd/scripts" --command "set DEVICE MPFS" \
  -c "telnet_port 4444" -f board/microchip_riscv_efp6.cfg -l "$OOLOG" >/dev/null 2>&1 &
sleep 14
(cd "$HERE/jtag_full" && "$GDB" -batch "$ELF" -x "$GDBSCRIPT" </dev/null > "$GDBLOG" 2>&1)
"$PY" - <<'PYEOF' 2>/dev/null || true
import socket, time
try:
    s = socket.create_connection(('127.0.0.1', 4444), timeout=3); time.sleep(0.3)
    try: s.recv(4096)
    except Exception: pass
    s.sendall(b"shutdown\n"); time.sleep(0.5); s.close()
except Exception:
    pass
PYEOF
grep -aE ">>>" "$GDBLOG" | tr -d '\r'
