"""Generate a STRUCTURED complex input for the CoreFFT phase test and write it as packed hex
(re<<16 | im, matching the TB's readmemh). A few impulses -> the analytic FFT is a sum of clean
phase ramps: rich magnitude ripple AND well-defined phase, so complex correlation is meaningful
(unlike flat random noise). Writes fft_vectors_n8192/phase_in.hex with N samples."""
import numpy as np, os

N = int(__import__("sys").argv[1]) if len(__import__("sys").argv) > 1 else 256
x = np.zeros(N, dtype=complex)
# SINGLE strong impulse at position p -> FFT[k] = A*exp(-j 2pi p k / N): EVERY bin is full-magnitude
# (|FFT| flat, no weak bins) so quantization noise is negligible and the phase is a clean ramp.
# CoreFFT correct => angle(out[k]) = -2pi p k/N (slope < 0); conjugate/+j convention => slope > 0.
p = 3
x[p] = 30000 + 0j

re = np.clip(np.round(x.real), -32768, 32767).astype(np.int64) & 0xFFFF
im = np.clip(np.round(x.imag), -32768, 32767).astype(np.int64) & 0xFFFF
words = ((re << 16) | im).astype(np.uint32)

out = "../fpga/sim/fft_vectors_n8192/phase_in.hex"
os.makedirs(os.path.dirname(out), exist_ok=True)
with open(out, "w") as f:
    for w in words:
        f.write(f"{w:08x}\n")
print(f"wrote {out}  ({N} samples, {int((x!=0).sum())} impulses)")
