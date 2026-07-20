"""Analyze the per-stage bright-band dumps from flow_pipe_trace_run.gdb (fabric mode) to find WHERE
the magnitude saturates. SCRATCH = range-FFT/corner-turn out (complex), SIG = azimuth-FFT out
(complex, = detect input), OUT = detected |.| (uint16). If SIG peak is near full int16 (~32767),
detect sqrt(I^2+Q^2) overflows uint16 -> the fix is more pre-detect right-shift (headroom)."""
import numpy as np, os

# scratch dir: $SAR_SCRATCH if the shell env set it, else <repo-root>/scratch
_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
D = os.environ.get("SAR_SCRATCH", os.path.join(_root, "scratch")) + "/trace_fab/"

def cplx(path):
    raw = np.fromfile(path, dtype=np.uint32)
    re = (raw >> 16).astype(np.int16).astype(np.float64)
    im = (raw & 0xFFFF).astype(np.int16).astype(np.float64)
    return np.abs(re + 1j*im)

def stage(name, mag, full):
    sat = 100.0 * (mag >= full*0.98).mean()
    print(f"  {name:26} peak|.|={mag.max():8.0f}  mean={mag.mean():8.1f}  median={np.median(mag):7.0f}  "
          f"sat(>={int(full*0.98)})={sat:5.1f}%   [int16 full={32767 if 'OUT' not in name else 65535}]")

print("=== per-stage magnitude (fabric mode=1, headroom=0) ===")
try:
    stage("SCRATCH (range/cornerturn)", cplx(D+"trace_scratch.bin"), 32767)
    stage("SIG (azimuth = detect in)",  cplx(D+"trace_sig.bin"),     32767)
    out = np.fromfile(D+"trace_out.bin", dtype=np.uint16).astype(np.float64)
    sat = 100.0*(out >= 65535*0.98).mean()
    print(f"  {'OUT (detected |.|)':26} peak|.|={out.max():8.0f}  mean={out.mean():8.1f}  median={np.median(out):7.0f}  "
          f"sat(>=64224)={sat:5.1f}%   [uint16 full=65535]")
    print("\nDIAGNOSIS:")
    print("  SIG peak near 32767 => azimuth output at full scale => detect |.| overflows uint16 => OUT saturates.")
    print("  Fix = right-shift SIG before detect (raise renorm headroom for the azimuth pass, or add a")
    print("  detect pre-shift). If SCRATCH is already saturated, the range pass over-scales for real data.")
except FileNotFoundError as e:
    print(f"  (stage dump missing: {e} -- run run_pipe_trace.sh first)")
