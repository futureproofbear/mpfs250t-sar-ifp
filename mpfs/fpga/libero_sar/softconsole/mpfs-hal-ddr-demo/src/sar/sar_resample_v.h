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
 * *** THE KNOB IS INVERTED RELATIVE TO EVERY OTHER ONE ON THIS PROJECT. ON BY DEFAULT. ***
 * SAR_CGENMODE / SAR_DUALFFT / SAR_RWRK_NW are all opt-in because their fabric predecessor is still
 * in the bitstream and a cold-boot zero has to mean "run the proven path". That is NOT true here.
 * Verified in the built netlist (libero_ffv/synthesis/SAR_TOP.vm, build of 2026-07-28): the only
 * resample module present is sar_resample_v -- the SmartHLS kernel was REPLACED at the same CIC
 * target, not added alongside it. There is nothing to fall back TO.
 *
 * An opt-in knob would therefore make the DEFAULT case the dangerous one: the legacy path writes
 * HLS_ARG0..3 at 0x0c/0x10/0x14/0x18, which on this core are IN_BASE / OUT_BASE / STATUS2 / DIMS.
 * The idx pointer would land in OUT_BASE and the output pointer would be read as {SN,QN}, so the
 * kernel would gather with garbage geometry straight into the coefficient buffer. So: a cold-boot
 * zero means ON, and only the exact word SAR_RSVMODE_LEGACY forces the old path -- which is correct
 * ONLY if this ELF is deliberately paired with a pre-2026-07-28 bitstream.
 */
#ifndef SAR_RESAMPLE_V_H
#define SAR_RESAMPLE_V_H

#include <stdint.h>

/* Runtime knob. 'RSV0' is the ONLY value that turns this OFF; anything else -- including a
 * cold-boot 0 -- runs sar_resample_v, because that is the only resample core in the bitstream.
 * Address chosen in the same debug-word block as the other knobs; 0xB0059148 is the first free
 * word after SAR_WORKBUF (0xB0059144). */
#define SAR_RSVMODE_ADDR    0xB0059148u
#define SAR_RSVMODE_LEGACY  0x52535630u   /* 'RSV0' -- force the SmartHLS arming path */

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

/* SINC MODE. 'SNC1' selects the 32-tap polyphase-sinc gather (LCFG[17]) over the 2-tap lerp.
 * OPT-IN and fail-safe, unlike SAR_RSVMODE: BOTH kernels are in the bitstream, so a cold-boot
 * zero gets the lerp -- the silicon-verified 14.92 s / corr 0.977 path -- and the two can be
 * A/B'd on ONE board run. That is the whole point of not replacing the lerp.
 * Measured motivation: the 2-tap kernel scallops 29.2 dB at this scene's 0.978-Nyquist band
 * edge (the linear-interpolation null at mu=0.5); 32 taps brings that to 3.46 dB. */
#define SAR_SINCMODE_ADDR   0xB0059164u
#define SAR_SINCMODE_ENABLE 0x534E4331u   /* 'SNC1' */

/* AXI4-Lite register map of sar_resample_v.v. 0x08 keeps the SmartHLS START/busy convention so
 * sar_k_start()/sar_k_wait() work unchanged. */
#define RSV_CTRL       0x08u   /* W bit0 = start ; R bit0 = busy */
#define RSV_IN_BASE    0x0cu
#define RSV_OUT_BASE   0x10u
#define RSV_STATUS2    0x14u   /* RO sticky: [0]extra [1]rlast [2]bresp [3]align [4]sat */
#define RSV_DIMS       0x18u   /* [15:0] QN outputs, [31:16] SN source samples */
#define RSV_LCFG       0x1cu   /* [5:0] SH, [13:8] FSH, [16] MODE, [17] SINC */
#define RSV_COEF_A     0x20u
#define RSV_COEF_BLO   0x24u
#define RSV_COEF_BHI   0x28u   /* B is 48-bit signed, split lo/hi */
#define RSV_TAB_CTRL   0x2cu   /* select = {[3],[1:0]}: 0=KR 1=KC 2=TS 3=INV 4=SINC.
                                * SPLIT because [2] is REWIND and predates the 5th table. */
#define RSV_TAB_DATA   0x30u   /* table word; the shared pointer auto-increments */

/* Scene-level table state, built once per frame and reused by every line. */
typedef struct {
    double   kr_off;      /* line-invariant offset, folded into B */
    double   kr_scale;    /* 2^30 / span, so the int32 table spans about +/-2^30 */
    uint32_t qn;          /* query entries pushed (= Np) */
    uint32_t _pad;        /* explicit: the build runs -Wpadded */
} sar_rsv_scene_t;

/* True unless the knob explicitly forces the legacy path. See the inversion note above. */
int  sar_rsv_enabled(void);

/* True when SAR_SINCMODE holds 'SNC1'. Opt-in: anything else means the 2-tap lerp. */
int  sar_rsv_sinc_enabled(void);

/* THE SINC COEFFICIENT TABLE IS LOADED BY THE HOST, NOT BY FIRMWARE.
 * 256 phases x 32 taps x int16 = 16 KB, and it does not fit: the app's .rodata lives in the
 * 256 KB L2 scratchpad, which is already full -- linking it overflowed the region by 15,584 bytes,
 * so even a quarter-size table would not fit. It does not need to be in the image anyway: the
 * table is SCENE-INDEPENDENT (a function of fractional delay only), so it is a one-time push.
 * Use mpfs/host/run_sinc_table_load.sh, which streams it into TAB_DATA over JTAG before PIPE. */

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
