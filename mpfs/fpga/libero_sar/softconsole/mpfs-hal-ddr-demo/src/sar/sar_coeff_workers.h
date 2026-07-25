/*
 * sar_coeff_workers.h -- spread per-line coefficient generation across the idle U54 harts.
 *
 * WHY. Silicon telemetry (RPROF[2]/RPROF[5] in ab_metrics.log, 2026-07-25) shows the range
 * gather is 99.57% MSS coefficient generation and 0.25% fabric kernel wait -- the fabric hides
 * completely under the CPU. Every fabric-side lever tried so far (a 2nd gather lane, prefetch
 * depth, burst length, tile size, clock) was therefore competing for 0.25% of the stage, which
 * is why each returned a fraction of its prediction.
 *
 * WHY MORE HARTS RATHER THAN FEWER INSTRUCTIONS. The loop is not arithmetic-bound. Measured
 * ~62.8 cycles/output for a ~20-instruction body (disassembly: one hoisted fdiv, the rest
 * flw/fmul/fcvt/sw/sh), i.e. ~3 cycles/instruction on an in-order core, at an effective
 * 93 MB/s -- far below DDR capability. That is the signature of cache-miss latency (~0.16
 * misses/output across the KR read and the idx/wq write-allocate, with no HW prefetcher), not
 * issue bandwidth. Extra harts overlap those stalls; a cheaper inner loop would not. Confirm on
 * silicon with RPROF[14]/RPROF[15] (minstret/mcycle over coefficient generation only): IPC << 1
 * supports this model, IPC ~ 1 refutes it and the lever would instead be fewer ops.
 *
 * SAFETY PROPERTIES
 *  - Slices are DISJOINT contiguous output ranges, so no locking is needed on idx[]/wq[].
 *  - Boundaries are forced to multiples of SAR_CWRK_ALIGN (32) so that no 64-byte cache line is
 *    shared between two harts. Without this, one hart's FLUSH64 could write back a line another
 *    hart is still storing into, losing that hart's coefficients -- a silently wrong image.
 *    idx is int32 (16/line) and wq is int16 (32/line), so 32 satisfies both.
 *  - Each hart publishes ONLY its own slice (FIC_0 is non-coherent; the fabric reads DDR).
 *  - The dispatcher's wait is BOUNDED. On timeout it disables workers for the rest of the run
 *    and recomputes the whole line itself. A late-waking worker is harmless: it writes the same
 *    deterministic bytes for the same job parameters, which are never reused once disabled.
 *  - Bit-exactness of the split is PROVEN board-free (ascending and descending source, 2/3/4/5/8
 *    way) by mpfs/host/check_coeff_split.py. Re-run it if the coefficient contract changes.
 */
#ifndef SAR_COEFF_WORKERS_H_
#define SAR_COEFF_WORKERS_H_

#include <stdint.h>
#include "sar_resample_coeffs.h"

#define SAR_CWRK_ADDR   0xB0059300u   /* free: past FICMON (ends 0xB00592E0) */
#define SAR_CWRK_MAGIC  0x43574B31u   /* 'CWK1' */
#define SAR_CWRK_MAXW   4u            /* hart1 (worker 0) + U54_2/3/4 */
#define SAR_CWRK_ALIGN  32u           /* output-index granularity -> 64B cache-line disjoint */

/* Runtime knob, JTAG-pokable before PIPE so the change is A/B-able without a reflash:
 * number of harts to use for coefficient generation. 0 or 1 = OFF (original single-hart path). */
#define SAR_CWRK_NW_ADDR 0xB0059134u

typedef struct {
    volatile uint32_t magic;                 /* SAR_CWRK_MAGIC once workers are parked+ready */
    volatile uint32_t seq;                   /* dispatcher bumps to release a job */
    volatile uint32_t ack[SAR_CWRK_MAXW];    /* worker w writes seq when its slice is published */
    volatile uint32_t alive[SAR_CWRK_MAXW];  /* worker w heartbeat (jobs completed) */
    volatile uint32_t fcsr0[SAR_CWRK_MAXW];  /* each hart's FCSR AS FOUND, before we normalise it.
                                              * DIAGNOSTIC for the 2026-07-25 +-1 LSB divergence:
                                              * nothing in the MPFS HAL startup initialises fcsr/frm,
                                              * and the float ops here use the DYNAMIC rounding mode
                                              * (only the fcvt.w.s truncations are rm-encoded, ,rtz).
                                              * Harts 2/3/4 were WFI stubs that never ran float code,
                                              * so a differing frm would round their coefficients
                                              * differently -- exactly a +-1 LSB, unbiased, boundary-
                                              * only divergence that appears ONLY with nw>1 and that a
                                              * single-rounding-mode host model cannot reproduce.
                                              * If these read back non-identical, that was the cause. */
    volatile uint32_t nw;                    /* workers in this job (1 = single-hart) */
    volatile uint32_t pass;                  /* 1 = pass1 (range), 2 = pass2 (azimuth) */
    volatile uint32_t line;                  /* pulse i (pass 1) or range bin j (pass 2) */
    volatile uint32_t q_total;               /* Np (pass 1) or Mp (pass 2) */
    volatile uint64_t geom_addr;             /* const sar_geom_t * */
    volatile uint64_t idx_addr;              /* int32_t * bank base */
    volatile uint64_t wq_addr;               /* int16_t * bank base */
} sar_cwrk_t;

#define SAR_CWRK ((sar_cwrk_t *)(uintptr_t)SAR_CWRK_ADDR)

/* Slice boundary for worker w of nw over Q outputs, aligned to SAR_CWRK_ALIGN.
 * Both the dispatcher and the workers MUST use this one definition. */
static inline uint32_t sar_cwrk_bound(uint32_t w, uint32_t nw, uint32_t Q)
{
    if (w == 0u) return 0u;
    if (w >= nw) return Q;
    uint32_t units = Q / SAR_CWRK_ALIGN;                  /* whole aligned blocks */
    uint32_t b = (uint32_t)(((uint64_t)w * units) / nw) * SAR_CWRK_ALIGN;
    return (b > Q) ? Q : b;
}

/* Entry point for U54_2/3/4. w = 1..3. Never returns. */
void sar_coeff_worker_main(uint32_t w);

/* Called once by hart1 before the pipeline runs. */
void sar_cwrk_init(void);

/* Generate one line's coefficients across `nw` harts (nw <= SAR_CWRK_MAXW).
 * nw <= 1, workers absent, or !sar_coeffs_ready(g) -> falls back to the single-hart path.
 * Publishes every slice to DDR. Returns the number of harts that actually participated. */
uint32_t sar_cwrk_line(const sar_geom_t *g, uint32_t pass, uint32_t line,
                       int32_t *idx, int16_t *wq, uint32_t q_total, uint32_t nw);

#endif /* SAR_COEFF_WORKERS_H_ */
