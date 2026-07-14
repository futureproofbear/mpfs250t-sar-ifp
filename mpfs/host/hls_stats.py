#!/usr/bin/env python3
"""hls_stats.py -- append-only ledger for SmartHLS report-vs-silicon statistics.

The SmartHLS report is a BEHAVIOURAL model. It cannot see the system intricacies
that actually bite on silicon (DDR latency, AXI backpressure, L2 coherency,
FIC/AXI-ID routing, ES errata, cross-IP handshakes). This ledger is where we
COLLECT what the report cannot predict, one measurement per line, so the gap
between "scheduled" and "silicon" is tracked instead of rediscovered.

Every measurement is one JSONL record in  docs/fpga/hls_silicon_stats.jsonl.
`report` rolls the ledger up per phenomenon.

Phenomenon taxonomy -- keep in sync with docs/fpga/HLS_SILICON_STATS.md:
  axi_ii_lie     effective II (cyc/elem) on silicon vs SmartHLS-scheduled II
  ddr_latency    DDR read round-trip latency (cycles)
  l2_coherency   cache-flush contract: cost and/or correctness
  fic_axi_id     FIC0 / AXI-ID routing observations
  es_errata      ER0219 (and other MPFS250T_ES) workarounds/observations
  corefft_rearm  CoreFFT (or other IP) re-arm handshake behaviour

Usage:
  hls_stats.py append --phenomenon axi_ii_lie --build resample-lsram \
       --metric eff_ii --value 1.02 --scheduled 1 --unit cyc/elem \
       --source run_resample_iso --note "idx/wq in LSRAM"

  hls_stats.py eff-ii --build resample-lsram --busy-cycles 8390 --elements 8192 \
       --scheduled 1 --source run_resample_iso --note "..."   # computes eff_ii + delta

  hls_stats.py report [--phenomenon axi_ii_lie]
"""
import argparse
import datetime
import json
import os
import sys

PHENOMENA = {
    "axi_ii_lie", "ddr_latency", "l2_coherency",
    "fic_axi_id", "es_errata", "corefft_rearm",
}

LEDGER = os.path.normpath(
    os.path.join(os.path.dirname(__file__), "..", "..",
                 "docs", "fpga", "hls_silicon_stats.jsonl"))


def _today():
    return datetime.date.today().isoformat()


def append_record(rec):
    """Append one measurement dict to the ledger. Fills ts if absent."""
    if rec.get("phenomenon") not in PHENOMENA:
        raise ValueError("phenomenon must be one of %s" % sorted(PHENOMENA))
    if not rec.get("ts"):
        rec["ts"] = _today()
    os.makedirs(os.path.dirname(LEDGER), exist_ok=True)
    with open(LEDGER, "a", encoding="utf-8") as f:
        f.write(json.dumps(rec, sort_keys=True) + "\n")
    return rec


def _load():
    if not os.path.exists(LEDGER):
        return []
    out = []
    with open(LEDGER, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                out.append(json.loads(line))
    return out


def cmd_append(a):
    rec = {k: v for k, v in {
        "phenomenon": a.phenomenon, "build": a.build, "metric": a.metric,
        "value": a.value, "scheduled": a.scheduled, "unit": a.unit,
        "source": a.source, "note": a.note, "ts": a.ts,
    }.items() if v is not None}
    print(json.dumps(append_record(rec), sort_keys=True))


def cmd_eff_ii(a):
    if a.elements <= 0:
        sys.exit("elements must be > 0")
    eff = a.busy_cycles / float(a.elements)
    rec = {
        "phenomenon": "axi_ii_lie", "build": a.build, "metric": "eff_ii",
        "value": round(eff, 4), "scheduled": a.scheduled, "unit": "cyc/elem",
        "source": a.source, "ts": a.ts,
    }
    if a.scheduled:
        rec["lie_ratio"] = round(eff / float(a.scheduled), 3)
    if a.note:
        rec["note"] = a.note
    append_record(rec)
    msg = "eff_ii=%.3f cyc/elem" % eff
    if a.scheduled:
        msg += "  (scheduled=%s -> %.1fx lie)" % (a.scheduled, eff / a.scheduled)
    print(msg)


def cmd_report(a):
    recs = _load()
    if a.phenomenon:
        recs = [r for r in recs if r.get("phenomenon") == a.phenomenon]
    if not recs:
        print("(ledger empty%s)" % (
            " for %s" % a.phenomenon if a.phenomenon else ""))
        return
    by_phen = {}
    for r in recs:
        by_phen.setdefault(r.get("phenomenon", "?"), []).append(r)
    for phen in sorted(by_phen):
        rows = sorted(by_phen[phen], key=lambda r: r.get("ts") or "")
        print("\n== %s  (%d records) ==" % (phen, len(rows)))
        for r in rows:
            bits = ["%-11s" % r.get("ts", "")]
            bits.append("%-16s" % (r.get("build") or "-"))
            metric = r.get("metric", "")
            val = r.get("value")
            unit = r.get("unit", "")
            if val is None:
                bits.append(metric)
            else:
                bits.append(("%s=%s %s" % (metric, val, unit)).rstrip())
            if r.get("lie_ratio"):
                bits.append("(%.1fx lie)" % r["lie_ratio"])
            elif r.get("scheduled") is not None:
                bits.append("(sched %s)" % r["scheduled"])
            if r.get("note"):
                bits.append("-- " + r["note"])
            print("  " + "  ".join(str(b) for b in bits))
    print("\nledger: %s" % LEDGER)


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    ap = sub.add_parser("append", help="append one measurement")
    ap.add_argument("--phenomenon", required=True, choices=sorted(PHENOMENA))
    ap.add_argument("--build")
    ap.add_argument("--metric", required=True)
    ap.add_argument("--value", type=float)
    ap.add_argument("--scheduled", type=float)
    ap.add_argument("--unit")
    ap.add_argument("--source")
    ap.add_argument("--note")
    ap.add_argument("--ts")
    ap.set_defaults(func=cmd_append)

    ep = sub.add_parser("eff-ii",
                        help="compute effective II from silicon busy-cycles/elements")
    ep.add_argument("--build", required=True)
    ep.add_argument("--busy-cycles", type=float, required=True)
    ep.add_argument("--elements", type=int, required=True)
    ep.add_argument("--scheduled", type=float,
                    help="SmartHLS-scheduled II, to compute the lie ratio")
    ep.add_argument("--source")
    ep.add_argument("--note")
    ep.add_argument("--ts")
    ep.set_defaults(func=cmd_eff_ii)

    rp = sub.add_parser("report", help="roll up the ledger")
    rp.add_argument("--phenomenon", choices=sorted(PHENOMENA))
    rp.set_defaults(func=cmd_report)

    a = p.parse_args()
    a.func(a)


if __name__ == "__main__":
    main()
