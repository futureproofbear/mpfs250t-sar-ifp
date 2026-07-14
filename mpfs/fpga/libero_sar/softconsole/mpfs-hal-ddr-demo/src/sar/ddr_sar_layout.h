/*******************************************************************************
 * ddr_sar_layout.h
 *
 * Bare-metal mirror of the host module sarProcessor/mpfs/host/ddr_layout.py.
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

/* ---- eMMC persistent layout (fixed-LBA regions + per-region superblock/TOC) --
 * eMMC is NOT the boot medium (the app boots from eNVM), so the whole device is
 * free for data. Two fixed logical regions, each versioned:
 *   INPUT  'SARI' -- staged scene blobs (SIG + tables + geom), write-once / RO.
 *   OUTPUT 'SARO' -- processed images, the only region firmware writes at runtime.
 * A low RESERVED region stays clear so a future eMMC boot/GPT can never collide.
 *
 * JOB IS NOT PERSISTED: the INPUT TOC stores the job-SEMANTIC fields and firmware
 * rebuilds sar_job_t in DDR at boot from them, so the volatile JOB layout can
 * keep changing during fabric/firmware iteration without reprovisioning the card
 * -- only a TOC-layout change bumps SAR_EMMC_VERSION and forces a reprovision.
 * Mirror of ddr_layout.py -- keep in lock-step. */
#define SAR_EMMC_BLK            (512u)
#define SAR_EMMC_RESERVED_LBA   (0x00000ULL)
#define SAR_EMMC_RESERVED_BLKS  (0x80000ULL)   /* 256 MiB (data never touches below IN) */
#define SAR_EMMC_IN_LBA         (0x80000ULL)   /* 256 MiB  : INPUT base */
#define SAR_EMMC_IN_BLKS        (0x800000ULL)  /* 4 GiB */
#define SAR_EMMC_OUT_LBA        (0x880000ULL)  /* 4.25 GiB : OUTPUT base */
#define SAR_EMMC_OUT_BLKS       (0x600000ULL)  /* 3 GiB */
#define SAR_EMMC_END_LBA        (SAR_EMMC_OUT_LBA + SAR_EMMC_OUT_BLKS) /* device >= this (7.25 GiB) */

#define SAR_EMMC_IN_MAGIC       (0x53415249u)  /* 'SARI' */
#define SAR_EMMC_OUT_MAGIC      (0x5341524Fu)  /* 'SARO' */
#define SAR_EMMC_VERSION        (1u)           /* bump on ANY TOC-layout change */
#define SAR_EMMC_MAX_SCENES     (64u)          /* TOC capacity per region */
#define SAR_EMMC_NAME_LEN       (32u)

/* INPUT TOC entry (88 B). The job-semantic fields feed sar_job_t at boot;
 * sar_job_t itself is never stored on the card. */
typedef struct __attribute__((packed)) {
    uint32_t valid;              /* 0 = empty slot */
    uint32_t scene_id;
    uint64_t lba;                /* absolute device LBA of the scene blob */
    uint64_t byte_len;           /* full blob length (SIG + tables + geom) */
    uint32_t blob_crc;           /* CRC32 of the whole blob (read-back check) */
    uint32_t M, N, fft_r, fft_a; /* -> sar_job_t */
    int32_t  bfp_in_exp;         /* -> sar_job_t */
    uint32_t sig_len;            /* -> sar_job_t (SIG sub-length within blob) */
    uint32_t sig_crc;            /* -> sar_job_t (SIG loopback CRC) */
    char     name[SAR_EMMC_NAME_LEN];  /* scene code (e.g. capture folder) */
} sar_emmc_in_entry_t;

typedef struct __attribute__((packed)) {
    uint32_t magic;              /* SAR_EMMC_IN_MAGIC */
    uint32_t version;            /* SAR_EMMC_VERSION */
    uint32_t count;              /* used TOC entries */
    uint32_t reserved;
    sar_emmc_in_entry_t toc[SAR_EMMC_MAX_SCENES];
} sar_emmc_in_super_t;

/* OUTPUT TOC entry (48 B): one per processing run. */
typedef struct __attribute__((packed)) {
    uint32_t valid;
    uint32_t scene_id;           /* INPUT scene that produced this */
    uint32_t run_seq;            /* monotonic run counter */
    uint32_t out_dtype;          /* SAR_OUT_DTYPE_* */
    uint64_t lba;                /* absolute device LBA of the image */
    uint64_t byte_len;
    uint32_t rows, cols;
    uint32_t out_crc;
    uint32_t reserved;
} sar_emmc_out_entry_t;

typedef struct __attribute__((packed)) {
    uint32_t magic;              /* SAR_EMMC_OUT_MAGIC */
    uint32_t version;            /* SAR_EMMC_VERSION */
    uint32_t count;
    uint32_t reserved;
    sar_emmc_out_entry_t toc[SAR_EMMC_MAX_SCENES];
} sar_emmc_out_super_t;

/* ---- INPUT scene blob: self-describing container of DDR segments -------------
 * One blob per scene (SIG + the 9 geometry arrays). Firmware reads the header +
 * segment table, then DMAs each segment from eMMC straight to its DDR buffer,
 * resolving the address from the segment ROLE via sar_emmc_role_addr() -- the raw
 * DDR address is NOT stored, so the DDR layout can change without reprovisioning.
 * Payloads are 512-aligned in the blob (block-aligned LBA for direct DMA).
 * Mirror of ddr_layout.py -- keep in lock-step. */
#define SAR_EMMC_BLOB_MAGIC     (0x53415242u)  /* 'SARB' */
#define SAR_EMMC_BLOB_VERSION   (1u)

typedef enum {
    SAR_SEG_SIG = 0, SAR_SEG_F0, SAR_SEG_DF, SAR_SEG_PR, SAR_SEG_TANS,
    SAR_SEG_INVORDER, SAR_SEG_KRGRID, SAR_SEG_KCGRID, SAR_SEG_HAMR, SAR_SEG_HAMC,
    SAR_SEG_COUNT
} sar_emmc_role_t;

typedef struct __attribute__((packed)) {
    uint32_t role;               /* sar_emmc_role_t */
    uint32_t blob_off;           /* byte offset in blob (512-aligned) */
    uint32_t byte_len;
    uint32_t crc;                /* CRC32 of the segment payload */
} sar_emmc_seg_t;

typedef struct __attribute__((packed)) {
    uint32_t magic;              /* SAR_EMMC_BLOB_MAGIC */
    uint32_t version;            /* SAR_EMMC_BLOB_VERSION */
    uint32_t seg_count;
    uint32_t total_len;          /* blob length in bytes (block-aligned) */
    /* sar_emmc_seg_t seg[seg_count] follows */
} sar_emmc_blob_hdr_t;

/* role -> DDR base address (mirror of EMMC_ROLE_ADDR in ddr_layout.py). */
static inline uint64_t sar_emmc_role_addr(uint32_t role)
{
    switch (role) {
    case SAR_SEG_SIG:      return SAR_SIG_ADDR;
    case SAR_SEG_F0:       return SAR_F0_ADDR;
    case SAR_SEG_DF:       return SAR_DF_ADDR;
    case SAR_SEG_PR:       return SAR_PR_ADDR;
    case SAR_SEG_TANS:     return SAR_TANS_ADDR;
    case SAR_SEG_INVORDER: return SAR_INVORDER_ADDR;
    case SAR_SEG_KRGRID:   return SAR_KRGRID_ADDR;
    case SAR_SEG_KCGRID:   return SAR_KCGRID_ADDR;
    case SAR_SEG_HAMR:     return SAR_HAMR_ADDR;
    case SAR_SEG_HAMC:     return SAR_HAMC_ADDR;
    default:               return 0;
    }
}


#ifdef __cplusplus
}
#endif

#endif /* DDR_SAR_LAYOUT_H_ */
