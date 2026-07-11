#!/usr/bin/env python3
# gen_and_check.py -- generate tb_in.hex / check tb_out.hex for the SmartHLS
# fixed-point 8192-point FFT kernel (fft_kernel.cpp).
#
# Data format (must match kernel exactly):
#   64-bit beat = TWO complex int16 samples.
#     beat[31:0]  = sample0, beat[63:32] = sample1
#   32-bit sample = { int16 re [31:16], int16 im [15:0] }
#   1 FFT row = 8192 complex samples = 4096 beats, natural time order in,
#   natural frequency order out (library bit-reverses internally).
#
# Usage:
#   python gen_and_check.py gen   <case>   # writes tb_in.hex in CWD
#   python gen_and_check.py check <case>   # reads tb_out.hex in CWD, compares
#
# tb_in.hex / tb_out.hex live in the CWD where `shls sw` runs the binary.
import sys
import numpy as np

N = 8192          # FFT points
BEATS = N // 2    # 4096 beats/row
IN_FILE = "tb_in.hex"
OUT_FILE = "tb_out.hex"


def clip16(x):
    return int(np.clip(x, -32768, 32767))


def to_int16(x):
    """round-to-nearest then clip to int16 (matches numpy golden quantization)."""
    return clip16(int(np.rint(x)))


def pack_sample(re, im):
    """32-bit sample = (uint16(re)<<16) | uint16(im)."""
    return ((re & 0xFFFF) << 16) | (im & 0xFFFF)


def pack_beats(x):
    """x: complex array len N -> list of 4096 uint64 beats."""
    re = np.rint(x.real).astype(np.int64)
    im = np.rint(x.imag).astype(np.int64)
    re = np.clip(re, -32768, 32767)
    im = np.clip(im, -32768, 32767)
    beats = []
    for b in range(BEATS):
        s0 = pack_sample(int(re[2 * b]),     int(im[2 * b]))
        s1 = pack_sample(int(re[2 * b + 1]), int(im[2 * b + 1]))
        beats.append(((s1 & 0xFFFFFFFF) << 32) | (s0 & 0xFFFFFFFF))
    return beats


def unpack_beats(beats):
    """beats: list of 4096 uint64 -> complex array len N."""
    x = np.zeros(N, dtype=np.complex128)
    for b, beat in enumerate(beats):
        s0 = beat & 0xFFFFFFFF
        s1 = (beat >> 32) & 0xFFFFFFFF
        for j, s in ((0, s0), (1, s1)):
            re = (s >> 16) & 0xFFFF
            im = s & 0xFFFF
            re = re - 0x10000 if re >= 0x8000 else re     # sign-extend int16
            im = im - 0x10000 if im >= 0x8000 else im
            x[2 * b + j] = complex(re, im)
    return x


def make_case(case):
    n = np.arange(N)
    if case == "tone":
        x = 20000.0 * np.exp(2j * np.pi * 137 * n / N)
    elif case == "twotone":
        x = (20000.0 * np.exp(2j * np.pi * 137 * n / N)
             + 8000.0 * np.exp(2j * np.pi * 3001 * n / N))
    elif case == "pointtarget":
        x = 15000.0 * np.exp(1j * np.pi * (n - 4096) ** 2 / N)
    elif case == "random":
        rng = np.random.RandomState(1234)
        re = rng.randint(-10000, 10001, size=N)
        im = rng.randint(-10000, 10001, size=N)
        x = re + 1j * im
    else:
        raise ValueError("unknown case: " + case)
    # quantize input to the int16 grid the kernel actually sees
    re = np.clip(np.rint(x.real), -32768, 32767)
    im = np.clip(np.rint(x.imag), -32768, 32767)
    return re + 1j * im


def golden(x):
    """numpy golden = fft(x)/8192, each component rounded-to-nearest & clipped int16."""
    g = np.fft.fft(x) / float(N)
    gr = np.clip(np.rint(g.real), -32768, 32767)
    gi = np.clip(np.rint(g.imag), -32768, 32767)
    return gr + 1j * gi


def gen(case):
    x = make_case(case)
    beats = pack_beats(x)
    with open(IN_FILE, "w") as f:
        for beat in beats:
            f.write("%016x\n" % (beat & 0xFFFFFFFFFFFFFFFF))
    print("gen %s: wrote %d beats to %s" % (case, len(beats), IN_FILE))


def check(case):
    with open(OUT_FILE) as f:
        beats = [int(line.strip(), 16) for line in f if line.strip()]
    if len(beats) != BEATS:
        print("WARNING: tb_out.hex has %d beats, expected %d" % (len(beats), BEATS))
    kern = unpack_beats(beats)

    x = make_case(case)
    gold = golden(x)

    # (a) complex correlation coefficient
    num = np.abs(np.vdot(gold, kern))
    den = np.linalg.norm(kern) * np.linalg.norm(gold)
    corr = num / den if den > 0 else 0.0

    # (b) peak-magnitude bin
    kpeak = int(np.argmax(np.abs(kern)))
    gpeak = int(np.argmax(np.abs(gold)))

    # (c) RMS + max abs error in LSBs (over re and im components jointly)
    err = kern - gold
    err_flat = np.concatenate([err.real, err.imag])
    rms = float(np.sqrt(np.mean(err_flat ** 2)))
    maxabs = float(np.max(np.abs(err_flat)))

    print("=" * 60)
    print("CASE: %s" % case)
    print("=" * 60)
    print("correlation coeff : %.9f" % corr)
    print("peak bin kernel   : %d" % kpeak)
    print("peak bin golden   : %d" % gpeak)
    print("peak bin match    : %s" % ("YES" if kpeak == gpeak else "NO"))
    print("RMS error   (LSB) : %.6f" % rms)
    print("max abs err (LSB) : %.1f" % maxabs)
    print("first 6 samples   kernel(re,im)        golden(re,im)")
    for i in range(6):
        print("  [%d]  (%8d,%8d)   (%8d,%8d)" % (
            i, int(kern[i].real), int(kern[i].imag),
            int(gold[i].real), int(gold[i].imag)))
    print()


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in ("gen", "check"):
        print("usage: gen_and_check.py {gen|check} <case>")
        sys.exit(2)
    mode, case = sys.argv[1], sys.argv[2]
    if mode == "gen":
        gen(case)
    else:
        check(case)
