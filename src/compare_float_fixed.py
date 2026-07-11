"""Compare the float-reference GeoTIFF against the fixed-point GeoTIFF.

Reads the two detected GeoTIFFs produced by form_image_pfa.py (float) and
form_image_pfa_fixed.py (fixed), confirms they are pixel-aligned (same grid, CRS
and affine), then quantifies the fixed-point error: SNR, ENOB, NRMSE, correlation,
peak error, bias, and the usable dynamic range of each. Writes a JSON summary and
a 3-panel diff PNG (float dB | fixed dB | |error|).

    python src/compare_float_fixed.py
"""
import sys
import json
from pathlib import Path

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import rasterio

sys.path.insert(0, str(Path(__file__).resolve().parent))
import form_image_pfa as ref
import form_image_pfa_fixed as fx
import fixedpoint as fp


def main():
    f_tif = ref.OUTPUT_DIR / f"{ref._stem}_detected.tif"
    x_tif = ref.OUTPUT_DIR / f"{ref._stem}_fixed{fx.NBITS}bit_detected.tif"
    for p in (f_tif, x_tif):
        if not p.exists():
            sys.exit(f"missing {p} -- run form_image_pfa.py and form_image_pfa_fixed.py first")

    A = rasterio.open(f_tif)
    B = rasterio.open(x_tif)
    if A.shape != B.shape:
        sys.exit(f"grid mismatch {A.shape} vs {B.shape}; both must be full-res")
    aligned = bool(A.transform.almost_equals(B.transform) and A.crs == B.crs)
    a = A.read(1).astype(np.float64)        # float reference magnitude
    b = B.read(1).astype(np.float64)        # fixed-point magnitude

    c = fp.compare(a, b)                     # SNR / ENOB / NRMSE / corr / DR (peak-normalized)
    an = a / (a.max() + 1e-30)
    bn = b / (b.max() + 1e-30)
    err = bn - an
    metrics = {
        "scene": ref.KEY.split("/")[2],
        "float_tif": f_tif.name,
        "fixed_tif": x_tif.name,
        "grid": list(A.shape),
        "nbits": fx.NBITS,
        "nbits_twiddle": fx.NBITS_TW,
        "geo_aligned": aligned,
        "snr_db": round(c["snr_db"], 2),
        "enob_bits": round(c["enob"], 2),
        "nrmse": round(c["nrmse"], 5),
        "pearson_corr": round(c["corr"], 5),
        "max_abs_err_norm": round(float(np.abs(err).max()), 5),
        "mean_bias_norm": round(float(err.mean()), 6),
        "dyn_range_float_db": round(c["dr_ref_db"], 1),
        "dyn_range_fixed_db": round(c["dr_test_db"], 1),
        "dyn_range_loss_db": round(c["dr_ref_db"] - c["dr_test_db"], 1),
    }
    print(json.dumps(metrics, indent=2))
    out_json = ref.OUTPUT_DIR / f"{ref._stem}_float_vs_fixed.json"
    out_json.write_text(json.dumps(metrics, indent=2))

    def db(x):
        p = np.percentile(x, 99.7)
        return 20 * np.log10(x / (p + 1e-12) + 1e-6)

    fig, axs = plt.subplots(1, 3, figsize=(16, 5.6))
    axs[0].imshow(db(a), cmap="gray", vmin=-30, vmax=5, origin="lower")
    axs[0].set_title("float reference (dB)")
    axs[1].imshow(db(b), cmap="gray", vmin=-30, vmax=5, origin="lower")
    axs[1].set_title(f"fixed {fx.NBITS}-bit (dB)")
    im = axs[2].imshow(np.abs(err), cmap="inferno", origin="lower")
    axs[2].set_title("|error| (peak-normalized)")
    fig.colorbar(im, ax=axs[2], fraction=0.046)
    for a_ in axs:
        a_.set_xticks([]); a_.set_yticks([])
    fig.suptitle(f"{metrics['scene']}  |  SNR {metrics['snr_db']} dB  "
                 f"ENOB {metrics['enob_bits']}  corr {metrics['pearson_corr']}")
    fig.tight_layout()
    out_png = ref.OUTPUT_DIR / f"{ref._stem}_float_vs_fixed.png"
    fig.savefig(out_png, dpi=120)
    print(f"wrote {out_json}")
    print(f"wrote {out_png}")


if __name__ == "__main__":
    main()
