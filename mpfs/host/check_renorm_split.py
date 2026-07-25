#!/usr/bin/env python3
"""check_renorm_split.py -- BOARD-FREE gate for splitting the FFT renormalize epilogue across harts.

The block-floating-point epilogue (fft1_gather_pass / fft_fabric_pass / fft2_ct_overlap) rescales
every row of the frame by `sh = (emax - exp[row]) + headroom`. sar_cwrk_renorm() splits the ROW
range across the U54 harts, each hart taking [row_bound(w), row_bound(w+1)).

Unlike the coefficient split (check_coeff_split.py), the arithmetic here carries NO state across
rows or across elements -- the worker copy in sar_coeff_workers.c is character-for-character the
serial loop. So what actually has to be proven is the PARTITION, and that is what this checks:

  1. row_bound() is an exact, disjoint, monotone cover of [0, rows) for every hart count.
  2. Applying the per-row shift slice-by-slice gives a byte-identical frame to the serial pass,
     for adversarial exponent patterns (all-equal, alternating, one bright row, random).
  3. Every row boundary is a 64 B cache-line boundary for BOTH row types, so no two harts can
     ever have stores in the same cache line (the hazard SAR_CWRK_ALIGN exists for on the
     coefficient split).

Usage:  python mpfs/host/check_renorm_split.py
"""
import sys
import numpy as np

SAR_GRID = 8192
ROW_BYTES = SAR_GRID * 4          # complex int16 pairs
ROW_BYTES_U16 = SAR_GRID * 2      # fused-detect magnitude rows
CACHE_LINE = 64
MAXW = 4


def row_bound(w, nw, rows):
    """Mirror of sar_cwrk_row_bound() in sar_coeff_workers.h."""
    if w == 0:
        return 0
    if w >= nw:
        return rows
    return (w * rows) // nw


def renorm_rows(frame, exp, emax, head, r0, r1):
    """Mirror of rwrk_renorm_rows(): frame is int16 (rows, 2*cols); >> is arithmetic on int16,
    which is exactly `(int32_t)(int16_t)x >> sh` truncated back to int16 (a right shift of an
    int16 always fits in an int16). Same for the uint16 detect rows, with a logical shift."""
    for row in range(r0, r1):
        sh = (emax - int(exp[row])) + head
        if sh == 0:
            continue
        frame[row] >>= np.int16(sh) if frame.dtype == np.int16 else np.uint16(sh)


def main():
    bad = 0

    # ---- 1. partition is an exact disjoint cover -------------------------------------------
    for rows in (SAR_GRID, 1, 2, 3, 5, 7, 1023, 8191):
        for nw in range(1, MAXW + 1):
            b = [row_bound(w, nw, rows) for w in range(nw + 1)]
            covered = []
            for w in range(nw):
                covered.extend(range(b[w], b[w + 1]))
            if b[0] != 0 or b[-1] != rows or any(b[i] > b[i + 1] for i in range(nw)):
                print(f"  FAIL bounds rows={rows} nw={nw}: {b}")
                bad += 1
            if covered != list(range(rows)):
                print(f"  FAIL cover rows={rows} nw={nw}: {b}")
                bad += 1

    # ---- 2. sliced == serial, byte for byte ------------------------------------------------
    rng = np.random.default_rng(20260725)
    rows, cols = 64, 32                      # small stand-in frame; the loop body is row-local
    patterns = {
        "all-equal": np.zeros(rows, np.uint8),
        "alternating": np.tile([0, 3], rows // 2).astype(np.uint8),
        "one-bright": np.array([0] * (rows - 1) + [11], np.uint8),
        "random": rng.integers(0, 12, rows, dtype=np.uint8),
    }
    for det in (0, 1):
        dt = np.uint16 if det else np.int16
        width = cols if det else 2 * cols
        base = rng.integers(np.iinfo(dt).min, np.iinfo(dt).max, (rows, width)).astype(dt)
        for name, exp in patterns.items():
            emax = int(exp.max())
            for head in (0, 1, 4):
                ref = base.copy()
                renorm_rows(ref, exp, emax, head, 0, rows)
                for nw in range(1, MAXW + 1):
                    got = base.copy()
                    for w in range(nw):
                        renorm_rows(got, exp, emax, head,
                                    row_bound(w, nw, rows), row_bound(w + 1, nw, rows))
                    if not np.array_equal(ref, got):
                        print(f"  FAIL det={det} {name} head={head} nw={nw}")
                        bad += 1

    # ---- 3. cache-line disjointness of a row split -----------------------------------------
    for nm, rb in (("complex", ROW_BYTES), ("detect", ROW_BYTES_U16)):
        if rb % CACHE_LINE:
            print(f"  FAIL {nm} row stride {rb} is not a multiple of {CACHE_LINE} B")
            bad += 1

    print(f"row strides: complex={ROW_BYTES} B, detect={ROW_BYTES_U16} B "
          f"(both {ROW_BYTES // CACHE_LINE} / {ROW_BYTES_U16 // CACHE_LINE} whole cache lines)")
    if bad == 0:
        print("PASS: the row split is an exact disjoint cover, cache-line disjoint, and "
              "bit-identical to the serial epilogue.")
        return 0
    print(f"FAIL: {bad} problems -- do NOT enable SAR_RWRK_NW.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
