"""Off-board (host PC) stage of the JTAG-batch SAR pipeline.

Parses a CPHD, builds the resample/geometry tables, quantizes the raw signal to
16-bit block-floating-point I/Q, and writes fixed-layout binaries plus a
debugger script that loads them into DDR over JTAG. The bare-metal app + FPGA
fabric then form the image into the OUT buffer; dump_output.py reads it back.

All the irregular work (sarpy parse, PVP geometry, resample-coefficient
generation) stays here on the host -- the board never parses a CPHD. This is the
GUI-free, no-network, no-SD workflow: the only board link is the debugger.

Fabric-loaded outputs (default ./jtag_stage/), in the resample kernel's format:
    sig.bin      int16 interleaved I/Q, raw signal (M*N*2 samples)   -> SIG_ADDR
    rs_idx1.bin  int32  pass-1 (range) gather indices  (M*N)         -> RS_COEF_BASE
    rs_wq1.bin   int16  pass-1 Q15 interp weights      (M*N)
    rs_idx2.bin  int32  pass-2 (azimuth) gather indices(N*M)
    rs_wq2.bin   int16  pass-2 Q15 interp weights      (N*M)
    rs_order.bin int32  pulse permutation for pass 2   (M)
    win.bin      int16  full 2-D Hamming taper, Q15, row-major (M*N) (window kernel)
    job.bin      96-byte job descriptor                              -> JOB_ADDR
    layout.json  dims, FFT lengths, addresses+sizes+CRCs, BFP scale, geocode, coeff corr
    load.gdb     'restore <bin> binary <addr>' for each buffer (SoftConsole GDB)
Also written for off-board geocode/debug only (not loaded to the board): kr/kc/tanphi.bin.

Usage:
    python serialize_inputs.py --in <scene>_CPHD.cphd [--out jtag_stage]
                               [--deci-pulse K] [--deci-sample K]
"""
import sys
import json
import argparse
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parents[1] / "src"))

import math                             # noqa: E402
import form_image_pfa as ref            # noqa: E402
from sar_pipeline import prepare_tables  # noqa: E402
import ddr_layout as L                   # noqa: E402

_C = getattr(ref, "C", 299792458.0)


def interp_coeffs(query, xp):
    """Quantize a 1-D linear resample to the fabric resample kernel's contract:

        out[i] = in[idx[i]] + (in[idx[i]+1] - in[idx[i]]) * wq[i]/32768

    Returns (idx int32, wq int16 Q15) with idx in xp's NATURAL (DDR) order so the
    kernel can index its input row directly. Out-of-range queries map to idx=-1
    (the kernel zero-fills, matching np.interp left=0/right=0). xp may be ascending
    or descending. Verified against np.interp to <0.05 LSB over random cases.
    """
    xp = np.asarray(xp, float)
    query = np.asarray(query, float)
    n = xp.size
    asc = xp[-1] >= xp[0]
    xa = xp if asc else xp[::-1]                  # ascending view for searchsorted
    k = np.searchsorted(xa, query) - 1           # xa[k] <= query < xa[k+1]
    valid = (k >= 0) & (k < n - 1)
    kk = np.clip(k, 0, n - 2)
    frac_a = (query - xa[kk]) / (xa[kk + 1] - xa[kk])
    if asc:
        idx = kk.astype(np.int64)
        wq = frac_a
    else:                                         # map ascending bracket back to natural order
        idx = (n - 2 - kk).astype(np.int64)
        wq = 1.0 - frac_a                         # measured from the lower natural endpoint
    idx = np.where(valid, idx, -1).astype(np.int32)
    wqi = np.where(valid, np.clip(np.round(wq * 32768.0), 0, 32767), 0).astype(np.int16)
    return idx, wqi


def resample_coeffs(tables):
    """2-pass polar->Cartesian keystone resample coefficients, computed with the
    SAME geometry as form_image_pfa.resample_kspace so the fabric matches the
    verified float pipeline. Returns idx1/wq1 (pass 1, range, M x N), idx2/wq2
    (pass 2, azimuth, N x M) and the pulse permutation `order` (argsort tan_phi).
    """
    ax, ay, freq = tables["ax"], tables["ay"], tables["freq"]
    KR, KC, tan_phi = tables["KR"], tables["KC"], tables["tan_phi"]
    m, n = tables["dims"]

    kmag = 2.0 * freq / _C
    dx, dy = ax.mean(), ay.mean()
    dn = math.hypot(dx, dy)
    pr = ax * (dx / dn) + ay * (dy / dn)
    kr = kmag * pr[:, None]                       # (M,N) per-pulse range-wavenumber

    idx1 = np.empty((m, n), np.int32)
    wq1 = np.empty((m, n), np.int16)
    for i in range(m):
        idx1[i], wq1[i] = interp_coeffs(KR, kr[i])

    order = np.argsort(tan_phi).astype(np.int32)  # monotonic source coords for pass 2
    tan_s = tan_phi[order]
    idx2 = np.empty((n, m), np.int32)
    wq2 = np.empty((n, m), np.int16)
    for j in range(n):
        idx2[j], wq2[j] = interp_coeffs(KC, KR[j] * tan_s)

    return {"idx1": idx1, "wq1": wq1, "idx2": idx2, "wq2": wq2, "order": order}


def _check_coeffs(signal, coeffs, ref_g2):
    """Apply the quantized coefficients in numpy and correlate against the float
    reference k-space, so emitted tables are trusted before they ever hit DDR."""
    def apply1(fp, idx, wq):
        out = np.zeros(idx.shape, complex)
        v = idx >= 0
        j = np.clip(idx, 0, fp.size - 2)
        lerp = fp[j] + (fp[j + 1] - fp[j]) * (wq.astype(float) / 32768.0)
        out[v] = lerp[v]
        return out
    m, n = signal.shape
    g1 = np.empty((m, n), complex)
    for i in range(m):
        g1[i] = apply1(signal[i], coeffs["idx1"][i], coeffs["wq1"][i])
    g1s = g1[coeffs["order"]]
    g2 = np.empty((m, n), complex)
    for j in range(n):
        g2[:, j] = apply1(g1s[:, j], coeffs["idx2"][j], coeffs["wq2"][j])
    a, b = g2.ravel(), ref_g2.ravel()
    return abs(np.vdot(a, b)) / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-30)


def serialize(cphd_path, out_dir, deci_pulse=1, deci_sample=1, grid=0):
    cphd_path, out_dir = Path(cphd_path), Path(out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    L.assert_fits()

    reader = ref.open_phase_history(str(cphd_path))
    meta = reader.cphd_meta
    assert meta.Global.DomainType == "FX", "expects FX-domain CPHD"

    tables = prepare_tables(reader, meta, deci_pulse, deci_sample)
    m, n = tables["dims"]
    mu, nu = tables["deci"]
    if max(m, n) > L.GRID_MAX:
        raise ValueError(f"scene {m}x{n} exceeds GRID_MAX {L.GRID_MAX}; "
                         f"decimate or raise GRID_MAX (and buffer sizes).")
    # FFT padded grid. The fabric CoreFFT is FIXED at 8192 (firmware SAR_GRID), so the
    # tables MUST target the fabric grid, not the scene's natural pow2. `grid` forces it
    # (use L.GRID_MAX for the on-silicon fabric); grid=0 keeps the legacy per-scene pow2.
    Mp = grid or L.pow2(m)                # azimuth (pulses) grid
    Np = grid or L.pow2(n)                # range (samples) grid
    print(f"  dims (M x N) = {m} x {n}  -> FFT grid {Mp} x {Np}"
          f"{'  (forced to fabric grid)' if grid else ''}")

    signal = np.asarray(
        reader.read_chip((0, tables["n_vec"], mu), (0, tables["n_samp"], nu), index=0),
        dtype=np.complex64)
    reader.close()

    # --- quantize the raw signal to 16-bit BFP I/Q (what the fabric consumes) --
    codes, lsb, exp = L.quantize_iq16(signal)
    sig_bytes = codes.tobytes()
    (out_dir / "sig.bin").write_bytes(sig_bytes)

    # --- resample geometry for ON-MSS coefficient generation -------------------
    # The board computes the (large, per-line) idx/wq on the fly from this small
    # geometry, so we never stage/transfer the ~768 MB full-grid coefficients.
    # First self-check: the SAME geometry, run through the verified host coeff path,
    # must reproduce the float k-space (corr~1.0) -- proves what the MSS will do.
    coeffs = resample_coeffs(tables)
    _saved = ref.WINDOW
    try:
        ref.WINDOW = False     # compare resample-only (the window kernel adds the taper)
        g2_ref, _ = ref.resample_kspace(signal, tables["freq"], tables["ax"], tables["ay"])
    finally:
        ref.WINDOW = _saved
    corr = _check_coeffs(signal, coeffs, g2_ref)
    print(f"  resample-geometry self-check vs float k-space: corr={corr:.6f}")
    if corr < 0.999:
        raise RuntimeError(f"resample geometry diverges from reference (corr={corr:.4f})")

    # Np, Mp already set above (fabric grid when forced, else per-scene pow2)
    freq, ax, ay = tables["freq"], tables["ax"], tables["ay"]
    f0 = freq[:, 0].astype(np.float32)                       # freq[i,j] = f0[i] + j*df[i]
    df = (freq[:, 1] - freq[:, 0]).astype(np.float32)
    dx, dy = ax.mean(), ay.mean(); dn = np.hypot(dx, dy)
    pr = (ax * (dx / dn) + ay * (dy / dn)).astype(np.float32)
    tan_phi = np.asarray(tables["tan_phi"])
    order = np.argsort(tan_phi)
    tan_s = tan_phi[order].astype(np.float32)                # pass-2 source scale (sorted)
    inv_order = np.argsort(order).astype(np.int32)           # pass-1 dst row (-> tan_phi sorted)
    # padded query grids: real grid in [0:n], then out-of-range so the kernel
    # zero-fills the FFT zero-pad region (idx=-1).
    KR = np.asarray(tables["KR"], float); KC = np.asarray(tables["KC"], float)
    oob_r = float(KR.max() + (KR.max() - KR.min()) + 1.0)
    oob_c = float(KC.max() + (KC.max() - KC.min()) + 1.0)
    KRp = np.full(Np, oob_r, np.float32); KRp[:n] = KR
    KCp = np.full(Mp, oob_c, np.float32); KCp[:m] = KC
    # 1-D Hamming tapers (Q15); the window kernel forms the 2-D product on the fly.
    # The taper spans the DATA extent (n range, m cross) and is ZERO in the FFT
    # zero-pad region -- emulate_fabric.py shows this is what matches the golden.
    hr = np.zeros(Np); hr[:n] = np.hamming(n)
    hc = np.zeros(Mp); hc[:m] = np.hamming(m)
    hamr = np.clip(np.round(hr * 32768.0), 0, 32767).astype(np.int16)
    hamc = np.clip(np.round(hc * 32768.0), 0, 32767).astype(np.int16)

    geom = {"f0": (f0, L.F0_ADDR), "df": (df, L.DF_ADDR), "pr": (pr, L.PR_ADDR),
            "tans": (tan_s, L.TANS_ADDR), "invorder": (inv_order, L.INVORDER_ADDR),
            "krgrid": (KRp, L.KRGRID_ADDR), "kcgrid": (KCp, L.KCGRID_ADDR),
            "hamr": (hamr, L.HAMR_ADDR), "hamc": (hamc, L.HAMC_ADDR)}
    geo_addr, geo_size, geo_crc = {}, {}, {}
    for name, (arr, addr) in geom.items():
        b = arr.tobytes()
        (out_dir / f"{name}.bin").write_bytes(b)
        geo_addr[name], geo_size[name], geo_crc[name] = addr, len(b), L.crc32(b)

    # small float geometry kept on disk for off-board geocode/debug (not fabric-loaded)
    np.asarray(tables["KR"], np.float32).tofile(out_dir / "kr.bin")
    np.asarray(tables["KC"], np.float32).tofile(out_dir / "kc.bin")
    np.asarray(tables["tan_phi"], np.float32).tofile(out_dir / "tanphi.bin")

    # --- layout / contract for the board and for dump_output ------------------
    geo = tables["geo"]
    layout = {
        "scene": cphd_path.stem,
        "dims": {"M": m, "N": n},
        "fft_len": {"R": Np, "A": Mp},
        "deci": {"pulse": mu, "sample": nu},
        "bfp_input": {"lsb": lsb, "exp": exp},   # value = code * lsb
        "addr": dict({
            "SIG": L.SIG_ADDR, "OUT": L.OUT_ADDR,
            "SCRATCH": L.SCRATCH_ADDR, "JOB": L.JOB_ADDR,
        }, **geo_addr),                         # f0/df/pr/tans/invorder/kr/kc/ham bases
        "sizes": dict({"sig": len(sig_bytes),
                       # OUT holds the focused image on the padded grid (A x R)
                       "out_uint16": Mp * Np * 2}, **geo_size),
        "crc32": dict({"sig": L.crc32(sig_bytes)}, **geo_crc),
        "resample": {"corr_vs_float": round(float(corr), 6), "order_len": int(m),
                     "coeffs": "computed on-MSS per line from this geometry"},
        # geometry kept for off-board geocode / GeoTIFF in dump_output (optional)
        "geocode": {
            "dc": geo["dc"], "dr": geo["dr"],
            "dhat": list(geo["dhat"]), "chat": list(geo["chat"]),
            "center_ecef": [float(v) for v in tables["center_ecef"]],
            "uiax": [float(v) for v in tables["uiax"]],
            "uiay": [float(v) for v in tables["uiay"]],
        },
    }
    (out_dir / "layout.json").write_text(json.dumps(layout, indent=2))

    # --- job descriptor the bare-metal app reads from DDR ----------------------
    job = L.pack_job(M=m, N=n, fft_r=Np, fft_a=Mp,
                     out_dtype=L.OUT_DTYPE_UINT16, bfp_in_exp=exp,
                     sig_len=len(sig_bytes), sig_crc=L.crc32(sig_bytes))
    (out_dir / "job.bin").write_bytes(job)

    # --- JTAG load script (SoftConsole / RISC-V GDB) --------------------------
    # Loads only the signal + small resample geometry + tapers + job (the MSS
    # computes the per-line coefficients from the geometry on the fly).
    gdb = ["# load SAR inputs into DDR over JTAG, then `continue` the bare-metal app",
           f"restore sig.bin binary 0x{L.SIG_ADDR:08X}"]
    for name in geom:
        gdb.append(f"restore {name}.bin binary 0x{geo_addr[name]:08X}")
    gdb.append(f"restore job.bin binary 0x{L.JOB_ADDR:08X}")
    (out_dir / "load.gdb").write_text("\n".join(gdb) + "\n")

    print(f"  wrote {out_dir}/  (sig {len(sig_bytes)/1e6:.0f} MB, lsb={lsb:g} exp={exp})")
    print(f"  load with:  (gdb) source {out_dir/'load.gdb'}")
    return layout


def main():
    ap = argparse.ArgumentParser(description="Serialize CPHD -> DDR binaries + JTAG load script")
    ap.add_argument("--in", dest="inp", required=True, help="a *_CPHD.cphd file")
    ap.add_argument("--out", default="jtag_stage", help="output dir for binaries")
    ap.add_argument("--deci-pulse", type=int, default=1)
    ap.add_argument("--deci-sample", type=int, default=1)
    ap.add_argument("--grid", type=int, default=0,
                    help="force the padded FFT grid (e.g. 8192 for the on-silicon fabric); "
                         "0 = legacy per-scene next-pow2")
    a = ap.parse_args()
    serialize(a.inp, a.out, a.deci_pulse, a.deci_sample, a.grid)


if __name__ == "__main__":
    main()
