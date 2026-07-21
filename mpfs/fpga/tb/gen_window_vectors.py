#!/usr/bin/env python
"""Generate bit-exact reference vectors for the fused-window feeder testbench.

The fused window in fft_feeder_v.v must be BIT-IDENTICAL to the fabric window pass it
replaces, so the pipeline CRC (0xd596c9eb) stays a valid gate. The authority for that
arithmetic is hls_window/window.cpp -- NOT silicon_emulator.window_fixed(), which applies
the two tapers as two separate >>15 rounds and therefore differs in the low bit:

    window.cpp            cw = (int16)((hamr[j]*hamc[k])>>15) ; out = (int16)((x*cw)>>15)
    silicon_emulator.py   t  = (x*hamr[j])>>15                ; out = (t*hamc[k])>>15

window.cpp is what the silicon actually ran, so it is what we reproduce here.

Emits (into this directory):
    win_in.hex    64-bit input beats,  one per line   {sample1, sample0}, sample = {I,Q}
    win_tab.hex   32-bit taper words,  one per line   {hamc[2i+1], hamc[2i]}
    win_exp.hex   64-bit expected beats after windowing
    win_dims.vh   `define ROWS/BEATS_PER_ROW/TAB_WORDS for the testbench
"""
import pathlib

ROWS = 8               # rows in the toy frame
SAMPLES_PER_ROW = 32   # -> 16 beats/row, 16 taper words
BEATS_PER_ROW = SAMPLES_PER_ROW // 2


def s16(x):
    """truncate to int16 with C wrap semantics (the (int16_t) cast)"""
    x &= 0xFFFF
    return x - 0x10000 if x >= 0x8000 else x


def shr15(x):
    """C arithmetic >>15 on a signed int32 -- Python's >> already floors"""
    return x >> 15


def q15(v):
    """clamp a float to the int16 Q15 range the host loader produces"""
    return max(-32768, min(32767, int(v * 32768)))


def main():
    here = pathlib.Path(__file__).resolve().parent

    # Tapers. Deliberately NOT smooth Hamming: adversarial values (negatives, extremes,
    # zero-pad) catch sign-extension and truncation bugs that a gentle taper hides.
    hamr = [q15(0.9 - 0.23 * j) for j in range(ROWS)]                    # per-row scalar
    hamc = [q15(0.8 - 0.05 * k) for k in range(SAMPLES_PER_ROW)]         # along-row table
    hamc[0] = 0                       # zero-pad edge
    hamc[-1] = 0
    hamc[3] = -32768                  # most-negative Q15
    hamc[4] = 32767
    hamr[2] = -32768
    hamr[5] = 0

    # Input samples: mix of sign combinations and extremes.
    def samp(j, k):
        i = s16((j * 7919 + k * 4523 + 13) * 37)
        q = s16((j * 6271 - k * 2749 - 5) * 53)
        if (j + k) % 17 == 0:
            i, q = -32768, 32767      # extremes
        return i, q

    in_beats, exp_beats = [], []
    for j in range(ROWS):
        for b in range(BEATS_PER_ROW):
            k0, k1 = 2 * b, 2 * b + 1
            i0, q0 = samp(j, k0)
            i1, q1 = samp(j, k1)
            # beat = {sample1, sample0}, sample = {I<<16 | Q}
            beat = ((i1 & 0xFFFF) << 48) | ((q1 & 0xFFFF) << 32) \
                 | ((i0 & 0xFFFF) << 16) | (q0 & 0xFFFF)
            in_beats.append(beat)

            # ---- window.cpp arithmetic ----
            cw0 = s16(shr15(hamr[j] * hamc[k0]))
            cw1 = s16(shr15(hamr[j] * hamc[k1]))
            o_i0, o_q0 = s16(shr15(i0 * cw0)), s16(shr15(q0 * cw0))
            o_i1, o_q1 = s16(shr15(i1 * cw1)), s16(shr15(q1 * cw1))
            exp_beats.append(((o_i1 & 0xFFFF) << 48) | ((o_q1 & 0xFFFF) << 32)
                             | ((o_i0 & 0xFFFF) << 16) | (o_q0 & 0xFFFF))

    tab = [((hamc[2 * i + 1] & 0xFFFF) << 16) | (hamc[2 * i] & 0xFFFF)
           for i in range(BEATS_PER_ROW)]

    (here / "win_in.hex").write_text("".join(f"{v:016x}\n" for v in in_beats))
    (here / "win_exp.hex").write_text("".join(f"{v:016x}\n" for v in exp_beats))
    (here / "win_tab.hex").write_text("".join(f"{v:08x}\n" for v in tab))
    (here / "win_scale.hex").write_text("".join(f"{v & 0xFFFF:04x}\n" for v in hamr))
    (here / "win_dims.vh").write_text(
        f"`define ROWS {ROWS}\n"
        f"`define BEATS_PER_ROW {BEATS_PER_ROW}\n"
        f"`define TAB_WORDS {BEATS_PER_ROW}\n")
    print(f"wrote {len(in_beats)} beats, {len(tab)} taper words, {ROWS} rows -> {here}")


if __name__ == "__main__":
    main()
