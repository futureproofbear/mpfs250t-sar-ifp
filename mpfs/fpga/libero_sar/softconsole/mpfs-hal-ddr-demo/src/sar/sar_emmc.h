/*******************************************************************************
 * sar_emmc.h -- eMMC bring-up + (later) CPHD provisioning/loading for the SAR
 * datapath. Milestone-1 here is a self-contained write->read->CRC round trip
 * that validates the MSS eMMC path AND the L2-coherency handling, with NO fabric
 * dependency (pure MSS + SDMMC hard block). It runs only when the app is built
 * with -DSAR_EMMC_ENABLE and the host pokes the eMMC mailbox command.
 *
 * Result is latched in DDR (no UART in this app) for a one-burst JTAG read, the
 * same reporting model as the M2 harness.
 *
 * Prereqs (board side, sarProcessor build): the MSS must be configured for eMMC
 * (MSSIO mux -> eMMC, not SD) and the mss_mmc driver compiled into the project.
 ******************************************************************************/
#ifndef SAR_EMMC_H_
#define SAR_EMMC_H_

#include <stdint.h>
#include "ddr_sar_layout.h"   /* SAR_EMMC_OUT_LBA */

/* Milestone-1 result record, latched in the DDR gap (job..geom) the host reads
 * over JTAG. Clear of the M2 result table (0xB0050000) and mailbox (0xB0058000). */
#define SAR_EMMC_RESULT_ADDR   (0xB005A000u)
#define SAR_EMMC_RESULT_MAGIC  (0xE3C0FFEEu)

/* Default scratch block for the round trip: the START of the OUTPUT region, so
 * the test never touches provisioned INPUT data (and there is no OUTPUT yet). */
#define SAR_EMMC_SCRATCH_LBA   ((uint32_t)SAR_EMMC_OUT_LBA)

/* verdict / fail codes */
enum {
    SAR_EMMC_PASS      = 0u,
    SAR_EMMC_ERR_INIT  = 1u,
    SAR_EMMC_ERR_WRITE = 2u,
    SAR_EMMC_ERR_READ  = 3u,
    SAR_EMMC_ERR_CRC   = 4u
};

typedef struct {
    volatile uint32_t magic;         /* SAR_EMMC_RESULT_MAGIC once valid */
    volatile uint32_t init_status;   /* MSS_MMC_init() return */
    volatile uint32_t write_status;  /* block-write return */
    volatile uint32_t read_status;   /* block-read return */
    volatile uint32_t crc_expected;  /* CRC32 of the written pattern */
    volatile uint32_t crc_readback;  /* CRC32 of the read-back block */
    volatile uint32_t memcmp_ok;     /* 1 if the bytes match exactly */
    volatile uint32_t lba;           /* scratch LBA used */
    volatile uint32_t verdict;       /* SAR_EMMC_PASS or a fail code */
} sar_emmc_result_t;

/* Init eMMC (8-bit bus, conservative LEGACY / 25 MHz) and run one single-block
 * write -> read-back -> CRC round trip at `scratch_lba`. Latches the detailed
 * result at SAR_EMMC_RESULT_ADDR; returns the verdict (0 = PASS). */
uint32_t sar_emmc_selftest(uint32_t scratch_lba);

/* ---- Milestone-2: CPHD-scene provisioning (bulk write to INPUT partition) ----
 * Writes a host-packed 'SARI' image (emmc_pack.py) from DDR to the eMMC INPUT
 * partition, reads it back and CRC-verifies, and TIMES the write so we get a
 * MEASURED throughput (not an extrapolation of the 512 B round trip). Uses the
 * same proven SYNCHRONOUS single-block primitive as the selftest -- no IRQ and
 * no SDMA-boundary servicing, so it cannot hang with MIE disabled on hart1
 * (SDMA completion is ISR-driven; hart1 runs with machine interrupts off). */
#define SAR_EMMC_PROV_RESULT_ADDR   (0xB005D000u)  /* clear of M1 record + its tx/rx bufs */
#define SAR_EMMC_PROV_RESULT_MAGIC  (0xE3C0FF20u)
#define SAR_EMMC_PROV_RB_ADDR       ((uint64_t)SAR_SCRATCH_ADDR)  /* read-back staging, clear of SIG src */

enum {
    SAR_EMMC_PROV_PASS      = 0u,
    SAR_EMMC_PROV_ERR_PARAM = 1u,
    SAR_EMMC_PROV_ERR_INIT  = 2u,
    SAR_EMMC_PROV_ERR_WRITE = 3u,
    SAR_EMMC_PROV_ERR_READ  = 4u,
    SAR_EMMC_PROV_ERR_CRC   = 5u
};

typedef struct {
    volatile uint32_t magic;         /* SAR_EMMC_PROV_RESULT_MAGIC once valid */
    volatile uint32_t init_status;   /* MSS_MMC_init() return */
    volatile uint32_t write_status;  /* last block-write return */
    volatile uint32_t read_status;   /* last block-read return */
    volatile uint32_t crc_expected;  /* CRC32 of the source image in DDR (== host image CRC) */
    volatile uint32_t crc_readback;  /* CRC32 read back from the eMMC */
    volatile uint32_t byte_len;      /* bytes provisioned */
    volatile uint32_t nblocks;       /* byte_len / 512 */
    volatile uint32_t dest_lba;      /* INPUT-partition start LBA */
    volatile uint32_t fail_blk;      /* first failing block index, else 0xFFFFFFFF */
    volatile uint64_t write_us;      /* mtime ticks (1 MHz => microseconds) over the write loop */
    volatile uint64_t read_us;       /* mtime ticks over the read-back loop */
    volatile uint64_t write_cycles;  /* mcycle delta over the write loop (600 MHz CPU) */
    volatile uint32_t verdict;       /* SAR_EMMC_PROV_PASS or a fail code */
    volatile uint32_t reserved;
} sar_emmc_prov_result_t;

/* Provision `byte_len` bytes from DDR `src_addr` to the eMMC starting at
 * `dest_lba` (block-multiple), read back + CRC-verify, timing the write.
 * Latches the record at SAR_EMMC_PROV_RESULT_ADDR; returns the verdict. */
uint32_t sar_emmc_provision(uint32_t src_addr, uint32_t byte_len, uint32_t dest_lba);

/* ---- Milestone-3: boot-time load + output persistence + ROI dump ------------
 * LOAD: read the packed SARI image from the eMMC INPUT partition and SCATTER each
 * blob segment to its role DDR address (sar_emmc_role_addr) + reconstruct the JOB
 * at SAR_JOB_ADDR from the TOC entry -- exactly the layout sar_form_image expects,
 * so a scene runs from the card with NO host JTAG load.
 * SAVEOUT: write the full OUT image (DDR) to the eMMC OUTPUT partition (SARO) so it
 * survives power-cycle; append a SARO TOC entry with out_crc.
 * ROI: gather a rectangular crop of OUT into a small staging buffer for a fast JTAG
 * dump -- source = DDR (same session) or the eMMC SARO image (later sessions). */
#define SAR_EMMC_LOAD_RESULT_ADDR   (0xB005E000u)
#define SAR_EMMC_LOAD_MAGIC         (0xE3C0FF30u)
#define SAR_EMMC_SAVE_RESULT_ADDR   (0xB005E100u)
#define SAR_EMMC_SAVE_MAGIC         (0xE3C0FF40u)
#define SAR_EMMC_ROI_RESULT_ADDR    (0xB005E200u)
#define SAR_EMMC_ROI_MAGIC          (0xE3C0FF50u)
/* Three non-overlapping scratch regions inside SCRATCH (0x98000000, 256 MiB), all
 * free after the pipeline / in a fresh session: crop output (host dumps this),
 * superblock/blob-header small reads, and the eMMC row buffer. */
#define SAR_EMMC_ROI_STAGE_ADDR     ((uint64_t)SAR_SCRATCH_ADDR)                 /* crop gather (<=64 MiB) */
#define SAR_EMMC_SB_SCRATCH_ADDR    ((uint64_t)SAR_SCRATCH_ADDR + 0x04000000ULL) /* superblock / blob hdr */
#define SAR_EMMC_ROI_ROWBUF_ADDR    ((uint64_t)SAR_SCRATCH_ADDR + 0x06000000ULL) /* one OUT row from eMMC */

enum {
    SAR_EMMC_M3_PASS      = 0u,
    SAR_EMMC_M3_ERR_PARAM = 1u,
    SAR_EMMC_M3_ERR_INIT  = 2u,
    SAR_EMMC_M3_ERR_MAGIC = 3u,   /* bad SARI/SARB/SARO magic */
    SAR_EMMC_M3_ERR_IO    = 4u,   /* block read/write failure */
    SAR_EMMC_M3_ERR_CRC   = 5u    /* segment / sig / out CRC mismatch */
};

typedef struct {
    volatile uint32_t magic;
    volatile uint32_t init_status;
    volatile uint32_t verdict;
    volatile uint32_t nseg;          /* segments loaded */
    volatile uint32_t sig_crc_exp;   /* TOC sig_crc */
    volatile uint32_t sig_crc_got;   /* CRC of SIG region after load */
    volatile uint32_t M, N;          /* from TOC (echo) */
    volatile uint32_t fail_role;     /* role at first failure, else 0xFFFFFFFF */
    volatile uint32_t io_status;     /* last MMC status */
    volatile uint64_t load_us;       /* mtime over the load */
} sar_emmc_load_result_t;

typedef struct {
    volatile uint32_t magic;
    volatile uint32_t init_status;
    volatile uint32_t verdict;
    volatile uint32_t out_crc;       /* CRC of the OUT image written */
    volatile uint32_t rows, cols;
    volatile uint32_t byte_len;
    volatile uint32_t io_status;
    volatile uint64_t write_us;
} sar_emmc_save_result_t;

typedef struct {
    volatile uint32_t magic;
    volatile uint32_t verdict;
    volatile uint32_t r0, r1, c0, c1;
    volatile uint32_t byte_len;      /* bytes gathered = (r1-r0)*(c1-c0)*2 */
    volatile uint32_t stage_addr;    /* where the crop lives (host dumps this) */
    volatile uint32_t crc;           /* CRC of the gathered crop */
    volatile uint32_t io_status;
} sar_emmc_roi_result_t;

/* Load the packed SARI image (scene index `scene_idx`, usually 0) from the eMMC
 * INPUT partition into the pipeline's DDR layout + reconstruct the JOB. */
uint32_t sar_emmc_load(uint32_t scene_idx);
/* Write the full OUT image (SAR_OUT_ADDR, rows x cols uint16) to the SARO partition. */
uint32_t sar_emmc_save_out(uint32_t rows, uint32_t cols, uint32_t scene_id, uint32_t run_seq);
/* Gather OUT[r0:r1, c0:c1] (uint16) into SAR_EMMC_ROI_STAGE_ADDR. from_emmc=0 reads
 * OUT from DDR (SAR_OUT_ADDR); from_emmc=1 reads the needed rows from the SARO image. */
uint32_t sar_emmc_roi(uint32_t r0, uint32_t r1, uint32_t c0, uint32_t c1, uint32_t from_emmc);

/* Full-image integrity check of the persisted OUT: read the SARO superblock, read
 * the whole stored image, recompute its CRC and compare to the TOC out_crc. Detects
 * a torn/incomplete SAVEOUT (which ROI's partial read cannot). */
#define SAR_EMMC_VERIFY_RESULT_ADDR (0xB005E300u)
#define SAR_EMMC_VERIFY_MAGIC       (0xE3C0FF60u)
#define SAR_EMMC_VERIFY_BUF_ADDR    ((uint64_t)SAR_SCRATCH_ADDR)   /* full-image read buffer */

typedef struct {
    volatile uint32_t magic;
    volatile uint32_t verdict;       /* PASS iff superblock committed AND CRC matches */
    volatile uint32_t out_crc_exp;   /* from the SARO TOC */
    volatile uint32_t out_crc_got;   /* recomputed over the stored image */
    volatile uint32_t byte_len;
    volatile uint32_t rows, cols;
    volatile uint32_t io_status;
    volatile uint64_t read_us;
} sar_emmc_verify_result_t;

uint32_t sar_emmc_verify_out(void);

#endif /* SAR_EMMC_H_ */
