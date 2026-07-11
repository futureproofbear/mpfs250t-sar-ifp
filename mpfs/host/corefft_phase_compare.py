"""PHASE-sensitive check of the silicon CoreFFT vs the bit-accurate golden.

The magnitude iso-test (corr=1.0) cannot see a phase error -- conjugation, a wrong sign, a bin
permutation all leave |FFT| unchanged. This compares the COMPLEX CoreFFT output (dumped by
corefft_stream64_lossck_tb with OUT_HEX set) against fixedpoint.fft1d_bfp of the same input, using
complex correlation. A phase-wrong FFT (the suspected pipeline bug) shows here as low complex corr
even though magnitude corr ~ 1.

Run from mpfs/host:  python corefft_phase_compare.py [N]
"""
import sys, numpy as np
sys.path.insert(0, "../../src")
import fixedpoint as fx

N = int(sys.argv[1]) if len(sys.argv) > 1 else 256
SIMDIR = "../fpga/sim/"


def read_hex_iq(path, count):
    w = []
    with open(path) as f:
        for ln in f:
            ln = ln.strip()
            if ln:
                w.append(int(ln, 16) & 0xFFFFFFFF)
            if len(w) >= count:
                break
    w = np.array(w, dtype=np.uint32)
    re = (w >> 16).astype(np.int16).astype(np.float64)
    im = (w & 0xFFFF).astype(np.int16).astype(np.float64)
    return re + 1j * im


inp = read_hex_iq(SIMDIR + "fft_vectors_n8192/phase_in.hex", N)           # the input CoreFFT saw
core = read_hex_iq(SIMDIR + f"phase_out_{N}.hex", N)                      # CoreFFT complex output

# ideal float golden (exact forward FFT) -- the phase reference
gold = np.fft.fft(inp)
bitrev = fx._bitrev_perm(N)


def ccorr(a, b):
    """complex correlation magnitude: |<a,b>|/(||a|| ||b||). 1 = same up to a global complex scale."""
    a = a - a.mean(); b = b - b.mean()
    d = np.linalg.norm(a) * np.linalg.norm(b)
    return abs(np.vdot(a, b) / d) if d else 0.0


def mcorr(a, b):
    a = np.abs(a); b = np.abs(b); a = a - a.mean(); b = b - b.mean()
    d = np.linalg.norm(a) * np.linalg.norm(b)
    return float(a @ b / d) if d else 0.0


# --- DECISIVE metric: complex ratio core/gold on strong bins ---
# If CoreFFT is a correct FFT (any sign convention aside), core = gold * K for a single complex
# constant K = 2^-exp * e^{j*theta}. Then |ratio| is constant across bins and angle(ratio) is a
# single constant. A phase BUG (conjugation, per-bin phase error, ordering) breaks that constancy.
def ratio_report(name, ref):
    mask = np.abs(ref) > 0.10 * np.abs(ref).max()
    r = core[mask] / ref[mask]
    magm, phm = np.median(np.abs(r)), np.median(np.angle(r))
    phspread = np.degrees(np.std(np.angle(r * np.exp(-1j * phm))))   # spread about the median phase
    magspread = np.std(np.abs(r)) / magm if magm else 9
    print(f"  vs {name:16}: |ratio| med={magm:7.4f} (spread {magspread*100:4.1f}%)  "
          f"phase med={np.degrees(phm):+6.1f} deg (spread {phspread:4.1f} deg)  [{int(mask.sum())} bins]")
    return phspread

print(f"N={N}   reference = exact float FFT of the same input")
print(f"  MAGNITUDE corr (flat-spectrum, noise-dominated -- unreliable here): {mcorr(gold, core):.3f}")
print("  ratio test (constant |ratio| + tight phase spread => CORRECT complex FFT):")
sp_nat = ratio_report("fft (natural)", gold)
ratio_report("conj(fft)", np.conj(gold))
ratio_report("fft[bitrev]", gold[bitrev])
igold = np.fft.ifft(inp) * N
ratio_report("ifft-conv(+j)", igold)
print(f"\nVERDICT: {'CoreFFT is PHASE-CORRECT' if sp_nat < 15 else 'CoreFFT phase is WRONG'} "
      f"(natural-FFT phase spread {sp_nat:.1f} deg; <15 deg = correct, tight).")
