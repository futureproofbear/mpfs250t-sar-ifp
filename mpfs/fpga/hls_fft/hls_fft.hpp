// ©2024 Microchip Technology Inc. and its subsidiaries
//
// Subject to your compliance with these terms, you may use this Microchip
// software and any derivatives exclusively with Microchip products. You are
// responsible for complying with third party license terms applicable to your
// use of third party software (including open source software) that may
// accompany this Microchip software. SOFTWARE IS “AS IS.” NO WARRANTIES,
// WHETHER EXPRESS, IMPLIED OR STATUTORY, APPLY TO THIS SOFTWARE, INCLUDING
// ANY IMPLIED WARRANTIES OF NON-INFRINGEMENT, MERCHANTABILITY, OR FITNESS FOR
// A PARTICULAR PURPOSE. IN NO EVENT WILL MICROCHIP BE LIABLE FOR ANY
// INDIRECT, SPECIAL, PUNITIVE, INCIDENTAL OR CONSEQUENTIAL LOSS, DAMAGE, COST
// OR EXPENSE OF ANY KIND WHATSOEVER RELATED TO THE SOFTWARE, HOWEVER CAUSED,
// EVEN IF MICROCHIP HAS BEEN ADVISED OF THE POSSIBILITY OR THE DAMAGES ARE
// FORESEEABLE.  TO THE FULLEST EXTENT ALLOWED BY LAW, MICROCHIP’S TOTAL
// LIABILITY ON ALL CLAIMS LATED TO THE SOFTWARE WILL NOT EXCEED AMOUNT OF
// FEES, IF ANY, YOU PAID DIRECTLY TO MICROCHIP FOR THIS SOFTWARE. MICROCHIP
// OFFERS NO SUPPORT FOR THE SOFTWARE. YOU MAY CONTACT MICROCHIP AT
// https://www.microchip.com/en-us/support-and-training/design-help/client-support-services
// TO INQUIRE ABOUT SUPPORT SERVICES AND APPLICABLE FEES, IF AVAILABLE.
//
// In-place FFT implementation is referenced from https://github.com/KastnerRG/pp4fpgas/tree/master
// Released under CC-BY-4.0 license. To see full license, see licenses folder in fft_license.

#pragma once


#include "common.hpp"



namespace hls {
namespace dsp {

// define the type of FFT data points
struct fft_data_t {
  ap_int<16> im;
  ap_int<16> re;
};

#include "twiddle.h"

template <unsigned int SIZE> 
void fft_in_place(hls::FIFO<fft_data_t> &in, hls::FIFO<fft_data_t> &out) {

	FLT_TYPE temp_R; // temporary storage complex variable
	FLT_TYPE temp_I; // temporary storage complex variable
  ap_fixpt<17,2> c, s;
  FLT_TYPE x_r_lower, x_i_lower, x_r, x_i, t00, t11;
	INT_TYPE i, j, k;	// loop indexes
	INT_TYPE i_lower;	// Index of lower point in butterfly
	INT_TYPE stage, DFTpts;
	INT_TYPE numBF;			// Butterfly Width
	INT_TYPE step = SIZE >> 1; // step=N>>1
  INT_TYPE cnt;

  // compute the number of stages needed based on the FFT size
  constexpr int NUMBER_OF_STAGES = log2(SIZE);

  // memory layout of Stage:
  // 0 - 255: Re part
  // 256 - 511: Im part
  hls::DoubleBuffer<FLT_TYPE[SIZE << 1]> Stage;
  auto Stage_P = Stage.producer();
  auto Stage_C = Stage.consumer();

  auto butterfly_loop_body = [&](int i, int k) {
        
        c = twiddleRe[k];
        s = twiddleIm[k];
        i_lower = i + numBF; // index of lower point in butterfly
        x_r_lower = Stage_C[i_lower] >> 1;
        x_i_lower = Stage_C[i_lower + SIZE] >> 1;
        x_r = Stage_C[i] >> 1;
        x_i = Stage_C[i + SIZE] >> 1;
        
        // apply the the Karatsuba pattern
        t00 = x_r_lower * c;
        t11 = x_i_lower * s;
        temp_R = t00 - t11;
        temp_I = (x_r_lower - x_i_lower) * (s - c) + t00 + t11;
        Stage_P[i_lower] = x_r - int(temp_R);
        Stage_P[i_lower + SIZE] = x_i - int(temp_I);
        Stage_P[i] = x_r + int(temp_R);
        Stage_P[i + SIZE] = x_i + int(temp_I);

  };

  Stage.producer_acquire();
  #pragma HLS loop pipeline
  for (unsigned i = 0; i < SIZE; i++) {
      // Decimation in Time, reverse bits to obtain new indices and swap elements
      int j = new_index<SIZE>(i);
      auto data = in.read();
      Stage_P[j] = data.re; // Re part
      Stage_P[j + SIZE] = data.im; // Im part
  }
  Stage.producer_release();

stage_loop:
	for (stage = 1; stage <= NUMBER_OF_STAGES; stage++) { // Do M stages of butterflies
      Stage.consumer_acquire();
      Stage.producer_acquire();

      DFTpts = 1 << stage;								 // DFT = 2^stage = points in sub DFT
      numBF = DFTpts / 2;									 // Butterfly WIDTHS in sub-DFT
      k = 0;
      j = numBF;
      i = 0;
      cnt = 0;
      
	// Perform butterflies for j-th stage
	butterfly_loop:
  #pragma HLS loop pipeline
  for(unsigned z = 0; z < SIZE/2; z++) {
      if(j == 0) {
        break;
      }
      butterfly_loop_body(i, k);
      i += DFTpts;

      if(i >= SIZE) {
        j -= 1;
        i = ++cnt;
        k += step;
      }
  }

		step = step / 2;
    Stage.consumer_release();
    Stage.producer_release();
	}

  Stage.consumer_acquire();
 #pragma HLS loop pipeline
  for (unsigned i = 0; i < SIZE; i++) {
    fft_data_t data;
    data.re = Stage_C[i];
    data.im = Stage_C[i + SIZE];
    out.write(data);
  }
  Stage.consumer_release();

}

// ---------------------------------------------------------------------------
// GLOBAL-BFP variant of fft_in_place. Differences vs the stock (unconditional)
// version above:
//   (1) NO per-stage >>1: the butterfly runs full-precision in a WIDE (int32-
//       class) datapath, so small values are never truncated toward zero stage-
//       by-stage (the mechanism that underflows a distributed scene).
//   (2) A single runtime OUTPUT shift `out_shift` (the block exponent, supplied
//       by an L1 pre-scan of the whole pass) normalizes the transform to int16,
//       with saturation. One shared exponent per pass keeps every row's scaling
//       consistent (required for a correct 2-D image). Emit out_shift to the host
//       as the BFP block exponent for the true radiometric (dB) scale.
// WIDE_TYPE holds the unscaled growth: |X| <= ||x||_1 <= N*2^15 = 2^28 for N=8192.
template <unsigned int SIZE>
void fft_in_place_bfp(hls::FIFO<fft_data_t> &in, hls::FIFO<fft_data_t> &out, unsigned out_shift) {
  typedef FLT_TYPE T;                       // ap_fixpt<22,16>: int16 range + 6 frac (BFP bypassed, plain 1/N FFT)
  constexpr int NUMBER_OF_STAGES = log2(SIZE);
  (void)out_shift;                          // BFP bypassed -- output already 1/N-normalized

  // SINGLE-ARRAY IN-PLACE radix-2 DIT (textbook Cooley-Tukey). No ping-pong banks
  // (the buf[rd]/buf[wr] runtime bank index dropped the butterfly writes on silicon
  // -> identity/passthrough), no int() truncation of the fixed-point accumulator.
  // Separate re[]/im[] each SIZE deep, updated IN PLACE.
  static T re[SIZE];
  static T im[SIZE];

  // ---- bit-reversed load ----
  #pragma HLS loop pipeline
  for (unsigned i = 0; i < SIZE; i++) {
    int j = new_index<SIZE>(i);
    auto data = in.read();
    re[j] = (T)data.re;
    im[j] = (T)data.im;
  }

  // ---- radix-2 DIT stages, in place. W = twiddleRe + j*twiddleIm (=cos - j*sin). ----
  int step = SIZE >> 1;
  for (int stage = 1; stage <= NUMBER_OF_STAGES; stage++) {
    const int DFTpts = 1 << stage;
    const int numBF  = DFTpts >> 1;
    for (int grp = 0; grp < SIZE; grp += DFTpts) {
      for (int b = 0; b < numBF; b++) {
        const int k      = b * step;           // twiddle index = b*(SIZE/DFTpts)
        const int idx    = grp + b;            // top
        const int idx_lo = idx + numBF;        // bottom
        ap_fixpt<17, 2> c = twiddleRe[k];
        ap_fixpt<17, 2> s = twiddleIm[k];
        T ar = re[idx]    >> 1, ai = im[idx]    >> 1;   // top    (per-stage >>1 -> 1/N)
        T br = re[idx_lo] >> 1, bi = im[idx_lo] >> 1;   // bottom
        T tr = br * c - bi * s;                          // Re(W * bottom)
        T ti = br * s + bi * c;                          // Im(W * bottom)
        re[idx]    = ar + tr;  im[idx]    = ai + ti;     // top'    = top + W*bottom
        re[idx_lo] = ar - tr;  im[idx_lo] = ai - ti;     // bottom' = top - W*bottom
      }
    }
    step >>= 1;
  }

  // ---- saturate to int16, stream out ----
  #pragma HLS loop pipeline
  for (unsigned i = 0; i < SIZE; i++) {
    fft_data_t data;
    int r = int(re[i]);
    int m = int(im[i]);
    if (r >  32767) r =  32767; else if (r < -32768) r = -32768;
    if (m >  32767) m =  32767; else if (m < -32768) m = -32768;
    data.re = r;
    data.im = m;
    out.write(data);
  }
}


/***
 * @function fft
 * Compute the FFT. Note that fft_data_t type is defined as:
 * ```cpp
 * struct fft_data_t {
 * ap_int<16> im;
 * ap_int<16> re;
 * };
 * ```
 * ![timing_diagram](../graphs/in-place-fft-timing.PNG)
 * @param {hls::FIFO<fft_data_t>&} fifo_in reference to the input fifo, where the depth must match the FFT size
 * @param {hls::FIFO<fft_data_t>&} fifo_out reference to the output fifo, where the depth must match the FFT size
 * @template {unsigned} SIZE the FFT transform size
 * @limitation The fft function currently only supports the radix-2, 256-point, forward inplace FFT implementation.
 * @example
 * hls::dsp::fft<SIZE>(fifo_in, fifo_out);
 */
template <unsigned SIZE> 
void fft(hls::FIFO<fft_data_t> &fifo_in, hls::FIFO<fft_data_t> &fifo_out) {
    static_assert(SIZE == 256, "FFT size is not 256!");
    fft_in_place<SIZE>(fifo_in, fifo_out);
    return;
}

} // namespace dsp
} // namespace hls