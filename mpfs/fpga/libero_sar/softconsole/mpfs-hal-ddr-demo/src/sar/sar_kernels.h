/*
 * sar_kernels.h -- register map for the SAR fabric accelerator as actually built
 * in Libero (SAR_TOP). The control plane is the MSS FIC0 initiator -> AXIIC_CTRL
 * (1 master -> 9 slaves); each slave is a 4 KiB window at 0x6000_n000.
 *
 * Each kernel exposes the SmartHLS control register layout (the hand-written
 * Verilog replacements deliberately preserve it -- see each kernel's generated
 * accelerator_drivers driver):
 *     +0x08  START / STATUS  -- write 1 to start; reads back 0 when idle/done
 *     +0x0c  arg0 pointer/scalar, then +0x10 arg1, +0x14 arg2, +0x18 arg3 ...
 */
#ifndef SAR_KERNELS_H_
#define SAR_KERNELS_H_

#include <stdint.h>

/* MSS FIC0 initiator window -> AXIIC_CTRL slaves (4 KiB each). */
#define SAR_FIC0_CTRL_BASE   0x60000000u
#define K_CORNER_TURN        (SAR_FIC0_CTRL_BASE + 0x0000u)  /* AXIIC_CTRL SLAVE0 */
/* SLAVE1/SLAVE2 REASSIGNED 2026-07-25 to the SECOND CoreFFT chain. They were K_WINDOW (the 2-D
 * Hamming window, fused into the feeder 2026-07-21 -- no firmware user since) and K_RESAMPLE2
 * (the 2-lane range gather: 4.85 s vs 5.78 s but 99.64% of a 1024x1024 ROI wrong on silicon,
 * openspec add-res2-dual-lane-gather -> verdict DO NOT COMMIT). Reusing them IN PLACE is what
 * keeps every other kernel at the address the firmware and the host .gdb scripts already use,
 * and keeps the DIC at NUM_INITIATORS=6 (the 8-master ceiling in sar_axi_idconv.v:145,153).
 * ANY firmware still writing 0x60001000/0x60002000 as a window/resample kernel now drives the
 * second FFT chain -- both old symbols are therefore DELETED, not redefined, so a stale user
 * fails to compile instead of silently arming an FFT feeder mid-resample. */
#define K_FFT_FEEDER_B       (SAR_FIC0_CTRL_BASE + 0x1000u)  /* SLAVE1: 2nd chain fft_feeder  (was K_WINDOW)   */
#define K_FFT_UNLOADER_B     (SAR_FIC0_CTRL_BASE + 0x2000u)  /* SLAVE2: 2nd chain fft_unloader (was K_RESAMPLE2) */
#define K_RESAMPLE           (SAR_FIC0_CTRL_BASE + 0x3000u)  /* SLAVE3 */
#define K_FFT_FEEDER         (SAR_FIC0_CTRL_BASE + 0x4000u)  /* SLAVE4 (CoreFFT build: fft_feeder) */
#define K_FFT_UNLOADER       (SAR_FIC0_CTRL_BASE + 0x5000u)  /* SLAVE5 (CoreFFT build: fft_unloader) */
#define K_FFT                (SAR_FIC0_CTRL_BASE + 0x4000u)  /* SLAVE4 (HLS-FFT build: fft_kernel, replaces feeder+unloader chain) */
#define K_FIC0MON            (SAR_FIC0_CTRL_BASE + 0x6000u)  /* SLAVE6: FIC_0 AXI monitor (sar_fic0s_mon.v, 2026-07-22 build) */
#define K_COEFFGEN           (SAR_FIC0_CTRL_BASE + 0x7000u)  /* SLAVE7: on-fabric azimuth resample coefficient generator (sar_coeffgen.v) */
#define K_COEFFGEN_B         (SAR_FIC0_CTRL_BASE + 0x8000u)  /* SLAVE8: 2nd chain's coefficient generator (2nd sar_coeffgen instance) */

/* On-fabric azimuth coefficient generator (sar_coeffgen.v). Hand-written Verilog; its output is
 * a {idx,wq} STREAM straight into the FFT-1 feeder's gather engine (no DDR, no DIC port), enabled
 * by K_FFT_GATHER_CTRL bit1. tan_s/inv_tan/KC are pushed ONCE PER SCENE against auto-incrementing
 * write pointers; per row only KR + 1/KR + START are written.
 * BIT-EXACTNESS: the datapath reproduces sar_coeffs_pass2_range()'s float32 values exactly
 * (mpfs/host/check_coeffgen_fixed.py, 45,038 outputs, both source orders), so enabling it cannot
 * move the pipeline CRC -- which is what makes a CRC-equality A/B the correct silicon acceptance
 * test. */
#define CGEN_CTRL            0x00u   /* W [0]=start row [1]=rewind tan [2]=rewind itan [3]=rewind kc; R [0]=busy */
#define CGEN_KR              0x04u   /* RW float32 bits of KR[j]              (per row) */
#define CGEN_RINV            0x08u   /* RW float32 bits of 1.0f/KR[j]         (per row, CPU-computed) */
#define CGEN_DIMS            0x0cu   /* RW [13:0]=S (=M source samples), [29:16]=QN (=Mp outputs) */
#define CGEN_TANW            0x10u   /* W tan_s[k] fp32 bits, ptr auto-increments; R = fill level */
#define CGEN_ITANW           0x14u   /* W inv_tan[k] fp32 bits, ptr auto-increments; R = fill level */
#define CGEN_KCW             0x18u   /* W KC[qi] fp32 bits, ptr auto-increments; R = fill level */
#define CGEN_STAT            0x1cu   /* R [0]=busy [1]=err_fmt [2]=err_dims [3]=degenerate [29:16]=outputs emitted */
#define CGEN_CTRL_START      0x1u
#define CGEN_CTRL_REWIND_ALL 0xEu    /* rewind tan + itan + kc write pointers (bits 1,2,3) */
#define CGEN_STAT_BUSY       0x1u
#define CGEN_STAT_ERR_FMT    0x2u    /* NaN/Inf/denormal reached the datapath -- values are garbage */
#define CGEN_STAT_ERR_DIMS   0x4u    /* tables not filled to S / S-1 / QN -- degenerate line emitted */
#define CGEN_STAT_DEGEN      0x8u

/* FIC_0 monitor register map (sar_fic0s_mon.v). 0x00 write-any = clear ALL. Reads are RO. */
#define FICMON_STATUS        0x00u   /* write clears; read = sticky flags + ar/r counts + 0xA5 sig */
#define FICMON_HIST_1        0x10u   /* AR bursts of 1 beat  (ARLEN==0, single-beat)  saturating */
#define FICMON_HIST_2_4      0x14u   /* AR bursts 2..4 beats */
#define FICMON_HIST_5_16     0x18u   /* AR bursts 5..16 beats */
#define FICMON_HIST_17_64    0x1cu   /* AR bursts 17..64 beats */
#define FICMON_HIST_65_256   0x20u   /* AR bursts 65..256 beats */
#define FICMON_BUSY          0x24u   /* cycles with an AR or R handshake in flight */
#define FICMON_ELAPSED       0x28u   /* total cycles since clear (utilization = busy/elapsed) */
#define FICMON_MAX_GAP       0x2cu   /* longest idle run between AR/R events (short-burst vs long-gap) */
/* v2 (2026-07-24): WRITE channel + intra-burst read-throttle -- splits "write time" from "DDR read
 * throttle" in the gather stall (see sar_fic0s_mon.v v2 map). */
#define FICMON_AW_COUNT      0x30u   /* AW handshakes (write bursts issued) */
#define FICMON_W_COUNT       0x34u   /* W beats accepted */
#define FICMON_B_STATUS      0x38u   /* [7:0]b_count [9:8]bresp [16..19]aw/w/b sticky [31:24]0x5A sig */
#define FICMON_WRITE_BUSY    0x3cu   /* cycles with AW/W/B handshake -> WRITE time */
#define FICMON_R_DATAWAIT    0x40u   /* cycles read-outstanding but RVALID low -> DDR read throttle */
#define FICMON_MAX_R_DATAWAIT 0x44u  /* longest such run */
#define FICMON_TOTAL_ACTIVE  0x48u   /* cycles with ANY handshake (true utilization numerator) */

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
