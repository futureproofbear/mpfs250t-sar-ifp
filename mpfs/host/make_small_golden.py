"""Generate the 8192x8192 GOLDEN detected-magnitude image for a decimated scene,
using the EXACT fabric orchestration (emulate_fabric.fabric_resample) at the fabric
grid. This is the spec the board's sar_form_image OUT must match (up to orientation
+ magnitude scaling). Saves the full magnitude (float32 .npy), a small PNG thumbnail,
and prints where the image energy concentrates so we know which contiguous OUT band
to dump back from the board (the 128 MB full OUT is impractical over JTAG).

    python make_small_golden.py --in <cphd> --deci-pulse 8 --deci-sample 8 --grid 8192 --out jtag_stage_small
"""
import sys, argparse
from pathlib import Path
import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parents[1] / "src"))
import form_image_pfa as ref
from sar_pipeline import prepare_tables
from emulate_fabric import fabric_resample


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="inp", required=True)
    ap.add_argument("--deci-pulse", type=int, default=8)
    ap.add_argument("--deci-sample", type=int, default=8)
    ap.add_argument("--grid", type=int, default=8192)
    ap.add_argument("--out", default="jtag_stage_small")
    a = ap.parse_args()
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)

    reader = ref.open_phase_history(a.inp)
    meta = reader.cphd_meta
    tables = prepare_tables(reader, meta, a.deci_pulse, a.deci_sample)
    m, n = tables["dims"]; mu, nu = tables["deci"]
    signal = np.asarray(reader.read_chip((0, tables["n_vec"], mu),
                                         (0, tables["n_samp"], nu), index=0), np.complex64)
    reader.close()
    sgn = tables.get("sgn", -1)
    print(f"  dims {m}x{n} -> grid {a.grid}x{a.grid}")

    # exact fabric orchestration (2-pass keystone resample) at the fabric grid
    g2 = fabric_resample(signal, tables, grid=a.grid)         # [range Np][cross Mp]
    Np, Mp = g2.shape
    ham_r = np.zeros(Np); ham_r[:n] = np.hamming(n)           # data-extent tapers, zero in pad
    ham_c = np.zeros(Mp); ham_c[:m] = np.hamming(m)
    g2w = g2 * np.outer(ham_r, ham_c)
    fwd = np.fft.fft2 if sgn < 0 else np.fft.ifft2
    mag = np.abs(fwd(g2w)).astype(np.float32)                 # plain 2-D FFT + detect, no shifts

    np.save(out / "golden_small_mag.npy", mag)
    # energy map: where is the image content? (per 512-row band, so we pick a dump band)
    B = 512
    band_energy = mag.reshape(mag.shape[0] // B, B, mag.shape[1]).sum(axis=(1, 2))
    top = int(np.argmax(band_energy))
    pk = np.unravel_index(int(np.argmax(mag)), mag.shape)
    print(f"  mag: min={mag.min():.3g} max={mag.max():.3g} mean={mag.mean():.3g}")
    print(f"  peak @ (row={pk[0]}, col={pk[1]})")
    print(f"  brightest 512-row band = rows [{top*B}:{(top+1)*B}]  (energy {band_energy[top]:.3g})")
    print(f"  band energy by 512-row block: {np.round(band_energy/band_energy.max(),2)}")

    # thumbnail (downsample 16x -> 512x512) for a quick visual, log-scaled
    th = mag[::16, ::16]
    thl = np.log1p(th / (th.mean() + 1e-9))
    thl = (255 * (thl - thl.min()) / (np.ptp(thl) + 1e-9)).astype(np.uint8)
    try:
        from PIL import Image
        Image.fromarray(thl).save(out / "golden_small_thumb.png")
        print(f"  wrote {out}/golden_small_thumb.png (512x512 log thumb)")
    except Exception as e:
        np.save(out / "golden_small_thumb.npy", thl)
        print(f"  (PIL unavailable: {e}) wrote golden_small_thumb.npy")
    print(f"  wrote {out}/golden_small_mag.npy  ({mag.nbytes/1e6:.0f} MB, {Np}x{Mp} float32)")


if __name__ == "__main__":
    main()
