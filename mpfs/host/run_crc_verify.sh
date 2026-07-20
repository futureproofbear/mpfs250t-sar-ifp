#!/usr/bin/env bash
# run_crc_verify.sh FILE [BASE_HEX]
# Load FILE to DDR (BASE_HEX, default 0x88000000) over JTAG, then have the
# CRC-mailbox firmware (u54_1.c) CRC32 the region on-target and compare to the
# host zlib.crc32 -- replaces the slow dump+cmp readback with a 4-byte read.
# Needs the CRC-mailbox firmware flashed (boot mode 1) and FlashPro on J33.
set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/sar_env.sh"   # SAR_ROOT / tool paths (see config.yaml)
FILE="${1:?usage: run_crc_verify.sh FILE [BASE_HEX]}"
BASE="${2:-0x88000000}"
NEW="$SAR_OPENOCD"
S="$SAR_SCRATCH"
MBX=0xB0058000

LEN=$(wc -c < "$FILE")
EXP=$(python -c "import zlib,sys;print('0x%08x'%(zlib.crc32(open(sys.argv[1],'rb').read())&0xffffffff))" "$FILE")
# scale firmware-CRC wait to size (~75 MB/s on-target) + margin
SLEEP_MS=$(( 2000 + LEN/20000 ))
LENHEX=$(printf "0x%08x" "$LEN")
CFG="$S/crc_verify_gen.cfg"
LOG="$S/crc_verify.log"
cat > "$CFG" <<CFGEOF
set DEVICE MPFS
source [find board/microchip_riscv_efp6.cfg]
init
targets mpfs.hart1_u54_1
mpfs.hart1_u54_1 arp_halt
mpfs.hart1_u54_1 arp_waitstate halted 5000
echo ">>> LOAD START $FILE ($LEN B) -> $BASE"
load_image "$FILE" $BASE bin
echo ">>> LOAD DONE; CRC mailbox"
mww 0xB0058004 $BASE
mww 0xB0058008 $LENHEX
mww 0xB005800C 0x00000000
mww 0xB0058010 0x00000000
mww 0xB0058000 0x43524333
resume
sleep $SLEEP_MS
mpfs.hart1_u54_1 arp_halt
mpfs.hart1_u54_1 arp_waitstate halted 5000
mem2array st 32 0xB0058010 1
mem2array rc 32 0xB005800C 1
echo [format ">>> CRC_STATUS=0x%08x CRC_RESULT=0x%08x" \$st(0) \$rc(0)]
echo ">>> CRCVERIFY DONE"
shutdown
CFGEOF

cmd /c "taskkill /F /IM openocd.exe" >/dev/null 2>&1
echo "file=$FILE len=$LEN base=$BASE host_zlib_crc=$EXP sleep_ms=$SLEEP_MS"
echo "load start: $(date +%H:%M:%S)"
"$NEW/bin/openocd.exe" -s "$NEW/openocd/scripts" -f "$CFG" -l "$LOG" >/dev/null 2>&1
echo "load end:   $(date +%H:%M:%S)"
GOT=$(grep -oiE "CRC_RESULT=0x[0-9a-f]{8}" "$LOG" | grep -oiE "0x[0-9a-f]{8}")
STAT=$(grep -oiE "CRC_STATUS=0x[0-9a-f]{8}" "$LOG" | grep -oiE "0x[0-9a-f]{8}")
echo "status=$STAT  on_target_crc=$GOT  host_crc=$EXP"
if [ "${GOT,,}" = "${EXP,,}" ] && [ "${STAT,,}" = "0xc0ffee03" ]; then
  echo "CRC VERIFY PASS"
else
  echo "CRC VERIFY FAIL"; grep -iE "Error|Unable|fail|invalid|LOAD|CRC" "$LOG" | tail -10
fi
