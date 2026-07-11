"""stitch_silicon_deci1.py -- reconstruct the FULL 8192x8192 silicon OUT from the two JTAG dumps
(out_q.bin = rows 0:2048, out_rest.bin = rows 2048:8192), correlate against the silicon-mirror
emulator golden, and render the full silicon image + a side-by-side vs the golden.

The emulator .npy is raw detect magnitude in NATURAL (unshifted) order, same order the silicon writes
to DDR, so silicon and golden are directly comparable without a transpose (the silmirror already
mirrors the pipeline's corner-turns). Display applies the same fftshift + dB stretch as the emulator.
"""
import sys
from pathlib import Path
import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
STAGE = HERE / "jtag_stage_deci1"
OUT = ROOT / "output"
DOCS = ROOT / "docs" / "fpga"
G = 8192


def load_silicon():
    q = np.fromfile(STAGE / "out_q.bin", np.uint16)
    r = np.fromfile(STAGE / "out_rest.bin", np.uint16)
    assert q.size == 2048 * G, f"out_q {q.size} != {2048*G}"
    assert r.size == 6144 * G, f"out_rest {r.size} != {6144*G}"
    full = np.vstack([q.reshape(2048, G), r.reshape(6144, G)])
    return full                                         # (8192, 8192) uint16, natural order


def corr(a, b):
    a = a.astype(np.float64).ravel(); b = b.astype(np.float64).ravel()
    a -= a.mean(); b -= b.mean()
    d = np.sqrt((a * a).sum() * (b * b).sum())
    return float((a * b).sum() / d) if d else 0.0


def stretch(img):
    """same display transform as silicon_emulator.save(): fftshift + 28 dB window + gamma 0.85."""
    full = np.fft.fftshift(img.astype(np.float64))
    db = 20.0 * np.log10(full + 1e-6)
    hi = np.percentile(db, 99.7); lo = hi - 28.0
    return (255 * np.clip((db - lo) / (hi - lo + 1e-9), 0, 1) ** 0.85).astype(np.uint8)


ORIENT = {"natural": lambda a: a, "transpose": lambda a: a.T, "flipud": lambda a: a[::-1],
          "fliplr": lambda a: a[:, ::-1], "rot180": lambda a: a[::-1, ::-1]}


def main():
    sil = load_silicon()
    gold = np.load(OUT / "centerfield_silmirror_deci1_mag.npy")
    if gold.shape != (G, G):
        gold = gold.reshape(G, G)
    print(f"silicon OUT: {sil.shape} peak={sil.max()} mean={sil.mean():.1f} "
          f"sat%={100*(sil>=0xFFFF).mean():.3f}")
    print(f"golden     : {gold.shape} peak={gold.max()} mean={gold.mean():.1f}")

    # primary: natural order. Also probe a few orientations as a sanity check.
    cands = {"natural": sil, "transpose": sil.T,
             "flipud": sil[::-1], "fliplr": sil[:, ::-1], "rot180": sil[::-1, ::-1]}
    print("\norientation vs golden (full-res, natural offset):")
    best = ("natural", corr(sil, gold))
    for name, v in cands.items():
        c = corr(v, gold)
        print(f"  {name:<10} corr = {c:+.4f}")
        if c > best[1]:
            best = (name, c)
    print(f">>> full-image corr (natural) = {corr(sil, gold):+.4f}   best = {best[0]} {best[1]:+.4f}")

    # --- speckle-suppressed scene match: 8x8 block-average both to 1024^2, then per-orientation
    #     phase-correlation to remove any fixed circular/linear offset (fftshift, DC-band edge). ---
    def blkmean(a, b=8):
        h, w = a.shape
        return a[:h//b*b, :w//b*b].astype(np.float64).reshape(h//b, b, w//b, b).mean((1, 3))

    def align_corr(a, g):
        """best corr of a vs g after the integer circular shift that maximizes phase correlation."""
        A = np.fft.fft2(a - a.mean()); Gc = np.fft.fft2(g - g.mean())
        R = A * np.conj(Gc); R /= np.abs(R) + 1e-9
        cc = np.fft.ifft2(R).real
        dy, dx = np.unravel_index(cc.argmax(), cc.shape)
        return corr(np.roll(a, (-dy, -dx), (0, 1)), g), (dy, dx)

    gd = blkmean(gold)
    print("\nspeckle-suppressed (8x8 block-avg, 1024^2), shift-aligned:")
    best2 = ("", -1, (0, 0))
    for name, v in cands.items():
        c, sh = align_corr(blkmean(np.ascontiguousarray(v)), gd)
        print(f"  {name:<10} aligned corr = {c:+.4f}  shift(dy,dx)={sh}")
        if c > best2[1]:
            best2 = (name, c, sh)
    print(f">>> best speckle-suppressed scene match = {best2[0]} corr {best2[1]:+.4f} shift {best2[2]}")

    # how much residual is speckle? sweep block size for the winning orientation.
    win = cands[best2[0]]
    print(f"\nspeckle sweep ({best2[0]}, aligned): more averaging -> closer to true scene match")
    for b in (4, 8, 16, 32):
        c, _ = align_corr(blkmean(np.ascontiguousarray(win), b), blkmean(gold, b))
        print(f"  block {b:>2}x{b:<2} ({G//b}^2)  aligned corr = {c:+.4f}")

    # render full silicon (winning display orientation) + side-by-side vs golden.
    # downsample to ~1600 px for the doc (8192^2 single-look speckle does not compress).
    sil_disp = ORIENT[best2[0]](sil)
    try:
        from PIL import Image
        def small(a, px=1600):
            im = Image.fromarray(stretch(a))
            return im.resize((px, px), Image.BILINEAR)
        small(sil_disp).save(DOCS / "img_silicon_full_deci1.png")
        s, g = small(sil_disp), small(gold)
        pair = Image.new("L", (s.width + 16 + g.width, s.height), 255)
        pair.paste(s, (0, 0)); pair.paste(g, (s.width + 16, 0))
        pair.save(DOCS / "img_silicon_full_vs_emu.png")
        print(f"\nwrote {DOCS/'img_silicon_full_deci1.png'} + img_silicon_full_vs_emu.png "
              f"(orientation: {best2[0]}, {1600}px)")
    except Exception as e:
        print(f"PIL render skipped: {e}")


if __name__ == "__main__":
    main()
