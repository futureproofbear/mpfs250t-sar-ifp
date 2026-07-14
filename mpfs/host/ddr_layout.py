"""Single source of truth for the JTAG-batch SAR datapath: DDR buffer addresses,
buffer sizes, the AXI4-Lite register map, and the on-disk binary formats.

This module is mirrored by the board-side C header ``ddr_sar_layout.h`` in this
repo's SoftConsole project (``mpfs/fpga/libero_sar/softconsole/mpfs-hal-ddr-demo/
src/sar/``) -- keep the two in lock-step. The host (serialize_inputs
/ dump_output) and the bare-metal driver both read their addresses from here so
there is exactly one place that defines the contract.

Why fixed addresses (not a CMA allocator): the runtime is bare-metal over JTAG,
so there is no Linux/CMA. The host bakes binaries into these absolute DDR
addresses with a debugger ``restore`` and dumps ``OUT`` back with ``dump binary
memory``; the bare-metal app programs the same addresses into the accelerator.

Memory map (Icicle Kit, cached DDR window @ 0x8000_0000, 1 GB total) -- see the
plan's risk #3 about the 1 GB vs 2 GB discrepancy; this layout fits 1 GB:

    0x80000000  +128 MB  app / heap / stack   (program when run from DDR)
    0x88000000  +256 MB  SIG      (input signal, complex int16 I/Q)
    0x98000000  +256 MB  SCRATCH  (corner-turn transpose buffer)
    0xA8000000  +128 MB  OUT      (detected magnitude, uint16 or uint8)
    0xB0000000   +16 MB  tables   (KR / KC / TANPHI / WIN tapers)
    0xB1000000  ......   free     (~240 MB headroom, double-buffering)
"""
from __future__ import annotations

import zlib
import numpy as np

# --------------------------------------------------------------------------- #
# Working-frame sizing. The fabric pads to a power-of-2 grid; buffers are sized
# to the padded maximum so the fixed addresses hold any scene up to GRID_MAX.
# --------------------------------------------------------------------------- #
GRID_MAX = 8192                      # padded FFT grid (rows = cols)
CPLX16_BYTES = 4                     # int16 I + int16 Q
FRAME_BYTES = GRID_MAX * GRID_MAX * CPLX16_BYTES        # 256 MiB
OUT_BYTES = GRID_MAX * GRID_MAX * 2                     # 128 MiB (uint16 worst case)

# --------------------------------------------------------------------------- #
# DDR buffer base addresses (physical, cached window).
# --------------------------------------------------------------------------- #
DDR_BASE = 0x80000000
APP_RESERVED = 0x08000000            # 128 MiB low DDR left for the program

SIG_ADDR     = 0x88000000            # +256 MiB -> 0x98000000
SCRATCH_ADDR = 0x98000000            # +256 MiB -> 0xA8000000
OUT_ADDR     = 0xA8000000            # +128 MiB -> 0xB0000000
TABLES_BASE  = 0xB0000000            # +16 MiB  -> 0xB1000000
KR_ADDR      = TABLES_BASE + 0x000000
KC_ADDR      = TABLES_BASE + 0x010000
TANPHI_ADDR  = TABLES_BASE + 0x020000
WIN_ADDR     = TABLES_BASE + 0x030000
JOB_ADDR     = TABLES_BASE + 0x040000   # job descriptor (host -> bare-metal app)

# Keystone resample geometry (small, O(M)/O(grid)) the MSS uses to compute the
# per-line resample coefficients on the fly -- avoids staging/transferring the
# ~768 MB full-grid coefficient set. Mirrors ddr_sar_layout.h (32 KiB slots).
GEOM_BASE     = TABLES_BASE + 0x100000
F0_ADDR       = GEOM_BASE + 0x00000     # float32[M]  start RF freq per pulse
DF_ADDR       = GEOM_BASE + 0x08000     # float32[M]  freq step per sample per pulse
PR_ADDR       = GEOM_BASE + 0x10000     # float32[M]  radial projection per pulse
TANS_ADDR     = GEOM_BASE + 0x18000     # float32[M]  tan(phi) sorted ascending
INVORDER_ADDR = GEOM_BASE + 0x20000     # int32[M]    pass-1 dst row (tan_phi sort)
KRGRID_ADDR   = GEOM_BASE + 0x28000     # float32[Np] padded range query grid
KCGRID_ADDR   = GEOM_BASE + 0x30000     # float32[Mp] padded cross query grid
HAMR_ADDR     = GEOM_BASE + 0x38000     # int16[Np]   1-D range Hamming taper (Q15)
HAMC_ADDR     = GEOM_BASE + 0x40000     # int16[Mp]   1-D cross Hamming taper (Q15)
# GEOM_BASE + 0x48000 .. + 0x380000 is firmware-internal resample-coeff scratch
# (single-line banks + chunked banks, see SAR_COEF*/SAR_COEFC* in ddr_sar_layout.h).
# The host does NOT load it; keep host allocations clear of this range.

DDR_TOP = DDR_BASE + 0x40000000      # 1 GiB ceiling (0xC0000000)

# --------------------------------------------------------------------------- #
# Job descriptor baked into DDR by the host. The bare-metal app reads it to know
# the scene size, the expected SIG CRC (M0 loopback), and the buffer addresses to
# program into the accelerator registers (M1/M2). Mirrors sar_job_t in
# ddr_sar_layout.h -- naturally aligned so packed == unpacked.
#   struct: 10x uint32 (one is int32 bfp_in_exp) then 7x uint64  = 96 bytes
# --------------------------------------------------------------------------- #
JOB_MAGIC = 0x53415231                  # 'SAR1'
JOB_FMT = "<IIIIIIiIII7Q"               # see field order in pack_job()
JOB_BYTES = 96


def pack_job(M, N, fft_r, fft_a, out_dtype, bfp_in_exp, sig_len, sig_crc):
    import struct
    return struct.pack(
        JOB_FMT,
        JOB_MAGIC, M, N, fft_r, fft_a, out_dtype, bfp_in_exp, sig_len, sig_crc, 0,
        SIG_ADDR, KR_ADDR, KC_ADDR, TANPHI_ADDR, WIN_ADDR, OUT_ADDR, SCRATCH_ADDR)

# --------------------------------------------------------------------------- #
# AXI4-Lite control register offsets (mirror of ../../docs/regmap.md). The bare-metal
# driver reaches these at the accelerator's fabric base over FIC.
# --------------------------------------------------------------------------- #
REG = {
    "CTRL":        0x00,   # bit0 START, bit1 RESET
    "STATUS":      0x04,   # bit0 DONE, bit1 BUSY, bit2 ERR
    "IRQ_EN":      0x08,   # bit0 enable done-interrupt
    "M":           0x0C,   # input rows (pulses)
    "N":           0x10,   # input cols (samples)
    "FFT_LEN_R":   0x14,   # range FFT length (pow2)
    "FFT_LEN_A":   0x18,   # azimuth FFT length (pow2)
    "BFP_SHIFT":   0x1C,   # block-floating-point exponent out
    "SIG_ADDR":    0x20,   # 64-bit (lo 0x20, hi 0x24)
    "KR_ADDR":     0x28,
    "KC_ADDR":     0x30,
    "TANPHI_ADDR": 0x38,
    "WIN_ADDR":    0x40,
    "OUT_ADDR":    0x48,
    "SCRATCH_ADDR": 0x50,
}
CTRL_START = 1 << 0
CTRL_RESET = 1 << 1
STATUS_DONE = 1 << 0
STATUS_BUSY = 1 << 1
STATUS_ERR  = 1 << 2

OUT_DTYPE_UINT16 = 0     # verification path (full dynamic range)
OUT_DTYPE_UINT8  = 1     # on-board AGC path (halves the JTAG dump)


def pow2(n: int) -> int:
    """Smallest power of two >= n."""
    p = 1
    while p < n:
        p <<= 1
    return p


# --------------------------------------------------------------------------- #
# Input-dimension handling limit + per-axis adaptive FFT-length selection.
#
# Datasets vary widely (Umbra CPHD NumSamples median ~22k, NumVectors median
# ~18k), so the gridded frame is chosen PER DATASET from the (decimated) dims:
#   * data that fits the native fabric CoreFFT (grid <= FFT_NATIVE = 8192) uses
#     the proven 8192 path -- unchanged, shipping today;
#   * larger data (up to HANDLING_LIMIT = 16384 per axis) needs the decomposed
#     16384-pt FFT + a 1 GiB-per-buffer DDR layout + 64-bit fabric addressing,
#     which is NOT YET BUILT (see the T3 scaling notes) -- the checker flags it;
#   * anything above HANDLING_LIMIT is rejected: decimate more.
# NumVectors -> azimuth (rows), NumSamples -> range (cols).
# --------------------------------------------------------------------------- #
FFT_NATIVE     = 8192       # native fabric CoreFFT point count (proven/shipping path)
HANDLING_LIMIT = 16384      # max supported gridded dimension per axis (hard ceiling)


def _ceil_div(a: int, b: int) -> int:
    return (a + b - 1) // b


def adaptive_fft_len(dim: int, axis: str = "") -> int:
    """Smallest supported FFT/grid length that holds `dim` samples on one axis:
    FFT_NATIVE (8192) when the data fits it, else HANDLING_LIMIT (16384).
    Raises ValueError if `dim` exceeds HANDLING_LIMIT."""
    g = pow2(dim)
    if g <= FFT_NATIVE:
        return FFT_NATIVE                      # <=8192 data -> native 8192 CoreFFT
    if g <= HANDLING_LIMIT:
        return HANDLING_LIMIT                   # 8193..16384 -> decomposed 16384 FFT (see needs_16384_path)
    raise ValueError(
        f"{axis or 'axis'} gridded dimension {dim} (pow2 {g}) exceeds the handling "
        f"limit {HANDLING_LIMIT}; increase decimation so this axis grids to "
        f"<= {HANDLING_LIMIT} (min decimation {_ceil_div(dim, HANDLING_LIMIT)}x).")


def plan_frame(num_vectors: int, num_samples: int,
               deci_pulse: int = 1, deci_sample: int = 1) -> dict:
    """Check + plan the working frame from raw CPHD dims. Applies decimation,
    validates each axis against HANDLING_LIMIT, and picks the per-axis FFT length
    (8192 native or 16384). Returns a plan dict; raises ValueError if the
    (decimated) data exceeds the handling limit on either axis."""
    M = _ceil_div(num_vectors, max(1, deci_pulse))    # azimuth rows  (NumVectors)
    N = _ceil_div(num_samples, max(1, deci_sample))   # range  cols   (NumSamples)
    fft_a = adaptive_fft_len(M, "azimuth (NumVectors)")
    fft_r = adaptive_fft_len(N, "range (NumSamples)")
    needs_16k = max(fft_a, fft_r) > FFT_NATIVE
    return {
        "M": M, "N": N, "fft_a": fft_a, "fft_r": fft_r,
        "grid": max(fft_a, fft_r),
        "native_8192": not needs_16k,       # True -> the shipping 8192 pipeline handles it as-is
        "needs_16384_path": needs_16k,      # True -> requires the not-yet-built 16384 datapath
    }


def check_input_dims(num_vectors: int, num_samples: int,
                     deci_pulse: int = 1, deci_sample: int = 1) -> dict:
    """Guard: raise unless the (decimated) CPHD dims are within the handling limit.
    Returns the plan on success. Thin wrapper over plan_frame for call sites that
    just want a pass/fail gate before staging a job."""
    return plan_frame(num_vectors, num_samples, deci_pulse, deci_sample)


def assert_fits():
    """Sanity-check that the working set stays under the 1 GB ceiling."""
    top = max(SIG_ADDR + FRAME_BYTES, SCRATCH_ADDR + FRAME_BYTES,
              OUT_ADDR + OUT_BYTES, WIN_ADDR + 0x010000)
    assert top <= DDR_TOP, f"layout overflows 1 GB DDR: 0x{top:08X} > 0x{DDR_TOP:08X}"
    assert SIG_ADDR >= DDR_BASE + APP_RESERVED, "SIG overlaps the app region"


# --------------------------------------------------------------------------- #
# eMMC persistent layout (fixed-LBA regions + per-region superblock/TOC).
#
# eMMC is NOT the boot medium (the app boots from eNVM), so the whole device is
# free for data. Two fixed logical regions, each with a versioned superblock +
# table-of-contents:
#   * INPUT  ('SARI') -- staged scene blobs (SIG + tables + geom); write-once,
#                        read-only at runtime.
#   * OUTPUT ('SARO') -- processed result images; the only region firmware writes
#                        while running.
# A low RESERVED region stays clear so a future eMMC bootloader/GPT can never
# collide with data.
#
# JOB IS NOT PERSISTED. The INPUT TOC stores the JOB-SEMANTIC fields; firmware
# reconstructs the (volatile) sar_job_t in DDR at boot via job_from_in_entry().
# So the JOB struct can keep changing during fabric/firmware iteration without
# reprovisioning the card -- only a TOC-layout change bumps EMMC_VERSION and
# forces a reprovision. Mirrors ddr_sar_layout.h -- keep in lock-step.
# --------------------------------------------------------------------------- #
EMMC_BLK           = 512
EMMC_RESERVED_LBA  = 0x00000            # boot / GPT / HSS headroom
EMMC_RESERVED_BLKS = 0x80000            # 256 MiB (data never touches below IN_LBA)
EMMC_IN_LBA        = 0x80000            # 256 MiB  : INPUT region base
EMMC_IN_BLKS       = 0x800000           # 4 GiB
EMMC_OUT_LBA       = 0x880000           # 4.25 GiB : OUTPUT region base
EMMC_OUT_BLKS      = 0x600000           # 3 GiB
EMMC_END_LBA       = EMMC_OUT_LBA + EMMC_OUT_BLKS   # device must be >= this (7.25 GiB)

EMMC_IN_MAGIC   = 0x53415249            # 'SARI'
EMMC_OUT_MAGIC  = 0x5341524F            # 'SARO'
EMMC_VERSION    = 1                     # bump on ANY TOC-layout change
EMMC_MAX_SCENES = 64                    # TOC capacity per region
EMMC_NAME_LEN   = 32

# struct formats (little-endian, packed == the C structs in ddr_sar_layout.h)
EMMC_SUPER_HDR_FMT = "<IIII"            # magic, version, count, reserved
EMMC_IN_ENTRY_FMT  = "<IIQQIIIIIiII32s" # sar_emmc_in_entry_t  (88 B)
EMMC_OUT_ENTRY_FMT = "<IIIIQQIIII"      # sar_emmc_out_entry_t (48 B)


def pack_in_entry(scene_id, lba, byte_len, blob_crc, M, N, fft_r, fft_a,
                  bfp_in_exp, sig_len, sig_crc, name):
    """Pack one INPUT TOC entry (valid=1). `name` is the scene code."""
    import struct
    nm = name.encode()[:EMMC_NAME_LEN].ljust(EMMC_NAME_LEN, b"\0")
    return struct.pack(EMMC_IN_ENTRY_FMT, 1, scene_id, lba, byte_len, blob_crc,
                       M, N, fft_r, fft_a, bfp_in_exp, sig_len, sig_crc, nm)


def job_from_in_entry(entry_fields, out_dtype):
    """Reconstruct the DDR JOB descriptor from an INPUT TOC entry.

    `entry_fields` is the tuple ``struct.unpack(EMMC_IN_ENTRY_FMT, ...)`` yields.
    This is the split that lets the JOB struct change without reprovisioning:
    the persisted contract is the TOC entry; the volatile sar_job_t is built here
    (out_dtype is a per-run choice, not an input property, so it is passed in)."""
    (_valid, _sid, _lba, _blen, _bcrc, M, N, fft_r, fft_a,
     bfp_in_exp, sig_len, sig_crc, _name) = entry_fields
    return pack_job(M, N, fft_r, fft_a, out_dtype, bfp_in_exp, sig_len, sig_crc)


def assert_emmc_fits(device_bytes=None):
    """Sanity-check the eMMC region math: ordered, non-overlapping regions, and
    struct formats matching the C sizes; optionally that it fits the device."""
    import struct
    assert EMMC_RESERVED_LBA + EMMC_RESERVED_BLKS <= EMMC_IN_LBA, "RESERVED overlaps INPUT"
    assert EMMC_IN_LBA + EMMC_IN_BLKS <= EMMC_OUT_LBA, "INPUT overlaps OUTPUT"
    assert struct.calcsize(EMMC_IN_ENTRY_FMT) == 88, "INPUT entry size drift vs C"
    assert struct.calcsize(EMMC_OUT_ENTRY_FMT) == 48, "OUTPUT entry size drift vs C"
    if device_bytes is not None:
        assert EMMC_END_LBA * EMMC_BLK <= device_bytes, (
            f"eMMC layout needs {EMMC_END_LBA * EMMC_BLK} B > device {device_bytes} B")


# --- INPUT scene blob: a self-describing container of DDR segments -------------
# One blob per scene = SIG + the 9 small geometry arrays (the exact bytes
# serialize_inputs.py stages; job.bin is NOT included -- JOB is reconstructed from
# the TOC). Firmware reads the header + segment table, then DMAs each segment from
# eMMC straight to its DDR buffer, resolving the address from the segment ROLE (not
# a stored address) -- the same decouple as job_from_in_entry: persist the role,
# resolve the volatile DDR address at boot. Segment payloads are 512-aligned in the
# blob so each maps to a block-aligned LBA for direct DMA. Mirror of ddr_sar_layout.h.
EMMC_BLOB_MAGIC   = 0x53415242          # 'SARB'
EMMC_BLOB_VERSION = 1
EMMC_BLOB_HDR_FMT = "<IIII"             # magic, version, seg_count, total_len (bytes)
EMMC_SEG_FMT      = "<IIII"             # role, blob_off (bytes, 512-aligned), byte_len, crc32

# segment role ids (blob segment -> DDR buffer). Order = serialize_inputs staging.
EMMC_ROLE = {"sig": 0, "f0": 1, "df": 2, "pr": 3, "tans": 4, "invorder": 5,
             "krgrid": 6, "kcgrid": 7, "hamr": 8, "hamc": 9}
# role id -> DDR base address firmware copies the segment to (mirror of the C map).
EMMC_ROLE_ADDR = {
    0: SIG_ADDR, 1: F0_ADDR, 2: DF_ADDR, 3: PR_ADDR, 4: TANS_ADDR, 5: INVORDER_ADDR,
    6: KRGRID_ADDR, 7: KCGRID_ADDR, 8: HAMR_ADDR, 9: HAMC_ADDR,
}


def _blkup(n):
    """Round n up to a whole eMMC block."""
    return (n + EMMC_BLK - 1) // EMMC_BLK * EMMC_BLK


def pack_blob(segs):
    """Pack an INPUT scene blob from ordered ``segs`` = [(role_id, payload_bytes)].
    Returns the blob bytes (block-aligned length). Segment payloads start at a
    512-aligned offset so their LBA is block-aligned for direct DMA to DDR."""
    import struct
    off0 = _blkup(struct.calcsize(EMMC_BLOB_HDR_FMT)
                  + struct.calcsize(EMMC_SEG_FMT) * len(segs))
    table, body, off = [], bytearray(), off0
    for role, pay in segs:
        table.append((role, off, len(pay), crc32(pay)))
        body += pay + b"\0" * ((-len(pay)) % EMMC_BLK)
        off = off0 + len(body)
    out = bytearray(struct.pack(EMMC_BLOB_HDR_FMT,
                                EMMC_BLOB_MAGIC, EMMC_BLOB_VERSION, len(segs), off))
    for e in table:
        out += struct.pack(EMMC_SEG_FMT, *e)
    out += b"\0" * (off0 - len(out))
    out += body
    return bytes(out)


def pack_in_super(entry_bytes_list):
    """Pack the INPUT superblock: header + the given TOC entries + empty slots,
    padded to a whole block. ``entry_bytes_list`` items come from pack_in_entry()."""
    import struct
    assert len(entry_bytes_list) <= EMMC_MAX_SCENES, "too many scenes for the TOC"
    esz = struct.calcsize(EMMC_IN_ENTRY_FMT)
    out = bytearray(struct.pack(EMMC_SUPER_HDR_FMT,
                                EMMC_IN_MAGIC, EMMC_VERSION, len(entry_bytes_list), 0))
    for e in entry_bytes_list:
        out += e
    out += b"\0" * (esz * (EMMC_MAX_SCENES - len(entry_bytes_list)))
    out += b"\0" * ((-len(out)) % EMMC_BLK)
    return bytes(out)


def crc32(buf: bytes) -> int:
    """IEEE 802.3 CRC-32, matching the board's ddr_packet_test reflected poly."""
    return zlib.crc32(buf) & 0xFFFFFFFF


def quantize_iq16(sig: np.ndarray):
    """Quantize a complex array to interleaved int16 I/Q (block-floating-point
    truncation, matching fixedpoint.quant mode='trunc'). Returns (codes, lsb, exp)
    where codes is a flat int16 array [I0,Q0,I1,Q1,...] and value = code * lsb."""
    import math
    M = max(float(np.abs(sig.real).max()), float(np.abs(sig.imag).max()))
    if M == 0.0:
        lsb, exp = 1.0, 0
    else:
        full = 2 ** 15 - 1
        exp = math.ceil(math.log2(M / full))
        lsb = 2.0 ** exp
    full = 2 ** 15 - 1
    qi = np.clip(np.floor(sig.real / lsb), -full - 1, full).astype(np.int16)
    qq = np.clip(np.floor(sig.imag / lsb), -full - 1, full).astype(np.int16)
    codes = np.empty(sig.size * 2, dtype=np.int16)
    codes[0::2] = qi.ravel()
    codes[1::2] = qq.ravel()
    return codes, lsb, exp
