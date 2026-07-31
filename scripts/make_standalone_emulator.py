#!/usr/bin/env python3
"""Assemble the standalone Python SAR emulator into a single hand-off folder.

WHY A BUILDER AND NOT A HAND-COPIED FOLDER. The emulator's sources live in two trees
(`src/` for the float reference, `mpfs/host/` for the bit-accurate mirror) plus one file in
`mpfs/fpga/tb/`. A copy made by hand silently drifts from the originals the next time anyone edits
them, and a drifted emulator is worse than no emulator -- it is the reference the board is scored
against. Re-run this script after any change and hand over the fresh folder.

The copied files are BYTE-IDENTICAL to the repo originals: no edits, no path rewriting. That works
because every module inserts its own directory on sys.path before importing its siblings, and in a
flat folder that resolves. The inserts that point at the repo layout (`../src`, `mpfs/fpga/tb`)
become harmless no-ops.

Usage:  python scripts/make_standalone_emulator.py [--out sar_emulator]
"""
import argparse
import pathlib
import shutil

ROOT = pathlib.Path(__file__).resolve().parents[1]

# (source path, why it is needed) -- the full transitive closure, traced from silicon_emulator.py
FILES = [
    ("mpfs/host/silicon_emulator.py",   "entry point: bit-accurate mirror of the board"),
    ("src/form_image_pfa.py",           "float reference + CPHD reader (sarpy)"),
    ("src/fixedpoint.py",               "fixed-point helpers"),
    ("mpfs/host/sar_pipeline.py",       "prepare_tables(): geometry -> f0/df/pr/tan_phi/KR/KC/window"),
    ("mpfs/host/serialize_inputs.py",   "interp_coeffs(): the verified idx/wq quantiser"),
    ("mpfs/host/ddr_layout.py",         "imported by serialize_inputs"),
    ("mpfs/host/accel.py",              "make_backend(), imported by sar_pipeline"),
    ("mpfs/host/sar_display.py",        "normal-score contrast stretch for viewing the output"),
    ("mpfs/fpga/tb/gen_resample_vectors.py",
                                        "sinc_table_q15(): the 32-tap table, SAME generator the RTL bench uses"),
    ("scripts/fetch_data.py",           "helper to download a CPHD from the Umbra open-data bucket"),
]

REQUIREMENTS = """\
# Required
numpy
sarpy            # CPHD phase-history reader
Pillow           # PNG output in sar_display.py

# Optional -- each has a fallback or is only used by a side path
scipy            # sar_display uses scipy.special.erfinv if present, else a builtin approximation
pyyaml           # form_image_pfa config loading
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="sar_emulator", help="output folder (relative to repo root)")
    a = ap.parse_args()

    out = ROOT / a.out
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)

    missing = [s for s, _ in FILES if not (ROOT / s).is_file()]
    if missing:
        raise SystemExit("missing sources, refusing to build:\n  " + "\n  ".join(missing))

    for src, _why in FILES:
        shutil.copy2(ROOT / src, out / pathlib.Path(src).name)

    (out / "requirements.txt").write_text(REQUIREMENTS, encoding="utf-8")
    shutil.copy2(ROOT / "docs" / "standalone_emulator_README.md", out / "README.md")

    print("built %s" % out)
    for src, why in FILES:
        print("  %-26s  %s" % (pathlib.Path(src).name, why))
    print("\n%d modules + requirements.txt + README.md" % len(FILES))


if __name__ == "__main__":
    main()
