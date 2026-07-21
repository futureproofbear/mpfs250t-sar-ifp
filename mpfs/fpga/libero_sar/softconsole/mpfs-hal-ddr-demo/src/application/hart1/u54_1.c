/*******************************************************************************
 * u54_1.c -- hart 1 (U54_1): SAR fabric M2 autonomous register-verification harness.
 *
 * Drives the data-plane bring-up verification plan (dataplane_bringup_vplan.md)
 * ON-SILICON with NO debugger in the loop, then latches a result table the host
 * reads with ONE short JTAG burst (the new OpenOCD HID can't sustain more).
 *
 * Safety: a machine-mode trap handler catches load/store ACCESS FAULTS (mcause
 * 5/7), records them, and skips the faulting instruction -- so the harness can
 * probe addresses that bus-fault (e.g. the DMA slave) WITHOUT hanging. All kernel
 * waits are bounded (M2_SPINS) so a stuck kernel yields HANG, never a lock-up.
 *
 * Result record (5x u32) at M2_RESULTS_ADDR, plus summary globals:
 *   status: 0 PASS | 1 FAIL | 2 FAULT | 3 HANG | 4 SKIP
 ******************************************************************************/
#include "mpfs_hal/mss_hal.h"
#include <string.h>
#include "../../sar/ddr_sar_layout.h"   /* SAR_*_ADDR, SAR_COEF_IDX/WQ, SAR_GRID_MAX */
#include "../../sar/sar_kernels.h"      /* K_* (incl K_FFT_UNLOADER), HLS_*, sar_reg_w/r, sar_k_* */
#include "../../sar/sar_sequencer.h"    /* sar_form_image() -- full PFA pipeline (M3) */
#ifdef SAR_EMMC_ENABLE
#include "../../sar/sar_emmc.h"         /* sar_emmc_selftest() -- Milestone-1 eMMC round trip */
#endif

#define MSS_SYSREG_BASE  0x20002000u    /* always-responsive MSS regs (no fabric dependency) */
#define SUBBLK_CLOCK_CR  (MSS_SYSREG_BASE + 0x84u)  /* bit24-27 = FIC0-3 clock enable */
#define SOFT_RESET_CR    (MSS_SYSREG_BASE + 0x88u)  /* bit24-27 = FIC0-3 reset (1=held) */
#define FIC_BITS_MASK    0x0F000000u                /* FIC0..FIC3 (bits 24..27) */

/* FIC0_S transaction monitor (sar_fic0s_mon.v) -- NEVER BUILT. Do not enable it blind.
 * 0x6000_6000 is AXIIC_CTRL slave6, which is NOT in the shipping fabric: reading an
 * unmapped slave window hangs the AXI un-haltably. The slot is also earmarked for a second
 * resample instance (K_RESAMPLE2) if the ID_FIX response-routing limitation is ever fixed,
 * in which case MON_STATUS would alias that kernel's START/busy word and enabling this
 * would corrupt an image mid-gather. Either way the #error below makes it fail at compile
 * time. To resurrect the monitor, give it its own free window and confirm it is in the
 * programmed bitstream first. */
#define MON_BASE         0x60006000u
#define MON_STATUS       (MON_BASE + 0x00u)   /* [0]ar_valid [1]ar_accepted [2]r_valid [3]r_accepted [4]r_last [6:5]rresp [15:8]ar_cnt [23:16]r_cnt [31:24]0xA5 */
#define MON_ARADDR_LO    (MON_BASE + 0x04u)
#define MON_ARADDR_HI    (MON_BASE + 0x08u)
#define MON_IDS          (MON_BASE + 0x0Cu)
#define M2_PROBE_MON     0
#if M2_PROBE_MON
#error "M2_PROBE_MON aliases K_RESAMPLE2 at 0x6000_6000 -- move the monitor to a free slave window"
#endif

#define M2_RESULTS_ADDR  0xB0050000u    /* unused DDR gap (job 0xB0040000 .. geom 0xB0100000) */
#define M2_MAX_REC       24u
#define M2_SPINS         0x02000000u    /* bounded kernel wait (~1 s), not the 0x40000000 default */
#define M2_MAGIC_DONE    0xC0FFEE02u

/* ---- Host->hart CRC mailbox -------------------------------------------------
 * After the M2 battery the hart enters a command loop watching this DDR mailbox,
 * so the host can verify a JTAG-loaded region WITHOUT the slow dump+cmp readback:
 * load data, write {base,len}+cmd, RESUME the hart, wait, then JTAG-read .result.
 * CRC32 is IEEE-802.3 reflected (poly 0xEDB88320, init/xorout 0xFFFFFFFF) =
 * Python zlib.crc32 (ddr_layout.crc32), so .result compares directly to the host. */
#define M2_MBX_ADDR      0xB0058000u    /* in the same DDR gap, clear of the 480 B result table */
#define MBX_CMD_CRC32    0x43524333u    /* 'CRC3' : CRC32 over [base, base+len)                  */
#define MBX_CMD_PIPE     0x50495045u    /* 'PIPE' : run full SAR PFA pipeline (sar_form_image),  */
                                        /*          .len = spin_limit (0=default); .result =     */
                                        /*          sar_seq_status_t (0=OK, else failing stage)  */
#define MBX_CMD_FFTHOLD  0x46484C44u    /* 'FHLD' : arm DMA + start FFT feeder, do NOT wait --   */
                                        /*          holds the stream stall live for SmartDebug   */
#define MBX_CMD_EMMC     0x454D4D43u    /* 'EMMC' : Milestone-1 eMMC write/read/CRC round trip.  */
                                        /*          .base = scratch LBA (0 = default OUT region); */
                                        /*          .result = verdict (0=PASS); details latched   */
                                        /*          at SAR_EMMC_RESULT_ADDR. Needs -DSAR_EMMC_ENABLE. */
#define MBX_CMD_EMMC_PROV 0x45505256u   /* 'EPRV' : Milestone-2 provision -- bulk-write a packed  */
                                        /*          'SARI' image from DDR to the INPUT partition. */
                                        /*          .base = DDR src addr (host-restored image);   */
                                        /*          .len  = image bytes (block-multiple; probe a  */
                                        /*          small span first for rate). Dest LBA fixed =   */
                                        /*          SAR_EMMC_IN_LBA. .result = verdict; timed       */
                                        /*          record at SAR_EMMC_PROV_RESULT_ADDR.           */
#define MBX_CMD_EMMC_LOAD 0x454C4F44u   /* 'ELOD' : M3 boot-load INPUT eMMC->DDR (segs->role addrs */
                                        /*          + JOB). .base = scene index (0). record@LOAD.  */
#define MBX_CMD_EMMC_SAVE 0x45534156u   /* 'ESAV' : M3 write full OUT (DDR) -> SARO. .base=scene_id */
                                        /*          .len=run_seq. rows=cols=8192. record@SAVE.     */
#define MBX_CMD_EMMC_ROI  0x45524F49u   /* 'EROI' : M3 crop OUT[r0:r1,c0:c1] from DDR -> stage.    */
#define MBX_CMD_EMMC_ROIE 0x45524F45u   /* 'EROE' : same, but read OUT rows from SARO (later run). */
                                        /*          .base=(r0<<16)|r1  .len=(c0<<16)|c1. rec@ROI.  */
#define MBX_CMD_EMMC_VOUT 0x45564F55u   /* 'EVOU' : full-image integrity check of persisted OUT     */
                                        /*          (recompute CRC vs SARO TOC). rec@VERIFY.        */
#define MBX_DONE_MAGIC   0xC0FFEE03u    /* hart sets .status to this when .result is valid */
typedef struct {
    volatile uint32_t cmd;      /* host writes a command; hart clears to 0 to ack */
    volatile uint32_t base;     /* region base (physical, cached DDR window)       */
    volatile uint32_t len;      /* region length in bytes                          */
    volatile uint32_t result;   /* hart writes CRC32 here                          */
    volatile uint32_t status;   /* hart writes MBX_DONE_MAGIC when result is valid */
    volatile uint32_t seq;      /* hart increments per completed command           */
} m2_mbx_t;

/* zlib-compatible CRC-32 (reflected). Bytewise: 8 MB ~tens of ms, 97 MB ~couple s
 * at DDR speed -- negligible next to the JTAG load it replaces verifying. */
static uint32_t crc32_ieee(const uint8_t *p, uint32_t n)
{
    uint32_t c = 0xFFFFFFFFu;
    for (uint32_t i = 0u; i < n; i++) {
        c ^= p[i];
        for (uint32_t k = 0u; k < 8u; k++)
            c = (c >> 1) ^ (0xEDB88320u & (uint32_t)(-(int32_t)(c & 1u)));
    }
    return c ^ 0xFFFFFFFFu;
}

typedef struct { uint32_t tag, addr, observed, expected, status; } m2_rec_t;
enum { M2_PASS = 0u, M2_FAIL = 1u, M2_FAULT = 2u, M2_HANG = 3u, M2_SKIP = 4u };

/* Summary globals (host reads these first -- only ~7 mdw, always within HID budget). */
volatile uint32_t g_m2_done = 0u, g_m2_total = 0u, g_m2_pass = 0u, g_m2_fail = 0u, g_m2_fault_cnt = 0u;
volatile uint32_t g_m2_first_fail = 0xFFFFFFFFu;

/* Trap-handler shared state. */
volatile uint32_t g_m2_fault = 0u, g_m2_fault_cause = 0u, g_m2_fault_addr = 0u, g_m2_fault_epc = 0u;

/* Machine-mode trap handler: recover load/store access faults; park on anything
 * unexpected (visible to the host via g_m2_fault_cause/epc). Interrupts are masked
 * during the harness so only synchronous exceptions reach here. */
void __attribute__((interrupt("machine"), aligned(64))) m2_trap_handler(void)
{
    unsigned long cause = read_csr(mcause);
    unsigned long epc   = read_csr(mepc);
    if (cause == 5u || cause == 7u) {               /* load / store access fault */
        g_m2_fault       = 1u;
        g_m2_fault_cause = (uint32_t)cause;
        g_m2_fault_addr  = (uint32_t)read_csr(mtval);
        g_m2_fault_epc   = (uint32_t)epc;
        uint16_t insn = *(volatile uint16_t *)(uintptr_t)epc;   /* skip the faulting insn */
        write_csr(mepc, epc + (((insn & 3u) == 3u) ? 4u : 2u)); /* 4 B if !compressed else 2 B */
    } else {
        g_m2_fault       = 0xBADu;
        g_m2_fault_cause = (uint32_t)cause;
        g_m2_fault_epc   = (uint32_t)epc;
        for (;;) { ; }                              /* unexpected: park for inspection */
    }
}

static m2_rec_t *m2_tbl(void) { return (m2_rec_t *)(uintptr_t)M2_RESULTS_ADDR; }

static void m2_rec(uint32_t tag, uint32_t addr, uint32_t obs, uint32_t exp, uint32_t status)
{
    if (g_m2_total < M2_MAX_REC) {
        m2_rec_t *r = &m2_tbl()[g_m2_total];
        r->tag = tag; r->addr = addr; r->observed = obs; r->expected = exp; r->status = status;
    }
    g_m2_total++;
    if (status == M2_PASS) {
        g_m2_pass++;
    } else {
        if (status == M2_FAULT) g_m2_fault_cnt++; else g_m2_fail++;
        if (g_m2_first_fail == 0xFFFFFFFFu) g_m2_first_fail = tag;
    }
    __asm volatile ("fence rw, rw");
}

/* Trap-protected 32-bit read: returns sentinel + sets *flt on a bus fault. */
static uint32_t m2_safe_r(uintptr_t addr, int *flt)
{
    g_m2_fault = 0u;
    __asm volatile ("fence rw, rw");
    uint32_t v = *(volatile uint32_t *)addr;        /* may fault -> handler skips it */
    __asm volatile ("fence rw, rw");
    if (g_m2_fault == 1u) { *flt = 1; return 0xDEADFA17u; }
    *flt = 0; return v;
}

/* Bounded kernel-done wait: 1 = went idle (done), 0 = timed out (HANG). */
static int m2_k_wait(uint32_t base)
{
    uint32_t s = M2_SPINS;
    while (s--) { if (sar_reg_r(base, HLS_START) == 0u) return 1; }
    return 0;
}

/* PRBS DDR data-integrity memtest -- on-target, runs at DDR speed (no JTAG bulk transfer).
 * 32-bit maximal Galois LFSR (poly 0x80200003) gives a pseudo-random binary sequence that
 * toggles every data line and walks the address bus, catching stuck-at/coupling/aliasing the
 * way real (low-entropy) SAR data won't. Write-all then read-all-compare over [base,base+4*words);
 * the region must exceed L2 (~2 MB) so the read-back hits DRAM, not cache. Returns mismatch count;
 * on first error fills *fa/*fe/*fg = addr/expected/got. */
static inline uint32_t prbs_step(uint32_t s)
{
    return (s >> 1) ^ (uint32_t)(-(int32_t)(s & 1u) & 0x80200003);
}
static uint32_t m2_prbs_memtest(uintptr_t base, uint32_t words,
                                uint32_t *fa, uint32_t *fe, uint32_t *fg)
{
    volatile uint32_t *p = (volatile uint32_t *)base;
    uint32_t s = 0xACE1ACE1u;                                  /* fixed seed (regenerable) */
    for (uint32_t i = 0u; i < words; i++) { p[i] = s; s = prbs_step(s); }
    __asm volatile ("fence rw, rw");
    s = 0xACE1ACE1u;
    uint32_t errs = 0u;
    for (uint32_t i = 0u; i < words; i++) {
        uint32_t v = p[i];
        if (v != s) { if (errs == 0u) { *fa = (uint32_t)(base + 4u * i); *fe = s; *fg = v; } errs++; }
        s = prbs_step(s);
    }
    return errs;
}

static void m2_run_tests(void)
{
    int flt;
    uint32_t v;

    /* T0 -- MSS fabric-interface clock/reset state. These MSS SYSREG regs always
     * respond (no fabric dependency), so this is a SAFE on-silicon discriminator
     * for the data-plane-dead hypothesis. PASS = all 4 FIC clocks enabled / all 4
     * FIC resets released; a cleared clock bit or set reset bit => MSS-side gating
     * (clock or reset), pointing away from a pure Libero fabric-CCC/decode issue. */
    v = m2_safe_r(SUBBLK_CLOCK_CR, &flt);
    m2_rec(0x01u, SUBBLK_CLOCK_CR, v, FIC_BITS_MASK,
           (!flt && (v & FIC_BITS_MASK) == FIC_BITS_MASK) ? M2_PASS : M2_FAIL);
    v = m2_safe_r(SOFT_RESET_CR, &flt);
    m2_rec(0x02u, SOFT_RESET_CR, v, 0u,
           (!flt && (v & FIC_BITS_MASK) == 0u) ? M2_PASS : M2_FAIL);

    /* T1 -- control-plane decode probe: the 5 populated kernel slaves' START/STATUS (+0x08).
     * decoded+idle => PASS; decoded+busy => FAIL; bus-fault => FAULT. HLS-FFT build: SLAVE5
     * (0x60005000) is UNUSED (the fft_unloader is gone; the fft_kernel on SLAVE4 replaces the
     * whole feeder+unloader chain). Do NOT probe 0x60005000 -- with no slave connected the CIC
     * routes the read to a dead target and it HANGS the AXI un-haltably (wedges JTAG examine). */
    /* DET removed from fabric (CPU detect ships) -> K_DETECT (SLAVE2, 0x60002000) is now a DEAD
     * target: the CIC routes a read there to nothing and it HANGS the AXI un-haltably (same trap as
     * the SLAVE5 note above; m2_safe_r cannot catch a non-responding target -> wedges JTAG examine at
     * boot). MUST drop K_DETECT from the decode probe now that the instance is gone. */
    const uint32_t slv[4] = { K_CORNER_TURN, K_WINDOW, K_RESAMPLE, K_FFT };
    for (uint32_t i = 0u; i < 4u; i++) {
        v = m2_safe_r(slv[i] + HLS_START, &flt);
        m2_rec(0x10u + i, slv[i] + HLS_START, v, 0u,
               flt ? M2_FAULT : (v == 0u ? M2_PASS : M2_FAIL));
    }

    /* T2 -- AXI4-Lite latch: write a distinct pattern to each RESAMPLE ARG, read back. */
    for (uint32_t a = 0u; a < 4u; a++) {
        uint32_t off = HLS_ARG0 + a * 4u;
        uint32_t pat = 0xA5A50000u | (a << 8) | 0x5Au;
        sar_reg_w(K_RESAMPLE, off, pat);
        v = m2_safe_r(K_RESAMPLE + off, &flt);
        m2_rec(0x20u + a, K_RESAMPLE + off, v, pat, (!flt && v == pat) ? M2_PASS : M2_FAIL);
    }

    /* T3 -- resample data-plane ladder L1: coeff idx=-1 (zero-fill, no SIG gather),
     * SCRATCH sentinel; start; bounded wait; require done AND SCRATCH changed.
     * Isolates whether the kernel's AXI master can read the coeff bank + write SCRATCH. */
    {
        int32_t *idx = (int32_t *)(uintptr_t)SAR_COEF_IDX(0);
        int16_t *wq  = (int16_t *)(uintptr_t)SAR_COEF_WQ(0);
        for (uint32_t j = 0u; j < SAR_GRID_MAX; j++) { idx[j] = -1; wq[j] = 0; }
        volatile uint32_t *scr = (volatile uint32_t *)(uintptr_t)SAR_SCRATCH_ADDR;
        scr[0] = 0xDEADBEEFu; scr[1] = 0xDEADBEEFu;
        __asm volatile ("fence rw, rw");
        sar_reg_w(K_RESAMPLE, HLS_ARG0, (uint32_t)SAR_SIG_ADDR);
        sar_reg_w(K_RESAMPLE, HLS_ARG1, (uint32_t)SAR_COEF_IDX(0));
        sar_reg_w(K_RESAMPLE, HLS_ARG2, (uint32_t)SAR_COEF_WQ(0));
        sar_reg_w(K_RESAMPLE, HLS_ARG3, (uint32_t)SAR_SCRATCH_ADDR);
        sar_k_start(K_RESAMPLE);
        int done = m2_k_wait(K_RESAMPLE);
        __asm volatile ("fence rw, rw");
        /* Do NOT CPU-read SCRATCH here: a hung kernel mid-DDR-transaction could
         * stall this load un-haltably. Record the completion verdict from the
         * (responsive) kernel slave only; the host JTAG-reads SCRATCH[0]
         * (0x98000000) separately to check dst-change vs the 0xDEADBEEF sentinel. */
        m2_rec(0x30u, K_RESAMPLE, sar_reg_r(K_RESAMPLE, HLS_START), 0xDEADBEEFu,
               done ? M2_PASS : M2_HANG);
    }

    /* T4 -- REMOVED. It armed the resample with a NULL (0x0) source pointer, whose AXI
     * burst read to the unmapped 0x0 region HANGS the kernel permanently (no bus
     * response). That left K_RESAMPLE wedged (busy=1) for the whole session, so the
     * real pipeline's resample could never run -> RETURN=2 (RESAMPLE timeout). A boot
     * self-test must never leave a kernel in a stuck state. */

    /* T7 -- PRBS DDR data-integrity memtest (on-target, 64 MB of SCRATCH > L2 -> exercises DRAM). */
    {
        uint32_t fa = 0u, fe = 0u, fg = 0u;
        uint32_t errs = m2_prbs_memtest((uintptr_t)SAR_SCRATCH_ADDR, 0x04000000u / 4u, &fa, &fe, &fg);
        m2_rec(0x70u, (uint32_t)SAR_SCRATCH_ADDR, errs, 0u, errs ? M2_FAIL : M2_PASS);
        if (errs) m2_rec(0x71u, fa, fg, fe, M2_FAIL);    /* first mismatch: addr | got | expected */
    }

    /* T5 -- HLS fft_kernel slave (@0x60004000, control SLAVE4). Replaces the entire CoreFFT
     * streaming chain (feeder + gearbox + CoreFFT + unloader). Read its START/ARG registers:
     * bus-fault => FAULT, else PASS. (SLAVE5 @0x60005000 is unused and MUST NOT be read -- a
     * read there hangs the AXI un-haltably, so this probes the fft_kernel on SLAVE4 instead.) */
    {
        const uint32_t off[4] = { HLS_START, HLS_ARG0, HLS_ARG1, HLS_ARG2 };
        for (uint32_t i = 0u; i < 4u; i++) {
            v = m2_safe_r(K_FFT + off[i], &flt);
            m2_rec(0x50u + i, K_FFT + off[i], v, 0u, flt ? M2_FAULT : M2_PASS);
        }
    }

    /* T6 -- FIC0_S monitor verdict (needs sar_fic0s_mon in the bitstream). Decodes the
     * AR/R handshake the resample read actually got. Records the raw STATUS + the captured
     * ARADDR, plus a verdict: PASS if the read completed (r_accepted), else FAIL/HANG with
     * the stuck stage visible in STATUS bits. Reading is safe only once slave6 exists. */
#if M2_PROBE_MON
    {
        uint32_t st  = m2_safe_r(MON_STATUS, &flt);
        uint32_t alo = m2_safe_r(MON_ARADDR_LO, &flt);
        m2_rec(0x60u, MON_STATUS, st, 0xA5u << 24,
               flt ? M2_FAULT
                   : ((st & 0x8u) ? M2_PASS                 /* r_accepted: data returned */
                      : ((st & 0x2u) ? M2_FAIL              /* AR accepted, no R -> ID/response routing */
                         : ((st & 0x1u) ? M2_HANG           /* ARVALID, no ARREADY -> MSS not accepting */
                            : M2_SKIP))));                  /* no AR at all -> upstream stall */
        m2_rec(0x61u, MON_ARADDR_LO, alo, 0xB0148000u, M2_SKIP);
    }
#endif
}

void u54_1(void)
{
    while (0u == (read_csr(mip) & MIP_MSIP)) { ; }   /* wait for E51 wake */
    clear_soft_interrupt();

    /* Mask async interrupts and install the fault-recovery trap vector (direct mode). */
    clear_csr(mstatus, MSTATUS_MIE);
    write_csr(mie, 0);
    write_csr(mtvec, (uintptr_t)m2_trap_handler);

    /* Clear the result table, run the battery, latch completion. */
    memset((void *)(uintptr_t)M2_RESULTS_ADDR, 0, M2_MAX_REC * sizeof(m2_rec_t));
    m2_run_tests();
    __asm volatile ("fence rw, rw");
    g_m2_done = M2_MAGIC_DONE;

    /* Command loop: serve host CRC-verify requests (and stay alive via heartbeat).
     * Single-hart coherency: the host loads data and writes the mailbox via THIS
     * hart's progbuf stores while halted, so on resume the hart reads a coherent
     * view of both the region and the command -- no cache flush needed. */
    m2_mbx_t *mbx = (m2_mbx_t *)(uintptr_t)M2_MBX_ADDR;
    mbx->cmd = 0u; mbx->status = 0u; mbx->result = 0u; mbx->seq = 0u;
    __asm volatile ("fence rw, rw");

    static volatile uint32_t heartbeat = 0u;
    for (;;) {
        heartbeat++;
        if (mbx->cmd == MBX_CMD_CRC32) {
            __asm volatile ("fence rw, rw");
            uint32_t crc = crc32_ieee((const uint8_t *)(uintptr_t)mbx->base, mbx->len);
            mbx->result = crc;
            __asm volatile ("fence rw, rw");
            mbx->status = MBX_DONE_MAGIC;
            mbx->seq    = mbx->seq + 1u;
            __asm volatile ("fence rw, rw");
            mbx->cmd    = 0u;                 /* ack: ready for the next command */
            __asm volatile ("fence rw, rw");
        }
#ifdef SAR_EMMC_ENABLE
        else if (mbx->cmd == MBX_CMD_EMMC) {
            /* Milestone-1: init eMMC + single-block write/read/CRC round trip.
             * .base reinterpreted as the scratch LBA (0 -> default OUT region);
             * .result = verdict, full record at SAR_EMMC_RESULT_ADDR. */
            __asm volatile ("fence rw, rw");
            mbx->result = sar_emmc_selftest(mbx->base ? mbx->base : SAR_EMMC_SCRATCH_LBA);
            __asm volatile ("fence rw, rw");
            mbx->status = MBX_DONE_MAGIC;
            mbx->seq    = mbx->seq + 1u;
            __asm volatile ("fence rw, rw");
            mbx->cmd    = 0u;
            __asm volatile ("fence rw, rw");
        }
        else if (mbx->cmd == MBX_CMD_EMMC_PROV) {
            /* Milestone-2: bulk-provision a packed 'SARI' image (host-restored to
             * .base in DDR, .len bytes) to the INPUT partition, read back + CRC
             * verify, timing the write. Dest is the fixed INPUT base LBA. */
            __asm volatile ("fence rw, rw");
            mbx->result = sar_emmc_provision(mbx->base, mbx->len,
                                             (uint32_t)SAR_EMMC_IN_LBA);
            __asm volatile ("fence rw, rw");
            mbx->status = MBX_DONE_MAGIC;
            mbx->seq    = mbx->seq + 1u;
            __asm volatile ("fence rw, rw");
            mbx->cmd    = 0u;
            __asm volatile ("fence rw, rw");
        }
        else if (mbx->cmd == MBX_CMD_EMMC_LOAD) {
            /* M3: load the scene from eMMC INPUT into the pipeline DDR layout + JOB. */
            __asm volatile ("fence rw, rw");
            mbx->result = sar_emmc_load(mbx->base);
            __asm volatile ("fence rw, rw");
            mbx->status = MBX_DONE_MAGIC; mbx->seq = mbx->seq + 1u;
            __asm volatile ("fence rw, rw");
            mbx->cmd = 0u;
            __asm volatile ("fence rw, rw");
        }
        else if (mbx->cmd == MBX_CMD_EMMC_SAVE) {
            /* M3: persist the full OUT image (8192x8192 uint16) to eMMC SARO. */
            __asm volatile ("fence rw, rw");
            mbx->result = sar_emmc_save_out((uint32_t)SAR_GRID_MAX, (uint32_t)SAR_GRID_MAX,
                                            mbx->base, mbx->len);
            __asm volatile ("fence rw, rw");
            mbx->status = MBX_DONE_MAGIC; mbx->seq = mbx->seq + 1u;
            __asm volatile ("fence rw, rw");
            mbx->cmd = 0u;
            __asm volatile ("fence rw, rw");
        }
        else if (mbx->cmd == MBX_CMD_EMMC_ROI || mbx->cmd == MBX_CMD_EMMC_ROIE) {
            /* M3: gather OUT[r0:r1,c0:c1] -> SAR_EMMC_ROI_STAGE_ADDR for a fast JTAG dump. */
            uint32_t from_emmc = (mbx->cmd == MBX_CMD_EMMC_ROIE) ? 1u : 0u;
            __asm volatile ("fence rw, rw");
            mbx->result = sar_emmc_roi(mbx->base >> 16, mbx->base & 0xFFFFu,
                                       mbx->len >> 16, mbx->len & 0xFFFFu, from_emmc);
            __asm volatile ("fence rw, rw");
            mbx->status = MBX_DONE_MAGIC; mbx->seq = mbx->seq + 1u;
            __asm volatile ("fence rw, rw");
            mbx->cmd = 0u;
            __asm volatile ("fence rw, rw");
        }
        else if (mbx->cmd == MBX_CMD_EMMC_VOUT) {
            /* M3: full-image integrity check of the persisted OUT (torn-write detect). */
            __asm volatile ("fence rw, rw");
            mbx->result = sar_emmc_verify_out();
            __asm volatile ("fence rw, rw");
            mbx->status = MBX_DONE_MAGIC; mbx->seq = mbx->seq + 1u;
            __asm volatile ("fence rw, rw");
            mbx->cmd = 0u;
            __asm volatile ("fence rw, rw");
        }
#endif
        else if (mbx->cmd == MBX_CMD_PIPE) {
            /* Full PFA pipeline over the JTAG-loaded scene+JOB. Bounded per-stage
             * waits inside sar_form_image mean a stuck kernel yields a TIMEOUT
             * status, never an un-haltable lock-up. .result = stage code. */
            /* FIC0 is NON-COHERENT: the host loads the scene+tables over JTAG through
             * the U54 cache, so the data sits in L2, NOT in the DDR the fabric kernels
             * read via FIC0. Flush L2 -> DDR here so the kernels see the real loaded
             * data (without this the whole pipeline runs on stale/zero DDR -> all-zero
             * output; see the sar_sequencer.c non-coherent-FIC0 caveat). */
            flush_l2_cache(1u);
            __asm volatile ("fence rw, rw");
            sar_seq_status_t s = sar_form_image(mbx->len);   /* .len = spin_limit (0=default) */
            /* Invalidate stale OUT L2 lines so the host's JTAG read of OUT (0xA8M) fetches
             * the kernel-written DDR image, not a stale cached copy. */
            flush_l2_cache(1u);
            mbx->result = (uint32_t)s;
            /* fft_kernel diagnostic snapshot (control reads are known-good): host reads these words
             * at M2_MBX_ADDR+0x20 to see the fft_kernel state when sar_form_image reports an FFT
             * timeout (result 4/6). NOTE: must NOT read K_FFT_UNLOADER (0x60005000) -- that slave is
             * unused in the HLS-FFT fabric and a read there hangs the AXI un-haltably. */
            volatile uint32_t *dbg = (volatile uint32_t *)(uintptr_t)(M2_MBX_ADDR + 0x20u);
            dbg[0] = sar_reg_r(K_FFT, HLS_START);  /* fft_kernel busy (nonzero = still running) */
            dbg[1] = sar_reg_r(K_FFT, HLS_ARG0);   /* src base */
            dbg[2] = sar_reg_r(K_FFT, HLS_ARG1);   /* dst base */
            dbg[3] = sar_reg_r(K_FFT, HLS_ARG2);   /* nrows */
            dbg[4] = 0u;
            dbg[5] = 0u;
            dbg[6] = 0u;
            dbg[7] = 0u;
            __asm volatile ("fence rw, rw");
            mbx->status = MBX_DONE_MAGIC;
            mbx->seq    = mbx->seq + 1u;
            __asm volatile ("fence rw, rw");
            mbx->cmd    = 0u;
            __asm volatile ("fence rw, rw");
        } else if (mbx->cmd == MBX_CMD_FFTHOLD) {
            /* Arm unloader + start feeder, no wait: leaves the FFT streaming path live in
             * fabric so SmartDebug can probe the output handshake. ACK
             * immediately; the host then kills OpenOCD and probes at leisure. */
            __asm volatile ("fence rw, rw");
            sar_fft_hold();
            mbx->result = 0u;
            __asm volatile ("fence rw, rw");
            mbx->status = MBX_DONE_MAGIC;
            mbx->seq    = mbx->seq + 1u;
            __asm volatile ("fence rw, rw");
        } else if (mbx->cmd == 0x46544553u) {   /* 'FTES': run fft_pass on SCRATCH (keeps symbol; also GDB-callable) */
            mbx->result = (uint32_t)sar_fft_pass_test();
            __asm volatile ("fence rw, rw");
            mbx->status = MBX_DONE_MAGIC;
            mbx->seq    = mbx->seq + 1u;
            __asm volatile ("fence rw, rw");
            mbx->cmd    = 0u;
            __asm volatile ("fence rw, rw");
        } else if (mbx->cmd == 0x53434C45u) {   /* 'SCLE': SCALE_EXP-capture isolation test (keeps symbol; GDB-callable) */
            mbx->result = (uint32_t)sar_fabric_scale_test();
            __asm volatile ("fence rw, rw");
            mbx->status = MBX_DONE_MAGIC;
            mbx->seq    = mbx->seq + 1u;
            __asm volatile ("fence rw, rw");
            mbx->cmd    = 0u;
            __asm volatile ("fence rw, rw");
        }
    }
}
