#!/usr/bin/env python
"""Decode + interpret the FIC_0 monitor snapshot the resample pipeline writes to DDR.

WHY: the resample gather kernel schedules at II=1 (verified) yet runs ~880 us/line against a
361 us schedule -- a 2.44x AXI stall on a CORRECT schedule. The two candidate causes need OPPOSITE
fixes and were not observable until the monitor (sar_fic0s_mon.v, 2026-07-22 bitstream) was added:

  A. SHORT BURSTS -- the kernel issues many small AR bursts (ARLEN histogram weighted to 1/2-4),
     bus mostly busy. Fix: make the kernel request longer bursts (kernel/pragma side).
  B. LONG IDLE GAPS -- bursts are long (histogram weighted to 65-256) but a large MAX_GAP sits
     between them, bus mostly idle. Fix: DDR/interconnect latency / prefetch depth (system side).

The firmware (sar_sequencer.c ficmon_snapshot) writes two 12-word records to 0xB0059240:
  slot 0 = pass-1 range gather line 0, slot 1 = pass-2 azimuth gather line 0.
Word layout: [0]=0xF1C0AA0p [1]=STATUS [2..6]=ARLEN hist(1/2-4/5-16/17-64/65-256)
             [7]=busy [8]=elapsed [9]=max_gap [10]=beats_this_line [11]=0.

USAGE: dump the 96 bytes at 0xB0059240 over JTAG, then
    python mpfs/host/decode_ficmon.py <dump.bin>
or pass the eight hex words of a single record on the command line:
    python mpfs/host/decode_ficmon.py 0xF1C0AA01 0x... ... (12 words)
"""
import struct
import sys

FCLK_HZ = 62.5e6            # OUT0 fabric clock the monitor counts on
BUCKETS = ["len=1", "2-4", "5-16", "17-64", "65-256"]


def decode_record(w):
    magic, status = w[0], w[1]
    hist = w[2:7]
    busy, elapsed, max_gap, beats = w[7], w[8], w[9], w[10]
    pass_id = magic & 0xF
    ok_magic = (magic & 0xFFFFFFF0) == 0xF1C0AA00
    print(f"  magic       0x{magic:08x}  {'OK' if ok_magic else '*** BAD -- not a monitor record'}"
          f"  (pass {pass_id})")
    if not ok_magic:
        print("  -> reads did not come from the monitor. Wrong bitstream (pre-2026-07-22), wrong")
        print("     address, or the record was never written. Do NOT interpret the rest.")
        return
    sig = (status >> 24) & 0xFF
    print(f"  STATUS      0x{status:08x}  sig=0x{sig:02x} {'(monitor alive)' if sig==0xA5 else '(*** sig!=0xA5, slave not decoding)'}")

    total = sum(hist)
    print(f"  ARLEN histogram ({total} AR bursts):")
    for name, c in zip(BUCKETS, hist):
        bar = "#" * int(40 * c / total) if total else ""
        pct = 100.0 * c / total if total else 0.0
        print(f"    {name:>7}: {c:8d}  {pct:5.1f}%  {bar}")

    util = busy / elapsed if elapsed else float("nan")
    print(f"  busy        {busy:10d} cyc")
    print(f"  elapsed     {elapsed:10d} cyc   = {elapsed/FCLK_HZ*1e6:8.1f} us")
    print(f"  utilization {100*util:6.1f}%  (busy/elapsed -- how much of the line the bus moved data)")
    print(f"  MAX_GAP     {max_gap:10d} cyc   = {max_gap/FCLK_HZ*1e9:8.0f} ns  (longest idle run between bursts)")
    if beats:
        print(f"  beats/line  {beats:10d} (expected)   avg burst = {beats/total:.1f} beats"
              if total else f"  beats/line  {beats}")

    # ---- verdict ----
    # NOTE: this monitor taps only the READ channel (AR/R). Writes (AW/W/B) are NOT counted, so
    # (elapsed - busy) is write-time PLUS genuine idle, and low read-utilization does NOT by itself
    # mean the bus is idle. Weigh that before concluding "stalled".
    short = (hist[0] + hist[1])                       # 1 + 2-4 beat bursts
    long_ = hist[4]                                   # 65-256 beat bursts
    short_frac = short / total if total else 0
    long_frac = long_ / total if total else 0
    avg_burst = beats / total if total else 0
    # a gap only counts as "big" if it is comparable to a whole burst's own data phase; a gap far
    # smaller than one burst is intra-burst throttling, not an inter-burst arbitration stall.
    big_gap = max_gap > max(200, 2 * avg_burst)
    print("  VERDICT:", end=" ")
    if util > 0.85:
        print("read bus NEAR-SATURATED -- reads are not the stall; the schedule roughly holds.")
    elif short_frac > 0.5:
        print(f"SHORT READ BURSTS dominate ({100*short_frac:.0f}% are <=4 beats), util {100*util:.0f}%. "
              "The kernel is not requesting long bursts -> fix is kernel/pragma side (raise "
              "max_burst_len, or restructure so bursts coalesce).")
    elif long_frac > 0.5 and big_gap:
        print(f"LONG READ BURSTS but a BIG inter-burst gap ({100*long_frac:.0f}% are 65-256 beats, "
              f"max gap {max_gap/FCLK_HZ*1e9:.0f} ns >> one burst). The kernel stalls BETWEEN bursts "
              "-> arbitration/outstanding-depth or a per-burst re-arm cost. Fix is system side.")
    elif long_frac > 0.5:
        print(f"LONG READ BURSTS, SMALL max gap ({max_gap/FCLK_HZ*1e9:.0f} ns << one "
              f"{avg_burst:.0f}-beat burst), read util {100*util:.0f}%. Burst length is NOT the "
              "problem and there is no single big stall -- the idle is DISTRIBUTED. Two things it can "
              "be, and this read-only monitor cannot separate them: (a) time spent WRITING output "
              "(invisible here), or (b) read DATA returning slower than 1 beat/cyc within each burst "
              "(DDR/interconnect read throughput). Lever: DELETE the DDR round-trip (fuse the stage) "
              "rather than tune burst length. A v2 monitor needs the write channel + intra-burst "
              "RVALID-gap counting to split (a) from (b).")
    else:
        print(f"MIXED -- util {100*util:.0f}%, short {100*short_frac:.0f}%, long {100*long_frac:.0f}%, "
              f"max gap {max_gap/FCLK_HZ*1e9:.0f} ns. Read the histogram + max_gap directly.")


def main():
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    if len(args) == 1 and not args[0].startswith("0x"):
        data = open(args[0], "rb").read()
        n = len(data) // 4
        words = list(struct.unpack("<%dI" % n, data[: n * 4]))
    else:
        words = [int(a, 0) for a in args]
    # split into 12-word records
    for slot in range(len(words) // 12):
        rec = words[slot * 12: slot * 12 + 12]
        label = {1: "PASS-1 range gather (line 0)", 2: "PASS-2 azimuth gather (line 0)"}.get(
            rec[0] & 0xF, f"slot {slot}")
        print(f"\n=== {label} ===")
        decode_record(rec)
    print()


if __name__ == "__main__":
    main()
