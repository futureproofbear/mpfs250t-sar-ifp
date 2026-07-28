/* sar_resample_v.h -- driver for the hand-written resample kernel with COEFFICIENT GENERATION
 * FUSED IN (mpfs/fpga/sar_resample_v.v), PASS 1 / MODE 0 only.
 *
 * WHAT CHANGES. The SmartHLS resample took four pointers (in, idx, wq, out) and needed 8192
 * coefficients per line computed on the CPU and published to DDR -- 32 KB idx + 16 KB wq per line
 * plus ~768 CCACHE flush stores, because FIC_0 is non-coherent. This kernel takes THREE SCALARS
 * per line and generates the coefficients itself, so none of that traffic exists. E4 measured ~40%
 * of the 5.212 s range gather as bus-idle waiting on exactly that CPU work.
 *
 * *** THIS IS NOT A BIT-EXACT REPLACEMENT. READ BEFORE COMPARING CRCs. ***
 * The kernel is deliberately fixed-point where the shipping path is float32. Measured on real
 * geometry (mpfs/host/check_resample_v_scalars.py, and the divergence study in the same commit):
 * against the shipping CPU coefficients, ~72% of in-range taps differ in wq by a few LSB of 32768
 * and ~0.08% of idx land in a different bracket. That is the DESIGN INTENT, not a defect --
 * sar_resample_v.v's header records that float32 puts 1484 of ~108k taps in the wrong bracket
 * where fixed point puts 86-181. The image is expected to be very slightly BETTER and to correlate
 * ~1.0 with the golden, but **crop CRC 0x319037b2 WILL NOT MATCH**. Validate a first run by
 * correlation against the golden and by eye; adopt the new CRC as the baseline only after that.
 *
 * FAIL-SAFE. Everything here is inert unless SAR_RSVMODE_ADDR holds SAR_RSVMODE_ENABLE, the same
 * discipline as SAR_CGENMODE / SAR_DUALFFT / SAR_RWRK_NW. A cold-boot DDR word means OFF, so the
 * shipping SmartHLS path is what runs until the knob is deliberately set.
 */
#ifndef SAR_RESAMPLE_V_H
#define SAR_RESAMPLE_V_H

#include <stdint.h>

/* Runtime knob. 'RSV1' -- the ONLY accepted value; anything else (including a cold-boot 0) keeps
 * the SmartHLS pass-1 path. Address chosen in the same debug-word block as the other knobs;
 * 0xB0059148 is the first free word after SAR_WORKBUF (0xB0059144). */
#define SAR_RSVMODE_ADDR    0xB0059148u
#define SAR_RSVMODE_ENABLE  0x52535631u   /* 'RSV1' */

/* Firmware WRITES this after the pass-1 loop; JTAG reads it. Frame-level, because STATUS2 is
 * sticky with no software clear (see resample_v_status.md) -- it says "something went wrong
 * somewhere in the frame", never which line. [31:16] = 0x5253 marks the word as written by this
 * run, so a stale or cold-boot value cannot be misread as a clean frame.
 *   [0] extra beat  [1] missing RLAST  [2] BRESP error  [3] misalignment  [4] saturation */
#define SAR_RSVSTAT_ADDR    0xB005914Cu
#define SAR_RSVSTAT_TAG     0x52530000u

/* LINE-0 SCALARS, published so the first board run can CHECK the firmware arithmetic instead of
 * assuming it. This C cannot be compiled or run on the development host (no gcc, no spike/qemu),
 * so mpfs/host/check_resample_v_scalars.py pins the expected values and this is where the board
 * says what it actually computed. Read these BEFORE judging the image -- a mismatch here explains
 * a wrong image completely, and a match rules the CPU side out.
 *   [0] SH  [1] A (int32)  [2] B low 32  [3] B high 32 (sign-extended)
 * Centerfield, stage jtag_stage_deci1, line 0:  SH=24  A=1340508486  B=-13348062548, i.e. the four
 * words read back as  0x00000018  0x4FE68946  0xE464BAAC  0xFFFFFFFC. */
#define SAR_RSVDBG_ADDR     0xB0059150u

/* AXI4-Lite register map of sar_resample_v.v. 0x08 keeps the SmartHLS START/busy convention so
 * sar_k_start()/sar_k_wait() work unchanged. */
#define RSV_CTRL       0x08u   /* W bit0 = start ; R bit0 = busy */
#define RSV_IN_BASE    0x0cu
#define RSV_OUT_BASE   0x10u
#define RSV_STATUS2    0x14u   /* RO sticky: [0]extra [1]rlast [2]bresp [3]align [4]sat */
#define RSV_DIMS       0x18u   /* [15:0] QN outputs, [31:16] SN source samples */
#define RSV_LCFG       0x1cu   /* [5:0] SH, [13:8] FSH, [16] MODE */
#define RSV_COEF_A     0x20u
#define RSV_COEF_BLO   0x24u
#define RSV_COEF_BHI   0x28u   /* B is 48-bit signed, split lo/hi */
#define RSV_TAB_CTRL   0x2cu   /* [1:0] select 0=KR 1=KC 2=TS 3=INV, [2] rewind pointer */
#define RSV_TAB_DATA   0x30u   /* table word; the shared pointer auto-increments */

/* Scene-level table state, built once per frame and reused by every line. */
typedef struct {
    double   kr_off;      /* line-invariant offset, folded into B */
    double   kr_scale;    /* 2^30 / span, so the int32 table spans about +/-2^30 */
    uint32_t qn;          /* query entries pushed (= Np) */
    uint32_t _pad;        /* explicit: the build runs -Wpadded */
} sar_rsv_scene_t;

/* True when the knob is armed. */
int  sar_rsv_enabled(void);

/* Build the int32 query table from the staged float32 KR grid and push it into the kernel.
 * `kr` is the krgrid table in DDR, `n_real` the genuine entries, `qn` the padded grid length.
 * Call ONCE per frame, before the line loop. Returns 0 on success. */
int  sar_rsv_load_kr(const float *kr, uint32_t n_real, uint32_t qn, sar_rsv_scene_t *sc);

/* Arm ONE line. x0/dx are this pulse's uniform source mapping (x0 = a*f0, dx = a*df, a = 2*pr/C).
 * Writes the scalars and pulses START; the caller waits with sar_k_wait(K_RESAMPLE, spins). */
void sar_rsv_arm_line(const sar_rsv_scene_t *sc, double x0, double dx,
                      uint32_t sn, uint32_t in_base, uint32_t out_base);

/* Derivation, exposed so a self-test can check it against the values
 * mpfs/host/check_resample_v_scalars.py pins. v = ((QTAB*A) >>> SH) + B, Q24 in source samples. */
void sar_rsv_scalars(const sar_rsv_scene_t *sc, double x0, double dx,
                     int32_t *a_out, uint32_t *sh_out, int64_t *b_out);

#endif /* SAR_RESAMPLE_V_H */
