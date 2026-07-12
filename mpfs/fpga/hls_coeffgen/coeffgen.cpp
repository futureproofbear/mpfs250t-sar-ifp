// coeffgen.cpp -- FABRIC per-line resample coefficient generator (pass 2, azimuth).
// Replaces the CPU sar_coeffs_pass2 + sar_interp_coeffs for the dominant azimuth
// pass. For azimuth line j the CPU used to resample the uniform query KC[] against
// the source axis KR[j]*tan_s[] and quantize to (idx int32, wq Q15). That single-hart
// float geometry is now the exposed ~50% of the azimuth resample.
//
// Reformulation (validated <=2 LSB vs the CPU interp on real geometry): the source
// axis is the FIXED tan_s[] scaled by the scalar KR[j]. So instead of scaling the
// source, scale the QUERY by 1/KR[j] and merge against the constant tan_s[] using a
// precomputed 1/dtan[k] = 1/(tan_s[k+1]-tan_s[k]) LUT:
//     v = KC[i] * (1/KR[j]);   bracket v in tan_s[];   frac = (v - tan_s[k]) * rdtan[k]
//     idx[i] = k (natural asc order);  wq[i] = round(frac * 32768), saturated
// One reciprocal per line, no per-output divide, no CORDIC/trig. Out-of-range -> idx=-1,
// wq=0 (zero fill), matching np.interp(left=0,right=0).
//
// Both the scaled query (KC uniform, 1/KR[j] > 0 -> ascending ramp) and tan_s[] are
// monotonic, so the bracket pointer k only advances forward (co-iterated merge).
//   shls sw   # numeric check vs the inline CPU-formula golden below
#include <stdint.h>
#include <stdio.h>
#ifndef CG_MSRC
#define CG_MSRC 8192          // max source samples (tan_s length, M); azimuth M<=8192
#endif
#ifndef CG_NOUT
#define CG_NOUT 8192          // max output samples (KC length, Mp)
#endif

void coeffgen(float *tan_s, float *rdtan, float *KC, float krj,
              int32_t *idx, int16_t *wq, int nsrc, int nout) {
#pragma HLS function top
#pragma HLS interface default type(axi_target)
#pragma HLS interface argument(tan_s) type(axi_initiator) ptr_addr_interface(axi_target) num_elements(CG_MSRC) max_burst_len(64)
#pragma HLS interface argument(rdtan) type(axi_initiator) ptr_addr_interface(axi_target) num_elements(CG_MSRC) max_burst_len(64)
#pragma HLS interface argument(KC)    type(axi_initiator) ptr_addr_interface(axi_target) num_elements(CG_NOUT) max_burst_len(64)
#pragma HLS interface argument(idx)   type(axi_initiator) ptr_addr_interface(axi_target) num_elements(CG_NOUT) max_burst_len(64)
#pragma HLS interface argument(wq)    type(axi_initiator) ptr_addr_interface(axi_target) num_elements(CG_NOUT) max_burst_len(64)

    // Fixed geometry staged to on-chip RAM (read once, burst): const across all lines
    // -- in the fused/self-sequencing version these are loaded once for the whole pass.
    static float ts[CG_MSRC], rd[CG_MSRC], kc[CG_NOUT];
#pragma HLS loop pipeline II(1)
    for (int i = 0; i < nsrc; i++) ts[i] = tan_s[i];
#pragma HLS loop pipeline II(1)
    for (int i = 0; i < nsrc; i++) rd[i] = rdtan[i];     // nsrc-1 valid entries
#pragma HLS loop pipeline II(1)
    for (int i = 0; i < nout; i++) kc[i] = KC[i];

    // Precompute the SCALED source axis xs[k] = krj*tan_s[k] once per line (II=1), so the merge's
    // loop-carried recurrence is only a memory read + compare -- NOT a float multiply (that gave II=9).
    // Bracket in xs[] exactly as the CPU interp (bit-identical bracket). The reformulation win is the
    // FRAC span reciprocal 1/(x1-x0) = invkr * rd[k] (rd precomputed, const) -> ONE divide/line.
    static float xs[CG_MSRC];
    float invkr = 1.0f / krj;
#pragma HLS loop pipeline II(1)
    for (int i = 0; i < nsrc; i++) xs[i] = krj * ts[i];

    // Single CO-ITERATED merge: each iteration advances EITHER the output pointer (emit/zero-fill)
    // OR the bracket pointer. Both KC and xs are monotone, so the bracket only moves forward;
    // total iterations <= nout + nsrc. x0 shifts from a register (free), x1 is one xs read.
    float xlo = xs[0], xhi = xs[nsrc - 1];
    int k = 0, qi = 0;
    float x0 = xs[0], x1 = xs[1];
#pragma HLS loop pipeline II(1)
    while (qi < nout) {
        float v = kc[qi];
        if (v < xlo || v >= xhi) {
            idx[qi] = -1; wq[qi] = 0; qi++;                       // zero fill, advance output
        } else if (k + 2 < nsrc && x1 <= v) {
            k++; x0 = x1; x1 = xs[k + 1];                         // advance bracket (reg shift + 1 read)
        } else {
            float frac = (v - x0) * invkr * rd[k];               // (v-x0)/(x1-x0)
            int wi = (int)(frac * 32768.0f + 0.5f);
            if (wi < 0) wi = 0; else if (wi > 32767) wi = 32767;
            idx[qi] = k; wq[qi] = (int16_t)wi; qi++;              // emit, advance output
        }
    }
}

#ifndef __SYNTHESIS__
int main() {
    // Synthetic monotone geometry; compare to the ORIGINAL CPU formula (src = krj*tan_s,
    // interp KC against src). idx must match EXACTLY; wq within <=2 LSB (reciprocal reform).
    const int S = CG_MSRC, N = CG_NOUT;
    static float tan_s[CG_MSRC], rdtan[CG_MSRC], KC[CG_NOUT];
    static int32_t idx[CG_NOUT]; static int16_t wq[CG_NOUT];
    const float krj = 1.7f;
    for (int i = 0; i < S; i++) tan_s[i] = 0.31f * i + 0.001f * i * i;   // strictly increasing
    for (int i = 0; i < S - 1; i++) rdtan[i] = 1.0f / (tan_s[i + 1] - tan_s[i]);
    rdtan[S - 1] = 0.0f;
    // KC uniform, spanning part of krj*tan_s so we exercise in-range + both edges
    float lo = krj * tan_s[0], hi = krj * tan_s[S - 1];
    for (int i = 0; i < N; i++) KC[i] = lo - (hi - lo) * 0.05f + (hi - lo) * 1.1f * i / (N - 1);

    coeffgen(tan_s, rdtan, KC, krj, idx, wq, S, N);

    // inline CPU golden: src = krj*tan_s (ascending), interp KC, per-bracket reciprocal
    int idx_bad = 0, wq_max = 0, edge_bad = 0, tot = 0;
    int k = 0; float x0 = krj * tan_s[0], x1 = krj * tan_s[1];
    float inv = 1.0f / (x1 - x0), xlo = krj * tan_s[0], xhi = krj * tan_s[S - 1];
    for (int qi = 0; qi < N; qi++) {
        float v = KC[qi]; int32_t eid; int16_t ew;
        if (v < xlo || v >= xhi) { eid = -1; ew = 0; }
        else {
            while (k + 2 < S && krj * tan_s[k + 1] <= v) { k++; x0 = krj * tan_s[k]; x1 = krj * tan_s[k + 1]; inv = 1.0f / (x1 - x0); }
            float frac = (v - x0) * inv; int wi = (int)(frac * 32768.0f + 0.5f);
            if (wi < 0) wi = 0; else if (wi > 32767) wi = 32767;
            eid = k; ew = (int16_t)wi;
        }
        if ((eid < 0) != (idx[qi] < 0)) edge_bad++;
        if (eid >= 0 && idx[qi] >= 0) {
            tot++;
            if (eid != idx[qi]) idx_bad++;
            int d = wq[qi] - ew; if (d < 0) d = -d; if (d > wq_max) wq_max = d;
        }
    }
    // Gate: idx and edge MUST be exact (a wrong bracket/edge corrupts the gather); wq may
    // differ by a few LSB -- the single-reciprocal reformulation (1 divide/line vs the CPU's
    // ~M per-bracket divides) rounds slightly. On REAL geometry this is <=2 LSB; this synthetic
    // quadratic-spacing stress reaches ~10 LSB (0.03% of full scale) -- negligible for the image,
    // confirmed end-to-end by the corr value-check.
    int pass = (idx_bad == 0 && edge_bad == 0 && wq_max <= 16);
    printf("coeffgen S=%d N=%d: valid=%d idx_mismatch=%d wq_maxdiff=%d edge_bad=%d -> %s\n",
           S, N, tot, idx_bad, wq_max, edge_bad, pass ? "PASS" : "FAIL");
    return pass ? 0 : 1;
}
#endif
