/* sar_resample_coeffs.c -- see header. Float math (run on a U54 hart with FPU). */
#include "sar_resample_coeffs.h"

/* ascending-view accessor: xa(k) walks xp in ascending order regardless of dir */
#define XA(arr, asc, S, k)  ((asc) ? (arr)[(k)] : (arr)[(S) - 1u - (k)])

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
    /* Bracket span is constant across all query points that fall in it, and there
     * are only S-1 brackets, so compute the RECIPROCAL of the span ONCE per bracket
     * (S-1 divisions total) and multiply per query -- replaces ~Q divisions with ~Q
     * multiplies (12x fewer divides for the pass-2 8192-wide line). Same brackets,
     * negligible (<=1 LSB Q15) numerical difference vs the divide. */
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
        uint32_t nat;
        float w;
        if (asc) { nat = k;            w = frac; }
        else     { nat = S - 2u - k;   w = 1.0f - frac; }
        int32_t wi = (int32_t)(w * 32768.0f + 0.5f);
        if (wi < 0) wi = 0;
        if (wi > 32767) wi = 32767;
        idx[qi] = (int32_t)nat;
        wq[qi] = (int16_t)wi;
    }
}

void sar_coeffs_pass1(const sar_geom_t *g, uint32_t i,
                      float *scratch, int32_t *idx, int16_t *wq)
{
    /* kr[i,j] = 2*(f0[i] + j*df[i])/C * pr[i] over the real N samples */
    float a = 2.0f * g->pr[i] / SAR_C_LIGHT;
    float f0 = g->f0[i], df = g->df[i];
    for (uint32_t j = 0; j < g->N; j++)
        scratch[j] = a * (f0 + (float)j * df);
    sar_interp_coeffs(g->KR, g->Np, scratch, g->N, idx, wq);
}

void sar_coeffs_pass2(const sar_geom_t *g, uint32_t j,
                      float *scratch, int32_t *idx, int16_t *wq)
{
    /* src[k] = KR[j] * tan_s[k] across the real M (sorted) pulses */
    float kr = g->KR[j];
    for (uint32_t k = 0; k < g->M; k++)
        scratch[k] = kr * g->tan_s[k];
    sar_interp_coeffs(g->KC, g->Mp, scratch, g->M, idx, wq);
}
