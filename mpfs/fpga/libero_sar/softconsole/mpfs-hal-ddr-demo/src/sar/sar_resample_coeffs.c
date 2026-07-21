/* sar_resample_coeffs.c -- see header. Float math (run on a U54 hart with FPU).
 *
 * WHY THIS LOOKS DIFFERENT FROM A GENERIC INTERPOLATOR (2026-07-21)
 * Silicon profiling showed resample is 96% CPU-bound HERE: 19.94 s of the 20.78 s gather time
 * is coefficient generation, against 6.1 ms spent waiting on the fabric kernel. The generic
 * bracket search was doing two things it did not need to:
 *   pass 1 -- searching a grid that is UNIFORM. scratch[j] = a*(f0 + j*df) expands to
 *             (a*f0) + (a*df)*j, an arithmetic progression, so the bracket is a closed form:
 *             k = floor((q-x0)/dx). One reciprocal per LINE replaces N-1 divides per line, and
 *             the scratch[] array is not needed at all.
 *   pass 2 -- recomputing 1/(xp[k+1]-xp[k]) every line, when xp[k] = KR[j]*tan_s[k] means that
 *             span is KR[j]*(tan_s[k+1]-tan_s[k]). The tan_s difference is LINE-INVARIANT, so
 *             its reciprocal is precomputed ONCE (sar_coeffs_init) and the per-line part is a
 *             single 1/KR[j]. 46M divides over the pass become 8192.
 *
 * ACCURACY: validated against a float64 reference on the real Umbra NDSU CPHD (deci 1 and 8) --
 * see mpfs/host/check_coeff_ndsu.py. The closed form is MORE accurate than the search it
 * replaces (deci-1 pass-1 position error: max 3.47e-2 vs 5.17e-2 source samples, and 806 vs
 * 1484 wrong brackets over the sampled lines), because it never accumulates the float32
 * representation error of a materialized grid. It is NOT bit-identical to the old path, so the
 * pipeline CRC changes -- that is expected and is why the host cross-check exists.
 *
 * The generic sar_interp_coeffs() is kept: it is the reference semantics, the fallback for a
 * non-uniform or degenerate line, and what the host model mirrors.
 */
#include "sar_resample_coeffs.h"

/* ascending-view accessor: xa(k) walks xp in ascending order regardless of dir */
#define XA(arr, asc, S, k)  ((asc) ? (arr)[(k)] : (arr)[(S) - 1u - (k)])

/* Line-invariant reciprocals of the pass-2 source spacing, 1/(tan_s[k+1]-tan_s[k]).
 * Built once by sar_coeffs_init(). Sized to the padded grid so any real M fits. */
#define SAR_COEFF_MAXS 8192u
static float s_inv_tan[SAR_COEFF_MAXS];
static uint32_t s_inv_tan_n;            /* 0 = not initialised -> pass 2 falls back */

void sar_coeffs_init(const sar_geom_t *g)
{
    s_inv_tan_n = 0u;
    if (g->M < 2u || g->M > SAR_COEFF_MAXS) return;
    for (uint32_t k = 0; k + 1u < g->M; k++) {
        float d = g->tan_s[k + 1u] - g->tan_s[k];
        s_inv_tan[k] = (d != 0.0f) ? (1.0f / d) : 0.0f;
    }
    s_inv_tan_n = g->M;
}

static inline void emit(int32_t k, float w, int32_t *idx, int16_t *wq, uint32_t qi)
{
    int32_t wi = (int32_t)(w * 32768.0f + 0.5f);
    if (wi < 0) wi = 0;
    if (wi > 32767) wi = 32767;
    idx[qi] = k;
    wq[qi] = (int16_t)wi;
}

void sar_interp_coeffs(const float *query, uint32_t Q,
                       const float *xp, uint32_t S,
                       int32_t *idx, int16_t *wq)
{
    if (S < 2u) {
        for (uint32_t i = 0; i < Q; i++) { idx[i] = -1; wq[i] = 0; }
        return;
    }
    int asc = (xp[S - 1u] >= xp[0]);
    float xlo = XA(xp, asc, S, 0u);
    float xhi = XA(xp, asc, S, S - 1u);
    uint32_t k = 0;                       /* moving bracket: xa[k] <= q < xa[k+1] */
    float x0 = XA(xp, asc, S, 0u);
    float x1 = XA(xp, asc, S, 1u);
    float inv = (x1 != x0) ? 1.0f / (x1 - x0) : 0.0f;
    for (uint32_t qi = 0; qi < Q; qi++) {
        float q = query[qi];
        if (q < xlo || q >= xhi) { idx[qi] = -1; wq[qi] = 0; continue; }
        while (k + 2u < S && XA(xp, asc, S, k + 1u) <= q) {
            k++;
            x0 = XA(xp, asc, S, k);
            x1 = XA(xp, asc, S, k + 1u);
            inv = (x1 != x0) ? 1.0f / (x1 - x0) : 0.0f;
        }
        float frac = (q - x0) * inv;
        if (asc) emit((int32_t)k,            frac,        idx, wq, qi);
        else     emit((int32_t)(S - 2u - k), 1.0f - frac, idx, wq, qi);
    }
}

/* Closed-form coefficients for a UNIFORM source grid xp[j] = x0 + j*dx.
 *
 *   t = (q - x0)/dx ,  k = floor(t) ,  frac = t - k
 * because q - xp[k] = dx*(t-k) and xp[k+1]-xp[k] = dx, so frac = dx(t-k)/dx = t-k exactly.
 * In-range reduces to 0 <= t < S-1.
 *
 * Handles a DESCENDING grid (dx < 0) without a separate case: t still increases as q moves
 * away from x0, floor(t) is already the NATURAL index, and frac is already the weight toward
 * index+1 -- so no ascending-view conversion is needed (unlike the generic path above). */
static void sar_uniform_coeffs(const float *query, uint32_t Q,
                               float x0, float dx, uint32_t S,
                               int32_t *idx, int16_t *wq)
{
    if (S < 2u || dx == 0.0f) {
        for (uint32_t i = 0; i < Q; i++) { idx[i] = -1; wq[i] = 0; }
        return;
    }
    const float inv  = 1.0f / dx;                 /* the ONLY divide in the whole line */
    const float tmax = (float)(S - 1u);
    for (uint32_t qi = 0; qi < Q; qi++) {
        float t = (query[qi] - x0) * inv;
        if (!(t >= 0.0f) || t >= tmax) { idx[qi] = -1; wq[qi] = 0; continue; }
        int32_t k = (int32_t)t;                   /* t >= 0, so truncation == floor */
        emit(k, t - (float)k, idx, wq, qi);
    }
}

void sar_coeffs_pass1(const sar_geom_t *g, uint32_t i,
                      float *scratch, int32_t *idx, int16_t *wq)
{
    /* kr[i,j] = 2*pr[i]/C * (f0[i] + j*df[i]) = x0 + j*dx -- uniform, so no grid is built and
     * no search is run. `scratch` is unused now; kept in the signature for the ABI. */
    (void)scratch;
    float a  = 2.0f * g->pr[i] / SAR_C_LIGHT;
    float x0 = a * g->f0[i];
    float dx = a * g->df[i];
    sar_uniform_coeffs(g->KR, g->Np, x0, dx, g->N, idx, wq);
}

void sar_coeffs_pass2(const sar_geom_t *g, uint32_t j,
                      float *scratch, int32_t *idx, int16_t *wq)
{
    /* src[k] = KR[j]*tan_s[k]. NOT uniform, so the bracket scan stays -- but the span is
     *     src[k+1]-src[k] = KR[j] * (tan_s[k+1]-tan_s[k])
     * whose second factor does not depend on j. Precomputed reciprocal * (1/KR[j]) replaces a
     * divide per bracket with a multiply, and the source is compared on the fly so the
     * scratch[] array is never materialized. */
    const uint32_t S = g->M;
    const float kr = g->KR[j];

    if (S < 2u || kr == 0.0f || s_inv_tan_n != S) {   /* degenerate / not initialised */
        if (S >= 2u && kr != 0.0f) {                  /* faithful fallback */
            for (uint32_t k = 0; k < S; k++) scratch[k] = kr * g->tan_s[k];
            sar_interp_coeffs(g->KC, g->Mp, scratch, S, idx, wq);
        } else {
            for (uint32_t i = 0; i < g->Mp; i++) { idx[i] = -1; wq[i] = 0; }
        }
        return;
    }

    const float r = 1.0f / kr;              /* the ONLY divide in the whole line */
    const int asc = (kr >= 0.0f);           /* tan_s ascends; kr<0 flips the source order */
    /* ascending-view of src: kr*tan_s[k] for kr>0, kr*tan_s[S-1-k] for kr<0 */
    #define SRC(kk) (kr * XA(g->tan_s, asc, S, (kk)))
    /* Matching ascending-view reciprocal. For kr>0 the view span is kr*(tan_s[k+1]-tan_s[k]).
     * For kr<0 the view walks tan_s backwards, so the span is
     *     xa[k+1]-xa[k] = kr*(tan_s[S-2-k] - tan_s[S-1-k]) = -kr*(tan_s[t+1]-tan_s[t]), t=S-2-k
     * i.e. the reciprocal picks up a SIGN FLIP as well as the index reversal. Using r for both
     * cases would give a negative weight on every descending line. */
    const float rr = asc ? r : -r;
    #define INVSPAN(kk) (s_inv_tan[(asc) ? (kk) : (S - 2u - (kk))] * rr)

    const float xlo = SRC(0u), xhi = SRC(S - 1u);
    uint32_t k = 0u;
    float x0 = SRC(0u);
    float inv = INVSPAN(0u);
    for (uint32_t qi = 0; qi < g->Mp; qi++) {
        float q = g->KC[qi];
        if (q < xlo || q >= xhi) { idx[qi] = -1; wq[qi] = 0; continue; }
        while (k + 2u < S && SRC(k + 1u) <= q) {
            k++;
            x0  = SRC(k);
            inv = INVSPAN(k);
        }
        float frac = (q - x0) * inv;
        if (asc) emit((int32_t)k,            frac,        idx, wq, qi);
        else     emit((int32_t)(S - 2u - k), 1.0f - frac, idx, wq, qi);
    }
    #undef SRC
    #undef INVSPAN
}
