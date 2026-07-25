/* sar_coeff_workers.c -- see header for the why, the safety properties, and the evidence. */
#include "mpfs_hal/mss_hal.h"
#include "sar_coeff_workers.h"
#include "ddr_sar_layout.h"

/* Publish a byte range L2 -> DDR. Same walk as the sequencer's helper; duplicated here because
 * that one is file-static and this code runs on a different hart. */
static inline void cwrk_flush_range(uint64_t base, uint64_t bytes)
{
    uint64_t addr = base & ~(uint64_t)(CACHE_BLOCK_BYTE_LENGTH - 1u);
    const uint64_t end = base + bytes;
    for (; addr < end; addr += CACHE_BLOCK_BYTE_LENGTH)
        CACHE_CTRL->FLUSH64 = addr;
}

/* Publish ONLY outputs [q0,q1) of one bank. Boundaries are SAR_CWRK_ALIGN-aligned, so the walked
 * lines belong exclusively to this hart (see the cache-line note in the header). */
static void cwrk_flush_slice(int32_t *idx, int16_t *wq, uint32_t q0, uint32_t q1)
{
    if (q1 <= q0) return;
    __asm volatile ("fence rw, rw");        /* my stores land before my flush walk */
    cwrk_flush_range((uint64_t)(uintptr_t)(idx + q0), (uint64_t)(q1 - q0) * 4u);
    cwrk_flush_range((uint64_t)(uintptr_t)(wq  + q0), (uint64_t)(q1 - q0) * 2u);
    __asm volatile ("fence rw, rw");        /* flush retires before I ack */
}

/* Compute + publish one slice. Shared by the dispatcher (w=0) and the workers. */
static void cwrk_do_slice(const sar_geom_t *g, uint32_t pass, uint32_t line,
                          int32_t *idx, int16_t *wq, uint32_t q0, uint32_t q1)
{
    if (q1 <= q0) return;
    if (pass == 1u) sar_coeffs_pass1_range(g, line, (float *)0, idx, wq, q0, q1);
    else            sar_coeffs_pass2_range(g, line, (float *)0, idx, wq, q0, q1);
    cwrk_flush_slice(idx, wq, q0, q1);
}

/* ---- RENORM job -------------------------------------------------------------------------
 * One hart's slice of the block-floating-point renormalize epilogue: rows [r0,r1) of the frame.
 *
 * CACHE CONTRACT (FIC_0 is non-coherent; the fabric both wrote this frame and will read it back).
 * Each hart brackets its OWN slice with the SAME primitive the serial epilogue uses, but with its
 * own hartid -- flush_l2_cache() cycles the WAY_MASK of the CALLING hart's D-cache and displaces
 * the L2 with zero-device reads through that hart's L1, so calling it per hart reduces the
 * property we depend on to exactly the one the serial path already proves on silicon: a hart's
 * own displacement flush publishes that hart's writes to DDR and invalidates its stale lines.
 * Nothing here relies on the (likely true, but unverified) assumption that one hart's L2 sweep
 * back-probes another hart's L1.
 *   pre-flush : invalidate, so this hart reads the fabric's DDR content and not a stale line.
 *   post-flush: publish, so the fabric's next read sees the renormalized values.
 * Concurrent sweeps are safe: an eviction always writes dirty data back before invalidating, so a
 * peer's sweep can never drop a store another hart has in flight, and the row ranges are disjoint
 * (a row is a whole number of 64 B cache lines, so no line is shared).
 * Cost: ~262k zero-device loads per sweep, i.e. a few ms -- 2 sweeps per hart, all overlapped,
 * against a 2.915 s epilogue. */
static void rwrk_prog(uint64_t prog_addr, uint32_t idx, uint32_t tot)
{
    volatile uint32_t *pg = (volatile uint32_t *)(uintptr_t)prog_addr;
    pg[0] = 5u; pg[1] = idx; pg[2] = tot; pg[3]++;      /* same record as the sequencer's SAR_PROG */
    __asm volatile ("fence rw, rw");
    cwrk_flush_range(prog_addr, 16u);                   /* JTAG reads PHYSICAL DDR */
}

static void rwrk_renorm_rows(const sar_cwrk_t *c, uint32_t hartid, uint32_t r0, uint32_t r1)
{
    if (r1 <= r0) return;
    /* Hoisted out of the loop: the descriptor is volatile, these are loop-invariant. */
    const uint8_t *rexp   = (const uint8_t *)(uintptr_t)c->exp_addr;
    const uint64_t base   = c->dst_addr;
    const uint32_t cols   = c->cols;
    const uint32_t emax   = c->emax;
    const uint32_t head   = c->headroom;
    const uint32_t det    = c->det;
    const uint32_t rows   = c->rows;
    const uint32_t stride = cols * (det ? 2u : 4u);
    /* Only the dispatcher hart publishes progress -- one writer, no race on the record. */
    const uint64_t prog   = (hartid == 1u) ? c->prog_addr : 0u;

    __asm volatile ("fence rw, rw");
    flush_l2_cache(hartid);                 /* invalidate: read the fabric's dst from DDR */
    for (uint32_t row = r0; row < r1; row++) {
        uint32_t sh = (uint32_t)(emax - (uint32_t)rexp[row]) + head;
        if (sh == 0u) continue;
        if (det) {
            uint16_t *d = (uint16_t *)(uintptr_t)(base + (uint64_t)row * stride);
            for (uint32_t i = 0; i < cols; i++) d[i] = (uint16_t)(d[i] >> sh);
        } else {
            uint32_t *d = (uint32_t *)(uintptr_t)(base + (uint64_t)row * stride);
            for (uint32_t i = 0; i < cols; i++) {
                uint32_t v = d[i];
                int32_t re = (int32_t)(int16_t)(v >> 16)     >> sh;
                int32_t im = (int32_t)(int16_t)(v & 0xFFFFu) >> sh;
                d[i] = (((uint32_t)(uint16_t)(int16_t)re) << 16) | (uint16_t)(int16_t)im;
            }
        }
        if (prog && (row & 0x7Fu) == 0u) rwrk_prog(prog, row, rows);
    }
    __asm volatile ("fence rw, rw");
    flush_l2_cache(hartid);                 /* publish: my rows reach DDR for the next kernel */
}

/* Normalise the FPU rounding mode and report what it was.
 *
 * ROOT CAUSE of the 2026-07-25 +-1 LSB divergence (silicon-proven concurrency-dependent: the SAME
 * binary gave crop CRC 0x319037b2 at CWRK_NW=1 and 0x4d64d464 at CWRK_NW=4). Nothing in the MPFS
 * HAL startup writes fcsr/frm, so each hart's rounding mode is whatever reset left it -- and it is
 * PER-HART state. The coefficient math uses the DYNAMIC rounding mode for every fmul/fadd/fsub and
 * for fcvt.s.w (only the fcvt.w.s truncations carry an explicit ,rtz). Harts 2/3/4 were parked WFI
 * stubs that had never executed a float instruction, so a differing frm on them went unnoticed
 * until they started generating coefficients: it perturbs only values sitting near a rounding
 * boundary, which is exactly a small, unbiased, +-1 LSB, boundary-only divergence that a
 * single-rounding-mode host model can never reproduce.
 *
 * frm = 0 = RNE (round-to-nearest-even) is the C/IEEE default and what the host models assume, so
 * normalising every participating hart to it makes the board agree with them AND with itself. */
static inline uint32_t cwrk_fpu_normalise(void)
{
    uint32_t was = (uint32_t)read_csr(fcsr);
    write_csr(fcsr, 0u);            /* frm = RNE, fflags cleared */
    return was;
}

void sar_cwrk_init(void)
{
    sar_cwrk_t *c = SAR_CWRK;
    c->seq = 0u;
    c->nw = 1u;
    c->job = SAR_CWRK_JOB_COEFF;             /* never leave the job kind as cold-boot garbage */
    for (uint32_t w = 0; w < SAR_CWRK_MAXW; w++) { c->ack[w] = 0u; c->alive[w] = 0u; c->fcsr0[w] = 0xFFFFFFFFu; }
    c->fcsr0[0] = cwrk_fpu_normalise();      /* hart1 (worker 0) -- the dispatcher itself */
    __asm volatile ("fence rw, rw");
    c->magic = SAR_CWRK_MAGIC;
    __asm volatile ("fence rw, rw");
}

void sar_coeff_worker_main(uint32_t w)
{
    sar_cwrk_t *c = SAR_CWRK;
    if (w == 0u || w >= SAR_CWRK_MAXW) { for (;;) __asm volatile ("wfi"); }

    /* Wait for hart1 to publish the block, then start in sync so seq==ack means "idle". */
    while (c->magic != SAR_CWRK_MAGIC) { __asm volatile ("nop"); }
    /* Match hart1's rounding mode BEFORE computing anything -- see cwrk_fpu_normalise(). This is
     * the fix for the +-1 LSB, CWRK_NW-dependent output divergence. */
    c->fcsr0[w] = cwrk_fpu_normalise();
    c->ack[w] = c->seq;
    __asm volatile ("fence rw, rw");

    for (;;) {
        uint32_t s = c->seq;
        if (s == c->ack[w]) { __asm volatile ("nop"); continue; }   /* idle spin */
        __asm volatile ("fence r, r");                               /* acquire the job fields */

        if (w < c->nw) {
            const uint32_t nw = c->nw;
            if (c->job == SAR_CWRK_JOB_RENORM) {
                const uint32_t rows = c->rows;
                rwrk_renorm_rows(c, (uint32_t)read_csr(mhartid),
                                 sar_cwrk_row_bound(w, nw, rows),
                                 sar_cwrk_row_bound(w + 1u, nw, rows));
            } else {
                const sar_geom_t *g = (const sar_geom_t *)(uintptr_t)c->geom_addr;
                const uint32_t Q  = c->q_total;
                cwrk_do_slice(g, c->pass, c->line,
                              (int32_t *)(uintptr_t)c->idx_addr,
                              (int16_t *)(uintptr_t)c->wq_addr,
                              sar_cwrk_bound(w, nw, Q), sar_cwrk_bound(w + 1u, nw, Q));
            }
            c->alive[w]++;
        }
        __asm volatile ("fence rw, rw");                             /* release before the ack */
        c->ack[w] = s;
    }
}

/* Bounded so a wedged worker can never hang the pipeline. Generous: one slice is ~0.2-0.9 ms and
 * this is a tight poll, so a real completion arrives orders of magnitude sooner. */
#define CWRK_SPIN_MAX  40000000u

static int s_cwrk_disabled;     /* sticky once a worker misses its deadline */

uint32_t sar_cwrk_line(const sar_geom_t *g, uint32_t pass, uint32_t line,
                       int32_t *idx, int16_t *wq, uint32_t q_total, uint32_t nw)
{
    sar_cwrk_t *c = SAR_CWRK;

    /* The *_range workers need the line-invariant reciprocals; without them they would emit a
     * zero-fill instead of coefficients (see sar_resample_coeffs.h). Never risk it. */
    if (nw <= 1u || s_cwrk_disabled || c->magic != SAR_CWRK_MAGIC || !sar_coeffs_ready(g)) {
        cwrk_do_slice(g, pass, line, idx, wq, 0u, q_total);
        return 1u;
    }
    if (nw > SAR_CWRK_MAXW) nw = SAR_CWRK_MAXW;

    c->geom_addr = (uint64_t)(uintptr_t)g;
    c->idx_addr  = (uint64_t)(uintptr_t)idx;
    c->wq_addr   = (uint64_t)(uintptr_t)wq;
    c->pass = pass; c->line = line; c->q_total = q_total; c->nw = nw;
    c->job = SAR_CWRK_JOB_COEFF;
    __asm volatile ("fence rw, rw");        /* job fields visible before the release */
    c->seq++;

    /* hart1 is worker 0 -- it does a slice too rather than idling. */
    cwrk_do_slice(g, pass, line, idx, wq,
                  sar_cwrk_bound(0u, nw, q_total), sar_cwrk_bound(1u, nw, q_total));

    for (uint32_t w = 1u; w < nw; w++) {
        uint32_t spins = 0u;
        while (c->ack[w] != c->seq) {
            if (++spins > CWRK_SPIN_MAX) {
                /* Deadline miss. Disable workers for the rest of the run and redo the WHOLE line
                 * here. A late worker is benign: for these same job fields it writes byte-identical
                 * coefficients, and seq is never bumped again once disabled. */
                s_cwrk_disabled = 1;
                cwrk_do_slice(g, pass, line, idx, wq, 0u, q_total);
                return 1u;
            }
        }
    }
    __asm volatile ("fence r, r");          /* acquire every worker's slice */
    return nw;
}

/* Deadline for the RENORM job, in MTIME ticks (1 MHz). A slice is ~0.7-1.0 s of DDR-bound
 * read-modify-write, so the COEFF job's tight spin count (sized for a ~0.5 ms slice) is far too
 * small here -- use wall-clock, which is also independent of how fast the polling loop runs.
 * 30 s means a hart is genuinely wedged, not merely slow. */
#define RWRK_DEADLINE_US  30000000u

uint32_t sar_cwrk_renorm(uint64_t dst, const uint8_t *row_exp, uint32_t rows, uint32_t cols,
                         uint32_t emax, uint32_t headroom, uint32_t det,
                         uint64_t prog_addr, uint32_t nw)
{
    sar_cwrk_t *c = SAR_CWRK;
    const uint32_t hartid = (uint32_t)read_csr(mhartid);

    if (nw > SAR_CWRK_MAXW) nw = SAR_CWRK_MAXW;
    c->dst_addr = dst;
    c->exp_addr = (uint64_t)(uintptr_t)row_exp;
    c->prog_addr = prog_addr;
    c->rows = rows; c->cols = cols; c->emax = emax; c->headroom = headroom; c->det = det;

    if (nw <= 1u || s_cwrk_disabled || c->magic != SAR_CWRK_MAGIC) {
        /* Exactly the original single-hart epilogue: fence, whole-L2 flush, the whole frame,
         * fence, whole-L2 flush. Same arithmetic, same order, same two flushes. */
        rwrk_renorm_rows(c, hartid, 0u, rows);
        return 1u;
    }

    c->nw = nw;
    c->job = SAR_CWRK_JOB_RENORM;
    __asm volatile ("fence rw, rw");        /* job fields visible before the release */
    c->seq++;

    /* hart1 is worker 0 -- it takes a slice too rather than idling. */
    rwrk_renorm_rows(c, hartid, sar_cwrk_row_bound(0u, nw, rows), sar_cwrk_row_bound(1u, nw, rows));

    const uint64_t deadline = readmtime() + (uint64_t)RWRK_DEADLINE_US;
    for (uint32_t w = 1u; w < nw; w++) {
        while (c->ack[w] != c->seq) {
            if (readmtime() > deadline) {
                /* NOT recoverable by redoing the work: a right-shift-in-place cannot be replayed,
                 * and a late worker would shift its rows a second time. The frame is partially
                 * renormalized, so fail LOUD and let the caller abort the pass. Sticky-disable so
                 * nothing else dispatches to a hart that has stopped answering. */
                s_cwrk_disabled = 1;
                return 0u;
            }
        }
    }
    __asm volatile ("fence r, r");          /* acquire every worker's slice */
    return nw;
}
