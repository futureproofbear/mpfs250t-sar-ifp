"""Numpy emulation of the EXACT fabric/MSS SAR datapath orchestration.

Purpose: validate the on-board orchestration -- per-line keystone resample with
MSS-computed (quantized) idx/wq, pulse reorder via inv_order, corner-turn
transpose between passes, 2-D Hamming window, 2-D FFT, detect -- reproduces the
float reference image BEFORE any hardware. This is the spec the C sequencer +
HLS kernels must match (esp. the output orientation).

The FFT/detect themselves are taken from the float reference (form_image_pfa) so
this isolates the *orchestration* (resample passes + reorder + transpose + window
layout); BFP fixed-point fidelity is validated separately in fixedpoint.py.

    python emulate_fabric.py --in <scene>_CPHD.cphd [--deci-pulse K --deci-sample K]
"""
import sys, argparse, math
from pathlib import Path
import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parents[1] / "src"))
import form_image_pfa as ref            # noqa: E402
from sar_pipeline import prepare_tables  # noqa: E402
from serialize_inputs import interp_coeffs  # verified quantizer  # noqa: E402

_C = getattr(ref, "C", 299792458.0)


def _apply(fp, idx, wq):
    """fabric lerp: out = fp[idx] + (fp[idx+1]-fp[idx])*wq/32768 ; idx<0 -> 0."""
    out = np.zeros(idx.shape, complex)
    v = idx >= 0
    j = np.clip(idx, 0, fp.size - 2)
    lerp = fp[j] + (fp[j + 1] - fp[j]) * (wq.astype(float) / 32768.0)
    out[v] = lerp[v]
    return out


def fabric_resample(signal, tables, grid=0):
    """Mirror sar_sequencer.c::resample_2pass exactly (orchestration, float data).
    `grid` forces the padded FFT grid (8192 for the on-silicon fabric); 0 = per-scene pow2."""
    m, n = signal.shape
    Mp, Np = (grid or ref_pow2(m)), (grid or ref_pow2(n))
    ax, ay, freq = tables["ax"], tables["ay"], tables["freq"]
    KR, KC, tan_phi = np.asarray(tables["KR"]), np.asarray(tables["KC"]), np.asarray(tables["tan_phi"])

    # --- geometry exactly as serialize_inputs emits for the MSS ---------------
    f0 = freq[:, 0].astype(np.float32)
    df = (freq[:, 1] - freq[:, 0]).astype(np.float32)
    dx, dy = ax.mean(), ay.mean(); dn = math.hypot(dx, dy)
    pr = (ax * (dx / dn) + ay * (dy / dn)).astype(np.float32)
    order = np.argsort(tan_phi)
    tan_s = tan_phi[order].astype(np.float32)
    inv_order = np.argsort(order)
    oob_r = float(KR.max() + (KR.max() - KR.min()) + 1.0)
    oob_c = float(KC.max() + (KC.max() - KC.min()) + 1.0)
    KRp = np.full(Np, oob_r, np.float32); KRp[:n] = KR
    KCp = np.full(Mp, oob_c, np.float32); KCp[:m] = KC

    # --- PASS 1 (range), per pulse -> SCRATCH[inv_order[i]] (pulse-sorted) -----
    scratch = np.zeros((Mp, Np), complex)
    for i in range(m):
        kr_i = (2.0 * pr[i] / _C) * (f0[i] + np.arange(n) * df[i])  # source positions
        idx, wq = interp_coeffs(KRp, kr_i)
        scratch[inv_order[i]] = _apply(signal[i], idx, wq)
    # rows m..Mp-1 stay zero (padding)

    # --- transpose SCRATCH(Mp x Np) -> SIG(Np x Mp) ---------------------------
    sig_t = scratch.T.copy()                                  # [range][cross]

    # --- PASS 2 (azimuth), per range bin -> g2[range][cross] ------------------
    g2 = np.zeros((Np, Mp), complex)
    for j in range(Np):
        src = KRp[j] * tan_s                                  # M sorted source positions
        idx, wq = interp_coeffs(KCp, src)
        g2[j] = _apply(sig_t[j, :m], idx, wq)
    return g2  # NOTE: layout is [range][cross] == transpose of resample_kspace's g2


def ref_pow2(x):
    return 1 << (int(x) - 1).bit_length()


def main():
    ap = argparse.ArgumentParser(description="Emulate the fabric SAR datapath vs the float golden")
    ap.add_argument("--in", dest="inp", required=True)
    ap.add_argument("--deci-pulse", type=int, default=1)
    ap.add_argument("--deci-sample", type=int, default=1)
    a = ap.parse_args()

    reader = ref.open_phase_history(a.inp)
    meta = reader.cphd_meta
    tables = prepare_tables(reader, meta, a.deci_pulse, a.deci_sample)
    m, n = tables["dims"]; mu, nu = tables["deci"]
    signal = np.asarray(reader.read_chip((0, tables["n_vec"], mu),
                                         (0, tables["n_samp"], nu), index=0), np.complex64)
    reader.close()
    geo, sgn = tables["geo"], tables.get("sgn", -1)
    print(f"  dims {m}x{n} -> grid {ref_pow2(m)}x{ref_pow2(n)}")

    # --- golden: float reference (resample_kspace already windows) -------------
    g2_ref, geo_full = ref.resample_kspace(signal, tables["freq"], tables["ax"], tables["ay"])
    img_ref, _ = ref.focus(g2_ref, geo_full, sgn)
    mag_ref = np.abs(img_ref)

    # --- fabric: orchestrated resample + 2-D Hamming, then a PLAIN FFT (what
    #     CoreFFT actually does -- no ifftshift/fftshift centering) -------------
    g2_fab = fabric_resample(signal, tables)              # [range j][cross k] (transposed)
    Np, Mp = g2_fab.shape
    ham_r = np.zeros(Np); ham_r[:n] = np.hamming(n)       # data-extent tapers, zero in pad
    ham_c = np.zeros(Mp); ham_c[:m] = np.hamming(m)
    g2_fab_w = g2_fab * np.outer(ham_r, ham_c)
    fwd = np.fft.fft2 if sgn < 0 else np.fft.ifft2
    mag_fab = np.abs(fwd(g2_fab_w))                       # plain 2-D FFT, no shifts

    # find the host post-processing (transpose? fftshift?) that recovers the golden
    def corr(a, b):
        a, b = a.ravel(), b.ravel()
        return float(abs(np.vdot(a, b)) / (np.linalg.norm(a) * np.linalg.norm(b) + 1e-30))
    cands = {
        "identity":            mag_fab,
        "transpose":           mag_fab.T,
        "fftshift":            np.fft.fftshift(mag_fab),
        "fftshift+transpose":  np.fft.fftshift(mag_fab).T,
        "transpose+fftshift":  np.fft.fftshift(mag_fab.T),
    }
    best_name, best_c = None, -1.0
    for name, cand in cands.items():
        c = corr(cand, mag_ref)
        print(f"  fabric (plain FFT) -> {name:20s} corr={c:.6f}")
        if c > best_c:
            best_name, best_c = name, c
    print(f"  BEST host post-processing = '{best_name}'  corr={best_c:.6f}  "
          + ("VALID" if best_c > 0.99 else "MISMATCH"))
    return 0 if best_c > 0.99 else 1


if __name__ == "__main__":
    raise SystemExit(main())
