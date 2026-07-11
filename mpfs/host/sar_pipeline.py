"""MPFS SAR pipeline (CPU host side).

Embedded, storage-to-storage batch processor for the PolarFire SoC Icicle Kit:

    /data/in/*_CPHD.cphd (+ _METADATA.json, pre-loaded)
        -> [CPU] parse + build resample/geometry tables
        -> [FPGA or CPU] focus: resample -> window -> 2-D FFT -> detect
        -> [CPU] geocode (ECEF->UTM) + write GeoTIFF
        -> /data/out/*_detected.tif

The heavy math is delegated to an accelerator backend (accel.py). The algorithm
itself is NOT duplicated here: the numpy backend reuses src/form_image_pfa.py so
this port stays consistent with the verified laptop reference.

Usage:
    python sar_pipeline.py --in <cphd> --out <dir> [--backend numpy|fpga]
    python sar_pipeline.py --watch /data/in --out /data/out   # batch daemon
"""
import sys
import time
import argparse
from pathlib import Path

import numpy as np

# Reuse the verified laptop reference as the single source of algorithm truth.
REF_DIR = Path(__file__).resolve().parents[2] / "src"
sys.path.insert(0, str(REF_DIR))
import form_image_pfa as ref          # noqa: E402

from accel import make_backend        # noqa: E402

C = ref.C


def prepare_tables(reader, meta, deci_pulse=1, deci_sample=1):
    """CPU stage: read PVP geometry and build the tables the focuser needs.

    Returns a dict with:
      ax, ay, freq, sgn          -> focusing inputs
      KR, KC, tan_phi, window    -> resample grids + taper (consumed by the FPGA)
      geo, center_ecef, uiax, uiay -> geometry for geocoding (CPU)
    """
    mu, nu = max(1, deci_pulse), max(1, deci_sample)
    n_vec, n_samp = reader.get_data_size_as_tuple()[0]
    sgn = int(meta.Global.SGN)

    tx = reader.read_pvp_variable("TxPos", 0)[::mu]
    rcv = reader.read_pvp_variable("RcvPos", 0)[::mu]
    srp = reader.read_pvp_variable("SRPPos", 0)[::mu]
    sc0 = reader.read_pvp_variable("SC0", 0)[::mu]
    scss = reader.read_pvp_variable("SCSS", 0)[::mu]
    apc = 0.5 * (tx + rcv)

    plan = meta.SceneCoordinates.ReferenceSurface.Planar
    uiax = np.array([plan.uIAX.X, plan.uIAX.Y, plan.uIAX.Z])
    uiay = np.array([plan.uIAY.X, plan.uIAY.Y, plan.uIAY.Z])

    los = srp - apc
    u = los / np.linalg.norm(los, axis=1, keepdims=True)
    ax = u @ uiax
    ay = u @ uiay

    m = len(range(0, n_vec, mu))
    n = len(range(0, n_samp, nu))
    k = np.arange(n)
    freq = sc0[:, None] + k[None, :] * (scss[:, None] * nu)     # (m,n) Hz

    # resample grids + pixel geometry (mirrors form_image_pfa.pfa, on the CPU
    # because the FPGA resampler consumes KR/KC and geocoding needs the spacing)
    kmag = 2.0 * freq / C
    dx, dy = ax.mean(), ay.mean()
    dn = np.hypot(dx, dy); dx, dy = dx / dn, dy / dn
    cx, cy = -dy, dx
    pr = ax * dx + ay * dy
    pc = ax * cx + ay * cy
    kr = kmag * pr[:, None]
    tan_phi = pc / pr
    kr_lo, kr_hi = kr.max(axis=1).min(), kr.min(axis=1).max()
    if kr_lo > kr_hi:
        kr_lo, kr_hi = kr.min(), kr.max()
    KR = np.linspace(kr_lo, kr_hi, n)
    kc_max = np.abs(KR[:, None] * tan_phi[None, :]).max()
    KC = np.linspace(-kc_max, kc_max, m)
    window = np.outer(np.hamming(m), np.hamming(n)).astype(np.float32)
    geo = {"dc": 1.0 / (KC[-1] - KC[0]), "dr": 1.0 / (KR[-1] - KR[0]),
           "dhat": (dx, dy), "chat": (cx, cy)}

    return {"ax": ax, "ay": ay, "freq": freq, "sgn": sgn,
            "KR": KR, "KC": KC, "tan_phi": tan_phi, "window": window,
            "geo": geo, "center_ecef": srp[0], "uiax": uiax, "uiay": uiay,
            "dims": (m, n), "deci": (mu, nu), "n_vec": n_vec, "n_samp": n_samp}


def process_scene(cphd_path, out_dir, backend, deci_pulse=1, deci_sample=1):
    cphd_path, out_dir = Path(cphd_path), Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    out_tif = out_dir / (cphd_path.stem.replace("_CPHD", "") + "_detected.tif")
    t0 = time.perf_counter()

    reader = ref.open_phase_history(str(cphd_path))
    meta = reader.cphd_meta
    assert meta.Global.DomainType == "FX", "expects FX-domain CPHD"

    tables = prepare_tables(reader, meta, deci_pulse, deci_sample)
    mu, nu = tables["deci"]
    print(f"  [CPU] tables ready  dims={tables['dims']}  backend={backend.name}")

    signal = np.asarray(
        reader.read_chip((0, tables["n_vec"], mu), (0, tables["n_samp"], nu), index=0),
        dtype=np.complex64)
    reader.close()

    detected = backend.focus(signal, tables)            # [FPGA or CPU]
    print(f"  [{backend.name}] focused {detected.shape}")

    # geocode + write GeoTIFF (reuse the verified reference writer)
    ref.save_detected_geotiff(detected, tables["geo"], tables["center_ecef"],
                              tables["uiax"], tables["uiay"], str(out_tif),
                              ref.GEO_EPSG, flip_col=ref.FLIP_COL, flip_row=ref.FLIP_ROW)
    print(f"  [CPU] wrote {out_tif.name}  ({time.perf_counter()-t0:.1f} s total)")
    return out_tif


def watch(in_dir, out_dir, backend, poll=5.0, deci_pulse=1, deci_sample=1):
    """Batch daemon: process every CPHD dropped into in_dir, once."""
    in_dir, out_dir = Path(in_dir), Path(out_dir)
    done = set()
    print(f"watching {in_dir} -> {out_dir} (backend={backend.name})")
    while True:
        for cphd in sorted(in_dir.glob("**/*_CPHD.cphd")):
            if cphd in done:
                continue
            print(f"[scene] {cphd.name}")
            try:
                process_scene(cphd, out_dir, backend, deci_pulse, deci_sample)
            except Exception as e:                      # keep the queue alive
                print(f"  !! failed: {e}")
            done.add(cphd)
        time.sleep(poll)


def main():
    ap = argparse.ArgumentParser(description="MPFS SAR pipeline (CPU host)")
    ap.add_argument("--in", dest="inp", help="a CPHD file, or with --watch a dir")
    ap.add_argument("--out", default="/data/out", help="output dir for GeoTIFFs")
    ap.add_argument("--backend", default="numpy", choices=["numpy", "fpga"])
    ap.add_argument("--watch", action="store_true", help="run as a batch daemon")
    ap.add_argument("--deci-pulse", type=int, default=1)
    ap.add_argument("--deci-sample", type=int, default=1)
    a = ap.parse_args()

    backend = make_backend(a.backend, ref_module=ref)
    if a.watch:
        watch(a.inp, a.out, backend, deci_pulse=a.deci_pulse, deci_sample=a.deci_sample)
    else:
        process_scene(a.inp, a.out, backend, a.deci_pulse, a.deci_sample)


if __name__ == "__main__":
    main()
