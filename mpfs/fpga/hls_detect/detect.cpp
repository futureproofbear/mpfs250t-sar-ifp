// detect.cpp -- SmartHLS magnitude detect (post-FFT datapath stage).
// in: complex int16 packed uint32 (I<<16)|Q; out: uint16 magnitude = |.|,
// saturated. Host (or on-board AGC) applies the dB/percentile view using
// BFP_SHIFT. Fixed-iteration integer sqrt (synthesizable, no FPU).
//   shls sw
#include <stdint.h>
#include <stdio.h>
#ifndef DN
#define DN (8192*8192)
#endif
// Branchless sign-extension of a 16-bit field to int32. Used for BOTH halves so SmartHLS cannot
// synthesize the I (high) and Q (low) paths differently: the previous `(int16_t)(x>>16)` was
// mis-synthesized (I treated as UNSIGNED -> negative I saturated detect on silicon; Q was fine).
static inline int32_t sext16(uint32_t u){ u &= 0xFFFFu; return (int32_t)(u ^ 0x8000u) - 0x8000; }
static inline int32_t hi16(uint32_t x){ return sext16(x >> 16); }
static inline int32_t lo16(uint32_t x){ return sext16(x); }

static inline uint32_t isqrt(uint64_t v) {           // floor(sqrt(v))
    // Classic digit-by-digit integer sqrt: only FIXED shifts (>>2, >>1) and
    // add/sub/compare -- no variable-position shift (1<<b), which crashed the
    // SmartHLS bitwidth analyzer. v here is < 2^31 (re,im are 16-bit), so the
    // largest needed power-of-four bit is 2^30; 16 fixed iterations cover it.
    uint64_t one = 1ULL << 30, res = 0, op = v;
#pragma HLS loop unroll
    for (int i = 0; i < 16; i++) {
        if (op >= res + one) { op -= res + one; res = (res >> 1) + one; }
        else { res >>= 1; }
        one >>= 2;
    }
    return (uint32_t)res;
}

void detect(uint32_t *in, uint16_t *out) {
#pragma HLS function top
#pragma HLS interface default type(axi_target)
#pragma HLS interface argument(in)  type(axi_initiator) ptr_addr_interface(axi_target) num_elements(DN) max_burst_len(64)
#pragma HLS interface argument(out) type(axi_initiator) ptr_addr_interface(axi_target) num_elements(DN) max_burst_len(64)
#pragma HLS loop pipeline II(1)
    for (int i = 0; i < DN; i++) {
        int32_t re = hi16(in[i]), im = lo16(in[i]);
        uint64_t m2 = (int64_t)re * re + (int64_t)im * im;
        uint32_t m = isqrt(m2);
        out[i] = (m > 0xFFFFu) ? 0xFFFFu : (uint16_t)m;
    }
}

int main() {
    static uint32_t in[DN]; static uint16_t out[DN];
    for (int i = 0; i < DN; i++)
        in[i] = (((uint32_t)(uint16_t)(int16_t)(i*5-2000)) << 16) | (uint16_t)(int16_t)(-i*2+700);
    detect(in, out);
    int err = 0;
    for (int i = 0; i < DN; i++) {
        int32_t re = hi16(in[i]), im = lo16(in[i]);
        uint32_t m = isqrt((int64_t)re*re + (int64_t)im*im);
        uint16_t exp = (m > 0xFFFFu) ? 0xFFFFu : (uint16_t)m;
        if (out[i] != exp) err++;
    }
    printf("detect N=%d: %s (%d errors)\n", DN, err ? "FAIL" : "PASS", err);
    return err ? 1 : 0;
}
