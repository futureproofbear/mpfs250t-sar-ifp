"""
Lightweight SAR image formation from Umbra CPHD via the Polar Format Algorithm.

Umbra CPHD is frequency-domain (FX) phase history from a spotlight, monostatic
collect, motion-compensated to a fixed Stabilization Reference Point (SRP = the
scene Image Area Reference Point). In the FX domain the phase history is the 2-D
Fourier transform of the scene reflectivity, sampled on a POLAR grid (radius =
range frequency, angle = look aspect). Two ways to focus it on a laptop:

  MODE = "quicklook" : window + a single 2-D FFT (treats the polar grid as
                       Cartesian). ~7 s, mild geometric warp. Good first look.

  MODE = "pfa"       : 2-pass keystone resample (polar -> Cartesian) + 2-D FFT.
                       ~12-15 s, geometrically correct over the whole scene.

Both are O(N log N) over the array (NOT O(pixels x pulses) like backprojection),
so they form the FULL scene cheaply. Backprojection only wins for a tiny ROI.

Verified facts for the test collect (read from the CPHD header):
  5634 pulses x 4319 samples, CF8 (complex64); DomainType FX; SGN = -1;
  fc 9.60 GHz (lambda 3.1 cm); BW 113.6 MHz (range res ~1.32 m);
  scene +/-2000 m; image-plane axes given as ReferenceSurface.Planar uIAX/uIAY.

Requires: numpy, matplotlib, sarpy (all already installed). scipy optional.
"""

import os
import sys
import math
import json
import time
import urllib.parse
import urllib.request
from pathlib import Path

import numpy as np
from sarpy.io.phase_history.converter import open_phase_history

C = 299_792_458.0  # m/s


class StepTimer:
    """Accumulate wall-time per named processing step; dump to JSON for the report."""
    def __init__(self):
        self._t = time.perf_counter()
        self.steps = []

    def lap(self, name):
        now = time.perf_counter()
        self.steps.append((name, now - self._t))
        print(f"    [t] {name:<28} {self.steps[-1][1]:8.2f} s")
        self._t = now

    def dump(self, path, meta=None):
        d = {"steps": [{"step": n, "seconds": round(s, 3)} for n, s in self.steps],
             "total_seconds": round(sum(s for _, s in self.steps), 3)}
        if meta:
            d["meta"] = meta
        Path(path).write_text(json.dumps(d, indent=2))
        print(f"    [t] timings -> {path}")

# --------------------------------------------------------------------------- #
# CONFIG  -- defaults below; override any field in <project_root>/config.yaml
# (or point SAR_CONFIG at another yaml). See config.yaml for the schema.
# --------------------------------------------------------------------------- #
# Paths are anchored to the project root (parent of this src/ dir), so the
# script runs the same from any working directory.
PROJECT_ROOT = Path(__file__).resolve().parent.parent

_cfg = {}
_cfg_path = Path(os.environ.get("SAR_CONFIG", PROJECT_ROOT / "config.yaml"))
if _cfg_path.exists():
    import yaml
    with open(_cfg_path) as _f:
        _cfg = yaml.safe_load(_f) or {}
    print(f"[cfg] loaded {_cfg_path.name}")

S3_BASE = _cfg.get("s3_base", "https://umbra-open-data-catalog.s3.us-west-2.amazonaws.com")
KEY = _cfg.get("key", ("sar-data/tasks/Centerfield, Utah/"
                       "c0dbd830-e863-42c5-97d0-2cfd291bcb2a/"
                       "2023-10-10-16-57-44_UMBRA-04/"
                       "2023-10-10-16-57-44_UMBRA-04_CPHD.cphd"))
DATA_ROOT = PROJECT_ROOT / _cfg.get("data_root", "data")   # mirror: data/<key...>
OUTPUT_DIR = PROJECT_ROOT / _cfg.get("output_dir", "output")
LOCAL_CPHD = DATA_ROOT.joinpath(*KEY.split("/"))

MODE = _cfg.get("mode", "pfa")              # "quicklook" or "pfa"
DECIMATE_PULSE = int(_cfg.get("decimate_pulse", 1))   # >1 -> coarser azimuth, faster
DECIMATE_SAMPLE = int(_cfg.get("decimate_sample", 1)) # >1 -> coarser range, faster
WINDOW = bool(_cfg.get("window", True))     # Hamming taper to suppress sidelobes
ESTIMATE_ONLY = bool(_cfg.get("estimate_only", False))  # print estimate then exit
SAVE_GEOTIFF = bool(_cfg.get("save_geotiff", True))     # write detected GeoTIFF (PFA)
GEO_EPSG = _cfg.get("geo_epsg", "auto")     # int EPSG, or "auto" -> UTM zone from scene
FLIP_COL = bool(_cfg.get("flip_col", True)) # rot180 vs the GEC convention (verified)
FLIP_ROW = bool(_cfg.get("flip_row", True))

# output names follow the capture id in the key (so each scene is distinct)
_stem = KEY.split("/")[-1].replace("_CPHD.cphd", "") or "scene"
OUT_TIF = OUTPUT_DIR / f"{_stem}_detected.tif"

# Calibration constants MEASURED on this laptop at M0*N0 = 5634*4319 elements.
# The estimator scales these to the actual (decimated) problem size.
_E0 = 5634 * 4319
_T_FFT0 = 6.4          # s, full 2-D FFT (complex64)
_T_P1_0 = 1.2          # s, range-interp pass
_T_P2_0 = 3.3          # s, azimuth-interp pass


# --------------------------------------------------------------------------- #
def download_if_needed(local, key):
    if os.path.exists(local):
        print(f"[1] using cached {local} ({os.path.getsize(local)/1e6:.1f} MB)")
        return
    url = S3_BASE + "/" + urllib.parse.quote(key)
    os.makedirs(os.path.dirname(local), exist_ok=True)
    print(f"[1] downloading {url}")
    urllib.request.urlretrieve(url, local)
    print(f"    saved {local} ({os.path.getsize(local)/1e6:.1f} MB)")


def estimate_resources(m, n, mode):
    """Print a measured-on-this-laptop estimate of RAM and wall-time."""
    e = m * n
    bytes_arr = e * 8                       # complex64
    log_ratio = math.log2(max(e, 2)) / math.log2(_E0)
    t_fft = _T_FFT0 * (e / _E0) * log_ratio
    if mode == "quicklook":
        n_big = 3                           # signal + window*sig + fft out
        t = t_fft + 0.4 * (e / _E0)
    else:                                   # pfa
        n_big = 4                           # signal + G1 + G2 + fft out
        t = _T_P1_0 * (e / _E0) + _T_P2_0 * (e / _E0) + t_fft + 1.0
    peak_gb = (bytes_arr * n_big + 200e6) / 1e9
    print("    ---------------------------------------------------------")
    print(f"    RESOURCE ESTIMATE  (mode={mode})")
    print(f"      array              : {m} x {n} = {e/1e6:.1f} M samples")
    print(f"      one array in RAM   : {bytes_arr/1e6:.0f} MB (complex64)")
    print(f"      peak RAM (approx)  : {peak_gb:.2f} GB  [of 15.8 GB]")
    print(f"      wall time (approx) : {t:.0f} s  [12 cores]")
    print("    ---------------------------------------------------------")
    return {"peak_gb": peak_gb, "seconds": t}


def transform2d(arr, sgn):
    """Signal->image 2-D transform honoring the CPHD SGN convention, centred."""
    fwd = np.fft.fft2 if sgn < 0 else np.fft.ifft2
    return np.fft.fftshift(fwd(np.fft.ifftshift(arr)))


def to_pow2(n):
    return 1 << int(math.ceil(math.log2(n)))


def hamming2d(shape):
    return np.outer(np.hamming(shape[0]), np.hamming(shape[1])).astype(np.float32)


def quicklook(sig, sgn):
    """Window + single 2-D FFT. Treats the polar grid as Cartesian (approx)."""
    if WINDOW:
        sig = sig * hamming2d(sig.shape)
    return transform2d(sig, sgn)


def resample_kspace(sig, freq, ax, ay):
    """Polar->Cartesian keystone resample + Hamming window.

    sig  : (M, N) complex signal
    freq : (M, N) RF frequency of each sample (Hz)
    ax,ay: (M,)   in-plane components of each pulse's unit look direction

    Returns (g2, geo): g2 is the (M, N) windowed k-space that feeds the 2-D FFT;
    geo holds the *unpadded* pixel spacing and rotated-frame unit vectors. The
    fixed-point script reuses this verbatim, so the float and fixed pipelines
    differ ONLY in the FFT/detect arithmetic.
    """
    m, n = sig.shape
    kmag = 2.0 * freq / C                       # |k| projected... (cycles/m), (M,N)
    # rotated frame: d_hat = mean radial direction, c_hat perpendicular
    dx, dy = ax.mean(), ay.mean()
    dn = math.hypot(dx, dy); dx, dy = dx / dn, dy / dn
    cx, cy = -dy, dx                            # perpendicular unit vector
    # per-pulse radial/cross unit projections (constant along samples)
    pr = ax * dx + ay * dy                      # along range (d_hat)
    pc = ax * cx + ay * cy                      # along cross (c_hat)
    kr = kmag * pr[:, None]                      # (M,N) range-wavenumber
    tan_phi = pc / pr                            # (M,) cross/range ratio per pulse

    # --- pass 1: resample each pulse onto a common uniform range grid KR -----
    kr_lo, kr_hi = kr.max(axis=1).min(), kr.min(axis=1).max()  # common overlap
    if kr_lo > kr_hi:
        kr_lo, kr_hi = kr.min(), kr.max()
    KR = np.linspace(kr_lo, kr_hi, n)
    g1 = np.empty((m, n), dtype=np.complex64)
    for i in range(m):
        xp = kr[i]
        if xp[0] > xp[-1]:
            xp = xp[::-1]; row = sig[i, ::-1]
        else:
            row = sig[i]
        g1[i] = (np.interp(KR, xp, row.real, left=0, right=0)
                 + 1j * np.interp(KR, xp, row.imag, left=0, right=0))

    # --- pass 2: per range bin, resample across pulses onto uniform cross KC --
    kc_max = np.abs(KR[:, None] * tan_phi[None, :]).max()
    KC = np.linspace(-kc_max, kc_max, m)
    g2 = np.empty((m, n), dtype=np.complex64)
    order = np.argsort(tan_phi)                 # monotonic source coords for interp
    tan_s = tan_phi[order]
    g1s = g1[order]
    for j in range(n):
        src = KR[j] * tan_s                     # (M,) cross positions at this range bin
        g2[:, j] = (np.interp(KC, src, g1s[:, j].real, left=0, right=0)
                    + 1j * np.interp(KC, src, g1s[:, j].imag, left=0, right=0))

    if WINDOW:
        g2 = g2 * hamming2d(g2.shape)
    # pixel spacing (m): 1 / total k-extent (cycles/m); rows=cross, cols=range
    dr = 1.0 / (KR[-1] - KR[0]) if KR[-1] != KR[0] else float("nan")
    dc = 1.0 / (KC[-1] - KC[0]) if KC[-1] != KC[0] else float("nan")
    geo = {"dc": dc, "dr": dr, "dhat": (dx, dy), "chat": (cx, cy)}
    return g2, geo


def focus(g2, geo, sgn):
    """Zero-pad the windowed k-space to a power-of-2 grid, then 2-D FFT.

    Padding to pow2 matches the radix-2 grid the FPGA fabric forms on, so the
    float GeoTIFF here and the fixed-point GeoTIFF are the same size and directly
    comparable. Pixel spacing is scaled to the finer (padded) grid.
    """
    m, n = g2.shape
    m2, n2 = to_pow2(m), to_pow2(n)
    pad = np.zeros((m2, n2), dtype=np.complex64)
    pad[:m, :n] = g2
    img = transform2d(pad, sgn)
    geo = dict(geo)
    geo["dr"] *= n / n2                          # range (cols), finer after padding
    geo["dc"] *= m / m2                          # cross (rows)
    return img, geo


def pfa(sig, freq, ax, ay, sgn):
    """2-pass keystone PFA: resample (polar->Cartesian) + pad-to-pow2 + 2-D FFT."""
    g2, geo = resample_kspace(sig, freq, ax, ay)
    return focus(g2, geo, sgn)


def save_detected_geotiff(img, geo, center_ecef, uiax, uiay, out_tif, epsg,
                          flip_col=False, flip_row=False, dtype="uint8"):
    """Detect |img|, attach a rotated affine (radar grid -> map), write GeoTIFF.

    The image is planar, so the radar grid maps to UTM by a single affine; we
    derive it from the scene-centre pixel and the per-pixel ground displacement
    vectors (like the GEC's own rotated geotransform). No resampling.
    """
    import rasterio
    from rasterio.transform import Affine
    import pyproj

    if epsg in (None, "auto"):                         # derive UTM zone from scene
        lon, lat = pyproj.Transformer.from_crs(4978, 4326, always_xy=True).transform(
            center_ecef[0], center_ecef[1], center_ecef[2])[:2]
        epsg = (32600 if lat >= 0 else 32700) + int((lon + 180) // 6) + 1
        print(f"    auto EPSG:{epsg} (lon {lon:.3f}, lat {lat:.3f})")

    m, n = img.shape                                  # rows=cross, cols=range
    row0, col0 = m // 2, n // 2                        # scene centre (post-fftshift)
    dhat = np.array(geo["dhat"]); chat = np.array(geo["chat"])
    sc = -1.0 if flip_col else 1.0
    sr = -1.0 if flip_row else 1.0
    # per-pixel ground displacement (ECEF) for +1 col (range) and +1 row (cross)
    v_col = sc * geo["dr"] * (dhat[0] * uiax + dhat[1] * uiay)
    v_row = sr * geo["dc"] * (chat[0] * uiax + chat[1] * uiay)

    tf = pyproj.Transformer.from_crs(4978, epsg, always_xy=True)  # ECEF -> UTM
    def to_map(p):
        x, y = tf.transform(p[0], p[1], p[2])[:2]
        return np.array([x, y])
    p0, pcol, prow = to_map(center_ecef), to_map(center_ecef + v_col), to_map(center_ecef + v_row)
    a = pcol - p0                                      # (dE, dN) per col
    b = prow - p0                                      # (dE, dN) per row
    A = Affine(a[0], b[0], p0[0] - a[0]*col0 - b[0]*row0,
               a[1], b[1], p0[1] - a[1]*col0 - b[1]*row0)

    amp = np.abs(img).astype(np.float32)
    if dtype == "float32":
        data = amp                                     # raw magnitude, no requantization
    else:
        hi = np.percentile(amp, 99.7)
        data = np.clip(amp / (hi + 1e-12) * 255.0, 0, 255).astype(np.uint8)

    with rasterio.open(out_tif, "w", driver="GTiff", height=m, width=n, count=1,
                       dtype=dtype, crs=f"EPSG:{epsg}", transform=A,
                       compress="lzw") as dst:
        dst.write(data, 1)
    b_ = rasterio.open(out_tif).bounds
    print(f"    wrote {out_tif}  {n}x{m} {dtype}  {os.path.getsize(out_tif)/1e6:.1f} MB")
    print(f"    centre UTM {tuple(round(v) for v in p0)}  bounds {tuple(round(v) for v in b_)}")


def main():
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    download_if_needed(LOCAL_CPHD, KEY)

    t = StepTimer()
    reader = open_phase_history(str(LOCAL_CPHD))
    meta = reader.cphd_meta
    sgn = int(meta.Global.SGN)
    n_vec, n_samp = reader.get_data_size_as_tuple()[0]
    print(f"[2] domain={meta.Global.DomainType} SGN={sgn} "
          f"pulses={n_vec} samples={n_samp}")
    assert meta.Global.DomainType == "FX", "script assumes FX domain"
    t.lap("open + read header")

    mu = max(1, DECIMATE_PULSE); nu = max(1, DECIMATE_SAMPLE)
    m_use = len(range(0, n_vec, mu)); n_use = len(range(0, n_samp, nu))

    est = estimate_resources(m_use, n_use, MODE)
    if ESTIMATE_ONLY:
        print("    ESTIMATE_ONLY set -> stopping before image formation.")
        reader.close(); return
    if est["peak_gb"] > 12.0:
        print("    WARNING: estimated RAM is high; consider increasing DECIMATE_*.")

    # --- PVP geometry -------------------------------------------------------- #
    tx = reader.read_pvp_variable("TxPos", 0)[::mu]
    rcv = reader.read_pvp_variable("RcvPos", 0)[::mu]
    srp = reader.read_pvp_variable("SRPPos", 0)[::mu]
    sc0 = reader.read_pvp_variable("SC0", 0)[::mu]
    scss = reader.read_pvp_variable("SCSS", 0)[::mu]
    apc = 0.5 * (tx + rcv)                       # monostatic antenna phase centre

    # image-plane axes from ReferenceSurface.Planar
    plan = meta.SceneCoordinates.ReferenceSurface.Planar
    uiax = np.array([plan.uIAX.X, plan.uIAX.Y, plan.uIAX.Z])
    uiay = np.array([plan.uIAY.X, plan.uIAY.Y, plan.uIAY.Z])

    # per-pulse unit look direction projected into the image plane
    los = srp - apc
    u = los / np.linalg.norm(los, axis=1, keepdims=True)
    ax = u @ uiax
    ay = u @ uiay
    t.lap("read PVP geometry")

    # --- read signal (decimated) -------------------------------------------- #
    sig = reader.read_chip((0, n_vec, mu), (0, n_samp, nu), index=0)
    sig = np.asarray(sig, dtype=np.complex64)
    print(f"[3] signal {sig.shape}  {sig.nbytes/1e6:.0f} MB in RAM")
    reader.close()
    t.lap("read signal (phase history)")

    # --- focus --------------------------------------------------------------- #
    if MODE == "quicklook":
        print("[4] quick-look 2-D FFT ...")
        img = quicklook(sig, sgn); geo = None
        t.lap("quicklook FFT")
    else:
        k = np.arange(n_use)
        freq = sc0[:, None] + k[None, :] * (scss[:, None] * nu)  # (M,N) Hz
        print("[4] PFA: pass1 range resample, pass2 azimuth resample, 2-D FFT ...")
        g2, geo = resample_kspace(sig, freq, ax, ay)
        t.lap("resample + window")
        img, geo = focus(g2, geo, sgn)
        t.lap("zero-pad + 2-D FFT")

    # --- detected GeoTIFF (PFA only; needs the resample geometry) ------------ #
    # float32 = raw magnitude (no requantization) so this float reference and the
    # fixed-point GeoTIFF are directly comparable on the same pow2 grid.
    if SAVE_GEOTIFF and geo is not None:
        print("[5] geocoding -> detected GeoTIFF ...")
        save_detected_geotiff(img, geo, srp[0], uiax, uiay, OUT_TIF, GEO_EPSG,
                              flip_col=FLIP_COL, flip_row=FLIP_ROW, dtype="float32")
        t.lap("detect + geocode + GeoTIFF")
    t.dump(OUTPUT_DIR / f"{_stem}_float.timing.json",
           meta={"mode": MODE, "pulses": n_vec, "samples": n_samp,
                 "grid": list(img.shape), "scene": KEY.split("/")[2]})


if __name__ == "__main__":
    main()
