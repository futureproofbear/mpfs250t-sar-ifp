/*******************************************************************************
 * sar_emmc.c -- Milestone-1 eMMC bring-up: single-block write/read/CRC round trip.
 *
 * Purpose: prove the MSS eMMC path works AND that the L2-coherency handling is
 * correct, BEFORE any CPHD is staged. Fabric-independent (MSS + SDMMC only).
 *
 * Coherency (the thing this milestone settles): the SDMMC master DMAs to/from
 * PHYSICAL DDR, while the CPU works through L2. So:
 *   - before the write: flush L2 so the tx bytes are in DDR for the DMA to read;
 *   - after the read:   flush (clean+invalidate) L2 so the CPU re-fetches the
 *                       DMA-written bytes from DDR, not a stale cached copy.
 * flush_l2_cache() on this platform is clean+invalidate (the sequencer relies on
 * it both to push to and to evict from DDR), so it serves both directions here.
 ******************************************************************************/
#ifdef SAR_EMMC_ENABLE   /* whole file inert unless the eMMC path is built in */
#include "mpfs_hal/mss_hal.h"                 /* flush_l2_cache, read_csr(mhartid) */
#include "mpfs_hal/common/mss_peripherals.h" /* mss_config_clk_rst, MSS_PERIPH_EMMC/_GPIO0 */
#include "drivers/mss/mss_gpio/mss_gpio.h"    /* Icicle eMMC/SD board mux select (GPIO0/12) */
#include "drivers/mss/mss_mmc/mss_mmc.h"      /* MSS_MMC_* */
#include "sar_emmc.h"
#include "../ddr_test/ddr_packet_test.h"      /* ddr_pkt_crc32 (IEEE-802.3, == host) */
#include <string.h>

extern uint64_t readmtime(void);              /* CLINT mtime, 1 MHz -> microseconds */

#define SAR_EMMC_BLK_BYTES 512u

/* Single-block DDR staging buffers in the same gap as the result record, so the
 * DMA source/dest are real DDR exercised through the L2-flush path. 4 KiB apart,
 * naturally aligned (the block APIs take uint32_t*). */
#define SAR_EMMC_TX_ADDR (SAR_EMMC_RESULT_ADDR + 0x1000u)
#define SAR_EMMC_RX_ADDR (SAR_EMMC_RESULT_ADDR + 0x2000u)

uint32_t sar_emmc_selftest(uint32_t scratch_lba)
{
    sar_emmc_result_t *r = (sar_emmc_result_t *)(uintptr_t)SAR_EMMC_RESULT_ADDR;
    uint8_t *tx = (uint8_t *)(uintptr_t)SAR_EMMC_TX_ADDR;
    uint8_t *rx = (uint8_t *)(uintptr_t)SAR_EMMC_RX_ADDR;
    uint32_t hart = (uint32_t)read_csr(mhartid);
    mss_mmc_cfg_t cfg;
    mss_mmc_status_t st;
    uint32_t i;

    memset((void *)r, 0, sizeof(*r));
    r->lba = scratch_lba;

    /* Icicle board: the shared MSS SDMMC controller is routed to EITHER the
     * on-board 8GB eMMC OR the microSD connector by mux U44/U29, whose select is
     * MSS GPIO0 pin 12 (LOW = eMMC). The generic mss_mmc driver never drives this
     * board GPIO (HSS mmc_init_emmc does) -- without it the controller talks to
     * nothing and CMD1 is silent (OP_COND_ERR). Select eMMC BEFORE MSS_MMC_init. */
    (void)mss_config_clk_rst(MSS_PERIPH_GPIO0, (uint8_t)hart, PERIPHERAL_ON);
    MSS_GPIO_init(GPIO0_LO);
    MSS_GPIO_config(GPIO0_LO, MSS_GPIO_12, MSS_GPIO_OUTPUT_MODE);
    MSS_GPIO_set_output(GPIO0_LO, MSS_GPIO_12, 0u);   /* 0 = route mux to eMMC */

    /* Turn ON the eMMC/SDMMC peripheral clock + release its reset BEFORE any
     * MSS_MMC_* register access. The block is clock-gated off at reset and is not
     * enabled by boot or by MSS_MMC_init; without this the first SDHCI register
     * access dead-buses and freezes the hart un-haltably (a stalled bus txn, which
     * no software watchdog can bound). Must precede MSS_MMC_init. */
    (void)mss_config_clk_rst(MSS_PERIPH_EMMC, (uint8_t)hart, PERIPHERAL_ON);

    /* eMMC = full 8-bit bus (soldered, all 8 data lines wired). LEGACY/25 MHz is
     * the conservative bring-up MODE (raise to HS200/HS400 later, both also 1.8 V).
     * 1.8 V matches the MMC MSSIO bank (BANK4_VOLTAGE = 1.8 in ICICLE_MSS.cfg). */
    cfg.clk_rate       = MSS_MMC_CLOCK_25MHZ;
    cfg.card_type      = MSS_MMC_CARD_TYPE_MMC;      /* eMMC */
    cfg.data_bus_width = MSS_MMC_DATA_WIDTH_8BIT;
    cfg.bus_speed_mode = MSS_MMC_MODE_LEGACY;
    cfg.bus_voltage    = MSS_MMC_1_8V_BUS_VOLTAGE;

    st = MSS_MMC_init(&cfg);
    r->init_status = (uint32_t)st;
    if (st != MSS_MMC_INIT_SUCCESS) { r->verdict = SAR_EMMC_ERR_INIT; goto done; }

    /* known, position-dependent pattern */
    for (i = 0u; i < SAR_EMMC_BLK_BYTES; i++)
        tx[i] = (uint8_t)(0x45u + i);
    r->crc_expected = ddr_pkt_crc32(tx, SAR_EMMC_BLK_BYTES);

    /* write: push tx L2 -> DDR so the SDMMC master reads the fresh bytes */
    flush_l2_cache(hart);
    st = MSS_MMC_single_block_write((const uint32_t *)tx, scratch_lba);
    r->write_status = (uint32_t)st;
    if (st != MSS_MMC_TRANSFER_SUCCESS) { r->verdict = SAR_EMMC_ERR_WRITE; goto done; }

    /* read back into a SEPARATE buffer */
    st = MSS_MMC_single_block_read(scratch_lba, (uint32_t *)rx);
    r->read_status = (uint32_t)st;
    if (st != MSS_MMC_TRANSFER_SUCCESS) { r->verdict = SAR_EMMC_ERR_READ; goto done; }
    /* invalidate stale L2 so the CPU sees the DMA-written DDR bytes */
    flush_l2_cache(hart);

    r->crc_readback = ddr_pkt_crc32(rx, SAR_EMMC_BLK_BYTES);
    r->memcmp_ok    = (memcmp(tx, rx, SAR_EMMC_BLK_BYTES) == 0) ? 1u : 0u;
    r->verdict = (r->crc_readback == r->crc_expected && r->memcmp_ok)
                 ? SAR_EMMC_PASS : SAR_EMMC_ERR_CRC;
done:
    r->magic = SAR_EMMC_RESULT_MAGIC;
    flush_l2_cache(hart);   /* push the result record to DDR for the JTAG read */
    return r->verdict;
}

/* ---- Milestone-2 provisioner ------------------------------------------------
 * Same eMMC bring-up as the selftest (kept separate so the proven selftest path
 * is untouched), then a bulk single-block write of the packed image, read-back,
 * and CRC verify -- with the write loop timed for a real throughput number. */
static mss_mmc_status_t prov_emmc_init(uint32_t hart)
{
    mss_mmc_cfg_t cfg;
    /* board mux -> eMMC (harmless here; the real select is the fabric SDIO_SW tie) */
    (void)mss_config_clk_rst(MSS_PERIPH_GPIO0, (uint8_t)hart, PERIPHERAL_ON);
    MSS_GPIO_init(GPIO0_LO);
    MSS_GPIO_config(GPIO0_LO, MSS_GPIO_12, MSS_GPIO_OUTPUT_MODE);
    MSS_GPIO_set_output(GPIO0_LO, MSS_GPIO_12, 0u);
    /* enable eMMC/SDMMC clock + release reset BEFORE any SDHCI register access */
    (void)mss_config_clk_rst(MSS_PERIPH_EMMC, (uint8_t)hart, PERIPHERAL_ON);
    cfg.clk_rate       = MSS_MMC_CLOCK_25MHZ;
    cfg.card_type      = MSS_MMC_CARD_TYPE_MMC;
    cfg.data_bus_width = MSS_MMC_DATA_WIDTH_8BIT;
    cfg.bus_speed_mode = MSS_MMC_MODE_LEGACY;
    cfg.bus_voltage    = MSS_MMC_1_8V_BUS_VOLTAGE;
    return MSS_MMC_init(&cfg);
}

uint32_t sar_emmc_provision(uint32_t src_addr, uint32_t byte_len, uint32_t dest_lba)
{
    sar_emmc_prov_result_t *r = (sar_emmc_prov_result_t *)(uintptr_t)SAR_EMMC_PROV_RESULT_ADDR;
    uint8_t *src = (uint8_t *)(uintptr_t)src_addr;
    uint8_t *rb  = (uint8_t *)(uintptr_t)SAR_EMMC_PROV_RB_ADDR;
    uint32_t hart = (uint32_t)read_csr(mhartid);
    mss_mmc_status_t st;
    uint32_t blk, nblocks;
    uint64_t t0, t1, cy0, cy1;

    memset((void *)r, 0, sizeof(*r));
    r->byte_len = byte_len; r->dest_lba = dest_lba; r->fail_blk = 0xFFFFFFFFu;

    if ((byte_len == 0u) || ((byte_len % SAR_EMMC_BLK_BYTES) != 0u)) {
        r->verdict = SAR_EMMC_PROV_ERR_PARAM; goto done;
    }
    nblocks = byte_len / SAR_EMMC_BLK_BYTES;
    r->nblocks = nblocks;

    st = prov_emmc_init(hart);
    r->init_status = (uint32_t)st;
    if (st != MSS_MMC_INIT_SUCCESS) { r->verdict = SAR_EMMC_PROV_ERR_INIT; goto done; }

    /* expected = CRC over the source image in DDR (equals the host image CRC).
     * Then flush so the SDMMC master reads the same bytes from DDR, not L2. */
    r->crc_expected = ddr_pkt_crc32(src, byte_len);
    flush_l2_cache(hart);

    /* ---- TIMED write: proven synchronous single-block primitive ---- */
    t0 = readmtime(); cy0 = read_csr(mcycle);
    for (blk = 0u; blk < nblocks; blk++) {
        st = MSS_MMC_single_block_write(
                 (const uint32_t *)(uintptr_t)(src_addr + blk * SAR_EMMC_BLK_BYTES),
                 dest_lba + blk);
        if (st != MSS_MMC_TRANSFER_SUCCESS) {
            r->write_status = (uint32_t)st; r->fail_blk = blk;
            r->verdict = SAR_EMMC_PROV_ERR_WRITE; goto done;
        }
    }
    cy1 = read_csr(mcycle); t1 = readmtime();
    r->write_us = t1 - t0; r->write_cycles = cy1 - cy0;
    r->write_status = (uint32_t)MSS_MMC_TRANSFER_SUCCESS;

    /* ---- read back into a SEPARATE DDR region (SCRATCH), then verify ---- */
    t0 = readmtime();
    for (blk = 0u; blk < nblocks; blk++) {
        st = MSS_MMC_single_block_read(
                 dest_lba + blk,
                 (uint32_t *)(uintptr_t)(SAR_EMMC_PROV_RB_ADDR + (uint64_t)blk * SAR_EMMC_BLK_BYTES));
        if (st != MSS_MMC_TRANSFER_SUCCESS) {
            r->read_status = (uint32_t)st; r->fail_blk = blk;
            r->verdict = SAR_EMMC_PROV_ERR_READ; goto done;
        }
    }
    t1 = readmtime();
    r->read_us = t1 - t0;
    r->read_status = (uint32_t)MSS_MMC_TRANSFER_SUCCESS;
    /* invalidate stale L2 so the CPU sees the DMA-written read-back bytes */
    flush_l2_cache(hart);
    r->crc_readback = ddr_pkt_crc32(rb, byte_len);
    r->verdict = (r->crc_readback == r->crc_expected)
                 ? SAR_EMMC_PROV_PASS : SAR_EMMC_PROV_ERR_CRC;
done:
    r->magic = SAR_EMMC_PROV_RESULT_MAGIC;
    flush_l2_cache(hart);   /* push the result record to DDR for the JTAG read */
    return r->verdict;
}

/* ---- Milestone-3: boot-load + output persistence + ROI dump -----------------*/

static mss_mmc_status_t emmc_rd_blocks(uint32_t lba, uintptr_t dst, uint32_t nblocks)
{
    mss_mmc_status_t st = MSS_MMC_TRANSFER_SUCCESS;
    for (uint32_t i = 0u; i < nblocks; i++) {
        st = MSS_MMC_single_block_read(lba + i,
                 (uint32_t *)(dst + (uintptr_t)i * SAR_EMMC_BLK_BYTES));
        if (st != MSS_MMC_TRANSFER_SUCCESS) break;
    }
    return st;
}
static mss_mmc_status_t emmc_wr_blocks(uintptr_t src, uint32_t lba, uint32_t nblocks)
{
    mss_mmc_status_t st = MSS_MMC_TRANSFER_SUCCESS;
    for (uint32_t i = 0u; i < nblocks; i++) {
        st = MSS_MMC_single_block_write(
                 (const uint32_t *)(src + (uintptr_t)i * SAR_EMMC_BLK_BYTES), lba + i);
        if (st != MSS_MMC_TRANSFER_SUCCESS) break;
    }
    return st;
}
static inline uint32_t bytes_to_blocks(uint32_t n)
{ return (n + SAR_EMMC_BLK_BYTES - 1u) / SAR_EMMC_BLK_BYTES; }

uint32_t sar_emmc_load(uint32_t scene_idx)
{
    sar_emmc_load_result_t *r = (sar_emmc_load_result_t *)(uintptr_t)SAR_EMMC_LOAD_RESULT_ADDR;
    uint32_t hart = (uint32_t)read_csr(mhartid);
    uintptr_t sbuf = (uintptr_t)SAR_EMMC_SB_SCRATCH_ADDR;
    uint64_t t0 = readmtime();
    mss_mmc_status_t st;

    memset((void *)r, 0, sizeof(*r));
    r->fail_role = 0xFFFFFFFFu;

    st = prov_emmc_init(hart);
    r->init_status = (uint32_t)st;
    if (st != MSS_MMC_INIT_SUCCESS) { r->verdict = SAR_EMMC_M3_ERR_INIT; goto done; }

    /* INPUT superblock -> TOC entry (read enough blocks to cover toc[scene_idx]) */
    uint32_t sb_blocks = bytes_to_blocks(16u + (scene_idx + 1u) * (uint32_t)sizeof(sar_emmc_in_entry_t));
    st = emmc_rd_blocks((uint32_t)SAR_EMMC_IN_LBA, sbuf, sb_blocks);
    if (st != MSS_MMC_TRANSFER_SUCCESS) { r->io_status = (uint32_t)st; r->verdict = SAR_EMMC_M3_ERR_IO; goto done; }
    sar_emmc_in_super_t *sb = (sar_emmc_in_super_t *)sbuf;
    if (sb->magic != SAR_EMMC_IN_MAGIC || scene_idx >= sb->count) { r->verdict = SAR_EMMC_M3_ERR_MAGIC; goto done; }
    sar_emmc_in_entry_t *e = &sb->toc[scene_idx];
    r->M = e->M; r->N = e->N; r->sig_crc_exp = e->sig_crc;
    uint32_t blob_lba = (uint32_t)e->lba;
    uint32_t sig_len  = e->sig_len;
    /* stash the job-semantic fields before we reuse sbuf for the blob header */
    uint32_t jM = e->M, jN = e->N, jFR = e->fft_r, jFA = e->fft_a;
    int32_t  jExp = e->bfp_in_exp; uint32_t jSigCrc = e->sig_crc;

    /* blob header + segment table (fits in the first block: 16B hdr + 10*16B) */
    st = emmc_rd_blocks(blob_lba, sbuf, 1u);
    if (st != MSS_MMC_TRANSFER_SUCCESS) { r->io_status = (uint32_t)st; r->verdict = SAR_EMMC_M3_ERR_IO; goto done; }
    sar_emmc_blob_hdr_t *bh = (sar_emmc_blob_hdr_t *)sbuf;
    if (bh->magic != SAR_EMMC_BLOB_MAGIC) { r->verdict = SAR_EMMC_M3_ERR_MAGIC; goto done; }
    sar_emmc_seg_t *segs = (sar_emmc_seg_t *)(sbuf + sizeof(sar_emmc_blob_hdr_t));
    uint32_t nseg = bh->seg_count;

    /* scatter each segment to its role DDR address */
    for (uint32_t s = 0u; s < nseg; s++) {
        uint64_t dst = sar_emmc_role_addr(segs[s].role);
        if (dst == 0u) { r->fail_role = segs[s].role; r->verdict = SAR_EMMC_M3_ERR_PARAM; goto done; }
        uint32_t seg_lba = blob_lba + segs[s].blob_off / SAR_EMMC_BLK_BYTES;
        st = emmc_rd_blocks(seg_lba, (uintptr_t)dst, bytes_to_blocks(segs[s].byte_len));
        if (st != MSS_MMC_TRANSFER_SUCCESS) {
            r->io_status = (uint32_t)st; r->fail_role = segs[s].role; r->verdict = SAR_EMMC_M3_ERR_IO; goto done;
        }
        r->nseg = s + 1u;
    }
    flush_l2_cache(hart);   /* SDMMC wrote physical DDR -> make L2 coherent (CPU coeffs + FIC0 SIG) */

    /* verify SIG region against the TOC (loopback: card -> DDR faithful) */
    r->sig_crc_got = ddr_pkt_crc32((const void *)(uintptr_t)SAR_SIG_ADDR, sig_len);
    if (r->sig_crc_got != r->sig_crc_exp) { r->verdict = SAR_EMMC_M3_ERR_CRC; goto done; }

    /* reconstruct the JOB (mirror of host pack_job / job_from_in_entry) */
    sar_job_t *job = (sar_job_t *)(uintptr_t)SAR_JOB_ADDR;
    job->magic = SAR_JOB_MAGIC;
    job->M = jM; job->N = jN; job->fft_r = jFR; job->fft_a = jFA;
    job->out_dtype = SAR_OUT_DTYPE_UINT16; job->bfp_in_exp = jExp;
    job->sig_len = sig_len; job->sig_crc = jSigCrc; job->reserved = 0u;
    job->sig_addr = SAR_SIG_ADDR; job->kr_addr = SAR_KR_ADDR; job->kc_addr = SAR_KC_ADDR;
    job->tanphi_addr = SAR_TANPHI_ADDR; job->win_addr = SAR_WIN_ADDR;
    job->out_addr = SAR_OUT_ADDR; job->scratch_addr = SAR_SCRATCH_ADDR;
    r->verdict = SAR_EMMC_M3_PASS;
done:
    r->load_us = readmtime() - t0;
    r->magic = SAR_EMMC_LOAD_MAGIC;
    flush_l2_cache(hart);
    return r->verdict;
}

uint32_t sar_emmc_save_out(uint32_t rows, uint32_t cols, uint32_t scene_id, uint32_t run_seq)
{
    sar_emmc_save_result_t *r = (sar_emmc_save_result_t *)(uintptr_t)SAR_EMMC_SAVE_RESULT_ADDR;
    uint32_t hart = (uint32_t)read_csr(mhartid);
    uintptr_t sbuf = (uintptr_t)SAR_EMMC_SB_SCRATCH_ADDR;
    uint64_t t0 = readmtime();
    mss_mmc_status_t st;

    memset((void *)r, 0, sizeof(*r));
    r->rows = rows; r->cols = cols;
    uint32_t byte_len = rows * cols * 2u;   /* uint16 image */
    r->byte_len = byte_len;
    if (rows == 0u || cols == 0u || (byte_len % SAR_EMMC_BLK_BYTES) != 0u) { r->verdict = SAR_EMMC_M3_ERR_PARAM; goto done; }

    st = prov_emmc_init(hart);
    r->init_status = (uint32_t)st;
    if (st != MSS_MMC_INIT_SUCCESS) { r->verdict = SAR_EMMC_M3_ERR_INIT; goto done; }

    /* OUT is fabric-written (FIC0 non-coherent) -> flush so the SDMMC master reads
     * the real image from DDR, then CRC the same bytes. */
    flush_l2_cache(hart);
    r->out_crc = ddr_pkt_crc32((const void *)(uintptr_t)SAR_OUT_ADDR, byte_len);

    uint32_t sb_blocks = bytes_to_blocks((uint32_t)sizeof(sar_emmc_out_super_t));
    uint32_t img_lba = (uint32_t)SAR_EMMC_OUT_LBA + sb_blocks;

    /* CRASH-SAFE ordering: INVALIDATE -> write IMAGE -> COMMIT superblock LAST.
     * The superblock is the single "this image is valid" record, so it must be the
     * LAST thing on the card. If power drops during the ~16 min image write, the
     * superblock is left invalid (magic 0), so a reader rejects the torn image
     * rather than trusting a half-written one. (Was superblock-first: a torn image
     * looked committed. See the SILICON_ISO_TEST_RUNBOOK M2 gotcha.) */

    /* 1) invalidate: zero the first block of the superblock region (magic -> 0) */
    memset((void *)sbuf, 0, SAR_EMMC_BLK_BYTES);
    flush_l2_cache(hart);
    st = emmc_wr_blocks(sbuf, (uint32_t)SAR_EMMC_OUT_LBA, 1u);
    if (st != MSS_MMC_TRANSFER_SUCCESS) { r->io_status = (uint32_t)st; r->verdict = SAR_EMMC_M3_ERR_IO; goto done; }

    /* 2) write the image payload (the long, interruptible part) */
    st = emmc_wr_blocks((uintptr_t)SAR_OUT_ADDR, img_lba, bytes_to_blocks(byte_len));
    if (st != MSS_MMC_TRANSFER_SUCCESS) { r->io_status = (uint32_t)st; r->verdict = SAR_EMMC_M3_ERR_IO; goto done; }

    /* 3) build + write the real superblock LAST = the commit point */
    memset((void *)sbuf, 0, (size_t)sb_blocks * SAR_EMMC_BLK_BYTES);
    sar_emmc_out_super_t *sb = (sar_emmc_out_super_t *)sbuf;
    sb->magic = SAR_EMMC_OUT_MAGIC; sb->version = SAR_EMMC_VERSION; sb->count = 1u;
    sar_emmc_out_entry_t *oe = &sb->toc[0];
    oe->valid = 1u; oe->scene_id = scene_id; oe->run_seq = run_seq;
    oe->out_dtype = SAR_OUT_DTYPE_UINT16; oe->lba = img_lba; oe->byte_len = byte_len;
    oe->rows = rows; oe->cols = cols; oe->out_crc = r->out_crc;
    flush_l2_cache(hart);   /* push superblock scratch to DDR for the SDMMC read */
    st = emmc_wr_blocks(sbuf, (uint32_t)SAR_EMMC_OUT_LBA, sb_blocks);
    if (st != MSS_MMC_TRANSFER_SUCCESS) { r->io_status = (uint32_t)st; r->verdict = SAR_EMMC_M3_ERR_IO; goto done; }
    r->verdict = SAR_EMMC_M3_PASS;
done:
    r->write_us = readmtime() - t0;
    r->magic = SAR_EMMC_SAVE_MAGIC;
    flush_l2_cache(hart);
    return r->verdict;
}

uint32_t sar_emmc_roi(uint32_t r0, uint32_t r1, uint32_t c0, uint32_t c1, uint32_t from_emmc)
{
    sar_emmc_roi_result_t *r = (sar_emmc_roi_result_t *)(uintptr_t)SAR_EMMC_ROI_RESULT_ADDR;
    uint32_t hart = (uint32_t)read_csr(mhartid);
    uint16_t *stage = (uint16_t *)(uintptr_t)SAR_EMMC_ROI_STAGE_ADDR;
    mss_mmc_status_t st;

    memset((void *)r, 0, sizeof(*r));
    r->r0 = r0; r->r1 = r1; r->c0 = c0; r->c1 = c1;
    r->stage_addr = (uint32_t)SAR_EMMC_ROI_STAGE_ADDR;

    uint32_t cols_img = SAR_GRID_MAX;   /* DDR path assumes full padded grid width */
    if (!(r0 < r1 && c0 < c1 && r1 <= SAR_GRID_MAX && c1 <= SAR_GRID_MAX)) { r->verdict = SAR_EMMC_M3_ERR_PARAM; goto done; }
    uint32_t crop_rows = r1 - r0, crop_cols = c1 - c0;
    r->byte_len = crop_rows * crop_cols * 2u;

    if (from_emmc == 0u) {
        const uint16_t *out = (const uint16_t *)(uintptr_t)SAR_OUT_ADDR;
        flush_l2_cache(hart);   /* OUT fabric-written -> refetch fresh from DDR */
        for (uint32_t rr = 0u; rr < crop_rows; rr++) {
            const uint16_t *srow = out + (uint64_t)(r0 + rr) * cols_img + c0;
            uint16_t *drow = stage + (uint64_t)rr * crop_cols;
            for (uint32_t cc = 0u; cc < crop_cols; cc++) drow[cc] = srow[cc];
        }
    } else {
        /* later session: OUT is only on the card. Read the SARO superblock, then
         * pull just the ROI rows (whole rows) and slice the columns. */
        uintptr_t sbuf = (uintptr_t)SAR_EMMC_SB_SCRATCH_ADDR;
        uint16_t *rowbuf = (uint16_t *)(uintptr_t)SAR_EMMC_ROI_ROWBUF_ADDR;
        st = prov_emmc_init(hart);
        if (st != MSS_MMC_INIT_SUCCESS) { r->io_status = (uint32_t)st; r->verdict = SAR_EMMC_M3_ERR_INIT; goto done; }
        uint32_t sb_blocks = bytes_to_blocks((uint32_t)sizeof(sar_emmc_out_super_t));
        st = emmc_rd_blocks((uint32_t)SAR_EMMC_OUT_LBA, sbuf, sb_blocks);
        if (st != MSS_MMC_TRANSFER_SUCCESS) { r->io_status = (uint32_t)st; r->verdict = SAR_EMMC_M3_ERR_IO; goto done; }
        sar_emmc_out_super_t *sb = (sar_emmc_out_super_t *)sbuf;
        if (sb->magic != SAR_EMMC_OUT_MAGIC || sb->count == 0u) { r->verdict = SAR_EMMC_M3_ERR_MAGIC; goto done; }
        sar_emmc_out_entry_t *oe = &sb->toc[0];
        uint32_t img_lba = (uint32_t)oe->lba;
        cols_img = oe->cols;
        if (c1 > cols_img || r1 > oe->rows) { r->verdict = SAR_EMMC_M3_ERR_PARAM; goto done; }
        uint32_t row_blocks = bytes_to_blocks(cols_img * 2u);   /* 8192*2 = 16 KiB = 32 blocks */
        for (uint32_t rr = 0u; rr < crop_rows; rr++) {
            uint32_t row_lba = img_lba + (uint32_t)(((uint64_t)(r0 + rr) * cols_img * 2u) / SAR_EMMC_BLK_BYTES);
            st = emmc_rd_blocks(row_lba, (uintptr_t)rowbuf, row_blocks);
            if (st != MSS_MMC_TRANSFER_SUCCESS) { r->io_status = (uint32_t)st; r->verdict = SAR_EMMC_M3_ERR_IO; goto done; }
            flush_l2_cache(hart);
            uint16_t *drow = stage + (uint64_t)rr * crop_cols;
            for (uint32_t cc = 0u; cc < crop_cols; cc++) drow[cc] = rowbuf[c0 + cc];
        }
    }
    flush_l2_cache(hart);
    r->crc = ddr_pkt_crc32((const void *)stage, r->byte_len);
    r->verdict = SAR_EMMC_M3_PASS;
done:
    r->magic = SAR_EMMC_ROI_MAGIC;
    flush_l2_cache(hart);
    return r->verdict;
}

uint32_t sar_emmc_verify_out(void)
{
    sar_emmc_verify_result_t *r = (sar_emmc_verify_result_t *)(uintptr_t)SAR_EMMC_VERIFY_RESULT_ADDR;
    uint32_t hart = (uint32_t)read_csr(mhartid);
    uintptr_t sbuf = (uintptr_t)SAR_EMMC_SB_SCRATCH_ADDR;
    uint64_t t0 = readmtime();
    mss_mmc_status_t st;

    memset((void *)r, 0, sizeof(*r));
    st = prov_emmc_init(hart);
    if (st != MSS_MMC_INIT_SUCCESS) { r->io_status = (uint32_t)st; r->verdict = SAR_EMMC_M3_ERR_INIT; goto done; }

    uint32_t sb_blocks = bytes_to_blocks((uint32_t)sizeof(sar_emmc_out_super_t));
    st = emmc_rd_blocks((uint32_t)SAR_EMMC_OUT_LBA, sbuf, sb_blocks);
    if (st != MSS_MMC_TRANSFER_SUCCESS) { r->io_status = (uint32_t)st; r->verdict = SAR_EMMC_M3_ERR_IO; goto done; }
    sar_emmc_out_super_t *sb = (sar_emmc_out_super_t *)sbuf;
    if (sb->magic != SAR_EMMC_OUT_MAGIC || sb->count == 0u) { r->verdict = SAR_EMMC_M3_ERR_MAGIC; goto done; }
    sar_emmc_out_entry_t *oe = &sb->toc[0];
    uint32_t img_lba = (uint32_t)oe->lba, byte_len = (uint32_t)oe->byte_len;
    r->out_crc_exp = oe->out_crc; r->byte_len = byte_len; r->rows = oe->rows; r->cols = oe->cols;

    /* read the whole stored image into SCRATCH and recompute the CRC */
    st = emmc_rd_blocks(img_lba, (uintptr_t)SAR_EMMC_VERIFY_BUF_ADDR, bytes_to_blocks(byte_len));
    if (st != MSS_MMC_TRANSFER_SUCCESS) { r->io_status = (uint32_t)st; r->verdict = SAR_EMMC_M3_ERR_IO; goto done; }
    flush_l2_cache(hart);
    r->out_crc_got = ddr_pkt_crc32((const void *)(uintptr_t)SAR_EMMC_VERIFY_BUF_ADDR, byte_len);
    r->verdict = (r->out_crc_got == r->out_crc_exp) ? SAR_EMMC_M3_PASS : SAR_EMMC_M3_ERR_CRC;
done:
    r->read_us = readmtime() - t0;
    r->magic = SAR_EMMC_VERIFY_MAGIC;
    flush_l2_cache(hart);
    return r->verdict;
}
#endif /* SAR_EMMC_ENABLE */
