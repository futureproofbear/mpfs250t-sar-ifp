"""Compare a board OUT band (dumped rows [0:R] of the 8192-wide detected-magnitude image)
against the golden. The board OUT is the plain (non-shifted) 2-D FFT magnitude, same as
golden_small_mag.npy. Orientation (transpose / flips) from the corner-turn + FFT-pass layout
is resolved empirically by correlating against all 8 dihedral variants of the golden's
matching region and reporting the best. High corr (>0.9) => the full pipeline produced the
correct image on silicon.

    python compare_out_band.py --band jtag_stage_small/out_band.bin --golden jtag_stage_small/golden_small_mag.npy --rows 256
"""
import argparse
import numpy as np

W = 8192


def corr(a, b):
    a = a.ravel().astype(np.float64); b = b.ravel().astype(np.float64)
    a -= a.mean(); b -= b.mean()
    d = np.linalg.norm(a) * np.linalg.norm(b)
    return float(a @ b / d) if d else 0.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--band", required=True, help="board OUT band .bin (uint16)")
    ap.add_argument("--golden", required=True, help="golden_small_mag.npy (8192x8192 float32)")
    ap.add_argument("--rows", type=int, default=256, help="rows in the band")
    a = ap.parse_args()

    board = np.fromfile(a.band, np.uint16).astype(np.float32)
    R = a.rows
    assert board.size == R * W, f"band size {board.size} != {R}*{W}={R*W}"
    board = board.reshape(R, W)
    g = np.load(a.golden, mmap_mode="r")
    assert g.shape == (W, W), f"golden shape {g.shape}"

    print(f"  board band {board.shape}: min={board.min():.0f} max={board.max():.0f} "
          f"mean={board.mean():.1f} nonzero={100*np.count_nonzero(board)/board.size:.1f}%")

    # candidate golden regions matching a top horizontal band, over the 8 dihedral orientations
    top = np.asarray(g[:R, :])            # identity top band
    topT = np.asarray(g[:, :R]).T         # transpose top band (= left col band transposed)
    cands = {
        "identity":            top,
        "flipud":              top[::-1, :],
        "fliplr":              top[:, ::-1],
        "rot180":              top[::-1, ::-1],
        "transpose":           topT,
        "transpose+flipud":    topT[::-1, :],
        "transpose+fliplr":    topT[:, ::-1],
        "transpose+rot180":    topT[::-1, ::-1],
    }
    best_name, best_c = None, -1.0
    for name, cand in cands.items():
        c = corr(board, cand)
        # magnitude compare is scale-invariant; also try log (in case detect log-scales)
        cl = corr(np.log1p(board), np.log1p(np.asarray(cand, np.float64)))
        cc = max(c, cl)
        print(f"  vs golden {name:18s} corr={c:+.4f}  logcorr={cl:+.4f}")
        if cc > best_c:
            best_name, best_c = name, cc
    verdict = "MATCH (pipeline correct)" if best_c > 0.9 else \
              ("PARTIAL" if best_c > 0.6 else "MISMATCH")
    print(f"  BEST orientation = '{best_name}'  corr={best_c:.4f}  => {verdict}")
    return 0 if best_c > 0.9 else 1


if __name__ == "__main__":
    raise SystemExit(main())
