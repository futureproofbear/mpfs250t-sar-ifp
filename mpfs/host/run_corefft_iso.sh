#!/usr/bin/env bash
# run_corefft_iso.sh -- end-to-end SILICON iso-test of the fabric CoreFFT range-FFT.
# Loads N known 8192-pt rows into DDR SIG, drives fft_feeder->CoreFFT->fft_unloader over
# JTAG (corefft_iso.gdb), reads back SCRATCH, and correlates each row vs the bit-accurate
# BFP golden (SCALE-INVARIANT corr/nrmse -- CoreFFT's block exponent differs by a power of
# 2, absorbed by the metric, exactly as proven in QuestaSim).
#
# PREREQ: program SAR_TOP_corefft.job (bitstreams/) + boot mode 0 (WFI) so hart1 halts.
# The firmware ELF is used only for init + the flush_l2_cache symbol; it must be the
# CoreFFT-build firmware (feeder@0x60004000 / unloader@0x60005000 -- sar_kernels.h).
set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/sar_env.sh"   # SAR_ROOT / tool paths (see config.yaml)
PY="$SAR_PYTHON"
# Windows-format ROOT: python + the Windows-native gdb (restore/dump/ELF) need C:/ paths,
# NOT MSYS /c/ (which they resolve inconsistently -> "No such file"). git-bash handles C:/ too.
ROOT="$SAR_ROOT"
HOST="$ROOT/mpfs/host"
GDBDIR="$HOST/jtag_full"
VEC="$HOST/corefft_vectors"
CASES="${CASES:-impulse impulse_k dc tone twotone twotone_hidr dc_smalltone random}"
NEW="$SAR_OPENOCD"
SC="$SAR_SOFTCONSOLE"
GDB="$SC/riscv-unknown-elf-gcc/bin/riscv64-unknown-elf-gdb.exe"
ELF="$ROOT/mpfs/fpga/libero_sar/softconsole/mpfs-hal-ddr-demo/Icicle-Kit-DDR-666MHz-eNVM-Scratchpad-Release/mpfs-hal-ddr-demo.elf"
LOG="$SAR_SCRATCH/corefft_iso.log"

# 1) bit-accurate BFP golden + input vectors (8192-pt)
"$PY" "$HOST/fft_golden.py" gen --n 8192 --out "$VEC" >/dev/null

# 2) concatenate the N input rows into one DDR image (word = (re<<16)|im, little-endian)
"$PY" - "$VEC" "$CASES" <<'PYEOF'
import sys, struct, pathlib
vec = pathlib.Path(sys.argv[1]); cases = sys.argv[2].split()
buf = bytearray()
for c in cases:
    for ln in (vec / f"{c}_in.hex").read_text().split():
        if ln.strip():
            buf += struct.pack('<I', int(ln, 16) & 0xFFFFFFFF)
(vec / "corefft_iso_in.bin").write_bytes(buf)
print(f"  input image: {len(cases)} rows, {len(buf)} bytes")
PYEOF

NROWS=$(echo $CASES | wc -w)
# NBEATS_OVERRIDE lets a diagnostic run fire a tiny single-burst read (e.g. 64 beats) to
# isolate a first-AR FIC0/DDR wedge (addr/ID routing) from a mid-stream count/4KB-boundary bug.
BEATS=${NBEATS_OVERRIDE:-$((NROWS * 4096))}   # 8192 samples/row / 2 samples per 64-bit beat
BYTES=$((NROWS * 32768))           # 8192 samples/row * 4 bytes/sample
DUMPHEX=$(printf '0x%x' $BYTES)

# 3) fill the gdb template
sed -e "s/@NBEATS@/$BEATS/g" -e "s/@DUMPHEX@/$DUMPHEX/g" \
    -e "s|@INBIN@|$VEC/corefft_iso_in.bin|g" -e "s|@OUTBIN@|$VEC/corefft_iso_out.bin|g" \
    "$GDBDIR/corefft_iso.gdb.tmpl" > "$GDBDIR/corefft_iso.gdb"

# 4) openocd + gdb (mirror run_fft_iso.sh; clean shutdown, no force-kill)
cd "$GDBDIR"
if tasklist 2>/dev/null | grep -qi openocd.exe; then
  echo ">>> WARNING: openocd.exe already running (stale). Close it cleanly; NOT force-killing." >&2; exit 1
fi
: > "$LOG"
"$NEW/bin/openocd.exe" -s "$NEW/openocd/scripts" --command "set DEVICE MPFS" \
    -f board/microchip_riscv_efp6.cfg -l "$LOG" >/dev/null 2>&1 &
sleep 14
# -batch + </dev/null: gdb exits after the script even if a command errors (e.g. DDR not
# yet initialized) -- prevents a script error from parking gdb at its prompt indefinitely.
"$GDB" -batch "$ELF" -x corefft_iso.gdb </dev/null 2>&1 | tr -d '\r' \
    | grep -avE '^Reading|warranty|GPL|free soft|GNU gdb|Copyright|documentation|bug report|configured as|^Type |sifive|For help|apropos'
# openocd may still be up if the script errored before 'monitor shutdown' -- clean it via telnet.
python - <<'PYEOF' 2>/dev/null || true
import socket,time
try:
    s=socket.create_connection(('127.0.0.1',4444),timeout=3); time.sleep(0.3); s.recv(4096)
    s.sendall(b'shutdown\n'); time.sleep(0.5); s.close()
except Exception: pass
PYEOF
echo ">>> gdb done (openocd shut down via monitor shutdown)"

# 5) split the readback into rows + correlate each vs the golden (scale-invariant)
if [ ! -f "$VEC/corefft_iso_out.bin" ]; then echo ">>> NO OUTPUT DUMP -- check openocd/boot-mode."; exit 1; fi
"$PY" - "$VEC" "$CASES" "$HOST/fft_golden.py" <<'PYEOF'
import sys, struct, pathlib, subprocess
vec = pathlib.Path(sys.argv[1]); cases = sys.argv[2].split(); golden = sys.argv[3]
raw = (vec / "corefft_iso_out.bin").read_bytes()
N = 8192
print(f"\n{'case':14} | silicon CoreFFT vs BFP golden")
allpass = True
for i, c in enumerate(cases):
    if (i + 1) * N * 4 > len(raw):
        print(f"{c:14} | (dump truncated: have {len(raw)} bytes, need {(i+1)*N*4}) -- SKIP")
        allpass = False
        continue
    words = struct.unpack_from(f'<{N}I', raw, i * N * 4)
    (vec / f"{c}_rtl.hex").write_text("\n".join(f"{w:08x}" for w in words) + "\n")
    r = subprocess.run([sys.executable, golden,
                        "check", "--expected", str(vec / f"{c}_out.hex"),
                        "--actual", str(vec / f"{c}_rtl.hex"),
                        "--corr-min", "0.999", "--nrmse-max", "0.02"],
                       capture_output=True, text=True)
    ok = r.returncode == 0
    allpass = allpass and ok
    line = (r.stdout.strip().splitlines() or [""])[-1]
    print(f"{c:14} | {line}")
print("\n" + (">>> ALL ROWS PASS" if allpass else ">>> SOME ROWS FAILED"))
PYEOF
