#!/usr/bin/env bash
# Read the LPDDR4 training result over JTAG -- no UART, no reflash, no power-cycle.
#
# WHY THIS EXISTS: the MPFS HAL prints training status over MMUART, but this board's
# USB-UART is not connected (only an Intel AMT SOL port enumerates on the host, and no
# FTDI device has ever appeared). The values the HAL prints are not software state --
# they are TIP hardware registers in CFG_DDR_SGMII_PHY, readable at any time over the
# FlashPro6 the same way we read DDR. So the console is not on the critical path.
#
# Registers (CFG_DDR_SGMII_PHY_BASE 0x20007000, offsets from mss_ddr_sgmii_phy_defs.h):
#   0x20007814  training_status  [7:0]  per-stage DONE flags
#   0x200078bc  expert_wrcalib          WRCALIB_RESULT (write-calibration, per lane)
#   0x2000720c  IOC_REG2                PCODE [6:0], NCODE [13:7]  (impedance calibration)
#   0x20007218  IOC_REG5                SRO slew-rate observations
#   0x20007008  DDRPHY_STARTUP
#
# training_status POLARITY (mss_ddr.c ~1490): a SET bit means that stage COMPLETED --
# each bit is what advances the training state machine to the next stage. So:
#   bit0 BCLK_SCLK  bit1 ADDCMD  bit2 WRLVL  bit3 RDGATE  bit4 DQ_DQS
# This is the opposite of an error register; do not read a clear bit as "no fault".
#
# ...BUT the expected value is NOT 0x1f. LIBERO_SETTING_TRAINING_SKIP_SETTING (0x02 on this
# board: SKIP_ADDCMD_TIP_TRAINING = 1) tells the TIP to skip stages, and a SKIPPED stage
# never sets its status bit. Expected = 0x1f & ~SKIP = 0x1d here. Comparing against a flat
# 0x1f reports a healthy board as "TRAINING INCOMPLETE" -- a false alarm that costs a
# debugging session, so the mask is applied below.
#
# Reads PHYSICAL addresses only -- no ELF symbols and no `call` -- so it is safe to run
# with an ELF that no longer matches the flashed firmware (which is exactly the state
# after a firmware edit but before a reflash).
#
# Attach-in-place (never `monitor reset halt`), telnet-4444 shutdown, never taskkill.
set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/sar_env.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"
GDBSCRIPT="$HERE/jtag_full/ddr_training.gen.gdb"
GDBLOG="$HERE/jtag_full/ddr_training.log"
OOLOG="${GDBLOG%.log}.openocd.log"
NEW="$SAR_OPENOCD"
SC="$SAR_SOFTCONSOLE"
GDB="$SC/riscv-unknown-elf-gcc/bin/riscv64-unknown-elf-gdb.exe"
ELF="$HERE/../fpga/libero_sar/softconsole/mpfs-hal-ddr-demo/Icicle-Kit-DDR-666MHz-eNVM-Scratchpad-Release/mpfs-hal-ddr-demo.elf"
PY="$SAR_PYTHON"

# Skip mask straight from the board's design config, so this never drifts from the build.
SKIP_HDR="$HERE/../fpga/libero_sar/softconsole/mpfs-hal-ddr-demo/src/boards/icicle-kit-es-ddr-666MHz/fpga_design_config/ddr/hw_ddr_options.h"
SKIP_MASK="$(grep -oE 'define LIBERO_SETTING_TRAINING_SKIP_SETTING\s+0x[0-9A-Fa-f]+' "$SKIP_HDR" \
             | grep -oE '0x[0-9A-Fa-f]+' | head -1)"
SKIP_MASK="${SKIP_MASK:-0x0}"
echo ">>> training skip mask from design config: $SKIP_MASK"

cat > "$GDBSCRIPT" <<GDBEOF
set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
shell $PY $HERE/jtag_full/wait_port.py
target extended-remote localhost:3333
monitor mpfs.hart1_u54_1 arp_halt
thread 2

set \$ts = *(unsigned int*)0x20007814
set \$wc = *(unsigned int*)0x200078bc
set \$r2 = *(unsigned int*)0x2000720c
set \$r5 = *(unsigned int*)0x20007218
set \$su = *(unsigned int*)0x20007008

set \$skip = $SKIP_MASK
set \$want = 0x1f & ~\$skip
printf ">>> training_status = 0x%08x  (skip mask 0x%02x -> expect 0x%02x)\n", \$ts, \$skip, \$want
printf ">>>   bit0 BCLK_SCLK = %u\n", (\$ts >> 0) & 1
printf ">>>   bit1 ADDCMD    = %u\n", (\$ts >> 1) & 1
printf ">>>   bit2 WRLVL     = %u\n", (\$ts >> 2) & 1
printf ">>>   bit3 RDGATE    = %u\n", (\$ts >> 3) & 1
printf ">>>   bit4 DQ_DQS    = %u\n", (\$ts >> 4) & 1
printf ">>> WRCALIB_RESULT  = 0x%08x\n", \$wc
printf ">>> PCODE = %u  NCODE = %u\n", (\$r2 & 0x7f), ((\$r2 >> 7) & 0x7f)
printf ">>> IOC_REG5 = 0x%08x   DDRPHY_STARTUP = 0x%08x\n", \$r5, \$su
if ((\$ts & \$want) == \$want)
  echo >>> VERDICT: every ENABLED training stage COMPLETED (skipped stages excluded).\n
else
  echo >>> VERDICT: TRAINING INCOMPLETE -- an enabled stage did not finish.\n
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
echo ">>> ddr training status:"
grep -aE "training_status|bit[0-4]|WRCALIB|PCODE|IOC_REG5|VERDICT" "$GDBLOG" | tail -20
