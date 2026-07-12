/*******************************************************************************
 * ddr_sar_layout.h
 *
 * Bare-metal mirror of the host module mpfs250t-sar-ifp/mpfs/host/ddr_layout.py.
 * Defines the JTAG-batch SAR contract: DDR buffer addresses, the accelerator
 * AXI4-Lite register map, and the job descriptor the host bakes into DDR.
 *
 * KEEP IN LOCK-STEP with ddr_layout.py -- it is the single source of truth.
 *
 * Runtime model: no Linux/CMA. The host loads binaries into the fixed DDR
 * addresses below with a debugger `restore`, then `continue`s this app, which
 * reads the job descriptor at JOB_ADDR and (M1/M2) programs the accelerator.
 * The host dumps OUT_ADDR back over JTAG.
 *
 * Memory map (Icicle Kit, cached DDR @ 0x8000_0000, 1 GB):
 *   0x80000000  +128 MB  app / heap / stack
 *   0x88000000  +256 MB  SIG      (input signal, complex int16 I/Q)
 *   0x98000000  +256 MB  SCRATCH  (corner-turn transpose buffer)
 *   0xA8000000  +128 MB  OUT      (detected magnitude, uint16/uint8)
 *   0xB0000000   +16 MB  tables   (KR / KC / TANPHI / WIN / JOB)
 ******************************************************************************/
#ifndef DDR_SAR_LAYOUT_H_
#define DDR_SAR_LAYOUT_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---- DDR buffer base addresses (physical, cached window) ---------------- */
#define SAR_SIG_ADDR        (0x88000000ULL)
#define SAR_SCRATCH_ADDR    (0x98000000ULL)
#define SAR_OUT_ADDR        (0xA8000000ULL)
#define SAR_TABLES_BASE     (0xB0000000ULL)
#define SAR_KR_ADDR         (SAR_TABLES_BASE + 0x000000ULL)
#define SAR_KC_ADDR         (SAR_TABLES_BASE + 0x010000ULL)
#define SAR_TANPHI_ADDR     (SAR_TABLES_BASE + 0x020000ULL)
#define SAR_WIN_ADDR        (SAR_TABLES_BASE + 0x030000ULL)  /* 2-D Hamming, Q15 int16 */
#define SAR_JOB_ADDR        (SAR_TABLES_BASE + 0x040000ULL)

/* ---- Keystone resample: small per-pulse geometry (host-staged, KB-sized) ----
 * The MSS computes the (large, per-line) idx/wq coefficients on the fly from
 * these, so we never store/transfer the ~768 MB full-grid coefficient set.
 * Each slot is 32 KiB (>= SAR_GRID_MAX * 4 B). */
#define SAR_GEOM_BASE       (SAR_TABLES_BASE + 0x100000ULL)
#define SAR_F0_ADDR         (SAR_GEOM_BASE + 0x00000ULL)  /* float[M]  start RF freq/pulse */
#define SAR_DF_ADDR         (SAR_GEOM_BASE + 0x08000ULL)  /* float[M]  freq step/sample/pulse */
#define SAR_PR_ADDR         (SAR_GEOM_BASE + 0x10000ULL)  /* float[M]  radial proj/pulse */
#define SAR_TANS_ADDR       (SAR_GEOM_BASE + 0x18000ULL)  /* float[M]  tan(phi) sorted asc */
#define SAR_INVORDER_ADDR   (SAR_GEOM_BASE + 0x20000ULL)  /* int32[M]  pass-1 dst row (tan_phi sort) */
#define SAR_KRGRID_ADDR     (SAR_GEOM_BASE + 0x28000ULL)  /* float[Np] uniform range grid */
#define SAR_KCGRID_ADDR     (SAR_GEOM_BASE + 0x30000ULL)  /* float[Mp] uniform cross grid */
/* 1-D Hamming tapers (Q15, data-extent, zero in FFT pad); the window kernel
 * forms the 2-D product hamr[j]*hamc[k] on the fly. */
#define SAR_HAMR_ADDR       (SAR_GEOM_BASE + 0x38000ULL)  /* int16[Np] range taper */
#define SAR_HAMC_ADDR       (SAR_GEOM_BASE + 0x40000ULL)  /* int16[Mp] cross taper */

/* MSS-computed coefficient line buffers, double-buffered (idx int32 + wq int16
 * per line); the resample kernel reads the active one while the MSS fills the
 * other. Two banks of (32 KiB idx + 16 KiB wq), 128 KiB apart. */
#define SAR_COEF_BASE       (SAR_GEOM_BASE + 0x48000ULL)
#define SAR_COEF_BANK(b)    (SAR_COEF_BASE + (uint64_t)(b) * 0x20000ULL)
#define SAR_COEF_IDX(b)     (SAR_COEF_BANK(b) + 0x00000ULL)   /* int32[Np] */
#define SAR_COEF_WQ(b)      (SAR_COEF_BANK(b) + 0x10000ULL)   /* int16[Np] */
#define SAR_COEF_LINE_F32   (SAR_COEF_BASE + 0x80000ULL)      /* float[Np] kr/src scratch */

#define SAR_GRID_MAX        (8192u)
#define SAR_FRAME_BYTES     ((uint64_t)SAR_GRID_MAX * SAR_GRID_MAX * 4u)  /* 256 MiB */
#define SAR_OUT_BYTES       ((uint64_t)SAR_GRID_MAX * SAR_GRID_MAX * 2u)  /* 128 MiB */

/* Chunked resample coefficients (per-CHUNK L2 flush instead of per-line).
 * The per-line whole-L2 flush -- each walks all 16 L2 ways, and it sits on the
 * resample critical path -- dominated the stage. The sequencer now precomputes
 * RESAMPLE_CHUNK lines of coeffs per fabric-arm batch and flushes ONCE per
 * chunk. Two chunk banks, double-buffered: the fabric streams bank b while the
 * MSS fills bank b^1, so the next chunk's coeff compute overlaps this chunk's
 * kernel runs (as the per-line path already did). Each line slot is a fixed
 * 48 KiB (32 KiB idx + 16 KiB wq) sized for the worst-case grid, so the slot
 * stride is Np/Mp-agnostic. Firmware-internal DDR scratch (host does not load
 * it; reserved in ddr_layout.py). Numerically identical to the per-line path. */
#define RESAMPLE_CHUNK          (16u)
#define SAR_COEFC_LINE_BYTES    ((uint64_t)SAR_GRID_MAX * 4u + (uint64_t)SAR_GRID_MAX * 2u) /* 48 KiB */
#define SAR_COEFC_BASE          (SAR_GEOM_BASE + 0x100000ULL)   /* 1 MiB into geom, clear of the F32 scratch */
#define SAR_COEFC_BANK(b)       (SAR_COEFC_BASE + (uint64_t)(b) * (uint64_t)RESAMPLE_CHUNK * SAR_COEFC_LINE_BYTES)
#define SAR_COEFC_IDX(b, c)     (SAR_COEFC_BANK(b) + (uint64_t)(c) * SAR_COEFC_LINE_BYTES)   /* int32[<=Np] */
#define SAR_COEFC_WQ(b, c)      (SAR_COEFC_IDX(b, c) + (uint64_t)SAR_GRID_MAX * 4u)          /* int16[<=Np] */

/* ---- Accelerator AXI4-Lite control base (mapped via FIC) -----------------
 * PLACEHOLDER: set to the real fabric base from the Libero memory map once the
 * accelerator is instantiated (FIC0 commonly maps at 0x6000_0000 on MPFS).   */
#ifndef SAR_ACCEL_BASE
#define SAR_ACCEL_BASE      (0x60000000ULL)
#endif

/* ---- AXI4-Lite register offsets (mirror of mpfs/regmap.md) -------------- */
#define SAR_REG_CTRL        (0x00u)   /* bit0 START, bit1 RESET */
#define SAR_REG_STATUS      (0x04u)   /* bit0 DONE, bit1 BUSY, bit2 ERR */
#define SAR_REG_IRQ_EN      (0x08u)
#define SAR_REG_M           (0x0Cu)
#define SAR_REG_N           (0x10u)
#define SAR_REG_FFT_LEN_R   (0x14u)
#define SAR_REG_FFT_LEN_A   (0x18u)
#define SAR_REG_BFP_SHIFT   (0x1Cu)
#define SAR_REG_SIG_ADDR    (0x20u)   /* 64-bit: lo 0x20, hi 0x24 */
#define SAR_REG_KR_ADDR     (0x28u)
#define SAR_REG_KC_ADDR     (0x30u)
#define SAR_REG_TANPHI_ADDR (0x38u)
#define SAR_REG_WIN_ADDR    (0x40u)
#define SAR_REG_OUT_ADDR    (0x48u)
#define SAR_REG_SCRATCH_ADDR (0x50u)

#define SAR_CTRL_START      (1u << 0)
#define SAR_CTRL_RESET      (1u << 1)
#define SAR_STATUS_DONE     (1u << 0)
#define SAR_STATUS_BUSY     (1u << 1)
#define SAR_STATUS_ERR      (1u << 2)

#define SAR_OUT_DTYPE_UINT16 (0u)
#define SAR_OUT_DTYPE_UINT8  (1u)

/* ---- Job descriptor (host -> app), mirror of ddr_layout.pack_job() ------
 * Naturally aligned (10x 32-bit then 7x 64-bit) so packed == unpacked = 96 B. */
#define SAR_JOB_MAGIC       (0x53415231u)   /* 'SAR1' */

typedef struct __attribute__((packed)) {
    uint32_t magic;
    uint32_t M;             /* input rows (pulses) */
    uint32_t N;             /* input cols (samples) */
    uint32_t fft_r;         /* range FFT length (pow2) */
    uint32_t fft_a;         /* azimuth FFT length (pow2) */
    uint32_t out_dtype;     /* SAR_OUT_DTYPE_* */
    int32_t  bfp_in_exp;    /* input-quant exponent (value = code * 2^exp) */
    uint32_t sig_len;       /* SIG bytes */
    uint32_t sig_crc;       /* expected CRC32 of SIG region (loopback check) */
    uint32_t reserved;
    uint64_t sig_addr;
    uint64_t kr_addr;
    uint64_t kc_addr;
    uint64_t tanphi_addr;
    uint64_t win_addr;
    uint64_t out_addr;
    uint64_t scratch_addr;
} sar_job_t;

#ifdef __cplusplus
}
#endif

#endif /* DDR_SAR_LAYOUT_H_ */
