/*
 * sar_kernels.h -- register map for the SAR fabric accelerator as actually built
 * in Libero (SAR_TOP). The control plane is the MSS FIC0 initiator -> AXIIC_CTRL
 * (1 master -> 7 slaves); each slave is a 4 KiB window at 0x6000_n000.
 *
 * Six of the slaves are SmartHLS kernels; each exposes the SmartHLS control
 * register layout (see each kernel's generated accelerator_drivers driver):
 *     +0x08  START / STATUS  -- write 1 to start; reads back 0 when idle/done
 *     +0x0c  arg0 pointer/scalar, then +0x10 arg1, +0x14 arg2, +0x18 arg3 ...
 * The sixth slave is the CoreAXI4DMAController control port.
 */
#ifndef SAR_KERNELS_H_
#define SAR_KERNELS_H_

#include <stdint.h>

/* MSS FIC0 initiator window -> AXIIC_CTRL slaves (4 KiB each). */
#define SAR_FIC0_CTRL_BASE   0x60000000u
#define K_CORNER_TURN        (SAR_FIC0_CTRL_BASE + 0x0000u)  /* AXIIC_CTRL SLAVE0 */
#define K_WINDOW             (SAR_FIC0_CTRL_BASE + 0x1000u)  /* SLAVE1 */
#define K_DETECT             (SAR_FIC0_CTRL_BASE + 0x2000u)  /* SLAVE2 */
#define K_RESAMPLE           (SAR_FIC0_CTRL_BASE + 0x3000u)  /* SLAVE3 */
#define K_FFT_FEEDER         (SAR_FIC0_CTRL_BASE + 0x4000u)  /* SLAVE4 (CoreFFT build: fft_feeder) */
#define K_FFT_UNLOADER       (SAR_FIC0_CTRL_BASE + 0x5000u)  /* SLAVE5 (CoreFFT build: fft_unloader) */
#define K_FFT                (SAR_FIC0_CTRL_BASE + 0x4000u)  /* SLAVE4 (HLS-FFT build: fft_kernel, replaces feeder+unloader chain) */
#define K_RESAMPLE2          (SAR_FIC0_CTRL_BASE + 0x6000u)  /* SLAVE6 (2nd resample instance; same arg map as K_RESAMPLE) */

/* SmartHLS control register offsets (common across all kernels). */
#define HLS_START            0x08u   /* write 1 = start; read == 0 = done */
#define HLS_ARG0             0x0cu
#define HLS_ARG1             0x10u
#define HLS_ARG2             0x14u
#define HLS_ARG3             0x18u

/* Per-kernel argument map (offset -> meaning), from the generated drivers:
 *   resample   : ARG0 in, ARG1 idx, ARG2 wq, ARG3 out
 *   window     : ARG0 in, ARG1 hamr, ARG2 hamc, ARG3 out (forms 2-D taper on the fly)
 *   corner_turn: ARG0 src, ARG1 dst
 *   detect     : ARG0 in, ARG1 out
 *   fft_feeder : ARG0 src, ARG1 nbeats        (out = AXI4-Stream to gearbox)
 *   fft_kernel : ARG0 src, ARG1 dst, ARG2 nrows   (HLS-FFT build; self-contained read+write master)
 */

static inline void     sar_reg_w(uint32_t base, uint32_t off, uint32_t v) {
    *(volatile uint32_t *)(uintptr_t)(base + off) = v;
}
static inline uint32_t sar_reg_r(uint32_t base, uint32_t off) {
    return *(volatile uint32_t *)(uintptr_t)(base + off);
}
static inline void sar_k_start(uint32_t base) { sar_reg_w(base, HLS_START, 1u); }
static inline int  sar_k_idle (uint32_t base) { return sar_reg_r(base, HLS_START) == 0u; }

/* Bounded wait; returns 1 on done, 0 on timeout. */
static inline int sar_k_wait(uint32_t base, uint32_t spins) {
    while (spins--) { if (sar_k_idle(base)) return 1; }
    return 0;
}

#endif /* SAR_KERNELS_H_ */
