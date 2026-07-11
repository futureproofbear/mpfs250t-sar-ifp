"""render_quarters.py -- render each 2048x8192 quarter of the deci-1 Centerfield silicon OUT as its
own image (user wants an image per quarter). Q1 = out_q.bin (rows 0:2048); Q2/Q3/Q4 = out_rest.bin
slices (rows 2048:4096 / 4096:6144 / 6144:8192). dB stretch: 20log10, 26 dB window, column-roll 4096.
"""
from pathlib import Path
import numpy as np

HERE = Path(__file__).resolve().parent
STAGE = HERE / "jtag_stage_deci1"
OUT = HERE.parents[1] / "output"
ROWS, W = 2048, 8192
SLICE = ROWS * W * 2                                    # 32 MiB per quarter


def stretch(q):
    q = np.roll(q.astype(np.float64), 4096, axis=1)    # col-roll (center the scene)
    db = 20.0 * np.log10(q + 1e-6)
    hi = np.percentile(db, 99.7); lo = hi - 26.0
    return (255 * np.clip((db - lo) / (hi - lo + 1e-9), 0, 1)).astype(np.uint8)


def load_quarter(n):
    if n == 1:
        raw = np.fromfile(STAGE / "out_q.bin", np.uint16)
    else:
        off = (n - 2) * ROWS * W
        raw = np.fromfile(STAGE / "out_rest.bin", np.uint16, count=ROWS * W, offset=off * 2)
    return raw.reshape(ROWS, W)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    from PIL import Image
    for n in (1, 2, 3, 4):
        q = load_quarter(n)
        img = Image.fromarray(stretch(q)).resize((1600, 400), Image.BILINEAR)
        p = OUT / f"cf_silicon_Q{n}.png"
        img.save(p)
        sat = 100 * (q >= 0xFFFF).mean()
        print(f"Q{n} rows {(n-1)*ROWS:>4}:{n*ROWS:<4}  peak={q.max():>5}  mean={q.mean():6.1f}  "
              f"sat%={sat:.3f}  -> {p.name}")


if __name__ == "__main__":
    main()
