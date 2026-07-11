"""Fixed-point version of form_image_pfa.py (FPGA-datapath emulation).

Same PFA focuser as the float reference, but the offloaded datapath (zero-pad ->
2-D FFT -> detect) runs in fixed point with a block-floating-point FFT (see
fixedpoint.py) -- what the PolarFire fabric would compute, truncating (floor) at
every datapath quantization. The resample and geocoding stay on the float CPU and
are IMPORTED from the reference so the two pipelines cannot drift: they share the
exact same resample, window, pow2 grid, geocoding and GeoTIFF format, and differ
ONLY in the FFT/detect arithmetic.

Output: a single full-resolution float32 detected GeoTIFF, pixel-aligned with the
float reference's GeoTIFF (output/<stem>_detected.tif), so the two can be
differenced directly to quantify the fixed-point loss.

    python src/form_image_pfa_fixed.py            # 16-bit by default
"""
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import form_image_pfa as ref
import fixedpoint as fp

NBITS = 16             # datapath bit width to emulate (matches CoreFFT config)
NBITS_TW = 18          # twiddle bit width (18x18 DSP)


def main():
    t = ref.StepTimer()
    rdr = ref.open_phase_history(str(ref.LOCAL_CPHD))
    meta = rdr.cphd_meta
    sgn = int(meta.Global.SGN)
    # the BFP FFT is forward-only; the float reference transform is forward for
    # SGN=-1 (this scene). Guard so the two stay equivalent.
    assert sgn < 0, "fixed BFP FFT is forward-only; matches SGN=-1"
    nv, ns = rdr.get_data_size_as_tuple()[0]
    mu = max(1, ref.DECIMATE_PULSE); nu = max(1, ref.DECIMATE_SAMPLE)  # same as reference
    print(f"[fixed] scene {ref.KEY.split('/')[2]}  {nv}x{ns}  decimate {mu}x{nu}  "
          f"SGN={sgn}  NBITS={NBITS} (tw {NBITS_TW})")

    sc0 = rdr.read_pvp_variable("SC0", 0)[::mu]
    scss = rdr.read_pvp_variable("SCSS", 0)[::mu]
    tx = rdr.read_pvp_variable("TxPos", 0)[::mu]
    rcvp = rdr.read_pvp_variable("RcvPos", 0)[::mu]
    srp = rdr.read_pvp_variable("SRPPos", 0)[::mu]
    plan = meta.SceneCoordinates.ReferenceSurface.Planar
    uiax = np.array([plan.uIAX.X, plan.uIAX.Y, plan.uIAX.Z])
    uiay = np.array([plan.uIAY.X, plan.uIAY.Y, plan.uIAY.Z])
    u = (srp - 0.5 * (tx + rcvp))
    u = u / np.linalg.norm(u, axis=1, keepdims=True)
    ax, ay = u @ uiax, u @ uiay

    t.lap("open + read header + PVP")
    sig = np.asarray(rdr.read_chip((0, nv, mu), (0, ns, nu), index=0), np.complex64)
    rdr.close()
    k = np.arange(sig.shape[1])
    freq = sc0[:, None] + k[None, :] * (scss[:, None] * nu)
    t.lap("read signal (phase history)")

    # identical resample + window as the float reference (imported, not copied)
    g2, geo = ref.resample_kspace(sig, freq, ax, ay)
    m2, n2 = fp._to_pow2(g2.shape[0]), fp._to_pow2(g2.shape[1])
    print(f"[fixed] resampled k-space {g2.shape} -> FFT {m2}x{n2}; focusing (BFP, floor)...")
    t.lap("resample + window")

    fixed_mag, (er, ea) = fp.focus_fixed(g2, NBITS, NBITS_TW)
    t.lap("input quant + BFP 2-D FFT + detect")
    print(f"  fixed dynamic range : {fp.dynamic_range_db(fixed_mag):.1f} dB")
    print(f"  BFP guard bits (range/azimuth FFT): {er[-1]-er[0]} / {ea[-1]-ea[0]}")

    # scale pixel spacing to the padded pow2 grid, exactly as ref.focus does
    geo = dict(geo)
    geo["dr"] *= g2.shape[1] / n2          # range (cols)
    geo["dc"] *= g2.shape[0] / m2          # cross (rows)

    out_tif = ref.OUTPUT_DIR / f"{ref._stem}_fixed{NBITS}bit_detected.tif"
    ref.OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    ref.save_detected_geotiff(fixed_mag, geo, srp[0], uiax, uiay, out_tif,
                              ref.GEO_EPSG, flip_col=ref.FLIP_COL,
                              flip_row=ref.FLIP_ROW, dtype="float32")
    t.lap("geocode + GeoTIFF")
    t.dump(ref.OUTPUT_DIR / f"{ref._stem}_fixed{NBITS}bit.timing.json",
           meta={"nbits": NBITS, "nbits_tw": NBITS_TW, "grid": [m2, n2],
                 "scene": ref.KEY.split("/")[2],
                 "bfp_exponents_range": er, "bfp_exponents_azimuth": ea,
                 "bfp_guard_bits_range": er[-1] - er[0],
                 "bfp_guard_bits_azimuth": ea[-1] - ea[0]})


if __name__ == "__main__":
    main()
