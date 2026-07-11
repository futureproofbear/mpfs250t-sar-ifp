#!/usr/bin/env bash
# lint_netlist.sh -- pre-build firebreak for the two silent-failure classes that cost us
# multiple build cycles on the SAR DMA bring-up:
#   (1) silent address/data GROUNDING from a width-mismatched sd_connect_pins on a SLAVE port
#       (CIC 32-bit TARGET5_ARADDR -> DMA 11-bit CTRL_ARADDR left CTRL_ARADDR tied to 0).
#   (2) protocol-type mismatch: an interconnect target left TYPE=0 (Full AXI4) while the attached
#       IP is AXI4-Lite (no ID/burst) -> 64->32 DWC silently black-holes the transaction.
#
# Run AFTER generate_component (SAR_TOP.v exists) and BEFORE run_tool SYNTHESIZE -- a 1-second grep
# vs a ~30-minute synth+P&R. Exits 1 on CRITICAL so a build/CI wrapper aborts early.
#
# Scope note: only SLAVE-side (CTRL_/S_AXI/*target*) address/data ties are CRITICAL -- a slave that
# can't be addressed is always a bug. MASTER-side (INITIATOR*/MASTER*) and ID-channel tie-offs are
# routinely intentional (read-only/write-only masters, unused IDs) -> reported as INFO, never fatal.
#
# Usage:  bash lint_netlist.sh [SAR_TOP.v] [AXIIC_CTRL.cxf] [AXIIC_C0.cxf]
set -u
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/libero_sar" && pwd)"
NETLIST="${1:-$ROOT/component/work/SAR_TOP/SAR_TOP.v}"
CIC_CXF="${2:-$ROOT/component/work/AXIIC_CTRL/AXIIC_CTRL.cxf}"
DIC_CXF="${3:-$ROOT/component/work/AXIIC_C0/AXIIC_C0.cxf}"

crit=0; warn=0
CRIT() { printf '  \xe2\x9c\x97 CRITICAL: %s\n' "$*"; crit=$((crit+1)); }
WARN() { printf '  ! WARNING : %s\n' "$*"; warn=$((warn+1)); }
INFO() { printf '  . info    : %s\n' "$*"; }

[ -f "$NETLIST" ] || { echo "lint: netlist not found: $NETLIST"; exit 2; }
echo "=== netlist lint: $(basename "$NETLIST") ==="

# helper: lines where pin <regex> is tied to a *_const_net_*
ties() { grep -anE "\.[A-Za-z0-9_]*($1)[A-Za-z0-9_]*[[:space:]]*\([[:space:]]*[A-Za-z0-9_]*_const_net_[0-9]+" "$NETLIST" 2>/dev/null | sed 's/^[[:space:]]*//'; }

# --- Check 1: SLAVE-side address/data/strobe tied to const (the real bug class) -------------
echo "[1] slave-side address/data silently tied to const (un-addressable slave)..."
hit=0
while IFS= read -r line; do
    [ -z "$line" ] && continue
    # skip master-side and ID-channel ties (intentional)
    printf '%s' "$line" | grep -qiE "INITIATOR|MASTER|_[AR]?ID|WID|RID|BID" && continue
    pin=$(printf '%s' "$line" | grep -aoE "\.[A-Za-z0-9_]+" | head -1)
    CRIT "slave addr/data tied to const (connection silently failed): $pin"
    printf '              %s\n' "$line"; hit=1
done < <(ties "ARADDR|AWADDR|WDATA|RDATA|WSTRB")
[ "$hit" -eq 0 ] && echo "    ok"

# --- Check 1b: master-side / ID ties (informational -- usually intentional) -----------------
nmaster=$(ties "ARADDR|AWADDR|WDATA|WSTRB" | grep -ciE "INITIATOR|MASTER")
[ "$nmaster" -gt 0 ] && INFO "$nmaster master-side channel tie-off(s) (read/write-only masters -- verify intended)"

# --- Check 2: key AXI pins left floating (dropped connection) -------------------------------
echo "[2] floating (unconnected) AXI addr/data/handshake pins..."
hit=0
while IFS= read -r line; do
    [ -z "$line" ] && continue
    WARN "AXI pin left floating: $(printf '%s' "$line" | sed 's/^[[:space:]]*//')"; hit=1
done < <(grep -anE "\.[A-Za-z0-9_]*(ARADDR|AWADDR|WDATA|RDATA|ARVALID|AWVALID|WVALID|RVALID|BVALID)[A-Za-z0-9_]*[[:space:]]*\([[:space:]]*\)" "$NETLIST" 2>/dev/null)
[ "$hit" -eq 0 ] && echo "    ok"

# --- Check 3: interconnect target protocol-type audit (connected targets only) --------------
echo "[3] interconnect target TYPE audit (0=AXI4, 1=AXI4-Lite, 3=AXI3)..."
for cxf in "$CIC_CXF" "$DIC_CXF"; do
    [ -f "$cxf" ] || continue
    nm=$(basename "$(dirname "$cxf")")
    # only targets that are actually wired in the netlist (have a connected ARVALID)
    used=$(grep -aoE "TARGET[0-9]+_ARVALID[[:space:]]*\([[:space:]]*[A-Za-z0-9_]+" "$NETLIST" 2>/dev/null | grep -aoE "TARGET[0-9]+" | sort -u)
    [ -z "$used" ] && continue
    echo "    $nm (connected targets):"
    for t in $used; do
        v=$(grep -aoE "${t}_TYPE\" value=\"[0-9]+" "$cxf" 2>/dev/null | grep -aoE "[0-9]+$" | head -1)
        [ -n "$v" ] && printf '      %s_TYPE=%s%s\n' "$t" "$v" "$([ "$v" = 1 ] && echo '  (AXI4-Lite)')"
    done
done
echo "    NOTE: any reduced-AXI4-Lite peripheral (no AxID/AxPROT, e.g. DMA AXI4TargetCtrl) MUST be"
echo "          TYPE=1. TYPE=0 + width down-convert silently black-holes single-beat reads."

echo "=== lint: $crit critical, $warn warning ==="
[ "$crit" -gt 0 ] && { echo "BUILD ABORT: fix CRITICAL grounding before synth (saves ~30 min/cycle)."; exit 1; }
exit 0
