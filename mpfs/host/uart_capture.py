#!/usr/bin/env python
"""Capture the MSS console during boot and report the DDR training result.

The MPFS HAL trains LPDDR4 on every power-on and prints the outcome over MMUART0.
`DEBUG_DDR_INIT` and `DEBUG_DDR_RD_RW_FAIL` are enabled in
boards/icicle-kit-es-ddr-666MHz/platform_config/mpfs_hal_config/mss_sw_config.h, so the
training status, write-calibration result and DQ/DQS window offsets are emitted every
boot -- and until now nothing has ever read them.

Why it matters: every fabric kernel measures 70-85 MB/s against a 500 MB/s FIC_0 ceiling,
and three separate data-movement optimisations (burst length, outstanding depth, beat
packing) all produced ~zero. A degraded-but-working DDR would inflate latency uniformly
and is consistent with that pattern. This does not prove it -- it just stops us guessing.

USAGE (the board must be OFF when you start this, then power it on):
    python mpfs/host/uart_capture.py --seconds 60
    ... power on the board now ...

The port defaults to config.yaml `board.uart_port`. 115200 8N1.
"""
import argparse
import datetime
import pathlib
import re
import sys

try:
    import serial
    import serial.tools.list_ports as list_ports
except ImportError:
    sys.exit("pyserial not installed:  python -m pip install pyserial")

# Markers the HAL emits (mss_ddr_debug.c). Ordered roughly as they appear.
MARKERS = [
    (re.compile(r"DDR Training version", re.I), "version"),
    (re.compile(r"training status\s*=\s*(0x[0-9a-fA-F]+)", re.I), "status"),
    (re.compile(r"WRCALIB_RESULT\s*:?\s*(0x[0-9a-fA-F]+)", re.I), "wrcalib"),
    (re.compile(r"DQDQS training window offset delay", re.I), "dqdqs"),
    (re.compile(r"READ/\s*WRITE ACCESS PASSED", re.I), "rw_pass"),
    (re.compile(r"FAIL|ERROR|RETRY", re.I), "fail"),
]


def cfg_port(default="COM4"):
    """Read board.uart_port from config.local.yaml then config.yaml (no yaml dep)."""
    root = pathlib.Path(__file__).resolve().parents[2]
    for name in ("config.local.yaml", "config.yaml"):
        p = root / name
        if not p.exists():
            continue
        for line in p.read_text(errors="replace").splitlines():
            m = re.match(r"\s*uart_port\s*:\s*(\S+)", line)
            if m:
                return m.group(1)
    return default


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", default=None, help="serial port (default: config board.uart_port)")
    ap.add_argument("--baud", type=int, default=115200)
    ap.add_argument("--seconds", type=float, default=60.0, help="how long to listen")
    ap.add_argument("--out", default=None, help="raw log path (default jtag_full/uart_<ts>.log)")
    a = ap.parse_args()

    port = a.port or cfg_port()
    here = pathlib.Path(__file__).resolve().parent
    stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    out = pathlib.Path(a.out) if a.out else here / "jtag_full" / f"uart_{stamp}.log"
    out.parent.mkdir(parents=True, exist_ok=True)

    available = [p.device for p in list_ports.comports()]
    if port not in available:
        print(f"[warn] {port} not enumerated. Present: {available or 'none'}")
        print("       The board's USB serial only appears when it is POWERED ON.")
        print("       Start this with the board OFF, then power it on -- or check the port name.")

    print(f"[uart] {port} @ {a.baud} for {a.seconds:.0f}s -> {out}")
    print("[uart] power-cycle the board NOW to catch the DDR training output\n")

    hits, lines = {}, 0
    try:
        with serial.Serial(port, a.baud, timeout=0.5) as ser, out.open("w", encoding="utf-8") as fh:
            deadline = datetime.datetime.now() + datetime.timedelta(seconds=a.seconds)
            buf = b""
            while datetime.datetime.now() < deadline:
                buf += ser.read(4096)
                while b"\n" in buf:
                    raw, buf = buf.split(b"\n", 1)
                    text = raw.decode("utf-8", errors="replace").rstrip("\r")
                    lines += 1
                    fh.write(text + "\n")
                    fh.flush()
                    print("   " + text)
                    for rx, key in MARKERS:
                        m = rx.search(text)
                        if m:
                            hits.setdefault(key, []).append(
                                m.group(1) if m.groups() else text.strip())
    except serial.SerialException as e:
        sys.exit(f"[uart] cannot open {port}: {e}\n"
                 f"       Is the board powered on? Is another tool holding the port?")
    except KeyboardInterrupt:
        print("\n[uart] interrupted")

    print(f"\n[uart] {lines} lines -> {out}")
    print("=== DDR training summary ===")
    if not hits:
        print("  NOTHING MATCHED. Either the board did not boot during the window, the console")
        print("  is on a different port, or DEBUG_DDR_INIT is not compiled in this image.")
        print("  Do NOT read that as 'training passed'.")
        return 1
    for key in ("version", "status", "wrcalib", "dqdqs", "rw_pass", "fail"):
        for v in hits.get(key, []):
            print(f"  {key:8s} {v}")
    if "fail" in hits:
        print("\n  ^ FAIL/ERROR/RETRY seen -- treat DDR as suspect and read the raw log.")
    elif "status" in hits:
        print("\n  Interpretation: a nonzero `training status` means at least one training")
        print("  stage did not converge cleanly. Compare WRCALIB_RESULT lanes against the")
        print("  MPFS HAL reference before concluding the DDR is healthy.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
