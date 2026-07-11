"""Milestone 1 verification: bit-exact FFT golden + test-vector generator.

The FPGA FFT (CoreFFT BFP, or the hand-written fpga/fft1d.cpp) is verified
against the bit-accurate NumPy block-floating-point FFT in src/fixedpoint.py --
the SAME emulator that sized the datapath. This tool turns that emulator into
co-simulation vectors:

  gen   : for several stimulus cases, write input codes, expected output codes,
          the per-stage BFP exponent schedule, and an optional twiddle ROM, in
          $readmemh hex + decimal CSV + a JSON manifest.
  check : compare an RTL/HLS output file against the expected codes; report the
          worst per-component error in LSBs and the complex correlation, and
          pass/fail at a tolerance (0 LSB = bit-exact for fft1d.cpp; a small
          tolerance + high correlation for CoreFFT, whose internal scheduling
          need not be bit-identical).

Reference contract (what the RTL must reproduce), from fixedpoint.fft1d_bfp:
  * radix-2 DIT, bit-reversed input order, natural-order output
  * twiddles truncated to nbits_tw fractional bits (floor, two's complement)
  * block-floating-point: after every stage, rescale the whole line to the
    smallest power-of-2 LSB that fits nbits (floor) -> one shared exponent/stage
  * input value  = in_code  * 2^e_in   (e_in  = exps[0])
    output value = out_code * 2^e_out   (e_out = exps[-1])
    BFP_SHIFT reported to the host = e_out - e_in

Hex word format: one 32-bit word per complex sample, (uint16(I) << 16) | uint16(Q),
each component a two's-complement 16-bit code. $readmemh loads it into reg[31:0].

Usage:
    python fft_golden.py gen   [--n 8192] [--bits 16] [--tw-bits 18] [--twiddle]
                               [--out fft_vectors]
    python fft_golden.py check --expected fft_vectors/random_out.hex \
                               --actual rtl_out.hex [--tol 0]
"""
import sys
import json
import argparse
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "src"))
import fixedpoint as fx                  # noqa: E402


# --------------------------------------------------------------------------- #
def _to_codes(arr, lsb):
    """Floor-quantize complex arr to signed int16 codes at step lsb (saturating)."""
    full = 2 ** 15 - 1
    re = np.clip(np.floor(arr.real / lsb), -full - 1, full).astype(np.int64)
    im = np.clip(np.floor(arr.imag / lsb), -full - 1, full).astype(np.int64)
    return re, im


def _round_codes(arr, lsb):
    """Recover exact integer codes from a value that is already an lsb multiple."""
    re = np.rint(arr.real / lsb).astype(np.int64)
    im = np.rint(arr.imag / lsb).astype(np.int64)
    return re, im


def _write_hex(path, re, im):
    """32-bit (I<<16)|Q two's-complement hex, one complex sample per line."""
    u = ((re.astype(np.uint32) & 0xFFFF) << 16) | (im.astype(np.uint32) & 0xFFFF)
    Path(path).write_text("\n".join(f"{w:08x}" for w in u) + "\n")


def _write_csv(path, re, im):
    Path(path).write_text("# re,im (signed integer codes)\n" +
                          "\n".join(f"{int(a)},{int(b)}" for a, b in zip(re, im)) + "\n")


def _read_hex_or_csv(path):
    """Read a vector written by _write_hex (.hex) or _write_csv (.csv/other)."""
    text = Path(path).read_text().strip().splitlines()
    if str(path).endswith(".hex"):
        re, im = [], []
        for ln in text:
            ln = ln.strip()
            if not ln or ln.startswith("//") or ln.startswith("#"):
                continue
            w = int(ln, 16) & 0xFFFFFFFF
            i = (w >> 16) & 0xFFFF
            q = w & 0xFFFF
            re.append(i - 0x10000 if i >= 0x8000 else i)     # sign-extend 16-bit
            im.append(q - 0x10000 if q >= 0x8000 else q)
        return np.array(re), np.array(im)
    re, im = [], []
    for ln in text:
        ln = ln.strip()
        if not ln or ln.startswith("#"):
            continue
        a, b = ln.split(",")
        re.append(int(a)); im.append(int(b))
    return np.array(re), np.array(im)


# --------------------------------------------------------------------------- #
def _cases(n):
    """A spread of stimuli that exercise spectral correctness and dynamic range."""
    k = np.arange(n)
    rng = np.random.default_rng(1234)
    scale = 2000.0
    kimp = 37 % n                                                          # non-trivial impulse pos
    return {
        "impulse": (np.where(k == 0, scale, 0)).astype(np.complex128),     # flat spectrum
        "dc":      np.full(n, scale, dtype=np.complex128),                 # bin-0 spike
        "tone":    scale * np.exp(2j * np.pi * (n // 8) * k / n),          # single bin
        "twotone": scale * (np.exp(2j * np.pi * 5 * k / n)
                            + 0.5 * np.exp(2j * np.pi * (n // 3) * k / n)),
        "random":  (scale * (rng.standard_normal(n) + 1j * rng.standard_normal(n))
                    / np.sqrt(2)).astype(np.complex128),
        # ---- failure-targeting additions ----
        # impulse at n=k -> rotating phasor exp(-j2pi k kimp/N): tests twiddle PHASE
        # (a butterfly that drops the twiddle term gives flat magnitude but wrong phase).
        "impulse_k": (np.where(k == kimp, scale, 0)).astype(np.complex128),
        # 60 dB two-tone: the BFP scale is set by the STRONG bin; a datapath that floors
        # small values (the old per-stage >>1 bug) loses the weak bin -> corr vs the
        # BFP golden (which keeps it) drops. Weak-bin survival also visible in *_out.csv.
        "twotone_hidr": scale * (np.exp(2j * np.pi * 11 * k / n)
                                 + 1e-3 * np.exp(2j * np.pi * (n // 3) * k / n)),
        # strong DC clutter + weak AC target (SAR-realistic dynamic range): same flooring
        # guard as twotone_hidr but with the strong component at bin 0.
        "dc_smalltone": (scale * np.ones(n)
                         + 1e-3 * scale * np.exp(2j * np.pi * (n // 5) * k / n)
                         ).astype(np.complex128),
    }


def gen(n, nbits, nbits_tw, out_dir, twiddle=False):
    out_dir = Path(out_dir); out_dir.mkdir(parents=True, exist_ok=True)
    perm = fx._bitrev_perm(n)
    manifest = {"n": n, "nbits": nbits, "nbits_tw": nbits_tw,
                "hex_format": "(uint16(I)<<16)|uint16(Q), two's complement",
                "reference": "fixedpoint.fft1d_bfp (radix-2 DIT, BFP, truncated twiddles)",
                "cases": {}}

    for name, x in _cases(n).items():
        lsb_in, e_in = fx.fit_scale(x, nbits)
        in_re, in_im = _to_codes(x, lsb_in)
        y, exps = fx.fft1d_bfp(x, nbits, nbits_tw, perm)
        lsb_out = 2.0 ** exps[-1]
        out_re, out_im = _round_codes(y, lsb_out)

        _write_hex(out_dir / f"{name}_in.hex", in_re, in_im)
        _write_hex(out_dir / f"{name}_out.hex", out_re, out_im)
        _write_csv(out_dir / f"{name}_in.csv", in_re, in_im)
        _write_csv(out_dir / f"{name}_out.csv", out_re, out_im)

        manifest["cases"][name] = {
            "e_in": int(e_in), "e_out": int(exps[-1]),
            "bfp_shift": int(exps[-1] - e_in),
            "stage_exps": [int(e) for e in exps],
            "out_peak_code": int(max(abs(out_re).max(), abs(out_im).max())),
            "files": {"in": f"{name}_in.hex", "out": f"{name}_out.hex"},
        }
        print(f"  {name:8s} e_in={e_in:+d} e_out={exps[-1]:+d} "
              f"bfp_shift={exps[-1]-e_in:+d} peak_code={manifest['cases'][name]['out_peak_code']}")

    if twiddle:
        # full-resolution ROM w[k]=exp(-2pi i k/n), k=0..n/2-1, truncated to nbits_tw.
        # stage s (m=1<<s) uses every (n/m)-th entry. Scale = 2^(nbits_tw-1).
        kk = np.arange(n // 2)
        w = np.exp(-2j * np.pi * kk / n)
        lsb_tw = 2.0 ** -(nbits_tw - 1)
        tw_re = np.clip(np.floor(w.real / lsb_tw), -(2 ** (nbits_tw - 1)), 2 ** (nbits_tw - 1) - 1).astype(np.int64)
        tw_im = np.clip(np.floor(w.imag / lsb_tw), -(2 ** (nbits_tw - 1)), 2 ** (nbits_tw - 1) - 1).astype(np.int64)
        _write_csv(out_dir / "twiddle.csv", tw_re, tw_im)
        manifest["twiddle"] = {"entries": n // 2, "bits": nbits_tw,
                               "scale": f"2^{nbits_tw-1}", "stage_stride": "n/(1<<s)",
                               "file": "twiddle.csv"}
        print(f"  twiddle  {n//2} entries @ {nbits_tw}-bit (scale 2^{nbits_tw-1})")

    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2))
    print(f"  wrote {out_dir}/  (N={n}, {nbits}-bit data / {nbits_tw}-bit twiddle)")
    return manifest


# --------------------------------------------------------------------------- #
def check(expected, actual, tol=0, corr_min=None, nrmse_max=None):
    """Compare an RTL/HLS output against the golden.

    Two verdict modes:
      * bit-exact (default): PASS iff worst per-component error <= `tol` LSB.
        Use for a hand-written kernel that mirrors fixedpoint exactly.
      * tolerance (when --corr-min/--nrmse-max given): PASS iff correlation and
        scale-aligned NRMSE meet the thresholds. Use for CoreFFT, whose internal
        block-floating-point scheduling differs, so its output may differ from
        the golden by an overall power-of-2 and a few LSBs. Both metrics are
        scale-invariant, so a different CoreFFT block exponent is not a failure.
    """
    er, ei = _read_hex_or_csv(expected)
    ar, ai = _read_hex_or_csv(actual)
    if er.shape != ar.shape:
        print(f"  FAIL size: expected {er.shape} actual {ar.shape}")
        return False
    dre = np.abs(ar - er); dim = np.abs(ai - ei)
    max_lsb = int(max(dre.max(), dim.max()))
    e = er + 1j * ei; a = ar + 1j * ai
    denom = (np.linalg.norm(e) * np.linalg.norm(a)) or 1.0
    corr = float(np.abs(np.vdot(e, a)) / denom)
    # least-squares complex scalar aligning `a` to `e` (absorbs an overall
    # gain / block-exponent difference), then residual NRMSE.
    aa = np.vdot(a, a)
    alpha = (np.vdot(a, e) / aa) if aa != 0 else 0.0
    nrmse = float(np.linalg.norm(e - alpha * a) / (np.linalg.norm(e) or 1.0))

    if corr_min is not None or nrmse_max is not None:
        cm = corr_min if corr_min is not None else 0.9999
        nm = nrmse_max if nrmse_max is not None else 1e-2
        ok = (corr >= cm) and (nrmse <= nm)
        verdict = f"corr>={cm} & nrmse<={nm}"
    else:
        n_bad = int(np.count_nonzero((dre > tol) | (dim > tol)))
        ok = max_lsb <= tol
        verdict = f"bit-exact tol={tol} (samples>tol={n_bad})"
    print(f"  N={er.size}  max|err|={max_lsb} LSB  corr={corr:.6f}  "
          f"nrmse={nrmse:.2e}  |scale|={abs(alpha):.4g}  [{verdict}]  -> "
          f"{'PASS' if ok else 'FAIL'}")
    return ok


# --------------------------------------------------------------------------- #
def main():
    ap = argparse.ArgumentParser(description="FFT bit-exact golden / co-sim vectors")
    sub = ap.add_subparsers(dest="cmd", required=True)

    g = sub.add_parser("gen")
    g.add_argument("--n", type=int, default=8192, help="FFT length (power of 2)")
    g.add_argument("--bits", type=int, default=16, help="data mantissa bits")
    g.add_argument("--tw-bits", type=int, default=18, help="twiddle bits")
    g.add_argument("--twiddle", action="store_true", help="also emit a twiddle ROM")
    g.add_argument("--out", default="fft_vectors")

    c = sub.add_parser("check")
    c.add_argument("--expected", required=True)
    c.add_argument("--actual", required=True)
    c.add_argument("--tol", type=int, default=0, help="bit-exact: max per-component LSB error")
    c.add_argument("--corr-min", type=float, default=None,
                   help="tolerance mode (CoreFFT): min correlation, e.g. 0.9999")
    c.add_argument("--nrmse-max", type=float, default=None,
                   help="tolerance mode (CoreFFT): max scale-aligned NRMSE, e.g. 0.01")

    a = ap.parse_args()
    if a.cmd == "gen":
        assert (a.n & (a.n - 1)) == 0, "N must be a power of 2"
        gen(a.n, a.bits, a.tw_bits, a.out, twiddle=a.twiddle)
    elif a.cmd == "check":
        ok = check(a.expected, a.actual, a.tol, a.corr_min, a.nrmse_max)
        sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
