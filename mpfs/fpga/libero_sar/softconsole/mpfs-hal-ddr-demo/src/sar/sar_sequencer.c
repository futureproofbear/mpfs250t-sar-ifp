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
#include "sar_coeff_workers.h"    /* spread coefficient generation over the idle U54 harts */
#include "sar_resample_v.h"       /* pass-1 gather with coefficient generation fused into fabric */
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
#define BUF_WORK     ((uint32_t)SAR_WORK_ADDR)

/* PRESERVE SIG. The pipeline used to ping-pong SIG<->SCRATCH:
 *     SIG->SCRATCH (gather), SCRATCH->SIG (CT#1), SIG->SCRATCH (FFT-1),
 *     SCRATCH->SIG (CT#2), SIG->OUT (FFT-2)
 * so both corner-turns wrote SIG -- the pipeline's OWN INPUT. A second PIPE without re-running
 * ELOD therefore processed the previous run's intermediate data and returned a wrong,
 * run-dependent CRC. That is not corruption and not a dual-chain fault, but it burned a whole
 * session before it was understood (see the SAR_DUALFFT note below).
 *
 * With WORK (0xC000_0000, non-cached, silicon-verified disjoint -- see ddr_sar_layout.h) the
 * rotation becomes SIG->SCRATCH->WORK->SCRATCH->WORK->OUT and SIG IS READ-ONLY AFTER LOAD, so a
 * scene can be re-run indefinitely from one ELOD. Every buffer keeps its role and size; only the
 * two corner-turn destinations and the two reads that follow them move.
 *
 * Knob-gated so the change is A/B-able in ONE binary: only the exact magic switches it, and a
 * cold-boot DDR word means the ORIGINAL ping-pong. Same discipline as every other knob here. */
#define SAR_WORKBUF_ADDR   0xB0059144u
#define SAR_WORKBUF_ENABLE 0x574B4231u        /* 'WKB1' -- the ONLY accepted value */
static inline int sar_workbuf_en(void)
{
    /* RE-ENABLED 2026-07-26 alongside the DIC target widening (axiic_c0_params_330.tcl
     * TARGET0_END_ADDR 0xbfffffff -> 0xffffffff). History of why it was off:
     * The DIC's DDR target window is 0x8000_0000..0xBFFF_FFFF (axiic_c0_params_330.tcl:1360,1363),
     * so 0xC000_0000 is ONE BYTE past the end of the fabric's address decode. Enabling this made
     * CT#1 write into nothing and RESAMPLE timed out on silicon (PIPE result=2).
     * The silicon alias test that motivated this answered the WRONG QUESTION: it proved the CPU
     * can reach 0xC000_0000, which was never in doubt. The fabric reaches DDR only through FIC_0
     * and this interconnect window.
     * To revive: the buffer must live INSIDE 0x8000_0000..0xBFFF_FFFF, and that region is already
     * full (SIG+SCRATCH+OUT+code = 768 MB exactly), so it needs the DIC target window widened AND
     * a cached-region reshuffle -- not just a knob. */
    /* DEAD -- DO NOT RE-ENABLE WITHOUT READING THIS.
     * The fabric and the CPU DISAGREE about what 0xC000_0000 means. hw_ddr_segs.h SEG1_2 maps the
     * CPU's non-cached window there onto physical DRAM offset 1792 MB, disjoint from the cached
     * region -- but that translation belongs to MSS masters and is NOT applied to FIC_0 traffic.
     * Proven on silicon 2026-07-26, third and final attempt: with the DIC window widened so the
     * address is reachable, a run COMPLETED (24.65 s, no timeout) but produced 0xc9fa44cf, and
     * SIG's CRC moved 0x89fa12dc -> 0x191733a0 even though BOTH corner-turns had been re-targeted
     * away from SIG. The fabric's WORK writes aliased straight back into the cached region.
     * A third frame buffer must therefore live INSIDE 0x8000_0000..0xBFFF_FFFF, where fabric and
     * CPU agree -- and that region is exactly full (SIG+SCRATCH+OUT+code = 768 MB). So this needs
     * a DDR re-layout, not an address. */
    return 0 && (*(volatile uint32_t *)(uintptr_t)SAR_WORKBUF_ADDR == SAR_WORKBUF_ENABLE);
}
/* The buffer the corner-turns write and the next stage reads: WORK when enabled, else SIG. */
static inline uint32_t sar_ctdst(void) { return sar_workbuf_en() ? BUF_WORK : BUF_SIG; }

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
 *         [6..9] pass2 same,                  [10] lines, [11] pass2 total.  All MTIME us.
 *
 * 2026-07-25 -- IPC INSTRUMENTATION.
 * [2] = coefficient generation AND its DDR publish. Splitting the flush into [1] was ATTEMPTED and
 * did not survive the multi-hart change: the publish moved inside sar_cwrk_line() (as
 * cwrk_flush_slice, since each hart must publish its own slice), so it is timed under [2] again
 * and **[1] reads 0** -- confirmed on silicon 2026-07-25. RPROF[14]/[15] likewise include the
 * FLUSH64 walk. To get the split back, time cwrk_flush_slice() separately inside the worker module.
 *
 * [14]/[15] = minstret/mcycle accumulated over sar_coeffs_pass1() ONLY. These decide WHY the
 * coefficient loop costs ~62.8 cycles/output for a ~20-instruction body:
 *     IPC = [14]/[15] ~= 1     -> arithmetic/issue-bound. Fewer ops (algorithmic rewrite) helps.
 *     IPC = [14]/[15] << 1     -> STALL-bound (the cache-miss model: ~0.16 misses/output on the
 *                                 KR read + idx/wq write-allocate, no HW prefetcher). Then fewer
 *                                 ops do NOT help and the lever is parallelism (more harts) or
 *                                 fewer BYTES, not fewer instructions.
 * instructions/output = [14] / (([4]-2) * Np)   (the -2 is the prologue lines computed outside
 * the loop; [4] counts kernel lines, which equals coeff lines to within that offset). */
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
#define FICMON_RECW            20u          /* words per record (v2: 12 v1 + 7 v2 + spare) */
#define FICMON_REC(slot)  ((volatile uint32_t *)(uintptr_t)(SAR_FICMON_ADDR + (slot) * FICMON_RECW * 4u))

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
    /* v2: write channel + intra-burst read-throttle */
    r[11] = sar_reg_r(K_FIC0MON, FICMON_AW_COUNT);
    r[12] = sar_reg_r(K_FIC0MON, FICMON_W_COUNT);
    r[13] = sar_reg_r(K_FIC0MON, FICMON_B_STATUS);
    r[14] = sar_reg_r(K_FIC0MON, FICMON_WRITE_BUSY);
    r[15] = sar_reg_r(K_FIC0MON, FICMON_R_DATAWAIT);
    r[16] = sar_reg_r(K_FIC0MON, FICMON_MAX_R_DATAWAIT);
    r[17] = sar_reg_r(K_FIC0MON, FICMON_TOTAL_ACTIVE);
    r[18] = 0u; r[19] = 0u;
    __asm volatile ("fence rw, rw");
    flush_range_to_ddr(SAR_FICMON_ADDR + slot * FICMON_RECW * 4u, FICMON_RECW * 4u); /* publish for JTAG read */
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
#define K_FFT_GATHER_CTRL 0x20u              /* [0] = gather enable, [1] = coefficients from the fabric stream */
#define K_FFT_GC_GATHER   0x1u
#define K_FFT_GC_CSTREAM  0x2u               /* 0 = idx/wq from DDR (default), 1 = from sar_coeffgen */
#define K_FFT_GC_SINC     0x4u               /* 0 = 2-tap lerp (default), 1 = 32-tap polyphase sinc */
#define K_FFT_GC_SCTRWND  0x8u               /* one-shot: rewind the sinc table write pointer */
#define K_FFT_SINC_TAB    0x30u              /* one Q15 tap per write, pointer auto-increments */

/* ---- AZIMUTH 32-TAP SINC (fft_feeder_v GATHER_CTRL[2]) -------------------------------------
 * The pass-2 twin of the range sinc. Legal here despite tau = tan(phi) being NON-uniform: measured
 * on the real Umbra NDSU CPHD (mpfs/host/check_pass2_sinc_uniformity.py), tau's spacing varies by
 * max/min = 1.00045 within any 32-tap window, so the kernel's equal-spacing assumption holds
 * locally and reconstruction matches a uniform-grid control to within a dB.
 *
 * FAIL-SAFE ENCODING, same discipline as SAR_CGENMODE: this word is uninitialised DDR on a cold
 * boot, so accept ONLY the exact magic. Anything else means OFF and the 2-tap lerp runs unchanged.
 *
 * The 16 KB table lives in FABRIC RAM, one copy PER CHAIN, and does not survive a fabric reprogram
 * or a power-cycle -- so it is pushed per power cycle, before the first armed row, and pushed to
 * BOTH chains. An unloaded table is all zeros: every phase would weight the same tap and the image
 * would be wrong in a way that looks like an interpolation bug rather than a missing load. */
#define SAR_AZSINCMODE_ADDR 0xB0059168u      /* free: 0x164 = SAR_SINCMODE (range sinc) */
#define SAR_AZSINC_ENABLE   0x41534E31u      /* 'ASN1' -- the ONLY accepted value */
/* 16 KB, host-staged, phase-major. MUST live clear of the 0xB0059xxx knob/telemetry block: the
 * first choice, 0xB0059200, SPANNED 0xB0059200..0xB005D1FF and swallowed SAR_FICMON (0x9240),
 * SAR_CWRK (0x9300), SAR_EMMC_RESULT (0xA000) and SAR_EMMC_PROV_RESULT (0xD000). FICMON and CWRK
 * are written DURING a run, so the first PIPE after a load was clean and every later one re-read a
 * partly-overwritten table; the eMMC overlap would have corrupted provisioning records outright.
 * 0xB006_0000 is unused all the way to GEOM_BASE at 0xB010_0000. */
#define SAR_AZSINC_TAB_ADDR 0xB0060000u
/* Range sinc table, same deal, 16 KB clear of the azimuth one. */
#define SAR_SINC_TAB_ADDR   0xB0064000u

static int sar_azsinc_enabled(void)
{
    return *(volatile uint32_t *)(uintptr_t)SAR_AZSINCMODE_ADDR == SAR_AZSINC_ENABLE;
}

/* Push the 256x32 Q15 sinc table into ONE chain's feeder. Rewinds first so a re-push cannot append
 * to a stale pointer. `tab` is phase-major, 8192 int16 -- the order the core's ct_we pointer
 * expects; it is staged in DDR by the host because it does not fit the L2 scratchpad image. */
/* Push the RANGE 32-tap table into sar_resample_v, from a host-staged DDR blob.
 *
 * WHY: the host loader had to issue 8192 separate AXI4-Lite writes over JTAG -- one gdb round trip
 * each, ~15 MINUTES at the 6 MHz clock ceiling, and repeated every power cycle. The payload is only
 * 16 KB; at 6 MHz that is ~22 ms of actual bits, so >99% of that wall clock was per-transaction
 * latency, not data. Doing the same 8192 writes from the U54 costs microseconds because they never
 * leave the die. Exactly the trick the azimuth table already used; the asymmetry was historical.
 *
 * Protocol per sar_resample_v.h:84-86 and gen_sinc_table_gdb.py: TAB_CTRL select is SPLIT --
 * {bit3, bits[1:0]} picks the table and bit2 rewinds the SHARED write pointer -- so table 4 (SINC)
 * with a rewind is 0x8 | 0x4 = 0xc. Then one 16-bit tap per TAB_DATA write, pointer auto-incrementing.
 * Reading TAB_DATA back returns the pointer, which must have wrapped to 0 after exactly 8192 writes:
 * that is the cheap proof every write landed rather than a prefix. */
static int sar_sinc_load_range(const int16_t *tab)
{
    sar_reg_w(K_RESAMPLE, RSV_TAB_CTRL, 0xcu);            /* select SINC table + rewind pointer */
    for (uint32_t i = 0; i < 256u * 32u; i++)
        sar_reg_w(K_RESAMPLE, RSV_TAB_DATA, (uint32_t)(uint16_t)tab[i]);
    return (int)(sar_reg_r(K_RESAMPLE, RSV_TAB_DATA) & 0x3FFFu);   /* 0 == wrapped == all landed */
}


static void sar_azsinc_load(uint32_t feed, const int16_t *tab)
{
    sar_reg_w(feed, K_FFT_GATHER_CTRL, K_FFT_GC_SCTRWND);
    for (uint32_t i = 0; i < 256u * 32u; i++)
        sar_reg_w(feed, K_FFT_SINC_TAB, (uint32_t)(uint16_t)tab[i]);
    sar_reg_w(feed, K_FFT_GATHER_CTRL, 0u);
}
#define K_FFT_IDX_BASE    0x24u              /* DDR byte addr of this row's idx[] */
#define K_FFT_WQ_BASE     0x28u              /* DDR byte addr of this row's wq[] */
#define K_FFT_GATHER_DIMS 0x2cu              /* [15:0]=SRC_LEN (source samples), [31:16]=QN (outputs) */
#define SAR_GATHERMODE_ADDR 0xB005911Cu      /* 0=standalone azimuth resample (default); 1=fused into FFT-1 */

/* ---- ON-FABRIC azimuth coefficients (sar_coeffgen.v -> feeder stream) ---------------------
 * Silicon 2026-07-25 decomposes FFT-1 (11.46 s of a 32.97 s frame) as RPROF[6] coefficient
 * generation 4.170 s + [7] arm 0.011 s + [8] renormalize epilogue 2.933 s + [9] residual fabric
 * wait 4.344 s = 99.95% of the stage. The fabric generator runs a row in ~147 us against 1499 us
 * single-hart on the CPU, and streaming its output straight into the feeder ALSO deletes the
 * idx+wq DDR load passes (6144 of 8961 read beats/row) and the per-row coefficient-bank L2 flush.
 *
 * FAIL-SAFE ENCODING, same discipline as SAR_CWRK_NW_ADDR: this word is uninitialised DDR on a
 * cold boot, so accept ONLY the exact magic. Anything else -- 0, 1, 0xdeadbeef -- means OFF and
 * the DDR coefficient path runs unchanged. A "non-zero = on" test would enable an unvalidated
 * datapath on random DDR content. The fabric bit is likewise 0 out of reset, so a bitstream with
 * the generator present but this knob unset behaves exactly as today. */
#define SAR_CGENMODE_ADDR 0xB0059138u        /* free: 0x134 = SAR_CWRK_NW, 0x180 = RPROF */
#define SAR_CGEN_ENABLE   0x43474E31u        /* 'CGN1' -- the ONLY accepted value */

/* ---- SECOND CoreFFT CHAIN: rows split within a pass ---------------------------------------
 * The two PASSES cannot overlap (FFT-2 consumes the corner-turn of FFT-1's output), so the only
 * available parallelism is splitting ROWS within a pass -- and rows ARE independent: each is its
 * own 8192-pt transform with its own block-floating-point exponent, reading a disjoint source row
 * and writing a disjoint 32 KiB destination row. Chain A takes the even rows (dst + 2k*32768),
 * chain B the odd ones (dst + (2k+1)*32768). Source is read-only. No aliasing.
 *
 * Legal ONLY as a ROW split: the FFT here is a row transform and the corner-turn is the pipeline's
 * only legal transpose point, so a column split would be wrong.
 *
 * The BFP contract survives untouched: emax = max over all 8192 sar_row_exp[], then each row is
 * shifted by (emax - exp_row). A max is order- and partition-independent, so the two-chain result
 * is BIT-EXACT to the one-chain result -- provided each chain latches its OWN row's exponent from
 * its OWN CoreFFT (fft_feeder_v.v:149-155 latches SCALE_EXP on OUTP_READY's falling edge and holds
 * it only until that chain's next frame). Two rules follow and are enforced below:
 *   (a) a chain's exponent MUST be read before THAT chain is re-armed. The loops therefore JOIN
 *       both chains and read both exponents before arming the next pair -- deliberately NOT
 *       software-pipelined. A re-arm-to-keep-the-fabric-busy loop would stamp row j+2's exponent
 *       onto row j, and the result is a smooth, plausible, wrong-brightness image.
 *   (b) feeder, unloader and coefficient generator must all belong to the same chain. They are
 *       bundled in sar_chain_t and every arm site takes a `const sar_chain_t *`, so a chain can
 *       only be mismatched by editing this table.
 *
 * Sizing (silicon, one FFT-1 row, coefficient generator on): READ_BUSY 2,862 + R_DATAWAIT 3,762
 * of ELAPSED 88,231 cycles = 7.5% FIC_0 read-channel occupancy, 45 AR bursts averaging 182 beats.
 * Two chains need ~15% of the single SASD read slot. CoreFFT itself is 69,790 cycles/row
 * (8192 load + 13x4106 compute + 8192 unload + ~25) = 698 us at 100 MHz, and that is the floor
 * the second chain halves. */
/* SECOND CoreFFT CHAIN. Silicon 2026-07-26: 31.11 s -> 24.84 s with the renormalize epilogue
 * on, output CRC 0x319037b2 UNCHANGED (three consecutive clean runs, blk = 64).
 *
 * !! ONE ELOD PER PIPELINE RUN !!  The internal corner-turn transposes SCRATCH -> SIG (see
 * resample_2pass below), so a run OVERWRITES ITS OWN INPUT. A second PIPE without reloading the
 * scene reads the previous run's intermediate data and produces a wrong, run-dependent CRC.
 * That is NOT corruption and NOT a dual-chain fault -- single chain does exactly the same. An
 * earlier revision of this comment blamed the second chain for "poisoning DDR past ELOD"; that
 * was wrong, and it sent a whole debugging session chasing AXI id mis-delivery and marginal
 * timing. Reload, then run. */
#define SAR_DUALFFT_ADDR   0xB005913Cu       /* free: 0x134 = SAR_CWRK_NW, 0x138 = SAR_CGENMODE */
#define SAR_DUALFFT_ENABLE 0x44464632u       /* 'DFF2' -- the ONLY accepted value */

typedef struct { uint32_t feed, unld, cgen; } sar_chain_t;
static const sar_chain_t SAR_CHAIN[2] = {
    { K_FFT_FEEDER,   K_FFT_UNLOADER,   K_COEFFGEN   },   /* FEED  / UNLD  / COEFG   */
    { K_FFT_FEEDER_B, K_FFT_UNLOADER_B, K_COEFFGEN_B },   /* FEED_B/ UNLD_B/ COEFG_B */
};

/* FAIL-SAFE, same discipline as SAR_CGENMODE / SAR_CWRK_NW: this word is uninitialised DDR on a
 * cold boot, so accept ONLY the exact magic. 0, 1 and 0xdeadbeef all mean ONE chain. Default OFF
 * makes the bitstream behaviour-neutral until deliberately switched, so the A/B is same-bitstream. */
static inline uint32_t sar_nchains(void)
{
    return (*(volatile uint32_t *)(uintptr_t)SAR_DUALFFT_ADDR == SAR_DUALFFT_ENABLE) ? 2u : 1u;
}

static uint8_t sar_row_exp[SAR_GRID];        /* per-row captured exponent (static, off-stack) */

/* Join: spin until EVERY active chain's feeder AND unloader report idle. Returns 0 = done,
 * 1 = an unloader stalled, 2 = a feeder stalled (the encoding the callers already map to
 * SAR_SEQ_TIMEOUT_*). Bounded by the same `budget` a single chain used -- the pair finishes in
 * about the time one row used to take, so the budget is if anything more generous per row. */
static int fft_join(uint32_t nch, uint32_t budget)
{
    uint32_t n = budget;
    while (n) {
        uint32_t c;
        for (c = 0; c < nch; c++)
            if (!sar_k_idle(SAR_CHAIN[c].feed) || !sar_k_idle(SAR_CHAIN[c].unld)) break;
        if (c == nch) return 0;
        n--;
    }
    for (uint32_t c = 0; c < nch; c++) if (!sar_k_idle(SAR_CHAIN[c].feed)) return 2;
    return 1;
}

/* ROW -> CHAIN MAPPING. BLOCK split: over [r0,r1) chain c owns the CONTIGUOUS run starting at
 * r0 + c*seg. Was an interleave (chain c took row+c). Rows are independent either way -- the FFT
 * is a row transform -- so both are equally legal, but the block split is strictly better here:
 *   - a per-chain fault becomes a VISIBLE half-image defect instead of smearing into every other
 *     line, which is what made the 2026-07-26 CRC divergence so hard to localise;
 *   - each chain walks its own contiguous DDR region instead of both chains interleaving through
 *     the same DRAM pages row by row.
 * seg is rounded UP, so when (r1-r0) is not a multiple of nch the last chain simply runs short;
 * every user must therefore guard `r < r1` rather than assume a full group. */
static inline uint32_t fft_seg(uint32_t r0, uint32_t r1, uint32_t nch)
{
    return ((r1 - r0) + nch - 1u) / nch;
}

/* BLOCK SIZE: how many consecutive rows a chain takes before handing over. One knob spans the
 * whole space -- blk == 1 is a full interleave, blk == seg is contiguous halves.
 *
 * THIS IS A PERFORMANCE KNOB ONLY. An earlier revision of this comment claimed the interleave was
 * WRONG on silicon and that a contiguous split fixed it. That was false: those runs were re-using
 * consumed input (a PIPE run overwrites SIG -- see the SAR_DUALFFT note), and the block size never
 * affected correctness at all. Every value tiles the frame exactly, so all of them are correct.
 *
 * What it DOES affect is DRAM locality. The DIC is single-outstanding, so it alternates between
 * the chains; at blk == seg every alternation is 128 MiB away and pays a precharge+activate, while
 * a coarse-but-small blk keeps each chain in its own pages and amortises the seek over blk rows.
 *
 * MEASURED (valid runs only -- ELOD immediately before each, no epilogue):
 *     blk = 64     27.83 s      <- default
 *     blk = 4096   28.28 s
 * blk = 1 and 256 have never been validly measured; their apparent failures were the reload
 * artifact above, so re-sweep before assuming 64 is optimal.
 *
 * Must DIVIDE seg so the mapping tiles the frame exactly; anything else falls back to the default.
 */
/* Debug-only: stop the frame after pass 1 so SCRATCH can be dumped and diffed against the
 * bit-accurate model VALUE BY VALUE. Free word after the RSVDBG block (0xB0059150..0x15C).
 * Fail-safe: only the exact magic acts, so cold-boot DDR means normal operation. */
#define SAR_P1STOP_ADDR  0xB0059160u
#define SAR_P1STOP_MAGIC 0x50315354u   /* 'P1ST' */
#define SAR_FFTBLK_ADDR 0xB0059140u        /* free: 0x13C = SAR_DUALFFT is the last one used */
#define SAR_FFTBLK_DEF  64u                /* silicon-measured best; 0/garbage/non-divisor -> this */
static inline uint32_t fft_blk(uint32_t seg)
{
    uint32_t v = *(volatile uint32_t *)(uintptr_t)SAR_FFTBLK_ADDR;
    if (v == 0u || v > seg || (seg % v) != 0u) {
        /* Cold-boot DDR is uninitialised, so an unset knob must land on the validated value, not
         * on whatever happens to be in the word. seg itself is the fallback only if the default
         * does not divide it (nch > 1 always gives seg = 4096, which 64 divides). */
        return ((seg % SAR_FFTBLK_DEF) == 0u) ? SAR_FFTBLK_DEF : seg;
    }
    return v;
}

/* Row owned by chain c on turn `row`. Chain c takes rows [.., ..+blk) then jumps nch*blk ahead. */
static inline uint32_t fft_row_of(uint32_t c, uint32_t row, uint32_t nch, uint32_t blk)
{
    return ((row / blk) * nch + c) * blk + (row % blk);
}

/* Capture this group's exponents, each from its own chain. Rule (a): called immediately after
 * fft_join() and always before the next arm. Skips chains whose row fell past r1. */
static inline void fft_capture_exp(uint32_t nch, uint32_t r0, uint32_t r1,
                                   uint32_t seg, uint32_t blk, uint32_t row)
{
    (void)seg;
    for (uint32_t c = 0; c < nch; c++) {
        uint32_t r = r0 + fft_row_of(c, row, nch, blk);
        if (r < r1)
            sar_row_exp[r] = (uint8_t)(sar_reg_r(SAR_CHAIN[c].feed, K_FFT_SCALE_EXP) & 0xFu);
    }
}

/* float32 -> its IEEE-754 bit pattern. The generator is a bit-exact binary32 emulator, so it is
 * fed BITS, not a converted value: KR[j] and 1.0f/KR[j] must be the same float expressions the C
 * uses (sar_coeffs_pass2_range's `r = 1.0f / kr`), or the weights diverge in the last place. */
static inline uint32_t f32_bits(float f)
{
    union { float f; uint32_t u; } c;
    c.f = f;
    return c.u;
}

/* Push the row-invariant tables into the generator, ONCE per scene (M + (M-1) + Mp AXI4-Lite
 * writes ~= 19.5k, ~2 ms -- free against the seconds saved, and deliberately not a DMA for the
 * same reason the feeder's taper is not: a second fabric read mode would arbitrate for AR/R).
 * VERIFIED, not assumed: the RTL exposes the three fill levels at 0x10/0x14/0x18, so read them
 * back and compare against S / S-1 / QN. 19.5k unverified writes over a control bus is exactly
 * the kind of silent partial failure that reads as an arithmetic bug on silicon.
 * Returns 0 on success, or a bitmask of which table came up short (1=tan_s, 2=inv_tan, 4=KC).
 * With two chains this runs on BOTH generators (they are independent instances with their own
 * table LSRAM -- the tables are row-invariant, but the RAMs are not shared). ~39k AXI4-Lite
 * writes, ~4 ms, once per scene. */
static int cgen_load_tables_one(uint32_t cg, const sar_geom_t *g)
{
    uint32_t itn = 0u;
    const float *itan = sar_coeffs_inv_tan(&itn);
    const uint32_t S = g->M, QN = g->Mp;
    int bad = 0;

    if (itan == 0 || itn != (S - 1u)) return 2;      /* sar_coeffs_init() has not run for this geometry */

    sar_reg_w(cg, CGEN_DIMS, (QN << 16) | (S & 0xFFFFu));
    sar_reg_w(cg, CGEN_CTRL, CGEN_CTRL_REWIND_ALL);
    for (uint32_t k = 0; k < S;  k++) sar_reg_w(cg, CGEN_TANW,  f32_bits(g->tan_s[k]));
    for (uint32_t k = 0; k < itn; k++) sar_reg_w(cg, CGEN_ITANW, f32_bits(itan[k]));
    for (uint32_t k = 0; k < QN; k++) sar_reg_w(cg, CGEN_KCW,   f32_bits(g->KC[k]));

    if (sar_reg_r(cg, CGEN_TANW)  != S)         bad |= 1;
    if (sar_reg_r(cg, CGEN_ITANW) != (S - 1u))  bad |= 2;
    if (sar_reg_r(cg, CGEN_KCW)   != QN)        bad |= 4;
    return bad;
}

/* Load every active chain's generator. Any short table on ANY chain fails the whole pass over to
 * the CPU coefficient path -- a half-loaded second generator would emit degenerate (all zero-fill)
 * lines for exactly half the image. */
static int cgen_load_tables(uint32_t nch, const sar_geom_t *g)
{
    int bad = 0;
    for (uint32_t c = 0; c < nch; c++) bad |= cgen_load_tables_one(SAR_CHAIN[c].cgen, g);
    return bad;
}

/* Arm ONE row of coefficients on ONE chain's generator. kr == 0 is the C's degenerate line (all
 * {-1, 0}); the generator takes that branch off KR alone, so write RINV = 0.0f rather than
 * 1.0f/0.0f -- an Inf would latch the sticky err_fmt and abort the pass on a line that is
 * legitimately degenerate. */
static inline void cgen_start_row(uint32_t cg, float kr)
{
    uint32_t krb = f32_bits(kr);
    /* Zero test done on the BITS, matching the RTL's own `(r_kr & 0x7FFFFFFF) == 0` degenerate
     * condition exactly (so -0.0f is caught too), rather than a float compare. */
    sar_reg_w(cg, CGEN_KR,   krb);
    sar_reg_w(cg, CGEN_RINV, (krb & 0x7FFFFFFFu) ? f32_bits(1.0f / kr) : 0u);
    sar_reg_w(cg, CGEN_CTRL, CGEN_CTRL_START);
}

/* Push the cross taper into EVERY active chain's feeder on-chip table (once per pass, ~4096
 * AXI4-Lite writes per chain ~= 1.3 ms -- free against the 6.0 s the window pass cost).
 * Deliberately not a fabric DMA: a second mode in the feeder's read FSM would have to arbitrate
 * for AR/R against the row feed. The taper is the COLUMN taper hamc[], identical for every row,
 * so both chains get the same 4096 words -- but each chain has its own `wtab` LSRAM and a chain
 * whose table was never loaded would multiply every sample by whatever LSRAM powered up holding. */
static void fft_win_load_taper(uint32_t nch)
{
    const int16_t *hamc = (const int16_t *)(uintptr_t)SAR_HAMC_ADDR;
    for (uint32_t c = 0; c < nch; c++) {
        sar_reg_w(SAR_CHAIN[c].feed, K_FFT_WIN_CTRL, 1u << 17);   /* rewind the write pointer */
        for (uint32_t i = 0; i < WIN_TAB_WORDS; i++)
            sar_reg_w(SAR_CHAIN[c].feed, K_FFT_WIN_TAB,
                      ((uint32_t)(uint16_t)hamc[2u * i + 1u] << 16) | (uint16_t)hamc[2u * i]);
    }
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

/* Arm ONE row on ONE chain, PLAIN (non-gather) feed. Every register write is addressed through
 * `ch`, so a chain's feeder and unloader cannot be mismatched at a call site. */
static void fft_arm_row_plain(const sar_chain_t *ch, uint32_t s, uint32_t d,
                              int win_en, int det_en, int16_t hamr_row)
{
    /* Written unconditionally (0 when disabled) so the enable cannot leak from the azimuth
     * pass into a later range pass -- same discipline as the fused window below. */
    sar_reg_w(ch->unld, K_UNL_DET_CTRL, det_en ? 1u : 0u);
    sar_reg_w(ch->unld, HLS_ARG0, d);
    sar_reg_w(ch->unld, HLS_ARG1, SAR_ROW_BEATS);   /* INPUT beats, both modes */
    sar_k_start(ch->unld);
    /* Arm the fused window for THIS row. Written unconditionally (0 when disabled) so the
     * enable can never persist from a previous pass into the azimuth FFT or a debug entry. */
    sar_reg_w(ch->feed, K_FFT_WIN_CTRL, win_en ? ((1u << 16) | (uint16_t)hamr_row) : 0u);
    sar_reg_w(ch->feed, HLS_ARG0, s);
    sar_reg_w(ch->feed, HLS_ARG1, SAR_ROW_BEATS);
    sar_k_start(ch->feed);
}

static int fft_fabric_pass(uint32_t src, uint32_t dst, uint32_t spins, int win_en, int det_en)
{
    uint32_t budget = spins ? spins : SAR_DEFAULT_SPINS;
    const int16_t *hamr = (const int16_t *)(uintptr_t)SAR_HAMR_ADDR;
    /* SAR_GRID (8192) is even, so the row loop always steps in whole groups of `nch`. */
    const uint32_t nch = sar_nchains();

    if (win_en) fft_win_load_taper(nch);

    /* ---- PASS 1: per-row fabric FFT; capture each row's actual CoreFFT exponent ----
     * With nch == 2 the rows are processed in disjoint pairs {row, row+1}: chain 0 takes the
     * even row, chain 1 the odd one, both armed then both joined. NOT software-pipelined --
     * see rule (a) at SAR_DUALFFT_ADDR: an exponent must be read before its chain is re-armed. */
    const uint32_t seg = fft_seg(0u, SAR_GRID, nch);
    const uint32_t blk = fft_blk(seg);
    for (uint32_t row = 0; row < seg; row++) {
        for (uint32_t c = 0; c < nch; c++) {
            uint32_t r = fft_row_of(c, row, nch, blk);
            if (r >= SAR_GRID) continue;                /* last chain runs short (see fft_seg) */
            uint32_t s = src + r * SAR_ROW_BYTES;
            /* detect mode halves the output row: uint16 magnitudes, not complex int32 */
            uint32_t d = dst + r * (det_en ? SAR_ROW_BYTES_U16 : SAR_ROW_BYTES);
            fft_arm_row_plain(&SAR_CHAIN[c], s, d, win_en, det_en, hamr[r]);
        }
        { int rc = fft_join(nch, budget);
          if (rc) return rc; }                          /* row stalled: 1=unloader, 2=feeder */
        /* SCALE_EXP is latched at the frame's OUTP_READY falling edge (before unloader DONE) */
        fft_capture_exp(nch, 0u, SAR_GRID, seg, blk, row);
        if ((row & 0x7Fu) == 0u) SAR_PROG(4u, row, seg);
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
    /* det_en: the unloader already took the magnitude, at the row's NATIVE exponent -- it cannot
     * do better, because emax is not known until every row is transformed. Magnitude is linear in
     * the operand scale, so shifting it here is algebraically the same global renormalize; only
     * the truncation point moves. Modelled in mpfs/host/model_detect_fusion.py: never worse than
     * the old order, <=2 LSB apart, because CoreFFT's BFP exponent is nearly always 0. Half the
     * data, no sqrt, no sign handling -- this is what remains of the 20.6 s detect stage.
     * Split across the worker harts (rows are independent); OFF unless SAR_RWRK_NW_ADDR holds the
     * exact magic, in which case this is the identical single-hart loop it always was. */
    if (sar_cwrk_renorm((uint64_t)dst, sar_row_exp, SAR_GRID, SAR_GRID, emax, headroom,
                        det_en ? 1u : 0u, (uint64_t)SAR_PROG_ADDR, sar_rwrk_nw()) == 0u)
        return 3;                             /* renorm worker deadline miss -> partially shifted */
    return 0;
}

/* ---- STEP 2: overlap the inter-FFT corner-turn (CT#2) with FFT-2 -------------------------------
 * Hides the ~6.2 s corner-turn under FFT-2's ~11 s by running them CONCURRENTLY on FIC_0 (measured
 * 81% overlap by the H4BT benchmark). Correctness (the critic's H1/H2) is kept by the STRIP-KERNEL
 * structure: the corner-turn runs as one bounded kernel PER STRIP, each to DONE, and FFT-2 reads a
 * strip only AFTER its corner-turn kernel completed -- the exact producer->consumer barrier the
 * sequential pipeline already relies on. The concurrency is between DISJOINT strips:
 *   CT#2(strip s):   SCRATCH cols [s*S,(s+1)*S) -> SIG rows [s*S,(s+1)*S)   (writes SIG strip s)
 *   FFT-2(strip s-1): SIG rows [(s-1)*S, s*S) -> OUT                        (reads SIG strip s-1)
 * SCRATCH read-only, OUT write-only, SIG strips disjoint -> no aliasing (why CT#2+FFT-2, not CT#1).
 * Only for the shipping gather-fused + det-fused config. PASS-2 renorm stays global at the end. */
#define SAR_OVERLAPMODE_ADDR  0xB0059130u    /* 0 = sequential (default), 1 = CT#2/FFT-2 overlap */

/* FFT-2 PASS-1 transform for rows [r0,r1): det (uint16 out), no window. Bit-identical to
 * fft_fabric_pass PASS 1 with det_en=1/win_en=0; captures each row's SCALE_EXP.
 * `nch` chains split the rows [r0,r1) in disjoint groups of nch, same rule as fft_fabric_pass:
 * arm all, join all, read all exponents, then advance. The caller's strip width (S = 1024) and
 * SAR_GRID are both even, so a group never straddles the strip boundary. */
static int fft2_pass1_rows(uint32_t src, uint32_t dst, uint32_t r0, uint32_t r1,
                           uint32_t budget, uint32_t nch)
{
    const uint32_t seg = fft_seg(r0, r1, nch);
    const uint32_t blk = fft_blk(seg);
    for (uint32_t row = 0; row < seg; row++) {
        for (uint32_t c = 0; c < nch; c++) {
            uint32_t r = r0 + fft_row_of(c, row, nch, blk);
            if (r >= r1) continue;                                  /* last chain runs short */
            uint32_t s = src + r * SAR_ROW_BYTES;
            uint32_t d = dst + r * SAR_ROW_BYTES_U16;               /* det: uint16 magnitudes */
            fft_arm_row_plain(&SAR_CHAIN[c], s, d, 0, 1, 0);        /* FFT-2 has no fused window */
        }
        { int rc = fft_join(nch, budget);
          if (rc) return rc; }
        fft_capture_exp(nch, r0, r1, seg, blk, row);
    }
    return 0;
}

/* Arm CT#2 for one strip: SCRATCH cols [cb, cb+S) -> SIG rows [cb, cb+S). No wait. */
static void ct2_strip_arm(uint32_t cb, uint32_t S)
{
    sar_reg_w(K_CORNER_TURN, HLS_ARG0, BUF_SCRATCH);
    sar_reg_w(K_CORNER_TURN, HLS_ARG1, sar_ctdst());
    sar_reg_w(K_CORNER_TURN, HLS_ARG2, cb);
    sar_reg_w(K_CORNER_TURN, HLS_ARG3, S);
    sar_k_start(K_CORNER_TURN);
}

/* Overlapped CT#2 + FFT-2 (det). Replaces sar_form_image steps 4+5 when overlap mode is on. */
static int fft2_ct_overlap(uint32_t spins)
{
    uint32_t budget = spins ? spins : SAR_DEFAULT_SPINS;
    const uint32_t S = 1024u;                 /* strip width: CT_T=128-aligned, SAR_GRID/S = 8 strips */
    const uint32_t K = SAR_GRID / S;
    /* Row split across the FFT chains is INSIDE a strip, so the strip producer->consumer barrier
     * (CT#2 strip s completes before FFT-2 reads it) is untouched: both chains only ever read
     * strip s-1, which the corner-turn finished before this iteration started. */
    const uint32_t nch = sar_nchains();

    flush_l2_cache(1u);                        /* match fft_pass's before-flush (SCRATCH/SIG to DDR) */
    __asm volatile ("fence rw, rw");

    /* prologue: strip 0 corner-turn to DONE (makes SIG rows [0,S) observable to the FFT feeder) */
    ct2_strip_arm(0u, S);
    if (!sar_k_wait(K_CORNER_TURN, budget)) return SAR_SEQ_TIMEOUT_CORNER;

    for (uint32_t s = 1u; s < K; s++) {
        ct2_strip_arm(s * S, S);                                    /* producer: strip s (no wait) */
        int r = fft2_pass1_rows(sar_ctdst(), BUF_OUT, (s - 1u) * S, s * S, budget, nch); /* consumer: strip s-1 */
        if (r) { (void)sar_k_wait(K_CORNER_TURN, budget);
                 return (r == 1) ? SAR_SEQ_TIMEOUT_FFT2 : SAR_SEQ_TIMEOUT_DMA; }
        if (!sar_k_wait(K_CORNER_TURN, budget)) return SAR_SEQ_TIMEOUT_CORNER;   /* join strip s */
        SAR_PROG(4u, s, K);
    }
    { int r = fft2_pass1_rows(sar_ctdst(), BUF_OUT, (K - 1u) * S, K * S, budget, nch); /* epilogue: last strip */
      if (r) return (r == 1) ? SAR_SEQ_TIMEOUT_FFT2 : SAR_SEQ_TIMEOUT_DMA; }

    /* global PASS-2 renorm over OUT (det), identical to fft_fabric_pass PASS 2 (det branch) */
    uint8_t emax = 0;
    for (uint32_t row = 0; row < SAR_GRID; row++) if (sar_row_exp[row] > emax) emax = sar_row_exp[row];
    uint32_t headroom = *(volatile uint32_t *)(uintptr_t)SAR_FFT_HEADROOM_ADDR;
    if (headroom > 12u) headroom = 0u;
    /* Same worker-hart split as the other two epilogues; OFF unless SAR_RWRK_NW_ADDR holds the
     * exact magic, in which case this is the identical single-hart loop between the same two
     * whole-L2 flushes. A deadline miss leaves OUT partially shifted -> fail LOUD. */
    if (sar_cwrk_renorm((uint64_t)BUF_OUT, sar_row_exp, SAR_GRID, SAR_GRID, emax, headroom,
                        1u, (uint64_t)SAR_PROG_ADDR, sar_rwrk_nw()) == 0u)
        return SAR_SEQ_TIMEOUT_FFT2;
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
    sar_reg_w(K_CORNER_TURN, HLS_ARG1, sar_ctdst());
    sar_reg_w(K_CORNER_TURN, HLS_ARG2, 0u);       /* c_base  */
    sar_reg_w(K_CORNER_TURN, HLS_ARG3, 0u);       /* c_count=0 => full frame */
    t0 = readmtime();
    sar_k_start(K_CORNER_TURN);
    if (!sar_k_wait(K_CORNER_TURN, spins)) { rec[15] = 0xDEAD0001u; goto pub; }
    t1 = readmtime();
    rec[1] = (uint32_t)(t1 - t0);                 /* t_ct  (us) */

    /* 2) FFT pass ALONE: SIG -> OUT (det), decoupled src/dst (no in-place stall) */
    t0 = readmtime();
    (void)fft_fabric_pass(sar_ctdst(), BUF_OUT, spins, 0, 1);
    t1 = readmtime();
    rec[2] = (uint32_t)(t1 - t0);                 /* t_fft (us) */

    /* 3) CONCURRENT: arm CT free-running, run the FFT pass while it writes SIG, then join CT. */
    sar_reg_w(K_CORNER_TURN, HLS_ARG0, BUF_SCRATCH);
    sar_reg_w(K_CORNER_TURN, HLS_ARG1, sar_ctdst());
    sar_reg_w(K_CORNER_TURN, HLS_ARG2, 0u);       /* c_base  */
    sar_reg_w(K_CORNER_TURN, HLS_ARG3, 0u);       /* c_count=0 => full frame */
    ficmon_clear();
    t0 = readmtime();
    sar_k_start(K_CORNER_TURN);                   /* CT free-runs on FIC_0 ... */
    (void)fft_fabric_pass(sar_ctdst(), BUF_OUT, spins, 0, 1);  /* ... while the FFT hammers FIC_0 too */
    if (!sar_k_wait(K_CORNER_TURN, spins)) rec[15] = 0xDEAD0002u;   /* join CT (should be long done) */
    t1 = readmtime();
    ficmon_snapshot(1u, 9u, SAR_ROW_BEATS);       /* concurrent-run bus behaviour -> slot 1 (0xB0059290); slot 0 keeps range gather */
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
/* Arm ONE row on ONE chain, GATHER feed (the fused azimuth resample). Every register write --
 * unloader, feeder AND coefficient generator -- is addressed through `ch`, so a chain's three
 * blocks cannot be mismatched at a call site. Rule (b) at SAR_DUALFFT_ADDR. */
static void fft1_arm_row_gather(const sar_chain_t *ch, uint32_t s, uint32_t d,
                                uint32_t idxb, uint32_t wqb, uint32_t M, uint32_t Mp,
                                int cgen_en, float kr, int16_t hamr_row)
{
    sar_reg_w(ch->unld, K_UNL_DET_CTRL, 0u);            /* FFT-1 never fuses detect */
    sar_reg_w(ch->unld, HLS_ARG0, d);
    sar_reg_w(ch->unld, HLS_ARG1, SAR_ROW_BEATS);
    sar_k_start(ch->unld);
    /* Feeder in GATHER mode: source row, this row's idx/wq, dims (SRC_LEN=M, QN=Mp), window on.
     * One START sequences load(src,idx,wq) -> gather+window+stream.
     * Fabric coefficients: start THIS chain's GENERATOR FIRST so it runs concurrently with the
     * feeder's source-row load -- it produces ~1 entry/cycle and its 32-deep output FIFO
     * rate-matches the gather. IDX_BASE/WQ_BASE are still written even in stream mode so the DDR
     * fallback stays armed and selectable by the control bit alone. */
    if (cgen_en) cgen_start_row(ch->cgen, kr);
    sar_reg_w(ch->feed, K_FFT_IDX_BASE,    idxb);
    sar_reg_w(ch->feed, K_FFT_WQ_BASE,     wqb);
    sar_reg_w(ch->feed, K_FFT_GATHER_DIMS, (Mp << 16) | (M & 0xFFFFu));
    sar_reg_w(ch->feed, K_FFT_GATHER_CTRL, K_FFT_GC_GATHER
                                           | (cgen_en ? K_FFT_GC_CSTREAM : 0u)
                                           | (sar_azsinc_enabled() ? K_FFT_GC_SINC : 0u));
    sar_reg_w(ch->feed, K_FFT_WIN_CTRL,    (1u << 16) | (uint16_t)hamr_row);
    sar_reg_w(ch->feed, HLS_ARG0,          s);          /* source row (Mp-wide, M valid) */
    sar_k_start(ch->feed);
}

static int fft1_gather_pass(const sar_geom_t *g, float *f32, uint32_t src, uint32_t dst,
                            uint32_t spins)
{
    (void)f32;                    /* scratch is unused on the closed-form pass-2 path */
    uint32_t budget = spins ? spins : SAR_DEFAULT_SPINS;
    const int16_t *hamr = (const int16_t *)(uintptr_t)SAR_HAMR_ADDR;
    const uint32_t Mp = g->Mp, M = g->M;
    int b = 0;

    /* Measured 2026-07-25: this stage is COEFF-PACED -- 1499 us/row of sar_coeffs_pass2 against
     * RPROF[9] = 0.53 us/row of residual fabric wait, i.e. the feeder/CoreFFT chain is already
     * idle by the time coefficients are ready. So route coefficient generation through the
     * multi-hart dispatcher (proven bit-exact, silicon-validated on pass 1). nw<=1 falls back to
     * the original single-hart path. Same fail-safe validation as resample_2pass: the knob is
     * uninitialised DDR on a cold boot, so only an exact 2..MAXW enables it. */
    uint32_t cwrk_nw = *(volatile uint32_t *)(uintptr_t)SAR_CWRK_NW_ADDR;
    if (cwrk_nw < 2u || cwrk_nw > SAR_CWRK_MAXW) cwrk_nw = 1u;

    /* ON-FABRIC coefficients (sar_coeffgen -> feeder stream). FAIL-SAFE: only the exact magic
     * enables it; a cold-boot garbage word leaves the DDR path running. The table load is then
     * VERIFIED against the generator's own fill-level registers before anything is armed -- if it
     * came up short we fall back to the CPU path for the whole pass rather than stream garbage,
     * and record which table failed in RPROF[11] for the host log. */
    int cgen_en = (*(volatile uint32_t *)(uintptr_t)SAR_CGENMODE_ADDR == SAR_CGEN_ENABLE);

    /* SECOND CHAIN -- ONLY with the fabric coefficient generator.
     *
     * This is a deliberate coupling, not an oversight. On the DDR coefficient path a row's idx/wq
     * are produced by the CPU at 1499 us/row single-hart (~508 us/row across 4 harts) against a
     * fabric floor of 698 us/row, i.e. the stage is ALREADY CPU-paced; two chains would need two
     * rows of coefficients per 698 us (~254 us/row of CPU budget) and the CPU cannot supply it.
     * A second chain there would double the fabric and buy nothing, while adding a 4-deep
     * coefficient bank rotation and a second per-row L2 flush onto the very FIC_0 read slot the
     * second chain exists to use. With the generator on, each chain has its OWN generator
     * (SAR_CHAIN[c].cgen) and needs no CPU coefficient work at all.
     * Recorded in RPROF[11] so the host log says WHY a run was single-chain. */
    uint32_t nch = sar_nchains();
    if (nch > 1u && !cgen_en) nch = 1u;

    if (cgen_en) {
        int bad = cgen_load_tables(nch, g);
        RPROF[11] = 0xC0EF0000ull | ((uint64_t)nch << 8) | (uint64_t)(uint32_t)bad;
        if (bad) { cgen_en = 0; nch = 1u; }
    } else {
        RPROF[11] = 0xC0EF0000ull | ((uint64_t)nch << 8) | 0x1000ull;   /* CPU coefficient path */
    }

    /* 32-tap sinc table -> BOTH chains, once per scene. Each feeder holds its own copy in fabric
     * RAM, so this must run for every chain that will be armed, and it must precede the first
     * armed row: the core reads the table per query and an unloaded one is all zeros. */
    /* RANGE table: pushed here for the same reason as the azimuth one -- from DDR, on-chip, in
     * microseconds instead of the host's 15-minute JTAG walk. Guarded by the same knob the datapath
     * uses, so an unarmed run does not touch the table at all. */
    if (sar_rsv_sinc_enabled()) {
        /* Non-zero write pointer means the table landed as a PREFIX, not in full -- fail loud
         * rather than focus a line against half a kernel. No RPROF slot is used: the map at
         * sar_sequencer.c:162 has 2,4,5,6,9,10,11,12,13,14,15 live, and quietly clobbering timing
         * telemetry to report a load is a worse trade than returning the error. */
        if (sar_sinc_load_range((const int16_t *)(uintptr_t)SAR_SINC_TAB_ADDR) != 0)
            return SAR_SEQ_TIMEOUT_RESAMPLE;
    }

    if (sar_azsinc_enabled()) {
        const int16_t *stab = (const int16_t *)(uintptr_t)SAR_AZSINC_TAB_ADDR;
        for (uint32_t c = 0; c < nch; c++) sar_azsinc_load(SAR_CHAIN[c].feed, stab);
    }

    fft_win_load_taper(nch);
    /* sar_cwrk_line() computes AND publishes, over the FULL Mp outputs. That also fixes a latent
     * bug: the old flush_coef_bank_to_ddr(b, M) published only M=5634 of the Mp=8192 entries
     * pass 2 writes, leaving [M,Mp) unpublished (harmless only because hamc[] is zero across the
     * FFT pad, so whatever the feeder gathered there was multiplied by zero). */
    if (!cgen_en)
        sar_cwrk_line(g, 2u, 0u, (int32_t *)(uintptr_t)SAR_COEF_IDX(0),
                                 (int16_t *)(uintptr_t)SAR_COEF_WQ(0), Mp, cwrk_nw);

    const uint32_t seg = fft_seg(0u, SAR_GRID, nch);
    const uint32_t blk = fft_blk(seg);
    for (uint32_t row = 0; row < seg; row++) {
        /* no explicit publish here: sar_cwrk_line() already published this bank when it computed it */
        /* E1: FIC_0 profile of ONE FFT-1 row GROUP. Measured this way it answered the
         * 2nd-CoreFFT-chain question: (READ_BUSY + R_DATAWAIT)/ELAPSED = 7.5% with the fabric
         * coefficient generator on, so the feeder holds the single SASD read slot only during its
         * source-row load and is silent through CoreFFT's ~698 us -- a 2nd chain fits with ~85%
         * of the slot still spare. Group 1, not 0 -- group 0 carries the taper-load transient. */
        if (row == 1u) ficmon_clear();
        RP_T0(tarm);                /* E3: time the whole arm block (unloader + feeder regs) */
        for (uint32_t c = 0; c < nch; c++) {
            uint32_t r = fft_row_of(c, row, nch, blk);
            if (r >= SAR_GRID) continue;                /* last chain runs short (see fft_seg) */
            /* Chain c takes row (row+c): DISJOINT 32 KiB destination rows, disjoint source rows,
             * src read-only. Legal as a ROW split only -- the FFT is a row transform and the
             * corner-turn is the pipeline's only legal transpose point. */
            fft1_arm_row_gather(&SAR_CHAIN[c],
                                src + r * Mp * 4u, dst + r * SAR_ROW_BYTES,
                                (uint32_t)SAR_COEF_IDX(b), (uint32_t)SAR_COEF_WQ(b),
                                M, Mp, cgen_en, g->KR[r], hamr[r]);
        }
        RP_ACC(7, tarm);            /* E3: per-group arm cost (was inside the unattributed 26%) */
        /* INSTRUMENTATION 2026-07-25 -- is this 15.14 s stage COEFF-paced or FABRIC-paced?
         * Pass 1 taught the lesson the hard way: it overlaps CPU coefficients with the fabric, so
         * its cost is max(coeff, kernel). Coefficients merely LOOKED like 99.6% because they were
         * marginally the longer of the two and hid a ~4.75 s kernel. Making them 2.95x faster
         * bought 2%. Measure the same split here BEFORE wiring in the multi-hart dispatcher.
         *   [6] = azimuth coefficient generation (sar_coeffs_pass2), overlapped with the feeder
         *   [9] = residual feeder/unloader wait AFTER coeff gen returned
         *   [7] = per-row coeff-bank publish;  [10] = rows
         * [9] ~ 0  -> COEFF-paced: multi-hart should convert, as pass 1's coeff time did.
         * [9] large -> FABRIC-paced: the feeder/CoreFFT is the floor and multi-hart buys ~nothing;
         *              do NOT spend a build on it. Slots [6..11] are free in the fused config. */
        /* cgen_en: the fabric generator IS this row's coefficients, so there is no next-row CPU
         * work to overlap -- the whole sar_cwrk_line() call, its multi-hart dispatch and its
         * per-bank L2 flush disappear, and RPROF[6] reads ~0. */
        /* nch == 1 here whenever !cgen_en (see the coupling above), so this stays a plain
         * single-chain double-buffered overlap. */
        if (!cgen_en && row + 1u < SAR_GRID) {            /* overlap: next row's coeffs under the feed */
            RP_T0(t);
            sar_cwrk_line(g, 2u, row + 1u, (int32_t *)(uintptr_t)SAR_COEF_IDX(b ^ 1),
                                           (int16_t *)(uintptr_t)SAR_COEF_WQ(b ^ 1), Mp, cwrk_nw);
            RP_ACC(6, t);
        }
        int rc;
        { RP_T0(t);
          rc = fft_join(nch, budget);
          RP_ACC(9, t); }
        /* E1 (FFT-1 row group) DISABLED 2026-07-27: it shares slot 1 with the range gather and runs
         * later, so it overwrote the gather record. Its result is already captured and recorded --
         * ~80% genuine FIC_0 idle (util 5.2%, r_datawait 7.3%, write 7.7%), i.e. FFT-1 is NOT
         * bus-bound. Re-enable only after moving SAR_CWRK to free a real third slot. */
        (void)0;  /* was: if (row == 1u) ficmon_snapshot(1u, 3u, Mp); */
        RPROF[10] += nch;
        if (rc) return rc;
        /* Rule (a): every chain's exponent is read HERE, after the join and before the next arm.
         * The feeder holds SCALE_EXP only until its own next frame, so a software-pipelined
         * re-arm would stamp row j+2's exponent onto row j. */
        fft_capture_exp(nch, 0u, SAR_GRID, seg, blk, row);
        /* Read EACH ACTIVE generator's STAT for THIS row and ABORT on err_fmt. err_fmt means a
         * NaN/Inf/denormal reached a datapath that has no path for one, so the row's weights are
         * garbage -- and it is STICKY, so a scene that trips it would otherwise produce a
         * plausible, quietly wrong image for every remaining row. err_dims means the tables went
         * short after the load check, which would silently emit a degenerate (all zero-fill)
         * line. One extra AXI4-Lite read per row per chain, on top of the SCALE_EXP read above. */
        if (cgen_en) {
            for (uint32_t c = 0; c < nch; c++) {
                uint32_t st = sar_reg_r(SAR_CHAIN[c].cgen, CGEN_STAT);
                if (st & (CGEN_STAT_ERR_FMT | CGEN_STAT_ERR_DIMS)) {
                    RPROF[11] = 0xC0EF0000ull | 0x8000ull | ((uint64_t)c << 24) | (uint64_t)st;
                    return 3;
                }
            }
        }
        if ((row & 0x7Fu) == 0u) SAR_PROG(4u, row, SAR_GRID);
        b ^= 1;
    }
    /* Clear on BOTH chains -- not just the active ones -- so a dual run followed by a single run
     * cannot leave chain B's gather armed for a later plain FFT. */
    for (uint32_t c = 0; c < 2u; c++) sar_reg_w(SAR_CHAIN[c].feed, K_FFT_GATHER_CTRL, 0u);

    /* global block exponent + renormalize -- identical to fft_fabric_pass PASS 2 (complex, det=0) */
    uint8_t emax = 0;
    for (uint32_t row = 0; row < SAR_GRID; row++)
        if (sar_row_exp[row] > emax) emax = sar_row_exp[row];
    uint32_t headroom = *(volatile uint32_t *)(uintptr_t)SAR_FFT_HEADROOM_ADDR;
    if (headroom > 12u) headroom = 0u;
    /* E3: this epilogue is a CPU read-modify-write over the whole 8192^2 frame between two
     * whole-L2 flushes. It is ONE-SHOT, not per-row, and no amount of fabric parallelism touches
     * it -- so it is a hard floor under this stage and the bulk of the ~2.96 s (26% of FFT-1)
     * that RPROF[6]+[7]+[9] never accounted for. Slot [8] was free in the fused config. */
    /* Rows are INDEPENDENT (the shift depends only on the scalar emax and this row's own
     * exponent), so split them across the same worker harts the coefficients use. OFF unless the
     * exact magic is at SAR_RWRK_NW_ADDR, so the A/B is same-binary; with it off this is the
     * identical single-hart loop between the identical two whole-L2 flushes. */
    RP_T0(tepi);
    uint32_t used = sar_cwrk_renorm((uint64_t)dst, sar_row_exp, SAR_GRID, SAR_GRID,
                                    emax, headroom, 0u, (uint64_t)SAR_PROG_ADDR, sar_rwrk_nw());
    RP_ACC(8, tepi);            /* E3: one-shot renormalize epilogue (incl. both whole-L2 flushes) */
    if (used == 0u) return 4;   /* renorm worker missed its deadline -> frame partially shifted */
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
    /* Coefficient generation is the pacing item (RPROF[2]/RPROF[5] = 99.57% on silicon) and its
     * loop is stall- not issue-bound, so spread each line across the otherwise-idle U54 harts.
     * JTAG-tunable at SAR_CWRK_NW_ADDR and read ONCE here so the whole run is one configuration:
     * 0/1 = the original single-hart path, up to SAR_CWRK_MAXW = all four harts. */
    /* FAIL-SAFE: this word is uninitialised DDR on a cold boot, so accept ONLY an exact, valid
     * request (2..MAXW). Anything else -- 0, 1, or garbage like 0xDEADBEEF -- means OFF. Clamping
     * out-of-range UP to MAXW would silently enable multi-hart on random DDR content. */
    uint32_t cwrk_nw = *(volatile uint32_t *)(uintptr_t)SAR_CWRK_NW_ADDR;
    if (cwrk_nw < 2u || cwrk_nw > SAR_CWRK_MAXW) cwrk_nw = 1u;
    sar_cwrk_init();
    /* SAR_RSVMODE: hand pass 1 to sar_resample_v, which generates its own coefficients, so none of
     * the per-line CPU coefficient work below runs at all. PASS 1 ONLY -- pass 2 is already fused
     * into the FFT-1 feeder and keeps sar_coeffgen. ON unless the knob holds exactly 'RSV0': this
     * core REPLACED the SmartHLS resample in the fabric, so there is no fallback path (the header
     * explains why that inverts the usual opt-in discipline).
     * NOT bit-exact against CRC 0x319037b2 by design; see sar_resample_v.h. */
    sar_rsv_scene_t rsv;
    int rsv_on = sar_rsv_enabled();
    if (rsv_on) {
        /* Loaded ONCE per scene. FAIL HARD if it does not build -- silently dropping to the
         * legacy arming path would send idx/out pointers into OUT_BASE/DIMS and gather garbage
         * into the coefficient buffer, which is worse than reporting failure. */
        uint32_t n_real = (g->N < Np) ? g->N : Np;
        if (sar_rsv_load_kr(g->KR, n_real, Np, &rsv) != 0) return 0;
        /* The sinc coefficient table is pushed by the HOST over JTAG (see sar_resample_v.h):
         * 16 KB does not fit in the L2 scratchpad the app's .rodata lives in. */
    }
    /* PASS 1 (range) */
    if (!rsv_on) {
        sar_coeffs_pass1(g, 0, f32, (int32_t *)(uintptr_t)SAR_COEF_IDX(0),
                                    (int16_t *)(uintptr_t)SAR_COEF_WQ(0));
    }
    for (int k = 0; k < 16; k++) RPROF[k] = 0;          /* profile accumulators ([14]/[15] = IPC) */
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
    /* NOT under RSVMODE: the probe pokes HLS_ARG0..3, which on sar_resample_v are IN_BASE /
     * OUT_BASE / STATUS2 / DIMS. It would silently rewrite the geometry, not re-run line 0. */
    const uint32_t PROBE = *(volatile uint32_t *)(uintptr_t)SAR_RPROF_PROBE_ADDR;
    if (!rsv_on && PROBE != 0u && PROBE <= 4096u) {
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
    /* PASS 1 (range) -- SINGLE LANE, double-buffered coefficients.
     *
     * REVERTED 2026-07-25 from the 2-lane RES/RES2 form. RES2's DIC initiator and CIC target are
     * now the second CoreFFT chain's UNLD_B (sar_kernels.h): K_RESAMPLE2 no longer exists, and
     * writing 0x60002000 here would arm an FFT unloader mid-resample. That is not the only
     * reason to drop it -- the 2-lane gather was measured on silicon (openspec
     * add-res2-dual-lane-gather/tasks.md) at 4.85 s vs 5.78 s (-16%, whole pipeline -0.6%) while
     * corrupting 99.64% of a 1024x1024 ROI against the known-good crop, verdict DO NOT COMMIT.
     * The row split that IS taken here is inside the FFT passes, where the rows are provably
     * independent and the partition is bit-exact (a max over per-row exponents).
     *
     * The multi-hart coefficient dispatcher (sar_cwrk_line, silicon-proven bit-exact) is KEPT:
     * it publishes every slice itself, so there is no separate per-bank flush in the loop, and
     * with cwrk_nw <= 1 it degrades to exactly the old single-hart compute+flush. */
    if (!rsv_on) flush_coef_bank_to_ddr(0, Np);    /* the prologue pass1() above does not publish */
    for (uint32_t i = 0; i < g->M; i++) {
        SAR_PROG(1u, i, g->M);
        /* RSV arms and starts in one call, so the counter clear has to happen before the arm.
         * The register writes it then includes are a handful of CIC beats, not FIC_0 traffic. */
        if (rsv_on && i == 0u) ficmon_clear();
        { RP_T0(t);
          if (rsv_on) {
              /* the kernel's whole per-line CPU cost: three scalars, in double (U54 is RV64GC).
               * kr[i,j] = 2*pr[i]/C * (f0[i] + j*df[i]) = x0 + j*dx -- the same uniform mapping
               * sar_coeffs_pass1() uses, kept in double here because A/B are exact integers. */
              /* NOT SAR_C_LIGHT: that is a FLOAT literal (299792458.0f), so it has already been
               * rounded to 299792448 before any cast to double can help -- a 3.34e-8 relative
               * error. It survives into A and, through the near-cancellation in (kr_off - x0),
               * lands as 1.49e-5 in B: a uniform 0.0119-sample range shift. Measured against the
               * board on 2026-07-29 it was the whole difference between a 55% and a 99.2%
               * value-level match on line 0. Small, but there is no reason to carry it. */
              double ag = 2.0 * (double)g->pr[i] / 299792458.0;
              double x0 = ag * (double)g->f0[i], dx = ag * (double)g->df[i];
              if (i == 0u) {
                  /* publish line 0's scalars so the first board run CHECKS this arithmetic against
                   * check_resample_v_scalars.py rather than assuming it -- the C cannot be run on
                   * the development host. See SAR_RSVDBG_ADDR in sar_resample_v.h. */
                  volatile uint32_t *d = (volatile uint32_t *)(uintptr_t)SAR_RSVDBG_ADDR;
                  int32_t a_dbg; uint32_t sh_dbg; int64_t b_dbg;
                  sar_rsv_scalars(&rsv, x0, dx, &a_dbg, &sh_dbg, &b_dbg);
                  d[0] = sh_dbg;
                  d[1] = (uint32_t)a_dbg;
                  d[2] = (uint32_t)((uint64_t)b_dbg & 0xFFFFFFFFu);
                  d[3] = (uint32_t)(((uint64_t)b_dbg >> 32) & 0xFFFFFFFFu);
              }
              sar_rsv_arm_line(&rsv, x0, dx, g->N,
                               BUF_SIG + i * g->N * 4u,
                               BUF_SCRATCH + (uint32_t)invord[i] * Np * 4u);
          } else {
              sar_reg_w(K_RESAMPLE, HLS_ARG0, BUF_SIG + i * g->N * 4u);        /* in  (N-wide) */
              sar_reg_w(K_RESAMPLE, HLS_ARG1, (uint32_t)SAR_COEF_IDX(b));
              sar_reg_w(K_RESAMPLE, HLS_ARG2, (uint32_t)SAR_COEF_WQ(b));
              sar_reg_w(K_RESAMPLE, HLS_ARG3, BUF_SCRATCH + (uint32_t)invord[i] * Np * 4u);
          }
          RP_ACC(0, t); }
        if (!rsv_on) {
            if (i == 0u) ficmon_clear();           /* FIC_0 behaviour of range gather line 0 */
            sar_k_start(K_RESAMPLE);
        }
        /* overlap: compute the NEXT line's coeffs into the other bank while this line gathers */
        if (!rsv_on && i + 1u < g->M) {
            RP_T0(t);
            uint64_t r0 = read_csr(minstret), c0 = read_csr(mcycle);
            sar_cwrk_line(g, 1u, i + 1u, (int32_t *)(uintptr_t)SAR_COEF_IDX(b ^ 1),
                                         (int16_t *)(uintptr_t)SAR_COEF_WQ(b ^ 1), Np, cwrk_nw);
            RPROF[14] += read_csr(minstret) - r0;
            RPROF[15] += read_csr(mcycle)   - c0;
            RP_ACC(2, t);
        }
        { RP_T0(t);
          if (!sar_k_wait(K_RESAMPLE, spins)) return 0;
          RP_ACC(3, t); }
        /* SLOT 1, not slot 0: the internal corner-turn snapshots slot 0 (pass tag 4) LATER in the
         * same frame, so a range-gather record written here was overwritten every run and the
         * 5.2 s gather -- the largest single block in the frame -- was never actually observable.
         * Found 2026-07-27 when E4 was read expecting gather data and returned corner-turn data.
         *
         * There is NO slot 2. FICMON's allocation ends at 0xB00592E0 and SAR_CWRK_ADDR starts at
         * 0xB0059300 (sar_coeff_workers.h) -- only 32 bytes, and a record is 80. Writing a slot 2
         * overruns the coefficient-worker control block, which silently drops the renormalize
         * epilogue to single-hart: measured 2026-07-27 as +2.0 s range-FFT and +1.6 s azimuth-FFT
         * (frame 18.48 -> 22.04 s) with resample untouched. Do not add a slot here without moving
         * SAR_CWRK first. */
        if (i == 0u) ficmon_snapshot(1u, 1u, Np / 2u);   /* Np samples, 2/beat */
        RPROF[4]++;
        b ^= 1;
    }
    RPROF[5] = readmtime() - sar_resample_ts[0];
    /* SAR_P1STOP: abort the frame right here, with SCRATCH still holding PURE pass-1 output.
     * FFT-1 writes BUF_SCRATCH (fft1_gather_pass, dst=BUF_SCRATCH), so after a normal PIPE the
     * pass-1 result is long gone and the only thing left to judge is the final image -- which is
     * scale-, phase- and orientation-invariant and hides exactly the kind of fault being hunted.
     * Returning 0 aborts the pipeline (the caller reports a stage failure), which is the POINT:
     * nothing downstream runs, so SCRATCH survives for a value-level dump. The non-zero mailbox
     * result is expected and is not a fault. */
    if (*(volatile uint32_t *)(uintptr_t)SAR_P1STOP_ADDR == SAR_P1STOP_MAGIC) {
        flush_l2_cache(1u);                 /* publish: the host reads DDR, FIC_0 is non-coherent */
        return 0;
    }
    if (rsv_on) {
        /* sticky and frame-level -- it cannot say WHICH line, only that one of them tripped */
        *(volatile uint32_t *)(uintptr_t)SAR_RSVSTAT_ADDR =
            SAR_RSVSTAT_TAG | (sar_reg_r(K_RESAMPLE, RSV_STATUS2) & 0xFFFFu);
    }
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
    /* E4: FIC_0 profile of THE WHOLE INTERNAL CORNER-TURN. This is the measurement that decides
     * whether replacing the SmartHLS corner_turn with hand-written Verilog is worth doing, and it
     * can KILL the idea as cheaply as it can justify it:
     *   TOTAL_ACTIVE/ELAPSED LOW  -> the port is idle, the kernel is not issuing, so ANY kernel
     *                               that issues back-to-back must be faster. Rewrite is justified.
     *   TOTAL_ACTIVE/ELAPSED HIGH -> the port/DDR is already saturated and a rewrite buys NOTHING.
     * R_DATAWAIT separates the two failure modes: it counts cycles with a read outstanding but
     * RVALID low, i.e. DDR throttling US, versus us simply failing to ask.
     * Sanity anchor for the arithmetic: this stage moves 512 MB (256 read + 256 written) and is
     * measured at ~5.4 s, i.e. ~82.6 MB/s, against a FIC_0 ceiling of 64 bit x 100 MHz = 800 MB/s.
     * NOTE the counters are CYCLE counts, not beat counts -- misreading them as beats is how the
     * earlier "one outstanding transaction" story was built. W_COUNT is the only beat counter. */
    ficmon_clear();
    sar_reg_w(K_CORNER_TURN, HLS_ARG0, BUF_SCRATCH);
    sar_reg_w(K_CORNER_TURN, HLS_ARG1, sar_ctdst());
    sar_reg_w(K_CORNER_TURN, HLS_ARG2, 0u);       /* c_base  */
    sar_reg_w(K_CORNER_TURN, HLS_ARG3, 0u);       /* c_count=0 => full frame */
    sar_k_start(K_CORNER_TURN);
    if (!sar_k_wait(K_CORNER_TURN, spins)) return 0;
    /* slot 0, pass tag 4 = internal corner-turn. beats = the WRITE side (Np*Mp*4 B / 8 B per beat),
     * so W_COUNT/r[10] is a direct did-it-move-what-we-think check. */
    ficmon_snapshot(0u, 4u, (Np * Mp) / 2u);
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
          sar_reg_w(K_RESAMPLE, HLS_ARG0, sar_ctdst() + j * Mp * 4u); /* in: what CT#1 wrote */
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
    flush_range_to_ddr(SAR_RPROF_ADDR, 128u);     /* publish so a JTAG physical read sees it (16 x u64) */
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
        int r = fft1_gather_pass(&g, f32g, sar_ctdst(), BUF_SCRATCH, spins);  /* gather from SIG -> SCRATCH */
        /* Re-publish RPROF: resample_2pass()'s flush already ran (it is called earlier), so
         * FFT-1's counters [6]/[7]/[9]/[10] would otherwise sit in L2 and a JTAG physical read
         * would return stale DDR. */
        __asm volatile ("fence rw, rw");
        flush_range_to_ddr(SAR_RPROF_ADDR, 128u);
        if (r == 1) return SAR_SEQ_TIMEOUT_FFT1;
        if (r == 2) return SAR_SEQ_TIMEOUT_DMA;
        /* r == 3: the fabric coefficient generator latched err_fmt/err_dims -- fail LOUD rather
         * than finish a plausible wrong image. RPROF[11] carries the raw STAT (0xC0EF8xxx). */
        if (r == 3) return SAR_SEQ_TIMEOUT_FFT1;
        /* r == 4: a renormalize worker hart missed its 30 s deadline. The frame is PARTIALLY
         * shifted and cannot be repaired by replaying the shift, so abort. */
        if (r == 4) return SAR_SEQ_TIMEOUT_FFT1;
    } else {
        int r = fft_pass(BUF_SCRATCH, BUF_SIG, spins, 1, 0);  /* window FUSED into this pass */
        if (r == 1) return SAR_SEQ_TIMEOUT_FFT1;          /* feeder stalled */
        if (r == 2) return SAR_SEQ_TIMEOUT_DMA;            /* DMA S2MM stalled (range) */
        if (r == 3) return SAR_SEQ_TIMEOUT_FFT1;           /* renorm worker deadline miss */
    }
    sar_stage_ts[3] = readmtime();

    /* 4+5) corner-turn (CT#2) then range-axis FFT (FFT-2). Buffers: non-fused CT SIG->SCRATCH,
     * FFT-2 SCRATCH->{OUT|SIG}; gather-fused CT SCRATCH->SIG, FFT-2 SIG->{OUT|SIG}. */
    const int det_fused = (*(volatile uint32_t *)(uintptr_t)SAR_DETECTMODE_ADDR == 3u);
    const uint32_t f2_src = gather_fused ? BUF_SIG : BUF_SCRATCH;
    const uint32_t f2_dst = det_fused ? BUF_OUT : (gather_fused ? BUF_SCRATCH : BUF_SIG);
    /* STEP 2 OVERLAP (SAR_OVERLAPMODE=1): fold steps 4+5, hiding CT#2 under FFT-2 via the
     * strip-kernel pipeline. Only for the shipping gather+det-fused config (SCRATCH->SIG->OUT,
     * disjoint buffers -- see fft2_ct_overlap). Any other config falls through to sequential. */
    const int overlap = (*(volatile uint32_t *)(uintptr_t)SAR_OVERLAPMODE_ADDR == 1u)
                        && gather_fused && det_fused;
    if (overlap) {
        int r = fft2_ct_overlap(spins);
        if (r) return (sar_seq_status_t)r;
        sar_stage_ts[4] = sar_stage_ts[3];            /* corner-turn hidden under FFT-2 */
        sar_stage_ts[5] = readmtime();                /* merged CT#2 + FFT-2 wall time */
    } else {
        /* 4) corner-turn (full frame) */
        sar_reg_w(K_CORNER_TURN, HLS_ARG0, gather_fused ? BUF_SCRATCH : BUF_SIG);
        sar_reg_w(K_CORNER_TURN, HLS_ARG1, gather_fused ? BUF_SIG     : BUF_SCRATCH);
        sar_reg_w(K_CORNER_TURN, HLS_ARG2, 0u);       /* c_base  */
        sar_reg_w(K_CORNER_TURN, HLS_ARG3, 0u);       /* c_count=0 => full frame */
        sar_k_start(K_CORNER_TURN);
        if (!sar_k_wait(K_CORNER_TURN, spins)) return SAR_SEQ_TIMEOUT_CORNER;
        sar_stage_ts[4] = readmtime();
        /* 5) FFT-2. FUSED DETECT (DETECTMODE 3): unloader writes uint16 |z| to OUT, step 6 vanishes. */
        { int r = fft_pass(f2_src, f2_dst, spins, 0, det_fused);
          if (r == 1) return SAR_SEQ_TIMEOUT_FFT2;          /* feeder stalled */
          if (r == 2) return SAR_SEQ_TIMEOUT_DMA;            /* DMA S2MM stalled (azimuth) */
          if (r == 3) return SAR_SEQ_TIMEOUT_FFT2; }         /* renorm worker deadline miss */
        sar_stage_ts[5] = readmtime();
    }

    /* 6) detect (sqrt(I^2+Q^2)): SIG -> OUT (azimuth-FFT output is in SIG).
     * DEFAULT = CPU detect (correct sqrt, corr 0.97 on silicon -- the SHIPPING path). The fabric
     * detect HLS is UNFIXABLE via SmartHLS (it mis-synthesizes the negative-I sign extension no
     * matter how detect.cpp is written -> ~50% saturation); DETECTMODE 2 selects it for testing only. */
    if (det_fused) {
        /* nothing to do: the unloader produced OUT during step 5, and the uint16 renormalize
         * inside fft_fabric_pass already applied the global block exponent. */
    } else {
        /* CPU detect (correct sqrt, corr 0.97 on silicon -- the non-fused SHIPPING path).
         * NOTE (2026-07-24): DETMODE==2 (standalone HLS fabric detect, K_DETECT) was REMOVED --
         * its DIC/CIC slot 2 is now the 2nd resample lane (RES2). That HLS detect was unfixable
         * (mis-synthesized the signed narrowing -> ~50% saturation) and test-only, so no loss.
         * Read the ACTUAL FFT-2 output buffer (f2_dst): SIG in the non-fused path, SCRATCH when
         * the gather fusion flipped the buffers. */
        flush_l2_cache(1u);                                  /* read fabric-written FFT-2 out from DDR */
        cpu_detect(f2_dst, BUF_OUT, SAR_GRID * SAR_GRID);
        flush_l2_cache(1u);                                  /* push OUT to DDR for JTAG readback */
    }
    sar_stage_ts[6] = readmtime();

    /* Ensure fabric writes to OUT land in DDR before the host JTAG-dumps it.
     * (Invalidate the OUT region if it was cached non-coherently.) */
    __asm volatile ("fence rw, rw");
    return SAR_SEQ_OK;
}
