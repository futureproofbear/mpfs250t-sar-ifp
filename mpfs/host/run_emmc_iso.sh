#!/usr/bin/env bash
# Milestone-1 eMMC self-test iso-run (PROVEN 2026-07-13: verdict=PASS).
# openocd (efp6, telnet 4444) + gdb batch driving jtag_full/emmc_selftest_iso.gdb
# (MAILBOX trigger; NO gdb inferior-call; SRS read gated on selftest-done). No force-kill.
# Prereq: board powered; eMMC-mux bitstream (SAR_TOP_ffv with SDIO_SW_* ties @ D7/C7/B7)
# programmed; -DSAR_EMMC_ENABLE firmware flashed (run_program.sh). Attach-in-place --
# do NOT reset (this ES silicon won't re-boot the U54 after a JTAG reset).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
GDBSCRIPT="$HERE/jtag_full/emmc_selftest_iso.gdb"
GDBLOG="$HERE/jtag_full/emmc_selftest_iso.log"
OOLOG="${GDBLOG%.log}.openocd.log"
NEW="/c/Users/lkwangsi/Tools/openocd-new/xpack-openocd-0.12.0-4"
SC="/c/Microchip/SoftConsole-v2022.2-RISC-V-747"
GDB="$SC/riscv-unknown-elf-gcc/bin/riscv64-unknown-elf-gdb.exe"
ELF="$HERE/../fpga/libero_sar/softconsole/mpfs-hal-ddr-demo/Icicle-Kit-DDR-666MHz-eNVM-Scratchpad-Release/mpfs-hal-ddr-demo.elf"

if tasklist 2>/dev/null | grep -qi openocd.exe; then
  echo ">>> ABORT: openocd.exe already running (stale) -- NOT force-killing (would wedge FP6)." ; exit 2
fi
: > "$OOLOG"; : > "$GDBLOG"
"$NEW/bin/openocd.exe" -s "$NEW/openocd/scripts" \
  --command "set DEVICE MPFS" \
  -c "telnet_port 4444" \
  -f board/microchip_riscv_efp6.cfg -l "$OOLOG" >/dev/null 2>&1 &
OO_PID=$!
sleep 14
"$GDB" -batch "$ELF" -x "$GDBSCRIPT" </dev/null > "$GDBLOG" 2>&1
echo "GDB_RC=$?" >> "$GDBLOG"
# graceful escape if gdb died before 'monitor shutdown' -- telnet shutdown, never taskkill
python - <<'PYEOF' 2>/dev/null || true
import socket,time
try:
    s=socket.create_connection(('127.0.0.1',4444),timeout=3); time.sleep(0.3)
    try: s.recv(4096)
    except Exception: pass
    s.sendall(b'shutdown\n'); time.sleep(0.5); s.close(); print("telnet-shutdown-sent")
except Exception as e: print("telnet-shutdown-skip:",e)
PYEOF
wait "$OO_PID" 2>/dev/null
echo ">>> eMMC iso-run done. Verdict + record in: $GDBLOG"
grep -aE "verdict=|SRS04|hart1 boot pc|selftest" "$GDBLOG" | tail -8
