#!/usr/bin/env python
"""check_tb_params.py -- GATE: the testbench must instantiate the SAME parameterisation that
synthesis does. Fails loudly when they diverge.

WHY THIS EXISTS -- 2026-07-29, and it cost a full board bring-up.

sar_resample_v passed 16/16 functional cases, a re-arm pass, a power-up pass, and every one of
those was mutation-verified non-vacuous. It then produced a completely wrong image on silicon
(correlation -0.04 against the known-good crop). The bench was not weak; it was testing a
DIFFERENT MODULE:

    parameter    bench      silicon (sar_resample_v_top defaults)
    TAB_AW       14         13      on-chip table depth   16384 vs 8192
    BUF_AW       6          12      source buffer      128 vs 8192 samples
    MAX_BURST    4          64      AXI beats per burst
    WF_AW        4          8       write FIFO depth

Those parameters size the exact structures the gather indexes into, so "16/16 pass" was a pass for
a configuration that is not in the bitstream. Worse, the divergence was KNOWN: tb_sar_resample.v's
own header records that TAB_AW=14 was FORCED because the module would not elaborate at its default
13 (vsim-8607, a negative replication multiplier). The D1 fix later removed that obstruction --
sar_resample_v_top now elaborates clean at 13 -- but the forced override was never revisited, and
nothing mechanical was watching. A comment is not a gate.

Run this BEFORE believing any bench result, and in CI/pre-build. It is deliberately dumb text
parsing: no simulator, no toolchain, runs in milliseconds, so there is no excuse to skip it.

Usage:  python check_tb_params.py            # check every registered DUT
        python check_tb_params.py --list     # show what is registered
"""
import argparse
import re
import sys
from pathlib import Path

FPGA = Path(__file__).resolve().parent.parent

# (module rtl, synthesis wrapper that instantiates it, testbench, DUT instance name in the TB)
# Add a row whenever a hand-written core gains a wrapper + bench. A core with no row here is
# UNGATED -- that is exactly the state sar_resample_v was in.
REGISTRY = [
    ("sar_resample_v.v", "sar_resample_v_top.v", "tb/tb_sar_resample.v"),
    ("corner_turn_v.v",  "corner_turn_v_top.v",  "tb/tb_corner_turn_v.v"),
    ("sar_coeffgen.v",   None,                   "tb/tb_sar_coeffgen.v"),
    # No wrapper yet -- the core is standalone pending integration, so its own defaults ARE what
    # synthesis would build. Registered from the start so it can never reach a bitstream with the
    # bench validating a different parameterisation, which is the failure this gate exists for.
    ("sar_sinc32_gather.v", None,                 "tb/tb_sar_sinc32.v"),
    # Added 2026-07-30 when the 32-tap sinc gather was integrated here. It was UNREGISTERED until
    # then -- i.e. ungated -- and registering it immediately exposed a full silicon divergence.
    ("fft_feeder_v.v",   "fft_feeder_top.v",     "tb/tb_fft_feeder_gather.v"),
]

# WAIVERS. A core whose bench genuinely cannot run at silicon parameters, with the reason and what
# retired the risk INSTEAD. A waiver still prints loudly on every run -- it is a visible debt, not
# a pass. Adding one requires saying what the small run can and cannot establish; if you cannot
# write that sentence, you do not have a waiver, you have an untested core.
WAIVERS = {
    "corner_turn_v":
        "GRID 16 vs 8192 and T_LOG2 2 vs 7. A full-size frame is 8192x8192 tiles -- hours of "
        "simulation per case, so the bench cannot run at silicon scale. Risk retired INSTEAD by an "
        "end-to-end silicon result: 25.16 -> 18.45 s with the crop CRC bit-exact from a cold start. "
        "What the small run establishes: tile sequencing, ragged edges, the re-arm path. What it "
        "does NOT: anything that only appears past a few hundred tiles.",
}

# Parameters that are pure plumbing: a mismatch cannot change functional behaviour, only the
# testbench's own convenience. Keep this list SHORT and justify every entry.
IGNORE = {"AXI_ID_W"}


def read(path):
    """Source with comments stripped. Without this, `parameter WF_AW = 8 // 256 beats` parses
    the comment as part of the value and the gate reports a phantom mismatch."""
    txt = path.read_text(errors="ignore")
    txt = re.sub(r"/\*.*?\*/", " ", txt, flags=re.S)
    return re.sub(r"//[^\n]*", "", txt)


def module_defaults(path, module):
    """`parameter integer NAME = VALUE` inside the module header."""
    txt = read(path)
    m = re.search(r"\bmodule\s+" + re.escape(module) + r"\b(.*?);", txt, re.S)
    if not m:
        return {}
    out = {}
    for name, val in re.findall(r"parameter\s+(?:integer\s+)?(\w+)\s*=\s*([^,\)\n]+)", m.group(1)):
        out[name] = val.strip()
    return out


def instantiation_overrides(path, module):
    """`module #(.NAME(VALUE), ...) inst (` -- the overrides an instantiation applies."""
    txt = read(path)
    m = re.search(re.escape(module) + r"\s*#\s*\((.*?)\)\s*\w+\s*\(", txt, re.S)
    if not m:
        return {}
    return {n: v.strip() for n, v in re.findall(r"\.(\w+)\s*\(\s*([^)]*?)\s*\)", m.group(1))}


def localparams(path):
    """The TB's own knobs. BOTH `localparam` and TB-level `parameter` -- benches use either, and
    missing one makes the gate report an unresolved name instead of the real value."""
    txt = read(path)
    # `(?:local)?param\s+` does NOT match "parameter": it consumes "param" and then demands
    # whitespace against the "eter". Spell both words out.
    return {n: v.strip() for n, v in
            re.findall(r"\b(?:localparam|parameter)\s+(?:integer\s+)?(\w+)\s*=\s*([^;,\)]+)", txt)}


def resolve(overrides, names, defaults):
    """A TB usually writes `.TAB_AW(TAB_AW)` and defines TAB_AW as a localparam. Follow that
    one hop, then fall back to the module default."""
    out = {}
    for k, v in overrides.items():
        v = v.strip()
        out[k] = names.get(v, v) if re.fullmatch(r"\w+", v) and not v.isdigit() else v
    for k, v in defaults.items():
        out.setdefault(k, v)
    return out


def check_one(rtl_name, wrapper_name, tb_name):
    module = rtl_name[:-2]
    rtl, tb = FPGA / rtl_name, FPGA / tb_name
    if not rtl.exists() or not tb.exists():
        print(f"  SKIP {module}: missing {rtl if not rtl.exists() else tb}")
        return True

    defaults = module_defaults(rtl, module)
    if not defaults:
        print(f"  SKIP {module}: no parameters declared")
        return True

    # SILICON side: the wrapper's overrides on top of the module defaults. No wrapper (the core is
    # instantiated directly in the SmartDesign) => the defaults ARE what synthesis builds.
    if wrapper_name and (FPGA / wrapper_name).exists():
        silicon = dict(defaults)
        silicon.update(instantiation_overrides(FPGA / wrapper_name, module))
        src = wrapper_name
    else:
        silicon, src = dict(defaults), f"{rtl_name} defaults"

    bench = resolve(instantiation_overrides(tb, module), localparams(tb), defaults)

    bad = []
    for k in sorted(set(silicon) | set(bench)):
        if k in IGNORE:
            continue
        s, b = silicon.get(k), bench.get(k)
        if s is None or b is None:
            continue
        if not b.isdigit():
            # Could not reduce the bench value to a number (a `define, a plusarg, a defparam).
            # That is still a FAIL: the gate exists to PROVE equivalence, and an unresolved
            # value proves nothing. Labelled so it is not mistaken for a numeric mismatch.
            bad.append((k, b + " (?)", s))
        elif s != b:
            bad.append((k, b, s))

    if bad and module in WAIVERS:
        print(f"  WAIVED {module}  (bench {tb_name}  vs  silicon {src})")
        print(f"        {'parameter':<14}{'BENCH':>10}{'SILICON':>10}")
        for k, b, s in bad:
            print(f"        {k:<14}{b:>10}{s:>10}")
        print(f"        reason: {WAIVERS[module]}")
        return True

    if bad:
        print(f"  FAIL {module}  (bench {tb_name}  vs  silicon {src})")
        print(f"        {'parameter':<14}{'BENCH':>10}{'SILICON':>10}")
        for k, b, s in bad:
            print(f"        {k:<14}{b:>10}{s:>10}")
        return False
    print(f"  ok   {module}  ({len(bench)} parameters agree with {src})")
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--list", action="store_true")
    a = ap.parse_args()
    if a.list:
        for r in REGISTRY:
            print(f"  {r[0]:<22} wrapper={r[1] or '(none)':<24} tb={r[2]}")
        return 0

    print("check_tb_params: does each bench instantiate what synthesis builds?")
    ok = all([check_one(*r) for r in REGISTRY])   # list(), not all-with-generator: check ALL
    if not ok:
        print("\n  A bench that runs a different parameterisation than synthesis proves NOTHING\n"
              "  about the bitstream. Either fix the bench to match, or -- if the override is\n"
              "  genuinely unavoidable -- add a second bench run at the silicon values and say\n"
              "  in the commit which properties the mismatched run can and cannot establish.")
    print(f"\n  {'PASS' if ok else 'FAIL'}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
