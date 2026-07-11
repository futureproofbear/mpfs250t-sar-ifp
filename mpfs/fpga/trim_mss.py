#!/usr/bin/env python3
# Trim the full Icicle MSS config down to: FIC_0 + LPDDR4 + MMUART_0 only.
# Disables FIC_1/2/3 and routes every other peripheral to UNUSED so the MSS stops
# exposing ~1300 fabric/MSSIO ports (which blew past the 144 fabric-I/O limit).
import sys, re

SRC = "mss_component/ICICLE_MSS.cfg.orig"
DST = "mss_component/ICICLE_MSS_min.cfg"

# specific keys that must take a fixed value (dependency fixes)
SET_VALS = {"EMMC_SD_SWITCHING": "DISABLED"}

# routing target values that mean "this peripheral is pinned out" -> set UNUSED
ROUTE_VALS = {"FABRIC", "MSSIO_B2", "MSSIO_B2_B", "MSSIO_B4", "MSSIO_B5",
              "MSSIO_B6", "SGMII_IO_B5"}
# keys to KEEP enabled even though they have a routing value
KEEP_KEYS = {"MMUART_0"}
# FIC enable flags to force false (keep only FIC_0)
FIC_FALSE = {"FIC_1_AXI4_INITIATOR_USED", "FIC_1_AXI4_TARGET_USED",
             "FIC_2_AXI4_INITIATOR_USED", "FIC_2_AXI4_TARGET_USED",
             "FIC_3_APB_INITIATOR_USED"}

changed = []
out = []
with open(SRC) as f:
    for line in f:
        m = re.match(r'^(\S+)(\s+)(\S.*?)\s*$', line.rstrip("\n"))
        if not m:
            out.append(line); continue
        key, gap, val = m.group(1), m.group(2), m.group(3)
        newval = val
        if key in SET_VALS:
            newval = SET_VALS[key]
        elif key in FIC_FALSE and val.lower() == "true":
            newval = "false"
        elif key not in KEEP_KEYS and val in ROUTE_VALS:
            newval = "UNUSED"
        if newval != val:
            changed.append(f"{key}: {val} -> {newval}")
            out.append(f"{key}{gap}{newval}\n")
        else:
            out.append(line if line.endswith("\n") else line + "\n")

with open(DST, "w") as f:
    f.writelines(out)

print(f"wrote {DST}  ({len(changed)} changes)")
for c in changed:
    print("  ", c)
