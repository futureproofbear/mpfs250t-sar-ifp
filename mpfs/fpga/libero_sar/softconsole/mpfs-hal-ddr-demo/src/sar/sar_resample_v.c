/* sar_resample_v.c -- see sar_resample_v.h for the contract and the CRC warning.
 *
 * The arithmetic here mirrors, step for step:
 *   mpfs/fpga/sar_resample_v.v          "NUMERIC FORMAT" block  (the hardware contract)
 *   mpfs/fpga/tb/gen_resample_vectors.py  build_mode0/pick_sh   (the TB's reference)
 *   mpfs/host/check_resample_v_scalars.py                       (the same maths on real geometry)
 *
 * It is written in DOUBLE and then rounded to integers, exactly as the RTL header specifies
 * ("the CPU does this once per scene, in double, then writes ints"). U54 is RV64GC, so double is
 * hardware, not soft-float.
 *
 * NOT COMPILE-VERIFIED AGAINST THE PYTHON. There is no host gcc and no spike/qemu on the
 * development machine, so this C cannot be run beside check_resample_v_scalars.py the way
 * check_coeffgen1_fixed.py gates the coeffgen. sar_rsv_scalars() is exposed so the values can be
 * checked ON THE BOARD against the ones that script pins:
 *     Centerfield line 0:  SH=24  A=1340508486  B=-13348062548
 */
#include "sar_resample_v.h"
#include "sar_kernels.h"

#define SH_REQ    44          /* ceiling from the RTL contract; back off until A fits int32 */
#define INT32_MAXV  2147483647LL
#define INT32_MINV (-2147483648LL)

/* round-half-up, matching Python's math.floor(x + 1/2) on a Fraction. Not lrint(): the default
 * rounding mode is round-half-to-EVEN, which disagrees on exact .5 and would silently produce a
 * table one LSB off in places. */
static int64_t iround_d(double x)
{
    double f = x + 0.5;
    int64_t i = (int64_t)f;          /* truncates toward zero */
    if (f < 0.0 && (double)i > f) i -= 1;    /* trunc == ceil for negatives -> step down to floor */
    return i;
}

int sar_rsv_enabled(void)
{
    return *(volatile uint32_t *)(uintptr_t)SAR_RSVMODE_ADDR == SAR_RSVMODE_ENABLE;
}

void sar_rsv_scalars(const sar_rsv_scene_t *sc, double x0, double dx,
                     int32_t *a_out, uint32_t *sh_out, int64_t *b_out)
{
    /* unit = 2^24 / (kr_scale * dx) = A / 2^SH */
    double unit = 16777216.0 / (sc->kr_scale * dx);

    /* Largest SH <= SH_REQ whose mantissa still fits int32. A silent wrap here would give a
     * plausible but wrong affine map, and every downstream check would then verify the wrong
     * thing -- which is exactly how this project lost six hypotheses to the coeffgen. */
    uint32_t sh = 0;
    int64_t  a  = 0;
    for (int s = SH_REQ; s >= 0; s--) {
        double scaled = unit * (double)(1ULL << s);
        /* reject before converting: (int64)NaN/huge is undefined behaviour */
        if (scaled > 9.0e18 || scaled < -9.0e18) continue;
        int64_t cand = iround_d(scaled);
        if (cand != 0 && cand <= INT32_MAXV && cand >= INT32_MINV) {
            sh = (uint32_t)s;
            a  = cand;
            break;
        }
    }

    *a_out  = (int32_t)a;
    *sh_out = sh;
    *b_out  = iround_d((sc->kr_off - x0) * 16777216.0 / dx);
}

int sar_rsv_load_kr(const float *kr, uint32_t n_real, uint32_t qn, sar_rsv_scene_t *sc)
{
    if (!kr || n_real < 2u || qn < n_real) return -1;

    /* Scale on the REAL entries only. serialize_inputs pads the query grid with a deliberate
     * out-of-range filler so the kernel zero-fills; on Centerfield the real span is 0.712 and the
     * filler sits 1.72 beyond the offset. Scaling on the padded grid would leave genuine queries
     * using only ~29% of +/-2^30 and throw away 1.77 bits of resolution, so the padding is CLAMPED
     * below instead. It carries no information -- it only has to stay out of range. */
    double lo = (double)kr[0], hi = (double)kr[0];
    for (uint32_t i = 1u; i < n_real; i++) {
        double v = (double)kr[i];
        if (v < lo) lo = v;
        if (v > hi) hi = v;
    }
    double span = hi - lo;
    if (!(span > 0.0)) return -2;

    sc->kr_off   = lo;
    sc->kr_scale = 1073741824.0 / span;      /* 2^30 / span */
    sc->qn       = qn;

    /* rewind the shared table pointer, select KR (sel 0), then stream qn words */
    sar_reg_w(K_RESAMPLE, RSV_TAB_CTRL, (1u << 2) | 0u);
    for (uint32_t i = 0u; i < qn; i++) {
        int64_t t = iround_d(((double)kr[i] - sc->kr_off) * sc->kr_scale);
        if (t > INT32_MAXV) t = INT32_MAXV;      /* the padding, clamped -- see above */
        else if (t < INT32_MINV) t = INT32_MINV;
        sar_reg_w(K_RESAMPLE, RSV_TAB_DATA, (uint32_t)(int32_t)t);
    }
    return 0;
}

void sar_rsv_arm_line(const sar_rsv_scene_t *sc, double x0, double dx,
                      uint32_t sn, uint32_t in_base, uint32_t out_base)
{
    int32_t  a;
    uint32_t sh;
    int64_t  b;
    sar_rsv_scalars(sc, x0, dx, &a, &sh, &b);

    sar_reg_w(K_RESAMPLE, RSV_DIMS, ((sn & 0xFFFFu) << 16) | (sc->qn & 0xFFFFu));
    sar_reg_w(K_RESAMPLE, RSV_LCFG, (sh & 0x3Fu));           /* FSH unused, MODE 0 = pass 1 */
    sar_reg_w(K_RESAMPLE, RSV_COEF_A,   (uint32_t)a);
    sar_reg_w(K_RESAMPLE, RSV_COEF_BLO, (uint32_t)((uint64_t)b & 0xFFFFFFFFu));
    sar_reg_w(K_RESAMPLE, RSV_COEF_BHI, (uint32_t)(((uint64_t)b >> 32) & 0xFFFFu));
    sar_reg_w(K_RESAMPLE, RSV_IN_BASE,  in_base);
    sar_reg_w(K_RESAMPLE, RSV_OUT_BASE, out_base);
    sar_k_start(K_RESAMPLE);
}
