/* sar_fft.c -- CPU (MSS U54) fixed-point radix-2 DIT 8192-pt FFT. See sar_fft.h.
 * W[k] = twRe[k] + j*twIm[k] = cos(2pi k/N) - j*sin(2pi k/N)  (Q15), matches np.fft.fft.
 * Per-stage >>1 keeps the datapath in int16 range (== 1/N normalized output). */
#include "sar_fft.h"
#include "sar_fft_twiddle.h"        /* const int16_t twRe[FN/2], twIm[FN/2] (precomputed -- no libm) */

#define FN       8192
#define FSTAGES  13
#define SAR_PROG_ADDR 0xB0059100u    /* [0]=pass [1]=idx [2]=total [3]=heartbeat (JTAG-pollable) */

static uint16_t brev[FN];
static int32_t  re[FN];              /* static working buffers (64 KB, off-stack, L2-resident) */
static int32_t  im[FN];
static int      inited = 0;

static void fft_init(void)
{
    for (unsigned i = 0; i < FN; i++) {   /* bit-reversal table (pure bit ops, no libm) */
        unsigned r = 0, x = i;
        for (int b = 0; b < FSTAGES; b++) { r = (r << 1) | (x & 1u); x >>= 1; }
        brev[i] = (uint16_t)r;
    }
    inited = 1;
}

void sar_cpu_fft(const uint32_t *src, uint32_t *dst, uint32_t nrows)
{
    volatile uint32_t *pg = (volatile uint32_t *)(uintptr_t)SAR_PROG_ADDR;
    if (!inited) fft_init();

    /* PASS 0: L1 pre-scan -> ONE global block exponent for the whole pass. |FFT| <= the
     * row's L1 norm (sum|re|+|im|); the global max over rows gives a single shift so every
     * row is scaled the SAME (per-row exponents would corrupt the 2-D image). NO per-stage
     * >>1 (that truncates the small AC bins to zero over 13 stages -> DC-only output). */
    uint64_t gmax = 0;
    for (uint32_t row = 0; row < nrows; row++) {
        const uint32_t *s = src + (uint64_t)row * FN;
        uint64_t rowsum = 0;
        for (unsigned i = 0; i < FN; i++) {
            uint32_t v = s[i];
            int32_t r = (int32_t)(int16_t)(v >> 16), m = (int32_t)(int16_t)(v & 0xFFFFu);
            rowsum += (uint64_t)((r < 0 ? -r : r) + (m < 0 ? -m : m));
        }
        if (rowsum > gmax) gmax = rowsum;
    }
    unsigned out_shift = 0;
    { uint64_t g = gmax; while (g > 32767u) { g >>= 1; out_shift++; } }

    /* PASS 1: full-precision radix-2 FFT per row (int64 twiddle mul, no per-stage scaling),
     * then normalize by the shared block exponent. re/im stay <= gmax (<= 2.7e8) so int32 is safe. */
    for (uint32_t row = 0; row < nrows; row++) {
        if ((row & 0x7Fu) == 0u) { pg[0] = 3u; pg[1] = row; pg[2] = nrows; pg[3]++; }

        const uint32_t *s = src + (uint64_t)row * FN;
        for (unsigned i = 0; i < FN; i++) {          /* bit-reversed load */
            uint32_t v = s[i];
            unsigned j = brev[i];
            re[j] = (int32_t)(int16_t)(v >> 16);
            im[j] = (int32_t)(int16_t)(v & 0xFFFFu);
        }

        int step = FN >> 1;
        for (int stage = 1; stage <= FSTAGES; stage++) {
            int dft = 1 << stage, nbf = dft >> 1;
            for (int grp = 0; grp < FN; grp += dft) {
                for (int b = 0; b < nbf; b++) {
                    int k   = b * step;
                    int idx = grp + b, lo = idx + nbf;
                    int64_t c = twRe[k], sn = twIm[k];
                    int32_t ar = re[idx], ai = im[idx];             /* top    (full precision) */
                    int32_t br = re[lo],  bi = im[lo];              /* bottom */
                    int32_t tr = (int32_t)(((int64_t)br * c - (int64_t)bi * sn) >> 15);  /* Re(W*bottom) */
                    int32_t ti = (int32_t)(((int64_t)br * sn + (int64_t)bi * c) >> 15);  /* Im(W*bottom) */
                    re[idx] = ar + tr; im[idx] = ai + ti;           /* top'    = top + W*bottom */
                    re[lo]  = ar - tr; im[lo]  = ai - ti;           /* bottom' = top - W*bottom */
                }
            }
            step >>= 1;
        }

        uint32_t *d = dst + (uint64_t)row * FN;
        for (unsigned i = 0; i < FN; i++) {          /* block-exponent normalize + saturate */
            int32_t r = re[i] >> out_shift, m = im[i] >> out_shift;
            if (r >  32767) r =  32767; else if (r < -32768) r = -32768;
            if (m >  32767) m =  32767; else if (m < -32768) m = -32768;
            d[i] = (((uint32_t)(uint16_t)(int16_t)r) << 16) | (uint16_t)(int16_t)m;
        }
    }
    pg[0] = 3u; pg[1] = nrows; pg[2] = nrows; pg[3]++;
}
