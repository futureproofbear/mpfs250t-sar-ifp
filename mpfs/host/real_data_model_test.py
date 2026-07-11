"""Run the fabric-vs-CPU BFP model on the REAL CPHD scene (not crafted phasors), at the board's
8192 grid, using the exact emulator resample. Answers: does the per-row-BFP+renormalize approach
reproduce the golden on the ACTUAL data the board fails on?

  CPU ~0.99 + FABRIC ~0.99 -> algorithm sound on real data; silicon corr~0 is an implementation bug.
  FABRIC << CPU            -> the approach fails on real data (unlike synthetic) -- found it in Python.
"""
import sys, numpy as np
sys.path.insert(0, "../../src"); sys.path.insert(0, ".")
import form_image_pfa as ref
from sar_pipeline import prepare_tables
from emulate_fabric import fabric_resample
import fixedpoint as fx
from model_fabric_fft import fft2_fabric_perrow_renorm, fft2_fabric_NORENORM, corr

GRID = int(sys.argv[1]) if len(sys.argv) > 1 else 8192
DECI = 8

print(f"opening CPHD {ref.LOCAL_CPHD.name} ...")
reader = ref.open_phase_history(str(ref.LOCAL_CPHD))
meta = reader.cphd_meta
tables = prepare_tables(reader, meta, DECI, DECI)
m, n = tables["dims"]; mu, nu = tables["deci"]
signal = np.asarray(reader.read_chip((0, tables["n_vec"], mu), (0, tables["n_samp"], nu), index=0), np.complex64)
reader.close()
sgn = tables.get("sgn", -1)
print(f"real scene {m}x{n} -> grid {GRID}x{GRID}, fwd sign {sgn}")

# exact board orchestration: 2-pass keystone resample at the fabric grid
g2 = fabric_resample(signal, tables, grid=GRID).astype(np.complex64)   # [range Np][cross Mp]
Np, Mp = g2.shape
ham_r = np.zeros(Np); ham_r[:n] = np.hamming(n)
ham_c = np.zeros(Mp); ham_c[:m] = np.hamming(m)
g2w = (g2 * np.outer(ham_r, ham_c)).astype(np.complex64)

# quantize windowed k-space to full-scale int16 codes (the fabric input quantizer)
lsb, _ = fx.fit_scale(g2w, 16)
codes = (np.floor(g2w.real / lsb) + 1j * np.floor(g2w.imag / lsb)).astype(np.complex64)
del g2, g2w

golden = np.abs(np.fft.fft2(codes))                            # float reference
print("running CPU model (global BFP) ...")
cpu, _ = fx.fft2_l1bfp(codes)
print("running FABRIC model (per-row BFP + renorm) ...")
fab, (emr, ema, er, ea) = fft2_fabric_perrow_renorm(codes)
print("running FABRIC NO-renorm (broken-capture case) ...")
nrn, (nr, na, ner, nea) = fft2_fabric_NORENORM(codes)

print("\n=== REAL SCENE, grid", GRID, "===")
print(f"  CPU (global BFP)          corr vs golden = {corr(golden, cpu):.4f}")
print(f"  FABRIC (per-row + renorm) corr vs golden = {corr(golden, fab):.4f}")
print(f"  FABRIC NO-renorm          corr vs golden = {corr(golden, nrn):.4f}")
print(f"  per-row exp spread: range={int(ner.max()-ner.min())}  azimuth={int(nea.max()-nea.min())}"
      f"  (emax r={emr} a={ema})")
print(f"  range exps: min={int(ner.min())} max={int(ner.max())} median={int(np.median(ner))}")
print(f"  azimuth exps: min={int(nea.min())} max={int(nea.max())} median={int(np.median(nea))}")
