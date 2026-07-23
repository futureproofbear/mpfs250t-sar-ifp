#!/usr/bin/env bash
# sar_env.sh -- single source of truth for paths in the shell (JTAG/board) scripts.
#
# Source this from any script under the repo:
#     source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/sar_env.sh"   # from mpfs/host/*
#
# It gives you:
#   SAR_ROOT      absolute repo root, DERIVED from this file's location (never hard-coded)
#   SAR_HOST      $SAR_ROOT/mpfs/host
#   SAR_FPGA      $SAR_ROOT/mpfs/fpga
#   SAR_SCRATCH   repo-relative working dir for dumps/logs (config: board.scratch_dir)
#   SAR_OPENOCD / SAR_SOFTCONSOLE / SAR_LIBERO / SAR_PYTHON / SAR_VAULT / SAR_LICENSE
#   SAR_GDB       the riscv64 gdb inside SoftConsole
#   SAR_UART      console COM port (config: board.uart_port)
# plus helpers:  win_path <p>  -> C:/...      msys_path <p> -> /c/...
#
# EXTERNAL tool locations come from <root>/config.yaml (toolchain:); override the file
# with SAR_CONFIG=/path/to/other.yaml. Nothing here is user-specific.

# --- repo root, derived from this script's own location (mpfs/host/lib -> ../../..) ---
SAR_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SAR_HOST="$SAR_ROOT/mpfs/host"
SAR_FPGA="$SAR_ROOT/mpfs/fpga"
export SAR_ROOT SAR_HOST SAR_FPGA

# --- path helpers (msys <-> windows) ---
win_path()  { printf '%s' "$1" | sed -E 's#^/([a-zA-Z])/#\1:/#'; }
msys_path() { printf '%s' "$1" | sed -E 's#^([a-zA-Z]):[/\\]#/\L\1/#; s#\\#/#g'; }

# --- read a flat "key: value" from a top-level yaml section (no yaml dep) ---
# config.local.yaml (git-ignored) wins over config.yaml, so YOUR machine-specific paths
# never get committed. Keep only the keys you need to override in the local file.
SAR_CONFIG="${SAR_CONFIG:-$SAR_ROOT/config.yaml}"
SAR_CONFIG_LOCAL="$SAR_ROOT/config.local.yaml"
_sar_cfg1() { # _sar_cfg1 <file> <section> <key>
  [ -f "$1" ] || return 0
  awk -v sec="$2:" -v key="$3:" '
    $0 ~ "^"sec"[[:space:]]*$" {inside=1; next}
    inside && /^[^[:space:]#]/ {inside=0}
    inside && $1==key {sub(/^[[:space:]]*[^:]+:[[:space:]]*/,""); sub(/[[:space:]]+#.*$/,""); print; exit}
  ' "$1"
}
_sar_cfg() { # _sar_cfg <section> <key>  -- local override first
  local v; v="$(_sar_cfg1 "$SAR_CONFIG_LOCAL" "$1" "$2")"
  [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  _sar_cfg1 "$SAR_CONFIG" "$1" "$2"
}

SAR_LIBERO="$(_sar_cfg toolchain libero)"
SAR_SOFTCONSOLE="$(_sar_cfg toolchain softconsole)"
SAR_OPENOCD="$(_sar_cfg toolchain openocd)"
SAR_PYTHON="$(_sar_cfg toolchain python)"
SAR_VAULT="$(_sar_cfg toolchain vault)"
SAR_LICENSE="$(_sar_cfg toolchain license_file)"
SAR_UART="$(_sar_cfg board uart_port)"
_scratch="$(_sar_cfg board scratch_dir)"
SAR_SCRATCH="$SAR_ROOT/${_scratch:-scratch}"

# shell scripts want msys form for local use; keep windows form for passing to .exe args
SAR_OPENOCD="$(msys_path "${SAR_OPENOCD:-}")"
SAR_SOFTCONSOLE="$(msys_path "${SAR_SOFTCONSOLE:-}")"
SAR_GDB="$SAR_SOFTCONSOLE/riscv-unknown-elf-gcc/bin/riscv64-unknown-elf-gdb.exe"
export SAR_LIBERO SAR_SOFTCONSOLE SAR_OPENOCD SAR_PYTHON SAR_VAULT SAR_LICENSE \
       SAR_UART SAR_SCRATCH SAR_GDB SAR_CONFIG

mkdir -p "$SAR_SCRATCH" 2>/dev/null || true

# --- fail loudly + early if an external tool is still a placeholder or missing ---
sar_require() { # sar_require SAR_OPENOCD [SAR_GDB ...]
  local v p bad=0
  for v in "$@"; do
    p="${!v-}"
    if [ -z "$p" ] || case "$p" in *"<you>"*) true;; *) false;; esac; then
      echo "ERROR: $v is unset/placeholder -- edit toolchain: in $SAR_CONFIG" >&2; bad=1; continue
    fi
    [ -e "$p" ] || { echo "ERROR: $v does not exist: $p (edit $SAR_CONFIG)" >&2; bad=1; }
  done
  [ "$bad" -eq 0 ] || return 1
}
