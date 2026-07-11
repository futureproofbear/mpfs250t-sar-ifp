"""Per-stage dynamic-range analysis for the fabric-vs-CPU FFT scaling trace.
Reads the 256 KB bright-band chunks dumped by flow_pipe_trace.gdb (complex int16 packed
uint32 = (I<<16)|Q) for SCRATCH (range-FFT out, transposed), SIG (azimuth-FFT out), OUT
(detected uint16 magnitude), and prints peak/mean |value| so we can see where a path loses
magnitude. Usage: python trace_peaks.py <trace_dir> [label]"""
import sys, numpy as np
from pathlib import Path

d = Path(sys.argv[1]); label = sys.argv[2] if len(sys.argv) > 2 else d.name


def cstats(fn):
    raw = np.fromfile(fn, dtype=np.uint32)
    re = (raw >> 16).astype(np.int16).astype(np.int32)
    im = (raw & 0xFFFF).astype(np.int16).astype(np.int32)
    mag = np.hypot(re, im)
    absmax = int(max(np.abs(re).max(), np.abs(im).max()))
    return len(raw), absmax, float(mag.max()), float(mag.mean()), int((np.abs(re) > 32000).sum() + (np.abs(im) > 32000).sum())


def ostats(fn):
    m = np.fromfile(fn, dtype=np.uint16).astype(np.float64)
    return len(m), int(m.max()), float(m.mean()), int((m >= 65535).sum()), 100.0 * (m >= 65535).mean()


print(f"=== {label} ===")
for tag, fn in [("SCRATCH=range-FFT-out", "trace_scratch.bin"), ("SIG=azimuth-FFT-out", "trace_sig.bin")]:
    p = d / fn
    if p.exists():
        n, amx, mmx, mmn, near = cstats(p)
        print(f"  {tag:22} N={n:6d}  |re/im|max={amx:6d}  magmax={mmx:8.0f}  magmean={mmn:8.1f}  near-fullscale={near}")
    else:
        print(f"  {tag:22} (missing {fn})")
p = d / "trace_out.bin"
if p.exists():
    n, mx, mn, sat, satp = ostats(p)
    print(f"  OUT=detect             N={n:6d}  max={mx:6d}  mean={mn:8.1f}  saturated(0xffff)={sat} ({satp:.1f}%)")
