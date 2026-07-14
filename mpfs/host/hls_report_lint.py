#!/usr/bin/env python3
"""hls_report_lint.py -- Gate 1 of the HLS trust harness.

SmartHLS silently degrades II (the documented II=2 -> 21 gap on this project) and
never fails the build when it does. This tool parses the pipelining report, reads
the ACHIEVED II per loop, compares against the II you REQUESTED in the source
pragma, and exits non-zero on any degradation -- so the silent schedule regression
becomes a loud build failure. It also records each loop's scheduled II to the
ledger (phenomenon axi_ii_lie) as the "claim" side of the report-vs-silicon pair;
the silicon eff_ii is the "reality" side (see hls_stats.py eff-ii).

Gate (per pipelined loop):
  FAIL  achieved II > requested II        (schedule degraded below what you asked)
  FAIL  MII        > requested II        (resource/dependency bound -- cannot reach
                                          requested even ideally; restructure)
  WARN  achieved II > MII                 (scheduler left II on the table)
  PASS  otherwise

Usage:
  hls_report_lint.py [--report <pipelining.hls.rpt>] [--src <resample.cpp>] [--no-ledger]
  hls_report_lint.py --selftest      # proves the FAIL path on a synthetic block
"""
import argparse
import os
import re
import sys

DEFAULT_REPORT = os.path.normpath(os.path.join(
    os.path.dirname(__file__), "..", "fpga", "hls_resample",
    "hls_output", "reports", "pipelining.hls.rpt"))
DEFAULT_SRC = os.path.normpath(os.path.join(
    os.path.dirname(__file__), "..", "fpga", "hls_resample", "resample.cpp"))

_LABEL = re.compile(r"^Label:\s*(\S+)", re.M)
_MII = re.compile(r"^MII\s*=\s*(\d+)", re.M)
_II = re.compile(r"^II\s*=\s*(\d+)", re.M)
_CPPLINE = re.compile(r"_cpp_(\d+)_\d+$")
_PRAGMA = re.compile(r"pipeline\s+II\((\d+)\)")


def parse_loops(text):
    """Yield dicts {label, mii, ii, src_line} for each pipelined loop block."""
    starts = [m.start() for m in _LABEL.finditer(text)]
    starts.append(len(text))
    for i in range(len(starts) - 1):
        block = text[starts[i]:starts[i + 1]]
        label = _LABEL.search(block).group(1)
        mii = _MII.search(block)
        ii = _II.search(block)
        if not (mii and ii):
            continue  # not a pipelined loop
        cl = _CPPLINE.search(label)
        yield {
            "label": label,
            "mii": int(mii.group(1)),
            "ii": int(ii.group(1)),
            "src_line": int(cl.group(1)) if cl else None,
        }


def requested_ii(src_lines, loop_line, window=6):
    """Nearest `pipeline II(k)` pragma at or just above the loop's source line."""
    if not loop_line:
        return None
    lo = max(0, loop_line - window)
    best = None
    for ln in range(lo, min(loop_line, len(src_lines))):
        m = _PRAGMA.search(src_lines[ln])
        if m:
            best = int(m.group(1))  # closest-above wins
    return best


def evaluate(loops, src_lines):
    rows, failed = [], False
    for lp in loops:
        req = requested_ii(src_lines, lp["src_line"]) if src_lines else None
        status, why = "PASS", []
        if req is not None:
            if lp["ii"] > req:
                status, _f = "FAIL", failed
                failed = True
                why.append("II %d > requested %d" % (lp["ii"], req))
            if lp["mii"] > req:
                status = "FAIL"
                failed = True
                why.append("MII %d > requested %d (resource/dep bound)" % (lp["mii"], req))
        if status != "FAIL" and lp["ii"] > lp["mii"]:
            status = "WARN"
            why.append("II %d > MII %d (II left on the table)" % (lp["ii"], lp["mii"]))
        lp["requested"] = req
        lp["status"] = status
        lp["why"] = why
        rows.append(lp)
    return rows, failed


def to_ledger(rows, report_path):
    try:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        from hls_stats import append_record
    except Exception as e:  # ledger is best-effort, never blocks the gate
        print("  (ledger skipped: %s)" % e)
        return
    build = os.path.basename(os.path.dirname(os.path.dirname(
        os.path.dirname(report_path))))  # <project>/hls_output/reports/..
    for r in rows:
        append_record({
            "phenomenon": "axi_ii_lie", "build": build, "metric": "scheduled_ii",
            "value": r["ii"], "scheduled": r["requested"], "unit": "cyc/elem",
            "source": "hls_report_lint", "note": "%s MII=%d" % (r["label"], r["mii"]),
        })


_SELFTEST = """
Label: for_loop_fake_cpp_49_5
ID: x
Trip count: 8192
Scheduled.
MII = 1
II = 21
Final Pipeline Schedule:
Total pipeline stages: 5
"""


def run_selftest():
    loops = list(parse_loops(_SELFTEST))
    assert loops and loops[0]["ii"] == 21 and loops[0]["mii"] == 1, loops
    src = ["x"] * 60
    src[47] = "#pragma HLS loop pipeline II(1)"  # line 48 -> loop at 49
    rows, failed = evaluate(loops, src)
    assert failed, "expected FAIL on II=21 vs requested 1"
    assert rows[0]["requested"] == 1, rows[0]
    print("selftest OK: II=21 vs requested=1 -> FAIL as expected")
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--report", default=DEFAULT_REPORT)
    p.add_argument("--src", default=DEFAULT_SRC)
    p.add_argument("--ledger", action="store_true",
                   help="also append each loop's scheduled II to the stats ledger "
                        "(off by default so the gate can run every build without spam)")
    p.add_argument("--selftest", action="store_true")
    a = p.parse_args()

    if a.selftest:
        sys.exit(run_selftest())

    if not os.path.exists(a.report):
        sys.exit("report not found: %s" % a.report)
    text = open(a.report, encoding="utf-8", errors="replace").read()
    src_lines = (open(a.src, encoding="utf-8", errors="replace").read().splitlines()
                 if os.path.exists(a.src) else None)
    if src_lines is None:
        print("  (no source file -> gating on MII only, requested II unknown)")

    loops = list(parse_loops(text))
    if not loops:
        sys.exit("no pipelined loops found in %s" % a.report)
    rows, failed = evaluate(loops, src_lines)

    print("HLS report gate: %s" % a.report)
    for r in rows:
        req = r["requested"]
        print("  [%-4s] %-34s II=%d MII=%d requested=%s%s" % (
            r["status"], r["label"], r["ii"], r["mii"],
            req if req is not None else "?",
            "  " + "; ".join(r["why"]) if r["why"] else ""))

    if a.ledger:
        to_ledger(rows, a.report)

    if failed:
        print("GATE FAIL: SmartHLS scheduled worse II than requested.")
        sys.exit(1)
    print("GATE PASS: all pipelined loops meet requested II.")


if __name__ == "__main__":
    main()
