"""Render a raw uint16 magnitude crop (dumped from OUT via ROI) to a PNG + stats.
Usage: render_crop.py <crop.bin> <rows> <cols> [out.png]
The image former writes OUT as uint16 detected magnitude, row-major. We log-scale
for display (SAR imagery spans a huge dynamic range)."""
import sys
import numpy as np

def main():
    if len(sys.argv) < 4:
        sys.exit("usage: render_crop.py <crop.bin> <rows> <cols> [out.png]")
    path, rows, cols = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    out = sys.argv[4] if len(sys.argv) > 4 else path.rsplit(".", 1)[0] + ".png"
    a = np.fromfile(path, dtype=np.uint16)
    if a.size < rows * cols:
        sys.exit(f"file has {a.size} u16, need {rows*cols} ({rows}x{cols})")
    a = a[:rows * cols].reshape(rows, cols).astype(np.float64)
    nz = np.count_nonzero(a)
    print(f"crop {rows}x{cols}  min={a.min():.0f} max={a.max():.0f} "
          f"mean={a.mean():.1f}  nonzero={nz}/{a.size} ({100.0*nz/a.size:.1f}%)")
    if a.max() <= 0:
        print("ALL ZERO -- pipeline produced no energy in this region.")
        return
    # log-scale to 8-bit for a viewable PNG
    disp = np.log1p(a)
    disp = (255.0 * (disp - disp.min()) / (disp.max() - disp.min() + 1e-9)).astype(np.uint8)
    try:
        from PIL import Image
        Image.fromarray(disp).save(out)
        print(f"wrote {out}")
    except Exception as e:
        np.save(out + ".npy", disp)
        print(f"PIL unavailable ({e}); wrote {out}.npy")

if __name__ == "__main__":
    main()
