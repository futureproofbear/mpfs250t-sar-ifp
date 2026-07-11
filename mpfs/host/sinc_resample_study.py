"""sinc_resample_study.py -- BOARD-FREE analytical study: does a windowed-sinc resample kernel
buy real artifact reduction over the current 2-tap linear lerp, and how many taps are worth it?

Three parts, all in Python (does not touch the board / the running OUT dump):

  A. KERNEL FREQUENCY RESPONSE -- linear(2) vs Lanczos-8(16) vs Lanczos-10(20) vs Kaiser-20.
     For a fractional-delay interpolator the figures of merit are (i) passband droop (how much the
     kernel attenuates real signal inside the occupied band) and (ii) worst spectral-image/alias
     leakage (the paired-echo / ghost energy the kernel fails to reject). Linear's sinc^2 response
     droops badly and rejects images only ~-13 dB; a windowed sinc pushes both far down.

  B. KEYSTONE FRACTIONAL-DELAY DISTRIBUTION (ship scene geometry) -- the wq/32768 fractional shifts
     the real resample actually asks for, PLUS the signal's occupied-bandwidth fraction. If the data
     is heavily oversampled (occupies << Nyquist) linear is already near-exact and sinc buys little;
     the study reports that fraction so the decision is data-driven, not faith-based.

  C. POINT-TARGET IMPULSE RESPONSE -- a single scatterer (pure tone in phase-history) resampled by a
     fractional delay with each kernel, then FFT'd to the image domain; measure PSLR / ISLR / worst
     spurious. Directly quantifies the sidelobe/ghost artifact each kernel produces.

    python sinc_resample_study.py                 # ship scene, deci 8 (matches emulator default)
    python sinc_resample_study.py --deci 4
"""
import sys, argparse
from pathlib import Path
import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parents[1] / "src"))
import form_image_pfa as ref
from sar_pipeline import prepare_tables
from serialize_inputs import interp_coeffs

SHIP = ("data/sar-data/tasks/ship_detection_testdata/6e495891-3cdd-4856-9b6f-b4f512a95f36/"
        "2023-09-06-06-12-08_UMBRA-04/2023-09-06-06-12-08_UMBRA-04_CPHD.cphd")
ROOT = HERE.parents[1]
OUT = ROOT / "output"


# --------------------------------------------------------------------------- kernels
def k_linear(t):
    """2-tap triangular (what the fabric does now)."""
    return np.maximum(0.0, 1.0 - np.abs(t))


def k_lanczos(t, a):
    """Lanczos-a windowed sinc: 2a taps. a=8 -> 16 taps, a=10 -> 20 taps."""
    t = np.asarray(t, float)
    out = np.sinc(t) * np.sinc(t / a)
    return np.where(np.abs(t) < a, out, 0.0)


def k_kaiser(t, half, beta):
    """Kaiser-windowed sinc, 2*half taps (half=10 -> 20 taps)."""
    t = np.asarray(t, float)
    w = np.i0(beta * np.sqrt(np.maximum(0.0, 1.0 - (t / half) ** 2))) / np.i0(beta)
    return np.where(np.abs(t) < half, np.sinc(t) * w, 0.0)


KERNELS = {
    "linear-2":   (k_linear, 1),
    "lanczos8-16": (lambda t: k_lanczos(t, 8), 8),
    "lanczos10-20": (lambda t: k_lanczos(t, 10), 10),
    "kaiser-20":  (lambda t: k_kaiser(t, 10, 12.0), 10),
}


def frac_delay_taps(kern, half, d, ntap_os=1):
    """Sampled interpolation weights for a fractional delay d in [0,1): taps at integer offsets
    n = -half+1..half around the sample, evaluated at (n - d)."""
    n = np.arange(-half + 1, half + 1)
    w = kern(n - d)
    return n, w


# --------------------------------------------------------------------------- A. freq response
def part_A():
    print("\n=== A. KERNEL FREQUENCY RESPONSE (fractional-delay reconstruction) ===")
    print(f"{'kernel':<14}{'taps':>5}{'droop@0.5Nyq dB':>18}{'droop@0.8Nyq dB':>18}"
          f"{'worst image dB':>16}")
    W = 4096
    w = np.linspace(0, np.pi, W)                       # 0..Nyquist (baseband)
    # evaluate over a fine grid of fractional delays; report worst case
    ds = np.linspace(0.0, 0.5, 11)
    rows = {}
    for name, (kern, half) in KERNELS.items():
        droop05 = droop08 = 0.0
        worst_img = -np.inf
        for d in ds:
            n, taps = frac_delay_taps(kern, half, d)
            # DTFT of the tap set: H(w) = sum taps[k] e^{-j w n[k]} ; ideal = e^{-j w d}
            H = (taps[None, :] * np.exp(-1j * np.outer(w, n))).sum(1)
            ideal = np.exp(-1j * w * d)
            mag = np.abs(H)
            # passband droop (dB) at 0.5 and 0.8 of Nyquist
            droop05 = min(droop05, 20 * np.log10(mag[int(0.5 * W)] + 1e-12))
            droop08 = min(droop08, 20 * np.log10(mag[int(0.8 * W)] + 1e-12))
            # spectral image: response into the first alias band [pi, 2pi] folded -> leakage
            wi = np.linspace(np.pi, 2 * np.pi, W)
            Hi = np.abs((taps[None, :] * np.exp(-1j * np.outer(wi, n))).sum(1))
            worst_img = max(worst_img, 20 * np.log10(Hi.max() + 1e-12))
        rows[name] = (half * 2, droop05, droop08, worst_img)
        print(f"{name:<14}{half*2:>5}{droop05:>18.2f}{droop08:>18.2f}{worst_img:>16.1f}")
    print("  (droop = worst attenuation of real in-band signal; image = worst alias/ghost the kernel"
          " lets through. linear's ~-13 dB image band is the paired-echo source.)")
    return rows


# --------------------------------------------------------------------------- B. keystone delays
def part_B(deci):
    print("\n=== B. KEYSTONE FRACTIONAL-DELAY DISTRIBUTION + BANDWIDTH OCCUPANCY (ship) ===")
    cphd = ROOT / SHIP
    if not cphd.exists():
        print(f"  MISSING CPHD: {cphd}  (skipping B)"); return None
    reader = ref.open_phase_history(str(cphd))
    meta = reader.cphd_meta
    tables = prepare_tables(reader, meta, deci, deci)
    m, n = tables["dims"]
    ax, ay, freq = tables["ax"], tables["ay"], tables["freq"]
    KR, KC, tan_phi = np.asarray(tables["KR"]), np.asarray(tables["KC"]), np.asarray(tables["tan_phi"])
    C = getattr(ref, "C", 299792458.0)
    f0 = freq[:, 0].astype(np.float64); df = (freq[:, 1] - freq[:, 0]).astype(np.float64)
    dx, dy = ax.mean(), ay.mean(); dn = np.hypot(dx, dy)
    pr = (ax * (dx / dn) + ay * (dy / dn)).astype(np.float64)
    Np = int(KR.size)
    oob_r = float(KR.max() + (KR.max() - KR.min()) + 1.0)
    KRp = np.full(Np, oob_r); KRp[:n] = KR

    # pass-1 (range) fractional weights across all pulses
    fracs = []
    for i in range(0, m, max(1, m // 400)):            # sample ~400 pulses for the histogram
        kr_i = (2.0 * pr[i] / C) * (f0[i] + np.arange(n) * df[i])
        _, wq = interp_coeffs(KRp, kr_i)
        fracs.append(wq.astype(np.float64) / 32768.0)
    reader.close()
    fr = np.concatenate(fracs)
    fr = fr[(fr > 0) & (fr < 1)]                        # drop the zero-fill / exact-hit entries
    # distance from nearest integer (0 or 1): linear error ~ peaks at 0.5
    dist = np.minimum(fr, 1 - fr)
    print(f"  pulses {m}  range bins {n}  valid frac-delay samples {fr.size}")
    print(f"  frac-delay:  mean|dist-to-int|={dist.mean():.3f}  frac in [0.3,0.7]={100*((fr>0.3)&(fr<0.7)).mean():.1f}%"
          f"  (higher => linear hurts more)")

    # occupied-bandwidth fraction: FFT a few raw range lines, find -20 dB support / Nyquist
    reader = ref.open_phase_history(str(cphd))
    sig = np.asarray(reader.read_chip((0, min(64, tables["n_vec"]), tables["deci"][0]),
                                      (0, tables["n_samp"], tables["deci"][1]), index=0), np.complex64)
    reader.close()
    S = np.abs(np.fft.fftshift(np.fft.fft(sig, axis=1), axes=1)).mean(0)
    S /= S.max() + 1e-12
    occ = (S > 10 ** (-20 / 20)).mean()                # fraction of Nyquist above -20 dB
    print(f"  occupied bandwidth ~{100*occ:.1f}% of Nyquist  "
          f"=> {'OVERSAMPLED: linear near-adequate' if occ < 0.6 else 'well-filled: linear droop/aliasing matters'}")
    return {"dist_mean": float(dist.mean()), "occ": float(occ), "fr": fr}


# --------------------------------------------------------------------------- C. point target
def _resample_1d(x, new_idx, kern, half):
    """Resample complex x at fractional positions new_idx using kernel (half taps each side)."""
    out = np.zeros(new_idx.size, complex)
    base = np.floor(new_idx).astype(int)
    frac = new_idx - base
    for k in range(-half + 1, half + 1):
        j = base + k
        v = (j >= 0) & (j < x.size)
        w = kern(k - frac)
        out[v] += x[j[v]] * w[v]
    return out


def _islr_pslr(psf):
    """PSLR (dB) and ISLR (dB) of a 1-D impulse response magnitude (peak-centered)."""
    mag = np.abs(psf); p = mag.argmax(); pk = mag[p]
    # mainlobe = out to first null either side
    def null(step):
        i = p
        while 0 < i < mag.size - 1 and mag[i + step] < mag[i]:
            i += step
        return i
    lo, hi = null(-1), null(1)
    main = (mag[lo:hi + 1] ** 2).sum()
    side = (mag ** 2).sum() - main
    side_peak = np.concatenate([mag[:lo], mag[hi + 1:]])
    pslr = 20 * np.log10((side_peak.max() + 1e-12) / pk)
    islr = 10 * np.log10((side + 1e-12) / (main + 1e-12))
    return pslr, islr


def part_C():
    print("\n=== C. POINT-TARGET IMPULSE RESPONSE (PSLR / ISLR / worst spur) ===")
    N = 1024
    # a single scatterer = pure tone in phase history; place off-grid so resampling matters
    k0 = 137.3                                         # fractional image-domain bin
    x = np.exp(2j * np.pi * k0 * np.arange(N) / N)
    x *= np.hamming(N)                                 # same taper family as the pipeline window
    # keystone-like resample: a mild frequency-dependent stretch (worst near band edge)
    stretch = 1.0 + 0.35 * (np.arange(N) / N - 0.5)    # +-17.5% fractional resample across the aperture
    new_idx = np.cumsum(stretch); new_idx *= (N - 1) / new_idx[-1]
    print(f"{'kernel':<14}{'PSLR dB':>10}{'ISLR dB':>10}{'worst spur dB':>15}")
    rows = {}
    for name, (kern, half) in KERNELS.items():
        xr = _resample_1d(x, new_idx, kern, half)
        psf = np.fft.fftshift(np.fft.fft(xr))
        pslr, islr = _islr_pslr(psf)
        mag = np.abs(psf); mag /= mag.max()
        # worst spur outside a +-8 bin mainlobe guard
        pk = mag.argmax(); guard = np.ones(mag.size, bool); guard[max(0, pk - 8):pk + 9] = False
        spur = 20 * np.log10(mag[guard].max() + 1e-12)
        rows[name] = (pslr, islr, spur)
        print(f"{name:<14}{pslr:>10.2f}{islr:>10.2f}{spur:>15.1f}")
    print("  (lower = cleaner point response. Delta linear->sinc = the artifact reduction on a bright"
          " scatterer; 'spur' is the ghost/paired-echo floor.)")
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--deci", type=int, default=8)
    a = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    A = part_A()
    B = part_B(a.deci)
    C = part_C()
    print("\n=== VERDICT INPUTS ===")
    if B is not None:
        drive = (B["occ"] >= 0.6) or (B["dist_mean"] > 0.3)
        print(f"  ship occupied-BW {100*B['occ']:.0f}% Nyq, mean frac-dist {B['dist_mean']:.2f} -> "
              f"sinc {'LIKELY WORTH IT' if drive else 'marginal (data oversampled)'}")
    lin = C["linear-2"]; k20 = C["kaiser-20"]
    print(f"  point-target spur: linear {lin[2]:.0f} dB -> kaiser-20 {k20[2]:.0f} dB "
          f"({lin[2]-k20[2]:+.0f} dB artifact change); ISLR {lin[1]:.1f} -> {k20[1]:.1f} dB")


if __name__ == "__main__":
    main()
