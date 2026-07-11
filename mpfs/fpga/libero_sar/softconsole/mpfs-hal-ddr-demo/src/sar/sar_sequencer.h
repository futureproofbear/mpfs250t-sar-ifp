/*
 * sar_sequencer.h -- bare-metal PFA pipeline sequencer for the SAR fabric
 * accelerator. Drives the five SmartHLS kernels + CoreFFT/DMA stream path
 * through the Polar Format Algorithm stages entirely from the RISC-V (the
 * heavy compute is in fabric; the CPU only programs registers and polls done).
 *
 * Pipeline (whole-frame, fixed 8192x8192 geometry baked into the kernels):
 *   resample -> window -> FFT(range) -> corner-turn -> FFT(azimuth) -> detect
 *
 * Inputs (JTAG-loaded into DDR by the host before calling): SIG signal,
 * resample idx/wq tables, window taper. Output: detected magnitude in OUT.
 */
#ifndef SAR_SEQUENCER_H_
#define SAR_SEQUENCER_H_

#include <stdint.h>

typedef enum {
    SAR_SEQ_OK = 0,
    SAR_SEQ_BAD_JOB,
    SAR_SEQ_TIMEOUT_RESAMPLE,
    SAR_SEQ_TIMEOUT_WINDOW,
    SAR_SEQ_TIMEOUT_FFT1,
    SAR_SEQ_TIMEOUT_CORNER,
    SAR_SEQ_TIMEOUT_FFT2,
    SAR_SEQ_TIMEOUT_DETECT,
    SAR_SEQ_TIMEOUT_DMA
} sar_seq_status_t;

/*
 * Run the full SAR image-formation pipeline on the fabric accelerator.
 * `spin_limit` bounds each stage's done-poll (0 = use the built-in default).
 * Returns SAR_SEQ_OK on success, or the stage that timed out.
 */
sar_seq_status_t sar_form_image(uint32_t spin_limit);

/*
 * Debug aid: arm the DMA S2MM + start the FFT feeder (range-FFT config,
 * SCRATCH->SCRATCH) and RETURN WITHOUT WAITING. Leaves the feeder/CoreFFT/DMA
 * stream handshake in its running/stalled state so SmartDebug can probe where
 * the stream stops (FEED:out_var_valid, GBX:in_phase, FFT:OUTP_READY/DATAO_VALID,
 * DMA TREADY). No bounded wait, no timeout -- the fabric holds the state.
 */
void sar_fft_hold(void);

/* Debug: run ONLY the range-FFT pass on SCRATCH (skip resample) for fast chunk-boundary
 * iteration. Returns fft_pass status (0 OK, 1 feeder stall, 2 DMA stall). */
int sar_fft_pass_test(void);
int sar_fabric_scale_test(void);

#endif /* SAR_SEQUENCER_H_ */
