"""Generate a KNOWN synthetic multi-row input for the injected fabric range-FFT value test (A2).
Rows are chosen to force a SPREAD of per-row block exponents -- exactly the thing the pipeline run
showed as suspiciously uniform. Writes:
  jtag_stage_small/inject_rows.bin  -- K rows x 8192 complex int16, packed (re<<16|im) as uint32,
                                       loadable over JTAG:  restore inject_rows.bin binary 0x88000000
  jtag_stage_small/inject_codes.npy -- the same rows as a complex array, for the bit-accurate model.
The rest of BUF_SIG (rows K..8191) is zeroed on-chip by 'SCLE' before these are injected.
"""
import numpy as np, os

N = 8192
n = np.arange(N)
rows = []
# row0: DC large  -> big exponent
rows.append(np.full(N, 8000.0 + 0j))
# row1: DC small (16:1 vs row0) -> smaller exponent, tests renorm ratio
rows.append(np.full(N, 500.0 + 0j))
# row2: single tone at bin 5, mid amplitude -> spike, moderate exp
rows.append(20000.0 * np.exp(2j*np.pi*5*n/N))
# row3: single tone at bin 100, with a phase offset -> tests phase through the chain
rows.append(15000.0 * np.exp(2j*np.pi*(100*n/N + 0.37)))
# row4: two tones 40 dB apart -> dynamic range within a row
rows.append(30000.0*np.exp(2j*np.pi*7*n/N) + 300.0*np.exp(2j*np.pi*333*n/N))
# row5: complex broadband (random) -> largest exponent growth
rng = np.random.default_rng(7)
rows.append(9000.0*(rng.standard_normal(N) + 1j*rng.standard_normal(N)))
# row6: tiny broadband -> smallest nonzero exponent
rows.append(120.0*(rng.standard_normal(N) + 1j*rng.standard_normal(N)))
# row7: full-scale tone -> exponent near max, saturation edge
rows.append(32000.0*np.exp(2j*np.pi*2048*n/N))

x = np.array(rows)
re = np.clip(np.round(x.real), -32768, 32767).astype(np.int64) & 0xFFFF
im = np.clip(np.round(x.imag), -32768, 32767).astype(np.int64) & 0xFFFF
words = ((re << 16) | im).astype(np.uint32)             # (K, N) packed re<<16|im

d = "jtag_stage_small"
os.makedirs(d, exist_ok=True)
words.tofile(d + "/inject_rows.bin")
codes = (re.astype(np.int16).astype(complex) + 1j*im.astype(np.int16).astype(complex))
np.save(d + "/inject_codes.npy", codes)
print(f"wrote {len(rows)} known rows -> {d}/inject_rows.bin ({words.nbytes} bytes) + inject_codes.npy")
print(f"row content: DC8000, DC500, tone@5, tone@100+phase, 2tone40dB, broadband, tiny-bb, fullscale@2048")
