/*******************************************************************************
 * sar_accel_driver.h
 *
 * Thin bare-metal driver for the SAR accelerator on the PolarFire SoC fabric.
 * The CPU does no DSP: it reads the job descriptor the host baked into DDR,
 * programs the accelerator's AXI4-Lite registers with the buffer addresses and
 * dimensions, starts it, waits for DONE, and reports the BFP shift back so the
 * host can rescale the dumped OUT buffer.
 *
 * The accelerator itself (window + resample + 2-D FFT + corner-turn + detect)
 * is the FPGA fabric described in mpfs250t-sar-ifp/mpfs/fpga + regmap.md. Until that
 * bitstream exists (Milestone 1/2), only sar_job_load()/sar_job_check_sig() are
 * exercised (Milestone 0 loopback); the register functions are no-ops against a
 * fabric that is not yet present.
 ******************************************************************************/
#ifndef SAR_ACCEL_DRIVER_H_
#define SAR_ACCEL_DRIVER_H_

#include <stdint.h>
#include "ddr_sar_layout.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    SAR_OK          = 0,
    SAR_BAD_MAGIC   = 1,   /* job descriptor not present / corrupt */
    SAR_SIG_CRC_FAIL = 2,  /* SIG region CRC != job.sig_crc (load/DDR fault) */
    SAR_ACCEL_ERR   = 3,   /* fabric raised STATUS.ERR */
    SAR_TIMEOUT     = 4,   /* DONE not seen within the poll budget */
    SAR_REG_FAIL    = 5    /* AXI4-Lite register read-back mismatch */
} sar_status_t;

/* Read + validate the job descriptor at SAR_JOB_ADDR. Returns SAR_OK or
 * SAR_BAD_MAGIC. On success *job is filled from DDR. */
sar_status_t sar_job_load(sar_job_t *job);

/* M0 loopback: recompute CRC32 over the loaded SIG region and compare to
 * job->sig_crc. Proves the JTAG load + DDR round-trip before any fabric exists.
 * Returns SAR_OK or SAR_SIG_CRC_FAIL; *crc_out (optional) gets the computed CRC. */
sar_status_t sar_job_check_sig(const sar_job_t *job, uint32_t *crc_out);

/* Program the accelerator registers from the job (addresses + dims). M1/M2. */
void sar_accel_config(const sar_job_t *job);

/* Pulse CTRL.START. */
void sar_accel_start(void);

/* Poll STATUS until DONE or ERR, up to `spins` iterations. Returns SAR_OK,
 * SAR_ACCEL_ERR, or SAR_TIMEOUT. */
sar_status_t sar_accel_wait_done(uint32_t spins);

/* Read the block-floating-point output exponent the fabric reports. */
int32_t sar_accel_read_bfp_shift(void);

/* Control-plane self-test: write/read-back the RW data registers (dims, FFT
 * lengths, BFP shift, buffer-address words) with walking patterns to prove the
 * host<->fabric AXI4-Lite path BEFORE the datapath works. Does NOT touch CTRL
 * (side effects) or STATUS (read-only). Returns SAR_OK, or SAR_REG_FAIL with
 * *fail_off (optional) set to the register offset that mismatched. Requires the
 * accelerator bitstream loaded (or an RTL/C-sim of the register block); reading
 * SAR_ACCEL_BASE on bare fabric will bus-fault. */
sar_status_t sar_accel_selftest(uint32_t *fail_off);

/* End-to-end: load job, (loopback CRC), config, start, wait, read BFP shift.
 * `with_fabric`=0 stops after the loopback CRC (Milestone 0, no bitstream).
 * On success *bfp_shift is set (only meaningful when with_fabric!=0). */
sar_status_t sar_run(sar_job_t *job, int with_fabric, int32_t *bfp_shift);

#ifdef __cplusplus
}
#endif

#endif /* SAR_ACCEL_DRIVER_H_ */
