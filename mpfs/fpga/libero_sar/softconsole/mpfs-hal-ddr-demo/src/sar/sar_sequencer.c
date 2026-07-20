/*
 * sar_sequencer.c -- PFA pipeline sequencer (see sar_sequencer.h).
 *
 * Buffer plan (1 GiB LPDDR4, 256 MiB per complex frame so buffers are reused):
 *   SIG     0x88000000  input signal; reused as scratch-2 once resample consumes it
 *   SCRATCH 0x98000000  primary intermediate
 *   OUT     0xA8000000  final detected magnitude (uint16)
 *   tables  0xB0000000  resample idx/wq + window taper (host-loaded)
 *
 *   resample : SIG     -> SCRATCH
 *   window   : SCRATCH -> SCRATCH  (element-wise, in place)
 *   FFT range: SCRATCH -> SCRATCH  (per-row, in place: a row is read before its
 *                                   transform is written back)
 *   corner   : SCRATCH -> SIG      (transpose needs a distinct buffer; SIG is free)
 *   FFT azim : SIG     -> SIG
 *   detect   : SIG     -> OUT
 */
#include "mpfs_hal/mss_hal.h"     /* flush_l2_cache -- FIC0 is non-coherent (see below) */
#include "sar_sequencer.h"
#include "sar_kernels.h"
#include "ddr_sar_layout.h"
#include "sar_resample_coeffs.h"
#include "sar_accel_driver.h"     /* sar_job_t, sar_job_load (M, N from the host job) */
#include "sar_fft.h"              /* sar_cpu_fft -- CPU FFT (HLS K_FFT butterfly broken on silicon) */

/* Fixed geometry baked into the kernels + CoreFFT (POINTS = 8192). */
#define SAR_GRID          8192u
#define SAR_FRAME_SAMPLES ((uint64_t)SAR_GRID * SAR_GRID)        /* complex samples */
#define SAR_FRAME_BEATS   ((uint32_t)(SAR_FRAME_SAMPLES / 2u))   /* 2 samples / 64-bit beat */
#define SAR_DEFAULT_SPINS 0x40000000u

/* ---- targeted coefficient-bank writeback ----------------------------------
 * The resample loop only needs the two coefficient tables the MSS just wrote to
 * be visible in DDR to the non-coherent FIC0 kernel. The HAL's flush_l2_cache()
 * is a way-by-way walk -- for each of the 16 ways it reads 131 KiB from the L2
 * zero device (~268k volatile loads) and perturbs the WayMask allocation policy
 * -- so using it per line evicts the whole 2 MiB L2 to publish 48 KiB. Instead
 * write just the covering lines to the CCACHE FLUSH64 register (writeback +
 * invalidate of the line containing the given physical address): ~768 stores.
 *
 * A bank is NOT 48 KiB contiguous: idx is Np*4 B at +0x0000 and wq is Np*2 B at
 * +0x10000, with a hole between (see ddr_sar_layout.h). Flushing one 48 KiB run
 * from the bank base would cover idx + half the hole and MISS wq entirely, so
 * the kernel would gather with stale weights -- a still-focused but subtly wrong
 * image. Flush the two ranges separately. */
static inline void flush_range_to_ddr(uint64_t base, uint64_t bytes)
{
    uint64_t addr = base & ~(uint64_t)(CACHE_BLOCK_BYTE_LENGTH - 1u);
    const uint64_t end = base + bytes;
    for (; addr < end; addr += CACHE_BLOCK_BYTE_LENGTH)
        CACHE_CTRL->FLUSH64 = addr;
}

/* Publish coefficient bank `b` (n entries: idx int32[n], wq int16[n]) to DDR. */
static inline void flush_coef_bank_to_ddr(int b, uint32_t n)
{
    __asm volatile ("fence rw, rw");   /* coeff stores land before the flush walk */
    flush_range_to_ddr(SAR_COEF_IDX(b), (uint64_t)n * 4u);
    flush_range_to_ddr(SAR_COEF_WQ(b),  (uint64_t)n * 2u);
    __asm volatile ("fence rw, rw");   /* flush retires before the kernel is armed */
}

/* 32-bit address views the fabric masters drive onto FIC0 -> DDR. */
#define BUF_SIG      ((uint32_t)SAR_SIG_ADDR)
#define BUF_SCRATCH  ((uint32_t)SAR_SCRATCH_ADDR)
#define BUF_OUT      ((uint32_t)SAR_OUT_ADDR)

/* ---- FFT pass (HLS fft_kernel) --------------------------------------------
 * The CoreFFT streaming chain (fft_feeder -> gearbox -> CoreFFT -> fft_unloader) is
 * REPLACED by a single plain-AXI HLS kernel (K_FFT, control SLAVE4). fft_kernel reads
 * `src`, does a forward 8192-pt FFT per row (unconditional 1/8192 scaling, numerically
 * validated to >0.9997 correlation vs the float golden), and writes `dst` -- all via
 * one self-contained AXI4 read+write master. No native-handshake IP, no dual-master
 * streaming, no per-transform re-arm: it joins the well-behaved plain-kernel datapath,
 * sidestepping the pipeline-context stall that wedged the CoreFFT streaming path.
 * HLS_ARG0 = src, HLS_ARG1 = dst, HLS_ARG2 = nrows, HLS_START = go/done. */
#define SAR_PROG_ADDR     0xB0059100u   /* progress: [0]=pass(1/2) [1]=cur idx [2]=total [3]=heartbeat (JTAG-pollable) */
/* The progress word must reach PHYSICAL DDR or a JTAG poll reads a stale value and the
 * counter looks frozen -- indistinguishable from a hung pipeline. This used to happen for
 * free, as a side effect of the per-line whole-L2 flush in resample_2pass(); that flush is
 * now targeted at the coefficient banks only, so publish this line explicitly. The four
 * words are 16 B at a 64 B-aligned address = exactly one cache line, so this is one store. */
#define SAR_PROG(pass,idx,tot) do { volatile uint32_t *pg=(volatile uint32_t*)(uintptr_t)SAR_PROG_ADDR; \
    pg[0]=(uint32_t)(pass); pg[1]=(uint32_t)(idx); pg[2]=(uint32_t)(tot); pg[3]++; \
    __asm volatile ("fence rw, rw"); flush_range_to_ddr(SAR_PROG_ADDR, 16u); } while (0)

/* Runtime FFT-mode selector (JTAG/host-writable DDR word): 0 = CPU sar_cpu_fft (default,
 * always-correct global-block-exponent path); 1 = fabric CoreFFT chain (fft_feeder ->
 * gearbox -> CoreFFT -> fft_unloader). The fabric chain was validated end-to-end on silicon
 * 2026-07-09 (corr=1.0, 8/8 cases) after the gearbox READ_OUTP/DATAO-latency fix. Left as a
 * runtime flag so CPU vs fabric can be A/B'd (correctness + speed) without reflashing.
 * CAVEAT: CoreFFT emits a PER-ROW block-floating-point exponent (SCALE_EXP), whereas
 * sar_cpu_fft applies ONE global exponent to all rows (per-row exponents corrupt the 2-D
 * image). The current fabric discards SCALE_EXP, so mode 1 is only image-correct if the
 * frame's rows are near-uniform magnitude; otherwise a SCALE_EXP-capture fabric revision +
 * per-row renormalize is required (tracked in openspec). */
#define SAR_FFTMODE_ADDR       0xB0059110u   /* 0=CPU, 1=fabric CoreFFT chain */
#define SAR_FFT_HEADROOM_ADDR  0xB0059114u   /* extra renormalize right-shift (detect headroom); JTAG-tunable */
#define SAR_DETECTMODE_ADDR    0xB0059118u   /* 0=fabric detect kernel, 1=CPU detect (correct sqrt --
                                              * the fabric detect HLS mis-synthesizes negative-I sign
                                              * extension, saturating ~50% of pixels; see memory) */

/* Per-stage wall-clock timing: MTIME (CLINT) runs at 1 MHz -> 1 tick = 1 us. sar_form_image stamps
 * sar_stage_ts[0..6] at each stage boundary; the host reads the symbol and diffs to get per-stage us.
 * Order: [0]=start [1]=resample [2]=window [3]=rangeFFT [4]=cornerturn [5]=azimuthFFT [6]=detect. */
extern uint64_t readmtime(void);
__attribute__((used)) volatile uint64_t sar_stage_ts[8];

/* Fabric CoreFFT with a GLOBAL block exponent, matching sar_cpu_fft. CoreFFT auto-scales each
 * row by its own per-row exponent exp_i (SCALE_EXP), which would corrupt the 2-D image; so we
 * ARM PER ROW, read exp_i from the feeder's SCALE_EXP register (0x14), then renormalize every
 * row to the shared global exponent E_global = max(exp_i): Output[i] >>= (E_global - exp_i).
 * Net effect: every row is scaled by the same E_global -> the CPU FFT's global-block-exponent
 * result, reconstructed from CoreFFT's actual (not estimated) exponents. */
#define SAR_ROW_BEATS   (SAR_GRID / 2u)      /* 8192 samples / 2 samples-per-beat = 4096 beats/row */
#define SAR_ROW_BYTES   (SAR_GRID * 4u)      /* 8192 samples * 4 bytes = 32768 bytes/row */
#define K_FFT_SCALE_EXP 0x14u                /* feeder reg: last frame's latched CoreFFT SCALE_EXP */

static uint8_t sar_row_exp[SAR_GRID];        /* per-row captured exponent (static, off-stack) */

static int fft_fabric_pass(uint32_t src, uint32_t dst, uint32_t spins)
{
    uint32_t budget = spins ? spins : SAR_DEFAULT_SPINS;

    /* ---- PASS 1: per-row fabric FFT; capture each row's actual CoreFFT exponent ---- */
    for (uint32_t row = 0; row < SAR_GRID; row++) {
        uint32_t s = src + row * SAR_ROW_BYTES;
        uint32_t d = dst + row * SAR_ROW_BYTES;
        sar_reg_w(K_FFT_UNLOADER, HLS_ARG0, d);
        sar_reg_w(K_FFT_UNLOADER, HLS_ARG1, SAR_ROW_BEATS);
        sar_k_start(K_FFT_UNLOADER);
        sar_reg_w(K_FFT_FEEDER,   HLS_ARG0, s);
        sar_reg_w(K_FFT_FEEDER,   HLS_ARG1, SAR_ROW_BEATS);
        sar_k_start(K_FFT_FEEDER);
        uint32_t n = budget;
        while (n) { if (sar_k_idle(K_FFT_FEEDER) && sar_k_idle(K_FFT_UNLOADER)) break; n--; }
        if (n == 0u) return sar_k_idle(K_FFT_FEEDER) ? 1 : 2;   /* row stalled: 1=unloader, 2=feeder */
        /* SCALE_EXP is latched at the frame's OUTP_READY falling edge (before unloader DONE) */
        sar_row_exp[row] = (uint8_t)(sar_reg_r(K_FFT_FEEDER, K_FFT_SCALE_EXP) & 0xFu);
        if ((row & 0x7Fu) == 0u) SAR_PROG(4u, row, SAR_GRID);
    }

    /* ---- global block exponent = the largest per-row exponent (brightest row) ---- */
    uint8_t emax = 0;
    for (uint32_t row = 0; row < SAR_GRID; row++)
        if (sar_row_exp[row] > emax) emax = sar_row_exp[row];

    /* HEADROOM: CoreFFT's exp is the ACTUAL per-row max, so emax puts the brightest content at
     * FULL int16 scale -> detect saturates. The CPU FFT instead scales from the (looser) input
     * L1-norm, leaving ~a few bits of headroom (its "raise out_shift" knob). Add the same here.
     * Runtime-tunable at 0xB0059114 so it can be swept over JTAG without reflashing. */
    uint32_t headroom = *(volatile uint32_t *)(uintptr_t)SAR_FFT_HEADROOM_ADDR;
    if (headroom > 12u) headroom = 0u;                    /* uninitialized/garbage -> 0 */

    /* ---- PASS 2: renormalize each row to E_global (dst is fabric-written DDR, FIC0 non-coherent).
     * Output[i] >>= (emax - exp_i): total right-shift = exp_i + (emax-exp_i) = emax for every row,
     * so all rows share one exponent -- preserving row-to-row relative magnitude (the 2-D image). */
    __asm volatile ("fence rw, rw");
    flush_l2_cache(1u);                       /* evict stale L2 -> read the fabric's dst from DDR */
    for (uint32_t row = 0; row < SAR_GRID; row++) {
        uint32_t sh = (uint32_t)(emax - sar_row_exp[row]) + headroom;
        if (sh == 0u) continue;
        uint32_t *d = (uint32_t *)(uintptr_t)(dst + row * SAR_ROW_BYTES);
        for (uint32_t i = 0; i < SAR_GRID; i++) {
            uint32_t v = d[i];
            int32_t re = (int32_t)(int16_t)(v >> 16)     >> sh;
            int32_t im = (int32_t)(int16_t)(v & 0xFFFFu) >> sh;
            d[i] = (((uint32_t)(uint16_t)(int16_t)re) << 16) | (uint16_t)(int16_t)im;
        }
        if ((row & 0x7Fu) == 0u) SAR_PROG(5u, row, SAR_GRID);
    }
    __asm volatile ("fence rw, rw");
    flush_l2_cache(1u);                       /* push renormalized dst to DDR for the next kernel */
    return 0;
}

/* One FFT pass over the whole frame: transform all SAR_GRID rows of `src` (each an 8192-pt
 * row FFT) into `dst`. Mode 0 = CPU sar_cpu_fft (HLS K_FFT butterfly was broken on silicon;
 * see m3 memory). Mode 1 = the now-working fabric CoreFFT chain. Returns 0 = OK. */
static int fft_pass(uint32_t src, uint32_t dst, uint32_t spins)
{
    /* FIC0 non-coherent: flush so `src` is in DDR (not stale L2) before the FFT, then flush
     * so `dst` reaches DDR for the next fabric kernel's FIC0 read. */
    flush_l2_cache(1u);
    __asm volatile ("fence rw, rw");
    int rc;
    if (*(volatile uint32_t *)(uintptr_t)SAR_FFTMODE_ADDR == 1u) {
        rc = fft_fabric_pass(src, dst, spins);
    } else {
        sar_cpu_fft((const uint32_t *)(uintptr_t)src, (uint32_t *)(uintptr_t)dst, SAR_GRID);
        rc = 0;
    }
    __asm volatile ("fence rw, rw");
    flush_l2_cache(1u);
    return rc;
}

/* ---- on-MSS keystone resample: 2 passes, coefficients computed per line -----
 * pass 1 (range): each real pulse row of SIG (N samples) is resampled to the
 *   padded width Np and written to SCRATCH at its tan_phi-sorted row (invord[i]),
 *   so SCRATCH ends up pulse-sorted; padded rows are then zeroed.
 * transpose SCRATCH -> SIG so range bins (columns) become rows.
 * pass 2 (azimuth): each range-bin row (M sorted pulses) is resampled to Mp,
 *   leaving the resampled k-space in SCRATCH (range x cross).
 * The resample kernel runs one line per call; the MSS double-buffers the next
 * line's coefficients (bank b^1) while the current line (bank b) streams. */
static int resample_2pass(const sar_geom_t *g, uint32_t spins)
{
    float *f32 = (float *)(uintptr_t)SAR_COEF_LINE_F32;
    const int32_t *invord = (const int32_t *)(uintptr_t)SAR_INVORDER_ADDR;
    const uint32_t Np = g->Np, Mp = g->Mp;
    int b = 0;

    /* PASS 1 (range) */
    sar_coeffs_pass1(g, 0, f32, (int32_t *)(uintptr_t)SAR_COEF_IDX(0),
                                (int16_t *)(uintptr_t)SAR_COEF_WQ(0));
    for (uint32_t i = 0; i < g->M; i++) {
        SAR_PROG(1u, i, g->M);
        sar_reg_w(K_RESAMPLE, HLS_ARG0, BUF_SIG + i * g->N * 4u);            /* in  (N-wide) */
        sar_reg_w(K_RESAMPLE, HLS_ARG1, (uint32_t)SAR_COEF_IDX(b));
        sar_reg_w(K_RESAMPLE, HLS_ARG2, (uint32_t)SAR_COEF_WQ(b));
        sar_reg_w(K_RESAMPLE, HLS_ARG3, BUF_SCRATCH + (uint32_t)invord[i] * Np * 4u);
        /* FIC0 non-coherent: the idx/wq coeffs just computed by the MSS (bank b) live in
         * L2, not DDR. Publish just that bank before the kernel reads it via FIC0, else
         * it gathers with stale coeffs. */
        flush_coef_bank_to_ddr(b, Np);
        sar_k_start(K_RESAMPLE);
        if (i + 1u < g->M)
            sar_coeffs_pass1(g, i + 1u, f32, (int32_t *)(uintptr_t)SAR_COEF_IDX(b ^ 1),
                                             (int16_t *)(uintptr_t)SAR_COEF_WQ(b ^ 1));
        if (!sar_k_wait(K_RESAMPLE, spins)) return 0;
        b ^= 1;
    }
    /* zero padded pulse rows (M..Mp-1) for clean FFT zero-padding (CPU clear; a
     * candidate for a fabric memset if this dominates runtime) */
    {
        volatile uint64_t *z = (volatile uint64_t *)(uintptr_t)(BUF_SCRATCH + g->M * Np * 4u);
        uint64_t words = ((uint64_t)(Mp - g->M) * Np) / 2u;   /* 2 complex int16 / 64-bit */
        for (uint64_t w = 0; w < words; w++) z[w] = 0u;
    }

    /* transpose SCRATCH(Mp x Np) -> SIG(Np x Mp) */
    sar_reg_w(K_CORNER_TURN, HLS_ARG0, BUF_SCRATCH);
    sar_reg_w(K_CORNER_TURN, HLS_ARG1, BUF_SIG);
    sar_k_start(K_CORNER_TURN);
    if (!sar_k_wait(K_CORNER_TURN, spins)) return 0;

    /* PASS 2 (azimuth) */
    sar_coeffs_pass2(g, 0, f32, (int32_t *)(uintptr_t)SAR_COEF_IDX(0),
                                (int16_t *)(uintptr_t)SAR_COEF_WQ(0));
    b = 0;
    for (uint32_t j = 0; j < Np; j++) {
        SAR_PROG(2u, j, Np);
        sar_reg_w(K_RESAMPLE, HLS_ARG0, BUF_SIG     + j * Mp * 4u);   /* in  (Mp-wide, M valid) */
        sar_reg_w(K_RESAMPLE, HLS_ARG1, (uint32_t)SAR_COEF_IDX(b));
        sar_reg_w(K_RESAMPLE, HLS_ARG2, (uint32_t)SAR_COEF_WQ(b));
        sar_reg_w(K_RESAMPLE, HLS_ARG3, BUF_SCRATCH + j * Mp * 4u);   /* out (Mp-wide) */
        flush_coef_bank_to_ddr(b, Mp);   /* publish just-computed coeffs L2 -> DDR (non-coherent FIC0) */
        sar_k_start(K_RESAMPLE);
        if (j + 1u < Np)
            sar_coeffs_pass2(g, j + 1u, f32, (int32_t *)(uintptr_t)SAR_COEF_IDX(b ^ 1),
                                             (int16_t *)(uintptr_t)SAR_COEF_WQ(b ^ 1));
        if (!sar_k_wait(K_RESAMPLE, spins)) return 0;
        b ^= 1;
    }
    return 1;
}

/* Debug: arm the unloader + start the feeder, do NOT wait -> hold the streaming path live for
 * SmartDebug (see sar_sequencer.h). Range-FFT config: SCRATCH -> (stream) -> SCRATCH. */
void sar_fft_hold(void)
{
    __asm volatile ("fence rw, rw");
    sar_reg_w(K_FFT_UNLOADER, HLS_ARG1, SAR_FRAME_BEATS);
    sar_reg_w(K_FFT_UNLOADER, HLS_ARG0, BUF_SCRATCH);
    sar_k_start(K_FFT_UNLOADER);
    sar_reg_w(K_FFT_FEEDER, HLS_ARG1, SAR_FRAME_BEATS);
    sar_reg_w(K_FFT_FEEDER, HLS_ARG0, BUF_SCRATCH);
    sar_k_start(K_FFT_FEEDER);
    /* return immediately; feeder + unloader run/stall in fabric, holding the handshake */
}

/* Debug: run ONLY the range-FFT pass (SIG -> SCRATCH), skipping the ~10 min resample. Fast
 * iteration on the feeder/CoreFFT/unloader streaming path.
 * Returns fft_pass status (0 OK, 1 feeder stall, 2 unloader stall); DMADBG @0xB0059200 on a stall. */
__attribute__((used)) int sar_fft_pass_test(void)
{
    __asm volatile ("fence rw, rw");
    /* DECOUPLED src/dst (SIG -> SCRATCH) so range-FFT input and output never alias. */
    return fft_pass(BUF_SIG, BUF_SCRATCH, 0x00200000u);
}

/* Debug: SCALE_EXP-capture + renormalize ISOLATION test (set fft mode=1 first). Fill SIG with
 * two DC rows at exactly 16:1 amplitude (row0 I=8000, row1 I=500), zero the rest, run the fabric
 * range-FFT (SIG->SCRATCH). A DC row of value V -> N*V at bin0: row0 bin0=8192*8000=6.55e7 (needs
 * CoreFFT SCALE_EXP~11), row1 bin0=8192*500=4.10e6 (~7). If per-row SCALE_EXP capture + global
 * renormalize preserve relative scale, SCRATCH row0/row1 bin0 magnitudes stay ~16:1; if the
 * capture is broken (rows read the same/wrong exp), both land near full-scale -> ratio ~1:1 --
 * which corrupts the 2-D image but is INVISIBLE to the scale-invariant per-row iso-test.
 * Read after: SCRATCH row0 bin0 @0x98000000, row1 bin0 @0x98008000; sar_row_exp[0..1]. */
__attribute__((used)) int sar_fabric_scale_test(void)
{
    uint32_t *sig = (uint32_t *)(uintptr_t)BUF_SIG;
    for (uint32_t i = 0; i < SAR_GRID; i++) sig[i]            = ((uint32_t)(uint16_t)8000u) << 16; /* row0 DC */
    for (uint32_t i = 0; i < SAR_GRID; i++) sig[SAR_GRID + i] = ((uint32_t)(uint16_t)500u)  << 16; /* row1 DC */
    for (uint64_t i = 2u * SAR_GRID; i < (uint64_t)SAR_GRID * SAR_GRID; i++) sig[i] = 0u;          /* zero rows 2..N */
    __asm volatile ("fence rw, rw");
    return fft_pass(BUF_SIG, BUF_SCRATCH, 0x00200000u);       /* fabric path when mode=1 */
}

/* CPU magnitude detect: sqrt(I^2+Q^2) over `n` complex-int16 words (I<<16|Q), SIG -> OUT. Correct
 * signed extraction (GCC sign-extends properly, unlike the fabric detect HLS). Confirms the pipeline
 * hits ~0.99 with a correct detect, without a fabric rebuild. Slow (~tens of seconds for 8192^2). */
static uint32_t cpu_isqrt(uint64_t v)
{
    uint64_t one = 1ULL << 30, res = 0, op = v;
    for (int i = 0; i < 16; i++) {
        if (op >= res + one) { op -= res + one; res = (res >> 1) + one; }
        else res >>= 1;
        one >>= 2;
    }
    return (uint32_t)res;
}
static void cpu_detect(uint32_t src, uint32_t dst, uint32_t n)
{
    const volatile uint32_t *in  = (const volatile uint32_t *)(uintptr_t)src;
    volatile uint16_t       *out = (volatile uint16_t *)(uintptr_t)dst;
    for (uint32_t i = 0; i < n; i++) {
        uint32_t w = in[i];
        int32_t re = (int32_t)(int16_t)(uint16_t)(w >> 16);   /* signed I */
        int32_t im = (int32_t)(int16_t)(uint16_t)(w & 0xFFFFu);/* signed Q */
        uint32_t m = cpu_isqrt((uint64_t)((int64_t)re * re + (int64_t)im * im));
        out[i] = (m > 0xFFFFu) ? 0xFFFFu : (uint16_t)m;
    }
}

sar_seq_status_t sar_form_image(uint32_t spin_limit)
{
    uint32_t spins = spin_limit ? spin_limit : SAR_DEFAULT_SPINS;

    /* scene dims come from the host job descriptor; padded grid is the fixed
     * size baked into the kernels + CoreFFT (square, SAR_GRID). */
    sar_job_t job;
    if (sar_job_load(&job) != SAR_OK) return SAR_SEQ_BAD_JOB;
    sar_geom_t g = {
        .M = job.M, .N = job.N, .Mp = SAR_GRID, .Np = SAR_GRID,
        .f0    = (const float *)(uintptr_t)SAR_F0_ADDR,
        .df    = (const float *)(uintptr_t)SAR_DF_ADDR,
        .pr    = (const float *)(uintptr_t)SAR_PR_ADDR,
        .tan_s = (const float *)(uintptr_t)SAR_TANS_ADDR,
        .KR    = (const float *)(uintptr_t)SAR_KRGRID_ADDR,
        .KC    = (const float *)(uintptr_t)SAR_KCGRID_ADDR,
    };

    /* Make CPU-prepared DDR (signal + geometry) visible to the fabric masters.
     * If FIC0 is used non-coherently, replace these fences with explicit
     * cache flush(before)/invalidate(after) of the touched DDR regions. */
    __asm volatile ("fence rw, rw");

    sar_stage_ts[0] = readmtime();
    /* 1) keystone resample (2-pass, MSS-computed coeffs): -> SCRATCH */
    if (!resample_2pass(&g, spins)) return SAR_SEQ_TIMEOUT_RESAMPLE;
    sar_stage_ts[1] = readmtime();

    /* 2) window (2-D Hamming: fabric forms hamr[j]*hamc[k]): SCRATCH -> SCRATCH */
    sar_reg_w(K_WINDOW, HLS_ARG0, BUF_SCRATCH);                  /* in  */
    sar_reg_w(K_WINDOW, HLS_ARG1, (uint32_t)SAR_HAMR_ADDR);      /* range taper [Np] */
    sar_reg_w(K_WINDOW, HLS_ARG2, (uint32_t)SAR_HAMC_ADDR);      /* cross taper [Mp] */
    sar_reg_w(K_WINDOW, HLS_ARG3, BUF_SCRATCH);                  /* out */
    sar_k_start(K_WINDOW);
    if (!sar_k_wait(K_WINDOW, spins)) return SAR_SEQ_TIMEOUT_WINDOW;
    sar_stage_ts[2] = readmtime();

    /* 3) range FFT: SCRATCH -> SIG (DECOUPLED src/dst -- an in-place FFT feeding-and-
     *    draining the SAME DDR page stalls at transform 1 on silicon: the DMA is still
     *    flushing transform t's output while the feeder pulls transform t+1's input over
     *    the shared interconnect, so CoreFFT drops BUF_READY and the pipeline locks up.
     *    SIG is free after resample, so ping-pong SCRATCH<->SIG keeps read/write on
     *    separate 256 MB pages. VALIDATED on silicon: decoupled fft_pass streams past
     *    transform 1 (in-place stalled at idx=1). */
    { int r = fft_pass(BUF_SCRATCH, BUF_SIG, spins);
      if (r == 1) return SAR_SEQ_TIMEOUT_FFT1;          /* feeder stalled */
      if (r == 2) return SAR_SEQ_TIMEOUT_DMA; }          /* DMA S2MM stalled (range) */
    sar_stage_ts[3] = readmtime();

    /* 4) corner-turn (transpose): SIG -> SCRATCH (range-FFT output is now in SIG) */
    sar_reg_w(K_CORNER_TURN, HLS_ARG0, BUF_SIG);
    sar_reg_w(K_CORNER_TURN, HLS_ARG1, BUF_SCRATCH);
    sar_k_start(K_CORNER_TURN);
    if (!sar_k_wait(K_CORNER_TURN, spins)) return SAR_SEQ_TIMEOUT_CORNER;
    sar_stage_ts[4] = readmtime();

    /* 5) azimuth FFT: SCRATCH -> SIG (DECOUPLED, same ping-pong as range FFT) */
    { int r = fft_pass(BUF_SCRATCH, BUF_SIG, spins);
      if (r == 1) return SAR_SEQ_TIMEOUT_FFT2;          /* feeder stalled */
      if (r == 2) return SAR_SEQ_TIMEOUT_DMA; }          /* DMA S2MM stalled (azimuth) */
    sar_stage_ts[5] = readmtime();

    /* 6) detect (sqrt(I^2+Q^2)): SIG -> OUT (azimuth-FFT output is in SIG).
     * DEFAULT = CPU detect (correct sqrt, corr 0.97 on silicon -- the SHIPPING path). The fabric
     * detect HLS is UNFIXABLE via SmartHLS (it mis-synthesizes the negative-I sign extension no
     * matter how detect.cpp is written -> ~50% saturation); DETECTMODE 2 selects it for testing only. */
    if (*(volatile uint32_t *)(uintptr_t)SAR_DETECTMODE_ADDR != 2u) {
        flush_l2_cache(1u);                                  /* read fabric-written SIG from DDR */
        cpu_detect(BUF_SIG, BUF_OUT, SAR_GRID * SAR_GRID);
        flush_l2_cache(1u);                                  /* push OUT to DDR for JTAG readback */
    } else {
        sar_reg_w(K_DETECT, HLS_ARG0, BUF_SIG);
        sar_reg_w(K_DETECT, HLS_ARG1, BUF_OUT);
        sar_k_start(K_DETECT);
        if (!sar_k_wait(K_DETECT, spins)) return SAR_SEQ_TIMEOUT_DETECT;
    }
    sar_stage_ts[6] = readmtime();

    /* Ensure fabric writes to OUT land in DDR before the host JTAG-dumps it.
     * (Invalidate the OUT region if it was cached non-coherently.) */
    __asm volatile ("fence rw, rw");
    return SAR_SEQ_OK;
}
