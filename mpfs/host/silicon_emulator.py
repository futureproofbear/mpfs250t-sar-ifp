"""silicon_emulator.py -- BIT-ACCURATE mirror of the on-silicon SAR datapath, end to end in fixed
point, so it predicts exactly what the board's sar_form_image (+ CoreFFT + HLS kernels) produces.

Datapath mirrored (matches src/sar/sar_sequencer.c + the HLS kernels + CoreFFT in-place BFP):
  1. int16 quantize of the CPHD signal (what gets loaded to BUF_SIG)
  2. 2-pass keystone RESAMPLE in FIXED POINT (int16 gather + int16 lerp weight, >>15 truncate) --
     the board golden used FLOAT here; this uses the same fixed-point lerp the fabric does
  3. 2-D Hamming WINDOW in fixed point (int16 hamr[j]*hamc[k], two >>15)
  4. adaptive BFP range FFT (CoreFFT model fft1d_bfp_hw_perrow) + per-row SCALE_EXP + firmware GLOBAL
     renormalize >>(emax-exp_i)  (== fft_fabric_pass)
  5. corner-turn (transpose)
  6. adaptive BFP azimuth FFT + renorm
  7. fixed DETECT: sqrt(I^2+Q^2), SIGNED extraction (the FIXED detect.cpp), uint16 saturate

Forms focused images for BOTH the Centerfield and ship CPHD scenes.

  python silicon_emulator.py                       # both scenes, board config (deci 8, grid 8192)
  python silicon_emulator.py --scene ship --deci 8 --grid 8192
"""
import sys, argparse
from pathlib import Path
import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parents[1] / "src"))
import form_image_pfa as ref
import fixedpoint as fx
from sar_pipeline import prepare_tables
from serialize_inputs import interp_coeffs        # the verified MSS idx/wq quantizer
import math

_C = getattr(ref, "C", 299792458.0)

# ---- CPHD scenes cached under data/ (see config.yaml) ----
SCENES = {
    "centerfield": "data/sar-data/tasks/Centerfield, Utah/c0dbd830-e863-42c5-97d0-2cfd291bcb2a/"
                   "2023-10-10-16-57-44_UMBRA-04/2023-10-10-16-57-44_UMBRA-04_CPHD.cphd",
    "ship":        "data/sar-data/tasks/ship_detection_testdata/6e495891-3cdd-4856-9b6f-b4f512a95f36/"
                   "2023-09-06-06-12-08_UMBRA-04/2023-09-06-06-12-08_UMBRA-04_CPHD.cphd",
}
ROOT = HERE.parents[1]


def _sat16(x):
    return np.clip(np.floor(x + 0.0), -32768, 32767)


def _shr_floor(x, s):
    """arithmetic >> s on a real array (floor), s scalar or per-row broadcast."""
    return np.floor(x / (2.0 ** s))


def apply_fixed(fp, idx, wq):
    """FIXED-POINT fabric lerp: out = fp[j] + ((fp[j+1]-fp[j]) * wq) >> 15, truncate to int16.
    fp is int16-valued complex; wq the int16 (0..32767) interp weight; idx<0 -> 0 (out of grid)."""
    out = np.zeros(idx.shape, np.complex128)
    v = idx >= 0
    j = np.clip(idx, 0, fp.size - 2)
    a, b = fp[j], fp[j + 1]
    lr = a.real + _shr_floor((b.real - a.real) * wq, 15)
    li = a.imag + _shr_floor((b.imag - a.imag) * wq, 15)
    lr = _sat16(lr); li = _sat16(li)
    out[v] = (lr + 1j * li)[v]
    return out


def resample_fixed(signal_i16, tables, grid):
    """sar_sequencer.c::resample_2pass in FIXED POINT. signal_i16 = int16-valued complex."""
    m, n = signal_i16.shape
    Mp = Np = grid
    ax, ay, freq = tables["ax"], tables["ay"], tables["freq"]
    KR, KC, tan_phi = np.asarray(tables["KR"]), np.asarray(tables["KC"]), np.asarray(tables["tan_phi"])
    f0 = freq[:, 0].astype(np.float32)
    df = (freq[:, 1] - freq[:, 0]).astype(np.float32)
    dx, dy = ax.mean(), ay.mean(); dn = math.hypot(dx, dy)
    pr = (ax * (dx / dn) + ay * (dy / dn)).astype(np.float32)
    order = np.argsort(tan_phi); tan_s = tan_phi[order].astype(np.float32)
    inv_order = np.argsort(order)
    oob_r = float(KR.max() + (KR.max() - KR.min()) + 1.0)
    oob_c = float(KC.max() + (KC.max() - KC.min()) + 1.0)
    KRp = np.full(Np, oob_r, np.float32); KRp[:n] = KR
    KCp = np.full(Mp, oob_c, np.float32); KCp[:m] = KC

    scratch = np.zeros((Mp, Np), np.complex128)          # PASS 1 (range) -> pulse-sorted rows
    for i in range(m):
        kr_i = (2.0 * pr[i] / _C) * (f0[i] + np.arange(n) * df[i])
        idx, wq = interp_coeffs(KRp, kr_i)
        scratch[inv_order[i]] = apply_fixed(signal_i16[i], idx, wq)
    sig_t = scratch.T.copy()
    g2 = np.zeros((Np, Mp), np.complex128)               # PASS 2 (azimuth)
    for j in range(Np):
        src = KRp[j] * tan_s
        idx, wq = interp_coeffs(KCp, src)
        g2[j] = apply_fixed(sig_t[j, :m], idx, wq)
    return g2, (m, n)


def _trunc16(x):
    """C's (int16_t) cast: wrap to 16 bits, not saturate."""
    x = np.asarray(x).astype(np.int64) & 0xFFFF
    return np.where(x >= 0x8000, x - 0x10000, x)


def window_fixed(g2, m, n):
    """2-D Hamming in fixed point. Tapers span the data extent (n range, m cross), zero in the
    pad.

    TRUNCATION ORDER MATTERS and this used to be WRONG (fixed 2026-07-21). The board folds the
    two tapers into a single Q15 coefficient FIRST and then applies it once:

        cw = (int16)((hamr[j]*hamc[k]) >> 15)        <- hls_window/window.cpp:63
        out = (int16)((x * cw) >> 15)                <- window.cpp:67-68

    This mirror instead applied the tapers as two INDEPENDENT >>15 rounds
    ((x*hamr)>>15 then *hamc>>15), which differs in the low bit and made the "bit-accurate"
    claim in this file's docstring false. It matters now because the pipeline CRC gate
    (0xd596c9eb) is being forfeited by the coefficient and detect fusions, so this mirror
    becomes the reference of record -- it has to actually match the silicon.

    The same arithmetic is now also implemented in fabric (the fused window in
    fft_feeder_v.v), verified bit-identical by mpfs/fpga/tb/tb_fft_feeder_win.v.
    """
    Np, Mp = g2.shape
    hr = np.zeros(Np); hr[:n] = np.hamming(n)
    hc = np.zeros(Mp); hc[:m] = np.hamming(m)
    hr_i = np.floor(hr * 32768).astype(np.int64)          # int16 tapers (as the board loads)
    hc_i = np.floor(hc * 32768).astype(np.int64)
    out_r = np.empty(g2.shape, np.float64)
    out_i = np.empty(g2.shape, np.float64)
    for j in range(Np):                                   # row-wise: the 2-D cw is 128 MB
        cw = _trunc16((hr_i[j] * hc_i) >> 15)             # combined Q15 taper, int16-truncated
        out_r[j] = _trunc16(_shr_floor(g2.real[j] * cw, 15))
        out_i[j] = _trunc16(_shr_floor(g2.imag[j] * cw, 15))
    return _sat16(out_r) + 1j * _sat16(out_i)


def fft_pass_bfp(x):
    """adaptive BFP FFT per row + firmware GLOBAL renorm >>(emax-exp_i) -- one pipeline FFT pass."""
    N = x.shape[-1]
    y, e = fx.fft1d_bfp_hw_perrow(x, 16, 16, fx._bitrev_perm(N))
    emax = int(e.max())
    sh = (emax - e)[..., None]
    y = np.floor(y.real / (2.0 ** sh)) + 1j * np.floor(y.imag / (2.0 ** sh))
    return _sat16(y.real) + 1j * _sat16(y.imag), e


def detect_fixed(z):
    """FIXED detect.cpp: sqrt(re^2+im^2) with SIGNED int16 re/im, floor, uint16 saturate."""
    re = _sat16(z.real).astype(np.int64)
    im = _sat16(z.imag).astype(np.int64)
    m = np.floor(np.sqrt((re * re + im * im).astype(np.float64)))
    return np.clip(m, 0, 0xFFFF).astype(np.uint16)


def form_image(cphd_path, deci, grid, sgn_default=-1):
    reader = ref.open_phase_history(str(cphd_path))
    meta = reader.cphd_meta
    tables = prepare_tables(reader, meta, deci, deci)
    m, n = tables["dims"]; mu, nu = tables["deci"]
    signal = np.asarray(reader.read_chip((0, tables["n_vec"], mu), (0, tables["n_samp"], nu), index=0),
                        np.complex64)
    reader.close()
    print(f"  scene {m}x{n} (deci {deci}) -> grid {grid}x{grid}")

    # int16 quantize of the signal (what the board loads into BUF_SIG)
    lsb, _ = fx.fit_scale(signal, 16)
    sig_i16 = (np.floor(signal.real / lsb) + 1j * np.floor(signal.imag / lsb))
    sig_i16 = _sat16(sig_i16.real) + 1j * _sat16(sig_i16.imag)

    g2, (m, n) = resample_fixed(sig_i16, tables, grid)      # 2-pass keystone, fixed point
    g2w = window_fixed(g2, m, n)                            # 2-D Hamming, fixed point
    yr, er = fft_pass_bfp(g2w)                              # range BFP FFT + renorm
    yt = np.swapaxes(yr, -1, -2)                            # corner-turn
    ya, ea = fft_pass_bfp(yt)                               # azimuth BFP FFT + renorm
    focused = np.swapaxes(ya, -1, -2)
    img = detect_fixed(focused)                            # fixed detect -> uint16
    print(f"  range exp spread {int(er.max()-er.min())}, azimuth exp spread {int(ea.max()-ea.min())}; "
          f"OUT peak={img.max()} mean={img.mean():.1f} sat%={100*(img>=0xFFFF).mean():.2f}")
    return img


def save(img, name, outdir):
    outdir.mkdir(parents=True, exist_ok=True)
    np.save(outdir / f"{name}_silmirror_mag.npy", img)
    # DISPLAY-ONLY (does not touch the saved .npy): fftshift centers DC (removes the edge DC band),
    # then SAR-standard dB display -- 28 dB window below the 99.7th pct + mild gamma (beats log1p,
    # which over-brightens the single-look speckle floor). Single-look, NO multi-look averaging.
    full = np.fft.fftshift(img.astype(np.float64))
    th = full[::max(1, full.shape[0] // 512), ::max(1, full.shape[1] // 512)]
    db = 20.0 * np.log10(th + 1e-6)
    hi = np.percentile(db, 99.7); lo = hi - 28.0
    thl = (255 * np.clip((db - lo) / (hi - lo + 1e-9), 0, 1) ** 0.85).astype(np.uint8)
    try:
        from PIL import Image
        Image.fromarray(thl).save(outdir / f"{name}_silmirror_thumb.png")
        print(f"  wrote {outdir/(name+'_silmirror_mag.npy')} + _thumb.png")
    except Exception:
        np.save(outdir / f"{name}_silmirror_thumb.npy", thl)
        print(f"  wrote {outdir/(name+'_silmirror_mag.npy')} (+ thumb.npy, no PIL)")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--scene", choices=list(SCENES) + ["both"], default="both")
    ap.add_argument("--deci", type=int, default=8)
    ap.add_argument("--grid", type=int, default=8192)
    a = ap.parse_args()
    outdir = ROOT / "output"
    scenes = list(SCENES) if a.scene == "both" else [a.scene]
    for s in scenes:
        cphd = ROOT / SCENES[s]
        if not cphd.exists():
            print(f"[{s}] MISSING CPHD: {cphd}"); continue
        print(f"[{s}] silicon-mirror focus:")
        img = form_image(cphd, a.deci, a.grid)
        save(img, s, outdir)


if __name__ == "__main__":
    main()
