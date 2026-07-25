/*
 * sar_resample_coeffs.h -- on-MSS keystone resample coefficient generation.
 *
 * The 2-D polar->Cartesian keystone resample needs per-line gather indices +
 * interpolation weights. Precomputing them for the full 8192x8192 grid would be
 * ~768 MB (won't fit in DDR / slow over JTAG), so the MSS computes them per line
 * just-in-time from a few small per-pulse geometry arrays. Mirrors the host
 * interp_coeffs() (verified corr=1.0 vs np.interp) so the board matches the
 * float reference pipeline.
 *
 * Output contract = the fabric resample kernel:
 *     out[i] = in[idx[i]] + (in[idx[i]+1]-in[idx[i]]) * wq[i]/32768
 *     idx in the source's NATURAL order; out-of-range -> idx=-1 (zero fill).
 */
#ifndef SAR_RESAMPLE_COEFFS_H_
#define SAR_RESAMPLE_COEFFS_H_

#include <stdint.h>

#define SAR_C_LIGHT 299792458.0f

/* Small geometry the host stages in DDR (all O(M) or O(grid), not O(M*N)). */
typedef struct {
    uint32_t M, N;            /* real pulses, real samples */
    uint32_t Mp, Np;          /* padded pow2 grid (square: Mp == Np) */
    const float  *f0;         /* [M] start RF freq per pulse (Hz) */
    const float  *df;         /* [M] freq step per sample per pulse (Hz) */
    const float  *pr;         /* [M] radial unit-projection per pulse */
    const float  *tan_s;      /* [M] tan(phi) sorted ascending (pass 2 source scale) */
    const float  *KR;         /* [Np] uniform range query grid */
    const float  *KC;         /* [Mp] uniform cross query grid */
} sar_geom_t;

/*
 * Quantize a 1-D linear resample of query[Q] against monotonic source xp[S] to
 * the kernel's (idx int32, wq Q15 int16) contract. query must be ascending; xp
 * may be ascending or descending. Two-pointer, O(Q + S).
 */
void sar_interp_coeffs(const float *query, uint32_t Q,
                       const float *xp, uint32_t S,
                       int32_t *idx, int16_t *wq);

/* Build the line-invariant pass-2 reciprocals 1/(tan_s[k+1]-tan_s[k]).
 * MUST be called once per scene before sar_coeffs_pass2(); until it is, pass 2 falls back to
 * the generic search so a missed call degrades speed, never correctness. */
void sar_coeffs_init(const sar_geom_t *g);

/* Pass 1 (range): coeffs for pulse row i. Writes idx[Np], wq[Np].
 * Source positions kr[i,j] = 2*(f0[i]+j*df[i])/C * pr[i] are built into `scratch`
 * (caller provides a float[N] temp). */
void sar_coeffs_pass1(const sar_geom_t *g, uint32_t i,
                      float *scratch, int32_t *idx, int16_t *wq);

/* Pass 2 (azimuth): coeffs for range bin j. Writes idx[Mp], wq[Mp].
 * Source positions src[k] = KR[j]*tan_s[k] are built into `scratch` (float[M]). */
void sar_coeffs_pass2(const sar_geom_t *g, uint32_t j,
                      float *scratch, int32_t *idx, int16_t *wq);

/* ---- OUTPUT-RANGE variants: compute only outputs [q0, q1) of the same line ------------------
 * For splitting one line's coefficient work across harts. Each worker writes a DISJOINT,
 * contiguous slice of idx[]/wq[], so no locking is needed -- but each worker must publish its
 * OWN slice (FIC_0 is non-coherent; see flush_coef_bank_range_to_ddr in the sequencer).
 *
 * BIT-EXACTNESS: these produce byte-identical idx/wq to the full-line calls above. Pass 1 is
 * trivially so (every output is an independent closed form). Pass 2 carries a moving bracket
 * `k` and so LOOKS order-dependent, but the scan's k at query q is a pure function of q --
 *     k = clamp( max{ j : SRC(j) <= q }, 0, S-2 )
 * because the while-loop advances until SRC(k+1) > q, never retreats, and KC is non-decreasing.
 * A cold-starting worker therefore binary-searches that same k and matches exactly.
 * PROVEN board-free over real staged geometry, ascending AND descending source (kr<0), for
 * 2/3/4/5/8-way splits: mpfs/host/check_coeff_split.py (320 checks, 0 mismatches).
 * Re-run that gate if this code or the emit()/quantisation contract ever changes. */
/* True once sar_coeffs_init() has built the reciprocals for THIS geometry. The *_range workers
 * require it (see the bit-exactness note above); gate any multi-hart dispatch on this. */
int sar_coeffs_ready(const sar_geom_t *g);

void sar_coeffs_pass1_range(const sar_geom_t *g, uint32_t i,
                            float *scratch, int32_t *idx, int16_t *wq,
                            uint32_t q0, uint32_t q1);
void sar_coeffs_pass2_range(const sar_geom_t *g, uint32_t j,
                            float *scratch, int32_t *idx, int16_t *wq,
                            uint32_t q0, uint32_t q1);

#endif /* SAR_RESAMPLE_COEFFS_H_ */
