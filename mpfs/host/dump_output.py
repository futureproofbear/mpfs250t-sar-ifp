"""Off-board (host PC) readback stage of the JTAG-batch SAR pipeline.

Three jobs, all GUI-free except the optional preview PNG which is written off-board
(rasterio/pyproj/matplotlib live here on the host, never on the SoC):

  gen-dump   : emit a debugger script that dumps the OUT buffer (and, for a
               loopback test, the SIG buffer) from DDR to a file over JTAG.
  loopback   : CRC-check a dumped SIG buffer against layout.json -- proves the
               JTAG load/dump round-trip and DDR integrity before any fabric
               exists (Milestone 0).
  readback   : reshape a dumped OUT buffer to the padded grid, rescale by the
               board-reported BFP_SHIFT, write a preview PNG + stats, and
               optionally compare against the numpy golden (correlation/PSLR).

  make-golden: run the verified numpy reference (form_image_pfa.pfa) to produce
               the golden magnitude image for the readback comparison.

Usage:
    python dump_output.py gen-dump   --stage jtag_stage [--loopback]
    python dump_output.py loopback   --stage jtag_stage --file sig_dump.bin
    python dump_output.py make-golden --in <scene>_CPHD.cphd --stage jtag_stage
    python dump_output.py readback   --stage jtag_stage --file out.bin \
                                     --bfp-shift N [--out-dtype uint16|uint8] \
                                     [--golden golden.npy]
"""
import sys
import json
import argparse
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parents[1] / "src"))

import ddr_layout as L                   # noqa: E402


def _load_layout(stage):
    return json.loads((Path(stage) / "layout.json").read_text())


# --------------------------------------------------------------------------- #
def gen_dump(stage, loopback=False):
    """Write a GDB script that dumps OUT (and SIG, if loopback) from DDR."""
    lay = _load_layout(stage)
    stage = Path(stage)
    lines = ["# dump SAR buffers from DDR over JTAG (run after STATUS.DONE)"]
    out_sz = lay["sizes"]["out_uint16"]
    out_a = L.OUT_ADDR
    lines.append(f"dump binary memory {stage/'out.bin'} 0x{out_a:08X} 0x{out_a + out_sz:08X}")
    if loopback:
        sig_a, sig_sz = L.SIG_ADDR, lay["sizes"]["sig"]
        lines.append(f"dump binary memory {stage/'sig_dump.bin'} "
                     f"0x{sig_a:08X} 0x{sig_a + sig_sz:08X}")
    script = stage / "dump.gdb"
    script.write_text("\n".join(lines) + "\n")
    print(f"  wrote {script}")
    print(f"  dump with:  (gdb) source {script}")


# --------------------------------------------------------------------------- #
def loopback(stage, dumped_file):
    """Verify a DDR-dumped SIG buffer matches what serialize_inputs wrote."""
    lay = _load_layout(stage)
    data = Path(dumped_file).read_bytes()
    exp_sz = lay["sizes"]["sig"]
    if len(data) != exp_sz:
        print(f"  FAIL size: got {len(data)} expected {exp_sz}")
        return False
    got, exp = L.crc32(data), lay["crc32"]["sig"]
    ok = got == exp
    print(f"  CRC32 sig: got 0x{got:08X} expected 0x{exp:08X}  -> "
          f"{'PASS' if ok else 'FAIL'}")
    return ok


# --------------------------------------------------------------------------- #
def make_golden(cphd_path, stage):
    """Numpy reference golden: focus the CPHD and save |img| on the padded grid."""
    import form_image_pfa as ref
    from sar_pipeline import prepare_tables
    reader = ref.open_phase_history(str(cphd_path))
    meta = reader.cphd_meta
    tables = prepare_tables(reader, meta)
    mu, nu = tables["deci"]
    signal = np.asarray(
        reader.read_chip((0, tables["n_vec"], mu), (0, tables["n_samp"], nu), index=0),
        dtype=np.complex64)
    reader.close()
    img, _ = ref.pfa(signal, tables["freq"], tables["ax"], tables["ay"], tables["sgn"])
    mag = np.abs(img).astype(np.float32)
    out = Path(stage) / "golden.npy"
    np.save(out, mag)
    print(f"  wrote {out}  shape={mag.shape}")
    return mag


def make_golden_fixed(cphd_path, stage, deci_pulse=1, deci_sample=1):
    """Full fixed-point 2-D oracle (resample->window->FFT->detect, all quantized)
    via fixedpoint.focus_full_fixed -- closer to what the fabric computes than the
    float golden, so the fabric output can be checked bit-for-bit-ish (tolerance).

    NOTE: scalar NumPy BFP at full 8192^2 is slow (minutes). For bring-up, decimate
    (e.g. --deci-pulse 8 --deci-sample 8) and serialize the SAME decimation so the
    fabric frame and this golden have matching dims."""
    import form_image_pfa as ref
    import fixedpoint as fx
    from sar_pipeline import prepare_tables
    reader = ref.open_phase_history(str(cphd_path))
    meta = reader.cphd_meta
    tables = prepare_tables(reader, meta, deci_pulse, deci_sample)
    mu, nu = tables["deci"]
    signal = np.asarray(
        reader.read_chip((0, tables["n_vec"], mu), (0, tables["n_samp"], nu), index=0),
        dtype=np.complex64)
    reader.close()
    mag, _geo, exps = fx.focus_full_fixed(signal, tables["freq"], tables["ax"], tables["ay"])
    out = Path(stage) / "golden_fixed.npy"
    np.save(out, mag)
    print(f"  wrote {out}  shape={mag.shape}  "
          f"BFP guard r/a={exps[0][-1]-exps[0][0]}/{exps[1][-1]-exps[1][0]}")
    return mag


# --------------------------------------------------------------------------- #
def _pslr_db(mag):
    """Peak-to-sidelobe ratio of the brightest point target (quick quality check)."""
    r, c = np.unravel_index(np.argmax(mag), mag.shape)
    peak = mag[r, c]
    r0, r1 = max(0, r - 16), min(mag.shape[0], r + 17)
    c0, c1 = max(0, c - 16), min(mag.shape[1], c + 17)
    win = mag[r0:r1, c0:c1].copy()
    pr, pc = r - r0, c - c0
    win[max(0, pr - 2):pr + 3, max(0, pc - 2):pc + 3] = 0   # null the mainlobe
    side = win.max()
    return 20 * np.log10(side / (peak + 1e-30) + 1e-30)


def readback(stage, dumped_file, bfp_shift, out_dtype="uint16", golden=None,
             preview=True):
    """Reshape OUT, rescale by BFP_SHIFT, write stats + preview, compare to golden.

    The fabric writes OUT range-major as (R, A) from a PLAIN (un-centered) 2-D
    FFT. To match the float golden's centered (azimuth, range) image we apply
    fftshift + transpose -- emulate_fabric.py determines this recipe exactly
    (corr 0.9999998 vs the float golden; transpose-only or shift-only give ~0.7).
    """
    lay = _load_layout(stage)
    A, R = lay["fft_len"]["A"], lay["fft_len"]["R"]
    np_dtype = np.uint16 if out_dtype == "uint16" else np.uint8
    raw = np.frombuffer(Path(dumped_file).read_bytes(), dtype=np_dtype)
    if raw.size != A * R:
        print(f"  WARN: {raw.size} samples != {R}x{A}={A*R}; truncating/padding")
        raw = np.resize(raw, A * R)
    # OUT (R, A) plain-FFT range-major -> fftshift + transpose -> golden (A, R)
    mag = np.fft.fftshift(raw.reshape(R, A).T).astype(np.float32) * (2.0 ** int(bfp_shift))

    print(f"  OUT {A}x{R} {out_dtype}  bfp_shift={bfp_shift}")
    print(f"  min={mag.min():.3g} max={mag.max():.3g} "
          f"p99.7={np.percentile(mag, 99.7):.3g}  PSLR={_pslr_db(mag):.1f} dB")

    if golden:
        from fixedpoint import compare
        ref_mag = np.load(golden)
        if ref_mag.shape != mag.shape:
            print(f"  WARN golden {ref_mag.shape} != OUT {mag.shape}; skipping compare")
        else:
            c = compare(ref_mag, mag)
            print(f"  vs golden: corr={c['corr']:.4f} SNR={c['snr_db']:.1f} dB "
                  f"ENOB={c['enob']:.2f} DR={c['dr_test_db']:.1f}/{c['dr_ref_db']:.1f} dB")

    if preview:
        try:
            import matplotlib
            matplotlib.use("Agg")
            import matplotlib.pyplot as plt
            hi = np.percentile(mag, 99.7)
            disp = np.clip(mag / (hi + 1e-12), 0, 1)
            png = Path(stage) / "out_preview.png"
            plt.imsave(png, disp, cmap="gray")
            print(f"  wrote {png}")
        except Exception as e:
            print(f"  (preview skipped: {e})")
    return mag


# --------------------------------------------------------------------------- #
def main():
    ap = argparse.ArgumentParser(description="Read back / verify SAR DDR buffers")
    sub = ap.add_subparsers(dest="cmd", required=True)

    g = sub.add_parser("gen-dump"); g.add_argument("--stage", default="jtag_stage")
    g.add_argument("--loopback", action="store_true")

    lb = sub.add_parser("loopback"); lb.add_argument("--stage", default="jtag_stage")
    lb.add_argument("--file", required=True)

    mg = sub.add_parser("make-golden"); mg.add_argument("--in", dest="inp", required=True)
    mg.add_argument("--stage", default="jtag_stage")

    mgf = sub.add_parser("make-golden-fixed"); mgf.add_argument("--in", dest="inp", required=True)
    mgf.add_argument("--stage", default="jtag_stage")
    mgf.add_argument("--deci-pulse", type=int, default=1)
    mgf.add_argument("--deci-sample", type=int, default=1)

    rb = sub.add_parser("readback"); rb.add_argument("--stage", default="jtag_stage")
    rb.add_argument("--file", required=True)
    rb.add_argument("--bfp-shift", type=int, required=True)
    rb.add_argument("--out-dtype", default="uint16", choices=["uint16", "uint8"])
    rb.add_argument("--golden", default=None)
    rb.add_argument("--no-preview", action="store_true")

    a = ap.parse_args()
    if a.cmd == "gen-dump":
        gen_dump(a.stage, a.loopback)
    elif a.cmd == "loopback":
        ok = loopback(a.stage, a.file)
        sys.exit(0 if ok else 1)
    elif a.cmd == "make-golden":
        make_golden(a.inp, a.stage)
    elif a.cmd == "make-golden-fixed":
        make_golden_fixed(a.inp, a.stage, a.deci_pulse, a.deci_sample)
    elif a.cmd == "readback":
        readback(a.stage, a.file, a.bfp_shift, a.out_dtype, a.golden,
                 preview=not a.no_preview)


if __name__ == "__main__":
    main()
