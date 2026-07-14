#!/usr/bin/env python3
"""hls_antipattern_lint.py -- Gate 0 of the HLS trust harness (source pre-screen).

Reads the living catalog docs/fpga/SMARTHLS_ANTIPATTERNS.md and checks HLS source
against the code shapes that this SmartHLS version has been PROVEN to mis-synthesise
(twiddle drop, sign-extension, DDR read in the II-critical loop, ...). Entries with
a machine `pattern:` are regex-screened over the source; entries without one are
printed as a manual review checklist. Exit non-zero if any `severity: block`
pattern matches -- so a known mis-synthesis shape can't silently reach a bitstream.

The catalog is the asset; this tool is a thin consumer. Add an entry the same
session you confirm a new mis-synthesis (see the catalog header for the format).

Usage:
  hls_antipattern_lint.py [--catalog <md>] [--src-glob 'mpfs/fpga/**/*.cpp' ...]
"""
import argparse
import glob
import os
import re
import sys

REPO = os.path.normpath(os.path.join(os.path.dirname(__file__), "..", ".."))
DEFAULT_CATALOG = os.path.join(REPO, "docs", "fpga", "SMARTHLS_ANTIPATTERNS.md")
DEFAULT_GLOBS = [
    "mpfs/fpga/**/*.cpp", "mpfs/fpga/**/*.hpp", "mpfs/fpga/**/*.h",
]
_BLOCK = re.compile(r"<!--\s*LINT\s*(.*?)-->", re.S)
_FENCE = re.compile(r"```.*?```", re.S)


def parse_catalog(path):
    """Return list of entry dicts from <!-- LINT key: value ... --> blocks.

    Fenced ``` code blocks are stripped first so the format EXAMPLE in the doc
    (shown as visible code) is not parsed as a real entry -- only the raw HTML
    comments in the body count.
    """
    entries = []
    text = _FENCE.sub("", open(path, encoding="utf-8").read())
    for m in _BLOCK.finditer(text):
        entry = {}
        for line in m.group(1).splitlines():
            line = line.strip()
            if not line or ":" not in line:
                continue
            k, v = line.split(":", 1)
            entry[k.strip()] = v.strip()
        if entry.get("id"):
            entries.append(entry)
    return entries


def source_files(globs):
    files = []
    for g in globs:
        for f in glob.glob(os.path.join(REPO, g), recursive=True):
            if os.sep + "hls_output" + os.sep in f:
                continue  # skip SmartHLS-generated output
            files.append(f)
    return sorted(set(files))


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--catalog", default=DEFAULT_CATALOG)
    p.add_argument("--src-glob", action="append", dest="globs")
    a = p.parse_args()
    globs = a.globs or DEFAULT_GLOBS

    if not os.path.exists(a.catalog):
        sys.exit("catalog not found: %s" % a.catalog)
    entries = parse_catalog(a.catalog)
    files = source_files(globs)
    print("catalog: %s  (%d entries)  |  sources: %d files\n" % (
        a.catalog, len(entries), len(files)))

    auto = [e for e in entries if e.get("pattern")]
    manual = [e for e in entries if not e.get("pattern")]

    blocked = False
    for e in auto:
        try:
            rx = re.compile(e["pattern"])
        except re.error as err:
            print("  [SKIP] %s: bad regex (%s)" % (e["id"], err))
            continue
        hits = []
        for f in files:
            for i, line in enumerate(open(f, encoding="utf-8", errors="replace"), 1):
                if rx.search(line):
                    hits.append((os.path.relpath(f, REPO), i, line.strip()))
        sev = e.get("severity", "warn")
        if hits:
            tag = "BLOCK" if sev == "block" else "WARN"
            if sev == "block":
                blocked = True
            print("  [%s] %s -- %s" % (tag, e["id"], e.get("message", "")))
            for rel, ln, txt in hits[:8]:
                print("        %s:%d  %s" % (rel, ln, txt[:80]))
        else:
            print("  [ ok ] %s (no match)" % e["id"])

    if manual:
        print("\n  Manual review checklist (no auto-pattern):")
        for e in manual:
            print("    - [%s] %s -- %s" % (
                e.get("severity", "warn"), e["id"], e.get("message", "")))

    if blocked:
        print("\nGATE FAIL: a `severity: block` anti-pattern matched.")
        sys.exit(1)
    print("\nGATE PASS: no blocking anti-pattern matched.")


if __name__ == "__main__":
    main()
