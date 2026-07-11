#ifndef SAR_FFT_H
#define SAR_FFT_H
#include <stdint.h>
/* CPU (MSS U54) fixed-point radix-2 DIT 8192-pt FFT, 1/N normalized (per-stage >>1).
 * Replaces the HLS K_FFT kernel, whose butterfly network drops the twiddle term on
 * silicon (identity/passthrough) -- a SmartHLS synthesis bug (see m3 memory 2026-07-04).
 * src/dst are DDR frames of 8192 x 8192 complex int16 (packed uint32 = I<<16 | Q).
 * Transforms `nrows` rows (each an independent 8192-pt row FFT), src -> dst.
 * NOT L2-coherent with FIC0: the caller must flush_l2_cache before (so this reads the
 * kernel-written DDR src) and after (so the kernel-read dst sees this CPU write). */
void sar_cpu_fft(const uint32_t *src, uint32_t *dst, uint32_t nrows);
#endif
