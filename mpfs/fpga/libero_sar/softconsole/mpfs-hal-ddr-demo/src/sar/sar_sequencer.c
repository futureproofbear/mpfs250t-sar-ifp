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
/* ---- resample per-line PROFILE (0xB0059180, 12 x uint64) ---------------------------------
 * Splits the resample line loop into its four components so we stop GUESSING which one owns
 * the ~1.34 ms/line gap (1.475 ms measured vs 131 us ideal at II=1 for 8192 elements @62.5 MHz).
 * Three data-movement hypotheses have already been falsified by assuming instead of measuring.
 *
 * The loop order is:  ARG writes -> flush coeff bank -> START -> compute NEXT line's coeffs -> WAIT
 * so the kernel runs concurrently with the coefficient generation. That makes `wait` the
 * discriminator:
 *     wait ~= 0        -> CPU-BOUND. Coefficient generation is the limiter; the kernel already
 *                         finished. Chunking/auto-rearm would NOT help -- coeff work is per-line.
 *     wait large       -> KERNEL-BOUND. The fabric gather is genuinely slow; look at the AXI path.
 *     regw+flush large -> ARM-BOUND. Then bigger payloads per arm is the right fix.
 *
 * Layout: [0..3] pass1 regw/flush/coeff/wait, [4] lines, [5] pass1 total,
 *         [6..9] pass2 same,                  [10] lines, [11] pass2 total.  All MTIME us. */
#define SAR_RPROF_ADDR         0xB0059180u
#define SAR_RPROF_PROBE_ADDR   0xB0059120u   /* 0 = off; else kernel-only probe iterations */
#define RPROF ((volatile uint64_t *)(uintptr_t)SAR_RPROF_ADDR)

/* ---- FIC_0 monitor snapshot (0xB0059240, 2 x 12 x uint32) --------------------------------
 * The gather kernel runs at II=1 (verified) yet ~880 us/line vs a 361 us schedule -- a 2.44x AXI
 * stall on a correct schedule. This captures WHY, per line, straight off the FIC_0 bus: clear the
 * monitor at sar_k_start, snapshot at sar_k_wait-done, so the counters cover exactly that line's
 * DDR-facing AXI activity (the resample kernel is the only fabric master live during a line; the
 * coeff-bank flush is CPU-side CCACHE, not FIC_0, so the monitor does not see it).
 * Snapshot slot 0 = pass-1 (range gather) line 0, slot 1 = pass-2 (azimuth gather) line 0.
 * Record layout per slot (12 x uint32): [0]=0xF1C0AA0p (p=pass) [1]=STATUS [2..6]=ARLEN hist
 * (1 / 2-4 / 5-16 / 17-64 / 65-256) [7]=busy [8]=elapsed [9]=max_gap [10]=beats_this_line [11]=0.
 * Decode with mpfs/host/decode_ficmon.py. Needs the 2026-07-22 monitor bitstream; on an older
 * bitstream K_FIC0MON does not decode and reads return the AXI default (harmless, obviously bogus). */
#define SAR_FICMON_ADDR        0xB0059240u
#define FICMON_REC(slot)  ((volatile uint32_t *)(uintptr_t)(SAR_FICMON_ADDR + (slot) * 48u))

static inline void ficmon_clear(void) { sar_reg_w(K_FIC0MON, FICMON_STATUS, 1u); }

static void ficmon_snapshot(uint32_t slot, uint32_t pass, uint32_t beats)
{
    volatile uint32_t *r = FICMON_REC(slot);
    r[0]  = 0xF1C0AA00u | (pass & 0xFu);
    r[1]  = sar_reg_r(K_FIC0MON, FICMON_STATUS);
    r[2]  = sar_reg_r(K_FIC0MON, FICMON_HIST_1);
    r[3]  = sar_reg_r(K_FIC0MON, FICMON_HIST_2_4);
    r[4]  = sar_reg_r(K_FIC0MON, FICMON_HIST_5_16);
    r[5]  = sar_reg_r(K_FIC0MON, FICMON_HIST_17_64);
    r[6]  = sar_reg_r(K_FIC0MON, FICMON_HIST_65_256);
    r[7]  = sar_reg_r(K_FIC0MON, FICMON_BUSY);
    r[8]  = sar_reg_r(K_FIC0MON, FICMON_ELAPSED);
    r[9]  = sar_reg_r(K_FIC0MON, FICMON_MAX_GAP);
    r[10] = beats;
    r[11] = 0u;
    __asm volatile ("fence rw, rw");
    flush_range_to_ddr(SAR_FICMON_ADDR + slot * 48u, 48u);   /* publish for a JTAG physical read */
}
#define RP_T0(v)  uint64_t v = readmtime()
#define RP_ACC(i, v) do { RPROF[i] += readmtime() - (v); } while (0)

#define SAR_DETECTMODE_ADDR    0xB0059118u   /* 0=fabric detect kernel, 1=CPU detect (correct sqrt --
                                              * the fabric detect HLS mis-synthesizes negative-I sign
                                              * extension, saturating ~50% of pixels; see memory) */

/* Per-stage wall-clock timing: MTIME (CLINT) runs at 1 MHz -> 1 tick = 1 us. sar_form_image stamps
 * sar_stage_ts[0..6] at each stage boundary; the host reads the symbol and diffs to get per-stage us.
 * Order: [0]=start [1]=resample [2]=window [3]=rangeFFT [4]=cornerturn [5]=azimuthFFT [6]=detect. */
extern uint64_t readmtime(void);
__attribute__((used)) volatile uint64_t sar_stage_ts[8];

/* Resample SUB-stage timestamps (MTIME, 1 us/tick). `resample` in sar_stage_ts is a single
 * number covering three structurally different workloads: a per-pulse gather (range), a global
 * transpose, and a per-range-bin gather (azimuth). They parallelise very differently -- the two
 * gathers are embarrassingly parallel across lines, the transpose is not -- so any parallel-fabric
 * design needs them measured, not apportioned. Indices: 0 start, 1 range done, 2 corner-turn done,
 * 3 azimuth done. Read with mpfs/host/run_stage_timing.sh. */
__attribute__((used)) volatile uint64_t sar_resample_ts[4];

/* Fabric CoreFFT with a GLOBAL block exponent, matching sar_cpu_fft. CoreFFT auto-scales each
 * row by its own per-row exponent exp_i (SCALE_EXP), which would corrupt the 2-D image; so we
 * ARM PER ROW, read exp_i from the feeder's SCALE_EXP register (0x14), then renormalize every
 * row to the shared global exponent E_global = max(exp_i): Output[i] >>= (E_global - exp_i).
 * Net effect: every row is scaled by the same E_global -> the CPU FFT's global-block-exponent
 * result, reconstructed from CoreFFT's actual (not estimated) exponents. */
#define SAR_ROW_BEATS   (SAR_GRID / 2u)      /* 8192 samples / 2 samples-per-beat = 4096 beats/row */
#define SAR_ROW_BYTES   (SAR_GRID * 4u)      /* 8192 samples * 4 bytes = 32768 bytes/row */
#define K_FFT_SCALE_EXP 0x14u                /* feeder reg: last frame's latched CoreFFT SCALE_EXP */
/* Fused magnitude-detect in the FFT unloader (fft_unloader_v.v). Deletes the separate detect
 * pass -- 20.6 s, 512 MB read + 128 MB written -- by computing |z| as the second FFT's output
 * streams to DDR. Only the AZIMUTH pass may enable it; the range pass must stay complex.
 * In detect mode a row is uint16 (16384 B), not complex int32 (32768 B). */
#define K_UNL_DET_CTRL  0x18u                /* unloader reg: [0] = fused detect enable */
#define K_UNL_STATUS2   0x14u                /* unloader sticky AXI/protocol error latches */
#define SAR_ROW_BYTES_U16 (SAR_GRID * 2u)    /* detect-mode output row */
/* Fused 2-D Hamming window in the feeder (fft_feeder_v.v) -- replaces the standalone window
 * pass, which cost 6.0 s reading and rewriting the whole 512 MB frame for an element-wise
 * multiply on data the feeder already reads. Bit-identical to hls_window/window.cpp; proven
 * by tb/tb_fft_feeder_win.v against vectors generated from that arithmetic. */
#define K_FFT_WIN_CTRL  0x18u                /* [15:0]=hamr[row] Q15, [16]=enable, [17]=rewind tab */
#define K_FFT_WIN_TAB   0x1cu                /* {hamc[2i+1],hamc[2i]}, pointer auto-increments */
#define WIN_TAB_WORDS   (SAR_GRID / 2u)      /* 8192 taps / 2 per word = 4096 words */
/* Fused azimuth-resample GATHER in the FFT-1 feeder (fft_feeder_v.v, 2026-07-22). Deletes the
 * standalone azimuth resample stage: the feeder gathers M source samples -> Mp outputs, windows,
 * and streams to CoreFFT, so the ~13.5 s pass folds under the FFT feed. Runtime-gated by
 * SAR_GATHERMODE_ADDR so the default pipeline is unchanged. idx/wq are read from DDR per row (the
 * feeder's own read master), NOT loaded over AXI4-Lite. */
#define K_FFT_GATHER_CTRL 0x20u              /* [0] = gather enable */
#define K_FFT_IDX_BASE    0x24u              /* DDR byte addr of this row's idx[] */
#define K_FFT_WQ_BASE     0x28u              /* DDR byte addr of this row's wq[] */
#define K_FFT_GATHER_DIMS 0x2cu              /* [15:0]=SRC_LEN (source samples), [31:16]=QN (outputs) */
#define SAR_GATHERMODE_ADDR 0xB005911Cu      /* 0=standalone azimuth resample (default); 1=fused into FFT-1 */

static uint8_t sar_row_exp[SAR_GRID];        /* per-row captured exponent (static, off-stack) */

/* Push the cross taper into the feeder's on-chip table (once per pass, ~4096 AXI4-Lite writes
 * ~= 1.3 ms -- free against the 6.0 s the window pass cost). Deliberately not a fabric DMA:
 * a second mode in the feeder's read FSM would have to arbitrate for AR/R against the row feed. */
static void fft_win_load_taper(void)
{
    const int16_t *hamc = (const int16_t *)(uintptr_t)SAR_HAMC_ADDR;
    sar_reg_w(K_FFT_FEEDER, K_FFT_WIN_CTRL, 1u << 17);        /* rewind the write pointer */
    for (uint32_t i = 0; i < WIN_TAB_WORDS; i++)
        sar_reg_w(K_FFT_FEEDER, K_FFT_WIN_TAB,
                  ((uint32_t)(uint16_t)hamc[2u * i + 1u] << 16) | (uint16_t)hamc[2u * i]);
}

/* CPU-side equivalent for the mode-0 (CPU FFT) fallback, which does not go through the feeder
 * and would otherwise silently transform UNWINDOWED data now that the window pass is gone.
 * Same arithmetic and truncation order as window.cpp / the fused feeder. */
static void fft_win_cpu(uint32_t buf, uint32_t rows)
{
    const int16_t *hamr = (const int16_t *)(uintptr_t)SAR_HAMR_ADDR;
    const int16_t *hamc = (const int16_t *)(uintptr_t)SAR_HAMC_ADDR;
    for (uint32_t j = 0; j < rows; j++) {
        uint32_t *d = (uint32_t *)(uintptr_t)(buf + j * SAR_ROW_BYTES);
        int32_t hr = hamr[j];
        for (uint32_t k = 0; k < SAR_GRID; k++) {
            int16_t cw = (int16_t)((hr * (int32_t)hamc[k]) >> 15);
            uint32_t v = d[k];
            int16_t re = (int16_t)(((int32_t)(int16_t)(v >> 16)      * cw) >> 15);
            int16_t im = (int16_t)(((int32_t)(int16_t)(v & 0xFFFFu)  * cw) >> 15);
            d[k] = (((uint32_t)(uint16_t)re) << 16) | (uint16_t)im;
        }
    }
}

static int fft_fabric_pass(uint32_t src, uint32_t dst, uint32_t spins, int win_en, int det_en)
{
    uint32_t budget = spins ? spins : SAR_DEFAULT_SPINS;
    const int16_t *hamr = (const int16_t *)(uintptr_t)SAR_HAMR_ADDR;

    if (win_en) fft_win_load_taper();

    /* ---- PASS 1: per-row fabric FFT; capture each row's actual CoreFFT exponent ---- */
    for (uint32_t row = 0; row < SAR_GRID; row++) {
        uint32_t s = src + row * SAR_ROW_BYTES;
        /* detect mode halves the output row: uint16 magnitudes, not complex int32 */
        uint32_t d = dst + row * (det_en ? SAR_ROW_BYTES_U16 : SAR_ROW_BYTES);
        /* Written unconditionally (0 when disabled) so the enable cannot leak from the azimuth
         * pass into a later range pass -- same discipline as the fused window below. */
        sar_reg_w(K_FFT_UNLOADER, K_UNL_DET_CTRL, det_en ? 1u : 0u);
        sar_reg_w(K_FFT_UNLOADER, HLS_ARG0, d);
        sar_reg_w(K_FFT_UNLOADER, HLS_ARG1, SAR_ROW_BEATS);   /* INPUT beats, both modes */
        sar_k_start(K_FFT_UNLOADER);
        /* Arm the fused window for THIS row. Written unconditionally (0 when disabled) so the
         * enable can never persist from a previous pass into the azimuth FFT or a debug entry. */
        sar_reg_w(K_FFT_FEEDER, K_FFT_WIN_CTRL,
                  win_en ? ((1u << 16) | (uint16_t)hamr[row]) : 0u);
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
        if (det_en) {
            /* The unloader already took the magnitude, at the row's NATIVE exponent -- it cannot
             * do better, because emax is not known until every row is transformed. Magnitude is
             * linear in the operand scale, so shifting it here is algebraically the same global
             * renormalize; only the truncation point moves. Modelled in
             * mpfs/host/model_detect_fusion.py: never worse than the old order, <=2 LSB apart,
             * because CoreFFT's BFP exponent is nearly always 0. Half the data, no sqrt, no sign
             * handling -- this is what remains of the 20.6 s detect stage. */
            uint16_t *d = (uint16_t *)(uintptr_t)(dst + row * SAR_ROW_BYTES_U16);
            for (uint32_t i = 0; i < SAR_GRID; i++) d[i] = (uint16_t)(d[i] >> sh);
        } else {
            uint32_t *d = (uint32_t *)(uintptr_t)(dst + row * SAR_ROW_BYTES);
            for (uint32_t i = 0; i < SAR_GRID; i++) {
                uint32_t v = d[i];
                int32_t re = (int32_t)(int16_t)(v >> 16)     >> sh;
                int32_t im = (int32_t)(int16_t)(v & 0xFFFFu) >> sh;
                d[i] = (((uint32_t)(uint16_t)(int16_t)re) << 16) | (uint16_t)(int16_t)im;
            }
        }
        if ((row & 0x7Fu) == 0u) SAR_PROG(5u, row, SAR_GRID);
    }
    __asm volatile ("fence rw, rw");
    flush_l2_cache(1u);                       /* push renormalized dst to DDR for the next kernel */
    return 0;
}

/* ---- H4 CONCURRENCY MICRO-BENCHMARK (firmware-only; current bitstream) ------------------------
 * Measures whether two fabric masters overlap or SERIALIZE on the single shared FIC_0 write channel
 * -- the H4 hazard the architectural-critic flagged, unmeasurable in cosim, that gates BOTH the
 * corner-turn/FFT overlap (Step 2) AND priority-3 write-parallelism.
 *
 * The scenario mirrors Step 2 (CT#2 SCRATCH->SIG concurrent with FFT-2 SIG->OUT) minus the strip
 * handshake -- for TIMING only, so the FFT reads whatever SIG the CT is mid-writing (garbage output
 * is expected and irrelevant; the wall-clock is the measurement). Three timings to a JTAG-readable
 * record @0xB005E400:
 *   t_ct   = corner-turn alone (SCRATCH->SIG, ~6.2 s expected)
 *   t_fft  = one FFT pass alone (SIG->OUT, det, ~11 s expected)
 *   t_conc = CT armed free-running, THEN the FFT pass, THEN wait CT  (both active concurrently)
 * gain = t_ct + t_fft - t_conc.  gain ~= t_ct  => FULL overlap (H4 benign, build Step 2).
 *                                 gain ~= 0     => SERIALIZED     (H4 bites, FIC_1 is the fix).
 * A ficmon snapshot (slot 0) captures the READ-channel bus behaviour during the concurrent run. */
#define SAR_H4_REC_ADDR  0xB005E400u
int fft_h4_bench(uint32_t spins)
{
    volatile uint32_t *rec = (volatile uint32_t *)(uintptr_t)SAR_H4_REC_ADDR;
    for (int i = 0; i < 16; i++) rec[i] = 0u;
    rec[0] = 0x48344253u;                         /* 'H4B\0' magic */
    uint64_t t0, t1;

    /* 1) corner-turn ALONE: SCRATCH -> SIG */
    sar_reg_w(K_CORNER_TURN, HLS_ARG0, BUF_SCRATCH);
    sar_reg_w(K_CORNER_TURN, HLS_ARG1, BUF_SIG);
    t0 = readmtime();
    sar_k_start(K_CORNER_TURN);
    if (!sar_k_wait(K_CORNER_TURN, spins)) { rec[15] = 0xDEAD0001u; goto pub; }
    t1 = readmtime();
    rec[1] = (uint32_t)(t1 - t0);                 /* t_ct  (us) */

    /* 2) FFT pass ALONE: SIG -> OUT (det), decoupled src/dst (no in-place stall) */
    t0 = readmtime();
    (void)fft_fabric_pass(BUF_SIG, BUF_OUT, spins, 0, 1);
    t1 = readmtime();
    rec[2] = (uint32_t)(t1 - t0);                 /* t_fft (us) */

    /* 3) CONCURRENT: arm CT free-running, run the FFT pass while it writes SIG, then join CT. */
    sar_reg_w(K_CORNER_TURN, HLS_ARG0, BUF_SCRATCH);
    sar_reg_w(K_CORNER_TURN, HLS_ARG1, BUF_SIG);
    ficmon_clear();
    t0 = readmtime();
    sar_k_start(K_CORNER_TURN);                   /* CT free-runs on FIC_0 ... */
    (void)fft_fabric_pass(BUF_SIG, BUF_OUT, spins, 0, 1);  /* ... while the FFT hammers FIC_0 too */
    if (!sar_k_wait(K_CORNER_TURN, spins)) rec[15] = 0xDEAD0002u;   /* join CT (should be long done) */
    t1 = readmtime();
    ficmon_snapshot(0u, 9u, SAR_ROW_BEATS);       /* concurrent-run bus behaviour -> 0xB0059240 */
    rec[3] = (uint32_t)(t1 - t0);                 /* t_conc (us) */

    {
        int32_t gain = (int32_t)(rec[1] + rec[2]) - (int32_t)rec[3];
        rec[4] = (uint32_t)gain;                                   /* overlap_gain (us) */
        rec[5] = rec[1] ? (uint32_t)(((int64_t)gain * 100) / (int32_t)rec[1]) : 0u;  /* % of t_ct hidden */
    }
pub:
    __asm volatile ("fence rw, rw");
    flush_range_to_ddr(SAR_H4_REC_ADDR, 64u);
    return 0;
}

/* FUSED FFT-1 with per-row azimuth-resample GATHER (SAR_GATHERMODE=1). Mirrors fft_fabric_pass
 * exactly EXCEPT each row's feeder is armed in gather mode: the feeder reads M source samples from
 * `src` row j, gathers to Mp with this row's idx/wq, windows, and streams to CoreFFT -- so the
 * azimuth resample stage folds under the FFT feed. idx/wq are computed on the MSS per row
 * (sar_coeffs_pass2, double-buffered so row j+1's coeffs compute while row j streams) and published
 * to DDR for the feeder's read master. Detect is NEVER fused here (FFT-1 stays complex).
 *
 * NOT YET SILICON-VALIDATED: the board was unavailable (JTAG wedged) when this was written. Gated
 * off by default (SAR_GATHERMODE); the standalone azimuth resample path is unchanged. Validate by
 * A/B vs SAR_GATHERMODE=0 on the same scene before trusting -- the CRC gate does not apply (the
 * fused gather is bit-identical to gather-then-window, tb/tb_fft_feeder_gather.v, but the whole
 * pipeline CRC has already moved off 0xd596c9eb). */
static int fft1_gather_pass(const sar_geom_t *g, float *f32, uint32_t src, uint32_t dst,
                            uint32_t spins)
{
    uint32_t budget = spins ? spins : SAR_DEFAULT_SPINS;
    const int16_t *hamr = (const int16_t *)(uintptr_t)SAR_HAMR_ADDR;
    const uint32_t Mp = g->Mp, M = g->M;
    int b = 0;

    fft_win_load_taper();
    sar_coeffs_pass2(g, 0, f32, (int32_t *)(uintptr_t)SAR_COEF_IDX(0),
                                (int16_t *)(uintptr_t)SAR_COEF_WQ(0));

    for (uint32_t row = 0; row < SAR_GRID; row++) {
        uint32_t d = dst + row * SAR_ROW_BYTES;
        flush_coef_bank_to_ddr(b, M);                     /* publish this row's coeffs L2->DDR */
        sar_reg_w(K_FFT_UNLOADER, K_UNL_DET_CTRL, 0u);     /* FFT-1 never fuses detect */
        sar_reg_w(K_FFT_UNLOADER, HLS_ARG0, d);
        sar_reg_w(K_FFT_UNLOADER, HLS_ARG1, SAR_ROW_BEATS);
        sar_k_start(K_FFT_UNLOADER);
        /* Feeder in GATHER mode: source row, this row's idx/wq, dims (SRC_LEN=M, QN=Mp), window on.
         * One START sequences load(src,idx,wq) -> gather+window+stream. */
        sar_reg_w(K_FFT_FEEDER, K_FFT_IDX_BASE,    (uint32_t)SAR_COEF_IDX(b));
        sar_reg_w(K_FFT_FEEDER, K_FFT_WQ_BASE,     (uint32_t)SAR_COEF_WQ(b));
        sar_reg_w(K_FFT_FEEDER, K_FFT_GATHER_DIMS, (Mp << 16) | (M & 0xFFFFu));
        sar_reg_w(K_FFT_FEEDER, K_FFT_GATHER_CTRL, 1u);
        sar_reg_w(K_FFT_FEEDER, K_FFT_WIN_CTRL,    (1u << 16) | (uint16_t)hamr[row]);
        sar_reg_w(K_FFT_FEEDER, HLS_ARG0,          src + row * Mp * 4u);   /* source row (Mp-wide, M valid) */
        sar_k_start(K_FFT_FEEDER);
        if (row + 1u < SAR_GRID)                          /* overlap: next row's coeffs under the feed */
            sar_coeffs_pass2(g, row + 1u, f32, (int32_t *)(uintptr_t)SAR_COEF_IDX(b ^ 1),
                                               (int16_t *)(uintptr_t)SAR_COEF_WQ(b ^ 1));
        uint32_t n = budget;
        while (n) { if (sar_k_idle(K_FFT_FEEDER) && sar_k_idle(K_FFT_UNLOADER)) break; n--; }
        if (n == 0u) return sar_k_idle(K_FFT_FEEDER) ? 1 : 2;
        sar_row_exp[row] = (uint8_t)(sar_reg_r(K_FFT_FEEDER, K_FFT_SCALE_EXP) & 0xFu);
        if ((row & 0x7Fu) == 0u) SAR_PROG(4u, row, SAR_GRID);
        b ^= 1;
    }
    sar_reg_w(K_FFT_FEEDER, K_FFT_GATHER_CTRL, 0u);        /* clear so a later plain FFT is unaffected */

    /* global block exponent + renormalize -- identical to fft_fabric_pass PASS 2 (complex, det=0) */
    uint8_t emax = 0;
    for (uint32_t row = 0; row < SAR_GRID; row++)
        if (sar_row_exp[row] > emax) emax = sar_row_exp[row];
    uint32_t headroom = *(volatile uint32_t *)(uintptr_t)SAR_FFT_HEADROOM_ADDR;
    if (headroom > 12u) headroom = 0u;
    __asm volatile ("fence rw, rw");
    flush_l2_cache(1u);
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
    flush_l2_cache(1u);
    return 0;
}

/* One FFT pass over the whole frame: transform all SAR_GRID rows of `src` (each an 8192-pt
 * row FFT) into `dst`. Mode 0 = CPU sar_cpu_fft (HLS K_FFT butterfly was broken on silicon;
 * see m3 memory). Mode 1 = the now-working fabric CoreFFT chain. Returns 0 = OK. */
/* `win_en` applies the fused 2-D Hamming window on the way into the FFT (range pass only --
 * the azimuth pass must NOT re-window). Mode 0 does not go through the feeder, so it applies
 * the same taper on the CPU first, keeping the fallback path correct. */
static int fft_pass(uint32_t src, uint32_t dst, uint32_t spins, int win_en, int det_en)
{
    /* FIC0 non-coherent: flush so `src` is in DDR (not stale L2) before the FFT, then flush
     * so `dst` reaches DDR for the next fabric kernel's FIC0 read. */
    flush_l2_cache(1u);
    __asm volatile ("fence rw, rw");
    int rc;
    if (*(volatile uint32_t *)(uintptr_t)SAR_FFTMODE_ADDR == 1u) {
        rc = fft_fabric_pass(src, dst, spins, win_en, det_en);
    } else {
        if (win_en) {
            fft_win_cpu(src, SAR_GRID);           /* in place, before the CPU transform */
            __asm volatile ("fence rw, rw");
        }
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

    sar_resample_ts[0] = readmtime();
    /* Build the line-invariant pass-2 reciprocals once for this scene (see
     * sar_resample_coeffs.c): 1/(tan_s[k+1]-tan_s[k]) does not depend on the line, so pass 2
     * needs only a single 1/KR[j] per line instead of M-1 divides. */
    sar_coeffs_init(g);
    /* PASS 1 (range) */
    sar_coeffs_pass1(g, 0, f32, (int32_t *)(uintptr_t)SAR_COEF_IDX(0),
                                (int16_t *)(uintptr_t)SAR_COEF_WQ(0));
    for (int k = 0; k < 14; k++) RPROF[k] = 0;          /* profile accumulators */
    /* KERNEL-ONLY PROBE. The main loop overlaps coefficient generation with the kernel, so
     * `wait` only proves the kernel finished FIRST -- it does not reveal how long the kernel
     * actually takes. Re-arm line 0 (coeffs already computed and flushed above) with nothing
     * else in the loop, so the measured time IS the gather kernel. This decides whether fusing
     * coefficient generation into the kernel could reach the projected ~200 us/line, or whether
     * the gather itself is already slower than that. Repeats the same line: harmless, the
     * output is overwritten by the real pass below. */
    /* OFF by default: the probe re-runs line 0 and so inflates the stage total, which would
     * silently corrupt any performance baseline taken from this build. Enable over JTAG by
     * writing the iteration count to SAR_RPROF_PROBE_ADDR before PIPE. */
    const uint32_t PROBE = *(volatile uint32_t *)(uintptr_t)SAR_RPROF_PROBE_ADDR;
    if (PROBE != 0u && PROBE <= 4096u) {
        sar_reg_w(K_RESAMPLE, HLS_ARG0, BUF_SIG + 0u);
        sar_reg_w(K_RESAMPLE, HLS_ARG1, (uint32_t)SAR_COEF_IDX(0));
        sar_reg_w(K_RESAMPLE, HLS_ARG2, (uint32_t)SAR_COEF_WQ(0));
        sar_reg_w(K_RESAMPLE, HLS_ARG3, BUF_SCRATCH + (uint32_t)invord[0] * Np * 4u);
        flush_coef_bank_to_ddr(0, Np);
        uint64_t t0 = readmtime();
        for (uint32_t p = 0; p < PROBE; p++) {
            sar_k_start(K_RESAMPLE);
            if (!sar_k_wait(K_RESAMPLE, spins)) return 0;
        }
        RPROF[12] = readmtime() - t0;
        RPROF[13] = PROBE;
    }
    for (uint32_t i = 0; i < g->M; i++) {
        SAR_PROG(1u, i, g->M);
        { RP_T0(t);
          sar_reg_w(K_RESAMPLE, HLS_ARG0, BUF_SIG + i * g->N * 4u);          /* in  (N-wide) */
          sar_reg_w(K_RESAMPLE, HLS_ARG1, (uint32_t)SAR_COEF_IDX(b));
          sar_reg_w(K_RESAMPLE, HLS_ARG2, (uint32_t)SAR_COEF_WQ(b));
          sar_reg_w(K_RESAMPLE, HLS_ARG3, BUF_SCRATCH + (uint32_t)invord[i] * Np * 4u);
          RP_ACC(0, t); }
        /* FIC0 non-coherent: the idx/wq coeffs just computed by the MSS (bank b) live in
         * L2, not DDR. Publish just that bank before the kernel reads it via FIC0, else
         * it gathers with stale coeffs. */
        { RP_T0(t); flush_coef_bank_to_ddr(b, Np); RP_ACC(1, t); }
        if (i == 0u) ficmon_clear();             /* capture FIC_0 behaviour of range gather line 0 */
        sar_k_start(K_RESAMPLE);
        if (i + 1u < g->M) {
            RP_T0(t);
            sar_coeffs_pass1(g, i + 1u, f32, (int32_t *)(uintptr_t)SAR_COEF_IDX(b ^ 1),
                                             (int16_t *)(uintptr_t)SAR_COEF_WQ(b ^ 1));
            RP_ACC(2, t);
        }
        { RP_T0(t);
          if (!sar_k_wait(K_RESAMPLE, spins)) return 0;
          RP_ACC(3, t); }
        if (i == 0u) ficmon_snapshot(0u, 1u, Np / 2u);   /* Np samples, 2/beat */
        RPROF[4]++;
        b ^= 1;
    }
    RPROF[5] = readmtime() - sar_resample_ts[0];
    /* zero padded pulse rows (M..Mp-1) for clean FFT zero-padding (CPU clear; a
     * candidate for a fabric memset if this dominates runtime) */
    {
        volatile uint64_t *z = (volatile uint64_t *)(uintptr_t)(BUF_SCRATCH + g->M * Np * 4u);
        uint64_t words = ((uint64_t)(Mp - g->M) * Np) / 2u;   /* 2 complex int16 / 64-bit */
        for (uint64_t w = 0; w < words; w++) z[w] = 0u;
    }
    /* These are CACHED CPU writes and the corner-turn below reads DDR over the
     * non-coherent FIC0, so they must be published. The region is ~84 MB against a
     * 2 MiB L2, so most lines write-back-evict naturally as the loop advances -- but
     * the final ~2 MiB (the highest pad rows) stays dirty and the corner-turn would
     * read whatever DDR held before, i.e. the previous run's data, NOT zeros. That
     * injects non-zero content into what the FFT expects to be zero-padding.
     * Whole-L2 (not a targeted range) is deliberate: at 64 B/line a targeted flush of
     * 84 MB would be ~1.3 M FLUSH64 stores, far worse than one way-walk. This runs
     * once per pipeline, not per line. */
    flush_l2_cache(1u);
    sar_resample_ts[1] = readmtime();          /* range gather + pad-zero + publish done */

    /* transpose SCRATCH(Mp x Np) -> SIG(Np x Mp) */
    sar_reg_w(K_CORNER_TURN, HLS_ARG0, BUF_SCRATCH);
    sar_reg_w(K_CORNER_TURN, HLS_ARG1, BUF_SIG);
    sar_k_start(K_CORNER_TURN);
    if (!sar_k_wait(K_CORNER_TURN, spins)) return 0;
    sar_resample_ts[2] = readmtime();          /* internal corner-turn done */

    /* FUSED azimuth gather (SAR_GATHERMODE=1): stop here. SIG now holds the corner-turned,
     * range-gathered data -- exactly the input the azimuth gather reads. The gather + azimuth
     * resample happen inside the FFT-1 feeder (fft1_gather_pass), so pass 2 is not run here. */
    if (*(volatile uint32_t *)(uintptr_t)SAR_GATHERMODE_ADDR == 1u) {
        sar_resample_ts[3] = readmtime();
        return 1;
    }

    /* PASS 2 (azimuth) */
    sar_coeffs_pass2(g, 0, f32, (int32_t *)(uintptr_t)SAR_COEF_IDX(0),
                                (int16_t *)(uintptr_t)SAR_COEF_WQ(0));
    b = 0;
    for (uint32_t j = 0; j < Np; j++) {
        SAR_PROG(2u, j, Np);
        { RP_T0(t);
          sar_reg_w(K_RESAMPLE, HLS_ARG0, BUF_SIG     + j * Mp * 4u); /* in  (Mp-wide, M valid) */
          sar_reg_w(K_RESAMPLE, HLS_ARG1, (uint32_t)SAR_COEF_IDX(b));
          sar_reg_w(K_RESAMPLE, HLS_ARG2, (uint32_t)SAR_COEF_WQ(b));
          sar_reg_w(K_RESAMPLE, HLS_ARG3, BUF_SCRATCH + j * Mp * 4u); /* out (Mp-wide) */
          RP_ACC(6, t); }
        { RP_T0(t); flush_coef_bank_to_ddr(b, Mp); RP_ACC(7, t); }    /* publish coeffs L2 -> DDR */
        if (j == 0u) ficmon_clear();             /* capture FIC_0 behaviour of azimuth gather line 0 */
        sar_k_start(K_RESAMPLE);
        if (j + 1u < Np) {
            RP_T0(t);
            sar_coeffs_pass2(g, j + 1u, f32, (int32_t *)(uintptr_t)SAR_COEF_IDX(b ^ 1),
                                             (int16_t *)(uintptr_t)SAR_COEF_WQ(b ^ 1));
            RP_ACC(8, t);
        }
        { RP_T0(t);
          if (!sar_k_wait(K_RESAMPLE, spins)) return 0;
          RP_ACC(9, t); }
        if (j == 0u) ficmon_snapshot(1u, 2u, Mp / 2u);   /* Mp samples, 2/beat */
        RPROF[10]++;
        b ^= 1;
    }
    RPROF[11] = readmtime() - sar_resample_ts[2];
    __asm volatile ("fence rw, rw");
    flush_range_to_ddr(SAR_RPROF_ADDR, 112u);     /* publish so a JTAG physical read sees it */
    sar_resample_ts[3] = readmtime();          /* azimuth gather done */
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
    /* Clear the fused window explicitly. A range pass that returned early (spin-budget
     * timeout) leaves win_en=1 and win_scale=hamr[last row], which would stream the whole
     * frame tapered by one near-zero scalar -- misleading telemetry in exactly the
     * SmartDebug session this entry point exists to serve. */
    sar_reg_w(K_FFT_FEEDER, K_FFT_WIN_CTRL, 0u);
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
    return fft_pass(BUF_SIG, BUF_SCRATCH, 0x00200000u, 0, 0);   /* streaming-path test: no window */
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
    /* SCALE_EXP isolation test: window OFF, or the taper would scale the two DC rows and
     * destroy the 16:1 ratio this test exists to measure. */
    return fft_pass(BUF_SIG, BUF_SCRATCH, 0x00200000u, 0, 0);    /* fabric path when mode=1 */
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

    /* 2) window: FUSED into the range-FFT feeder (step 3), so there is no longer a standalone
     *    pass here. It was a full-frame SCRATCH->SCRATCH element-wise multiply -- 512 MB read +
     *    512 MB written, 6.0 s -- on data the feeder already streams. The taper is now applied
     *    in fft_feeder_v.v, bit-identically (tb/tb_fft_feeder_win.v). The K_WINDOW kernel is
     *    still instantiated in the fabric but is no longer armed.
     *    The timestamp slot is kept (readers index it) and now reads as ~0. */
    sar_stage_ts[2] = readmtime();

    /* 3) range FFT: SCRATCH -> SIG (DECOUPLED src/dst -- an in-place FFT feeding-and-
     *    draining the SAME DDR page stalls at transform 1 on silicon: the DMA is still
     *    flushing transform t's output while the feeder pulls transform t+1's input over
     *    the shared interconnect, so CoreFFT drops BUF_READY and the pipeline locks up.
     *    SIG is free after resample, so ping-pong SCRATCH<->SIG keeps read/write on
     *    separate 256 MB pages. VALIDATED on silicon: decoupled fft_pass streams past
     *    transform 1 (in-place stalled at idx=1). */
    /* GATHER-FUSED (SAR_GATHERMODE=1): the azimuth resample gather is folded into THIS FFT feed.
     * resample_2pass stopped after the internal corner-turn, so SIG holds the gather INPUT. FFT-1
     * gathers from SIG and writes SCRATCH (decoupled, same in-place-stall avoidance). This FLIPS
     * the downstream buffers: corner-turn SCRATCH->SIG, FFT-2 SIG->... (below). SCRATCH is free
     * here because pass 2 no longer wrote it. */
    const int gather_fused = (*(volatile uint32_t *)(uintptr_t)SAR_GATHERMODE_ADDR == 1u);
    float *f32g = (float *)(uintptr_t)SAR_COEF_LINE_F32;
    if (gather_fused) {
        int r = fft1_gather_pass(&g, f32g, BUF_SIG, BUF_SCRATCH, spins);  /* gather from SIG -> SCRATCH */
        if (r == 1) return SAR_SEQ_TIMEOUT_FFT1;
        if (r == 2) return SAR_SEQ_TIMEOUT_DMA;
    } else {
        int r = fft_pass(BUF_SCRATCH, BUF_SIG, spins, 1, 0);  /* window FUSED into this pass */
        if (r == 1) return SAR_SEQ_TIMEOUT_FFT1;          /* feeder stalled */
        if (r == 2) return SAR_SEQ_TIMEOUT_DMA;            /* DMA S2MM stalled (range) */
    }
    sar_stage_ts[3] = readmtime();

    /* 4) corner-turn (transpose). Non-fused: SIG->SCRATCH (FFT-1 out is in SIG).
     *    Fused: SCRATCH->SIG (FFT-1 out is in SCRATCH). */
    sar_reg_w(K_CORNER_TURN, HLS_ARG0, gather_fused ? BUF_SCRATCH : BUF_SIG);
    sar_reg_w(K_CORNER_TURN, HLS_ARG1, gather_fused ? BUF_SIG     : BUF_SCRATCH);
    sar_k_start(K_CORNER_TURN);
    if (!sar_k_wait(K_CORNER_TURN, spins)) return SAR_SEQ_TIMEOUT_CORNER;
    sar_stage_ts[4] = readmtime();

    /* 5) azimuth FFT (the true RANGE-axis FFT). Non-fused: SCRATCH->{OUT|SIG}. Fused: SIG->{OUT|SIG}
     *    -- corner-turn wrote SIG, so FFT-2 reads SIG.
     * FUSED DETECT (runtime, DETECTMODE 3): the unloader takes |z| as this FFT streams out, so it
     * writes uint16 magnitudes DIRECTLY to OUT and step 6 disappears. */
    const int det_fused = (*(volatile uint32_t *)(uintptr_t)SAR_DETECTMODE_ADDR == 3u);
    const uint32_t f2_src = gather_fused ? BUF_SIG : BUF_SCRATCH;
    const uint32_t f2_dst = det_fused ? BUF_OUT : (gather_fused ? BUF_SCRATCH : BUF_SIG);
    { int r = fft_pass(f2_src, f2_dst, spins, 0, det_fused);
      if (r == 1) return SAR_SEQ_TIMEOUT_FFT2;          /* feeder stalled */
      if (r == 2) return SAR_SEQ_TIMEOUT_DMA; }          /* DMA S2MM stalled (azimuth) */
    sar_stage_ts[5] = readmtime();

    /* 6) detect (sqrt(I^2+Q^2)): SIG -> OUT (azimuth-FFT output is in SIG).
     * DEFAULT = CPU detect (correct sqrt, corr 0.97 on silicon -- the SHIPPING path). The fabric
     * detect HLS is UNFIXABLE via SmartHLS (it mis-synthesizes the negative-I sign extension no
     * matter how detect.cpp is written -> ~50% saturation); DETECTMODE 2 selects it for testing only. */
    if (det_fused) {
        /* nothing to do: the unloader produced OUT during step 5, and the uint16 renormalize
         * inside fft_fabric_pass already applied the global block exponent. */
    } else if (*(volatile uint32_t *)(uintptr_t)SAR_DETECTMODE_ADDR != 2u) {
        /* Read the ACTUAL FFT-2 output buffer (f2_dst): SIG in the non-fused path, SCRATCH when
         * the gather fusion flipped the buffers. */
        flush_l2_cache(1u);                                  /* read fabric-written FFT-2 out from DDR */
        cpu_detect(f2_dst, BUF_OUT, SAR_GRID * SAR_GRID);
        flush_l2_cache(1u);                                  /* push OUT to DDR for JTAG readback */
    } else {
        sar_reg_w(K_DETECT, HLS_ARG0, f2_dst);
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
