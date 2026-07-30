#!/usr/bin/env python
"""Emit the azimuth 32-tap polyphase sinc table as a raw int16 blob for DDR.

WHY A BLOB AND NOT A GDB SCRIPT. The RANGE sinc loader (run_sinc_table_load.sh) pushes 8192 words
one AXI4-Lite `set` at a time, because sar_resample_v's table lives behind a CIC register and there
is no other way in. That took ~15 minutes over JTAG at the 6 MHz clock ceiling.

The AZIMUTH table does not have that problem: the firmware reads it from DDR
(SAR_AZSINC_TAB_ADDR = 0xB0059200) and pushes it into both feeders itself, on-chip, at CPU speed.
So the host only has to land 16 KB in DDR, which `restore ... binary` does in one transfer.

Same table as pass 1 -- SCENE-INDEPENDENT, a pure function of fractional delay -- so it is generated
from the same authority (mpfs/fpga/tb/gen_resample_vectors.py) rather than reimplemented here.
Phase-major, 256 phases x 32 taps, int16 little-endian, DC-normalised so each phase sums to
exactly 2^15.

Run:  python mpfs/host/gen_azsinc_table_bin.py [-o mpfs/host/jtag_full/azsinc_table.bin]
"""
import argparse
import struct
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1] / "mpfs" / "fpga" / "tb"))
sys.path.insert(0, str(HERE.parents[0] / "fpga" / "tb"))
from gen_resample_vectors import sinc_table_q15          # noqa: E402

PHASES, TAPS = 256, 32


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", "--out", default=str(HERE / "jtag_full" / "azsinc_table.bin"))
    a = ap.parse_args()

    tab = sinc_table_q15(PHASES, TAPS)
    assert len(tab) == PHASES and len(tab[0]) == TAPS

    # Non-negotiable invariant: unity DC gain at EVERY phase. A phase that does not sum to 2^15 is
    # a per-phase gain error, i.e. amplitude ripple across the image that no downstream scaling
    # removes. Checked here rather than trusted, because the blob is opaque once it is in DDR.
    for ph, row in enumerate(tab):
        s = sum(row)
        if s != 1 << 15:
            raise SystemExit("phase %d sums to %d, not %d" % (ph, s, 1 << 15))
        for t in row:
            if not (-32768 <= t <= 32767):
                raise SystemExit("phase %d has tap %d outside int16" % (ph, t))

    blob = b"".join(struct.pack("<h", t) for row in tab for t in row)
    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_bytes(blob)
    peak = max(range(TAPS), key=lambda k: tab[0][k])
    print("wrote %s  (%d bytes, %d phases x %d taps)" % (out, len(blob), PHASES, TAPS))
    print("  every phase sums to exactly 2^15; phase 0 peaks at tap %d" % peak)


if __name__ == "__main__":
    main()
