/*******************************************************************************
 * sar_accel_driver.c
 *
 * Implementation of the thin SAR accelerator driver. Plain C against memory and
 * MMIO pointers (no HAL dependency); console output stays in the caller, as in
 * ddr_packet_test.c. CRC reuses the verified ddr_pkt_crc32 (reflected IEEE
 * 802.3), which matches the host's zlib.crc32 over the same bytes.
 ******************************************************************************/
#include "sar_accel_driver.h"
#include "../ddr_test/ddr_packet_test.h"   /* ddr_pkt_crc32 */

/* ---- MMIO accessors (volatile so the compiler keeps every access) -------- */
static inline void reg_w32(uint32_t off, uint32_t v)
{
    *(volatile uint32_t *)(uintptr_t)(SAR_ACCEL_BASE + off) = v;
}

static inline uint32_t reg_r32(uint32_t off)
{
    return *(volatile uint32_t *)(uintptr_t)(SAR_ACCEL_BASE + off);
}

static inline void reg_w64(uint32_t off, uint64_t addr)
{
    reg_w32(off,        (uint32_t)(addr & 0xFFFFFFFFu));     /* lo */
    reg_w32(off + 4u,   (uint32_t)(addr >> 32));             /* hi */
}

/* ---- DDR accessor for the job descriptor -------------------------------- */
static inline uint8_t mem_r8(uint64_t addr)
{
    return *(volatile uint8_t *)(uintptr_t)addr;
}

sar_status_t sar_job_load(sar_job_t *job)
{
    uint8_t *dst = (uint8_t *)job;
    for (uint32_t i = 0u; i < sizeof(sar_job_t); i++) {
        dst[i] = mem_r8(SAR_JOB_ADDR + i);
    }
    if (job->magic != SAR_JOB_MAGIC) {
        return SAR_BAD_MAGIC;
    }
    return SAR_OK;
}

sar_status_t sar_job_check_sig(const sar_job_t *job, uint32_t *crc_out)
{
    /* CRC the SIG region in DDR exactly as the host CRC'd sig.bin. */
    uint32_t crc = ddr_pkt_crc32((const void *)(uintptr_t)job->sig_addr,
                                 (size_t)job->sig_len);
    if (crc_out) {
        *crc_out = crc;
    }
    return (crc == job->sig_crc) ? SAR_OK : SAR_SIG_CRC_FAIL;
}

void sar_accel_config(const sar_job_t *job)
{
    reg_w32(SAR_REG_M,         job->M);
    reg_w32(SAR_REG_N,         job->N);
    reg_w32(SAR_REG_FFT_LEN_R, job->fft_r);
    reg_w32(SAR_REG_FFT_LEN_A, job->fft_a);
    reg_w64(SAR_REG_SIG_ADDR,     job->sig_addr);
    reg_w64(SAR_REG_KR_ADDR,      job->kr_addr);
    reg_w64(SAR_REG_KC_ADDR,      job->kc_addr);
    reg_w64(SAR_REG_TANPHI_ADDR,  job->tanphi_addr);
    reg_w64(SAR_REG_WIN_ADDR,     job->win_addr);
    reg_w64(SAR_REG_OUT_ADDR,     job->out_addr);
    reg_w64(SAR_REG_SCRATCH_ADDR, job->scratch_addr);
}

void sar_accel_start(void)
{
    reg_w32(SAR_REG_CTRL, SAR_CTRL_START);
}

sar_status_t sar_accel_wait_done(uint32_t spins)
{
    for (uint32_t i = 0u; i < spins; i++) {
        uint32_t s = reg_r32(SAR_REG_STATUS);
        if (s & SAR_STATUS_ERR) {
            return SAR_ACCEL_ERR;
        }
        if (s & SAR_STATUS_DONE) {
            return SAR_OK;
        }
    }
    return SAR_TIMEOUT;
}

int32_t sar_accel_read_bfp_shift(void)
{
    return (int32_t)reg_r32(SAR_REG_BFP_SHIFT);
}

sar_status_t sar_accel_selftest(uint32_t *fail_off)
{
    /* RW data registers safe to write/read-back (no side effects). Address regs
     * are 64-bit -> exercise both 32-bit words. */
    static const uint32_t rw_regs[] = {
        SAR_REG_M, SAR_REG_N, SAR_REG_FFT_LEN_R, SAR_REG_FFT_LEN_A,
        SAR_REG_BFP_SHIFT,
        SAR_REG_SIG_ADDR, SAR_REG_SIG_ADDR + 4u,
        SAR_REG_KR_ADDR, SAR_REG_KR_ADDR + 4u,
        SAR_REG_KC_ADDR, SAR_REG_KC_ADDR + 4u,
        SAR_REG_TANPHI_ADDR, SAR_REG_TANPHI_ADDR + 4u,
        SAR_REG_WIN_ADDR, SAR_REG_WIN_ADDR + 4u,
        SAR_REG_OUT_ADDR, SAR_REG_OUT_ADDR + 4u,
        SAR_REG_SCRATCH_ADDR, SAR_REG_SCRATCH_ADDR + 4u,
    };
    static const uint32_t pats[] = {0xA5A5A5A5u, 0x5A5A5A5Au, 0xFFFFFFFFu, 0x00000000u};
    const uint32_t n_regs = (uint32_t)(sizeof(rw_regs) / sizeof(rw_regs[0]));

    for (uint32_t r = 0u; r < n_regs; r++) {
        for (uint32_t p = 0u; p < (uint32_t)(sizeof(pats) / sizeof(pats[0])); p++) {
            reg_w32(rw_regs[r], pats[p]);
            if (reg_r32(rw_regs[r]) != pats[p]) {
                if (fail_off) {
                    *fail_off = rw_regs[r];
                }
                return SAR_REG_FAIL;
            }
        }
    }
    return SAR_OK;
}

sar_status_t sar_run(sar_job_t *job, int with_fabric, int32_t *bfp_shift)
{
    sar_status_t st = sar_job_load(job);
    if (st != SAR_OK) {
        return st;
    }

    /* Always validate the JTAG-loaded input first (cheap, catches load/DDR faults). */
    st = sar_job_check_sig(job, (uint32_t *)0);
    if (st != SAR_OK) {
        return st;
    }

    if (!with_fabric) {
        return SAR_OK;          /* Milestone 0: loopback only, no bitstream */
    }

    sar_accel_config(job);
    sar_accel_start();
    /* ~50M spins is a generous budget for a single frame at fabric clock;
     * tune once real timing is known. */
    st = sar_accel_wait_done(50000000u);
    if (st != SAR_OK) {
        return st;
    }
    if (bfp_shift) {
        *bfp_shift = sar_accel_read_bfp_shift();
    }
    return SAR_OK;
}
