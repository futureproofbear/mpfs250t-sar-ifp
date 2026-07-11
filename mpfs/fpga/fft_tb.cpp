// fft_tb.cpp -- bit-exact C reference model + co-sim testbench for the 1-D FFT.
//
// PURPOSE
//   1. The reference model `fft1d_bfp_ref()` below is the BIT-EXACT spec the
//      fabric FFT must reproduce. It mirrors src/fixedpoint.py::fft1d_bfp
//      (radix-2 DIT, bit-reversed input, truncated twiddles, conditional
//      block-floating-point). Verified equal to the NumPy emulator's output
//      codes for all stimulus cases at N=64/256/1024 (see M1_cosim.md).
//   2. The I/O harness reads the $readmemh vectors from mpfs/host/fft_golden.py,
//      runs a kernel, and writes the result in the same format so that
//      `python fft_golden.py check` can compare it to the golden.
//
// USAGE (host C-sim -- reproduces the golden exactly, no FPGA tools needed):
//   g++ -O2 -std=c++14 fft_tb.cpp -o fft_tb
//   fft_tb 8192 fft_vectors/random_in.hex fft_vectors/twiddle.csv rtl_out.hex
//   python ../host/fft_golden.py check --expected fft_vectors/random_out.hex --actual rtl_out.hex --tol 0
//   # -> PASS, bit-exact
//
// PORTING TO HARDWARE
//   Replace the call to fft1d_bfp_ref() with your kernel under test: the
//   corrected SmartHLS fft1d.cpp (an integer mantissa + explicit block exponent,
//   NOT the placeholder ap_fixed<24,12>), or a CoreFFT C-model. Keep this exact
//   I/O so the same vectors and checker apply. CoreFFT will pass only to a small
//   LSB tolerance (see M1_cosim.md), not bit-exact.
//
// Datapath uses `double` to match NumPy float64 element-wise arithmetic, which is
// what makes the host run bit-identical to the emulator. The HARDWARE datapath is
// fixed point (16-bit mantissa / 18-bit twiddle / 48-bit accumulate); this model
// defines the VALUES it must produce, not the gate-level types.

#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <math.h>          // C global fmax/fabs/log2/ceil/floor/pow/lround
#include <vector>
#include <string>
#include <fstream>
#include <sstream>

static int NBITS = 16;                  // data mantissa  (match fft_golden --bits)
static int NBITS_TW = 18;               // twiddle bits   (match fft_golden --tw-bits)

struct C { double re, im; };

// ---- BFP helpers, mirroring fixedpoint.fit_scale / quant (floor) ---------- //
static int fit_exp(const std::vector<C> &x) {
    double M = 0.0;
    for (const C &v : x) {
        M = fmax(M, fmax(fabs(v.re), fabs(v.im)));
    }
    if (M == 0.0) return 0;
    const double full = (double)((1 << (NBITS - 1)) - 1);
    return (int)ceil(log2(M / full));
}

static void quant(std::vector<C> &x, int e) {
    const double s = pow(2.0, e);
    for (C &v : x) {
        v.re = floor(v.re / s) * s;
        v.im = floor(v.im / s) * s;
    }
}

static unsigned bitrev(unsigned x, int logn) {
    unsigned r = 0;
    for (int i = 0; i < logn; i++) { r = (r << 1) | (x & 1u); x >>= 1; }
    return r;
}

// ---- the reference FFT: returns the final block exponent (== BFP_SHIFT) --- //
// twiddle[k] = W_N^k = exp(-2*pi*i*k/N), already truncated to NBITS_TW (the ROM
// from fft_golden.py --twiddle). Stage s (m=1<<s) uses stride N/m.
static int fft1d_bfp_ref(std::vector<C> &x, const std::vector<C> &twiddle) {
    const int n = (int)x.size();
    int logn = 0; while ((1 << logn) < n) logn++;

    std::vector<C> b(n);
    for (int i = 0; i < n; i++) b[bitrev(i, logn)] = x[i];   // bit-reversed load
    x.swap(b);

    int e = fit_exp(x); quant(x, e);                          // input quantize
    int elast = e;
    for (int s = 1; s <= logn; s++) {
        int m = 1 << s, mh = m >> 1, stride = n / m;
        for (int k = 0; k < n; k += m) {
            for (int j = 0; j < mh; j++) {
                const C w = twiddle[j * stride];
                C a = x[k + j], bb = x[k + j + mh];
                double tr = w.re * bb.re - w.im * bb.im;      // complex multiply
                double ti = w.re * bb.im + w.im * bb.re;
                x[k + j].re      = a.re + tr;  x[k + j].im      = a.im + ti;
                x[k + j + mh].re = a.re - tr;  x[k + j + mh].im = a.im - ti;
            }
        }
        e = fit_exp(x); quant(x, e); elast = e;               // BFP rescale/stage
    }
    return elast;
}

// ---- I/O: $readmemh hex (uint16(I)<<16)|uint16(Q), and twiddle CSV -------- //
static int s16(unsigned v) { return (v & 0x8000u) ? (int)v - 0x10000 : (int)v; }

static std::vector<C> read_hex_codes(const std::string &path) {
    std::vector<C> out;
    std::ifstream f(path);
    std::string ln;
    while (std::getline(f, ln)) {
        size_t p = ln.find_first_not_of(" \t");
        if (p == std::string::npos || ln[p] == '#' || ln[p] == '/') continue;
        unsigned w = (unsigned)std::stoul(ln.substr(p), nullptr, 16);
        out.push_back(C{(double)s16((w >> 16) & 0xFFFF), (double)s16(w & 0xFFFF)});
    }
    return out;
}

static std::vector<C> read_twiddle_csv(const std::string &path) {
    std::vector<C> out;
    const double lsb = pow(2.0, -(NBITS_TW - 1));             // codes -> value
    std::ifstream f(path);
    std::string ln;
    while (std::getline(f, ln)) {
        if (ln.empty() || ln[0] == '#') continue;
        std::stringstream ss(ln); std::string a, bb;
        std::getline(ss, a, ','); std::getline(ss, bb, ',');
        out.push_back(C{std::stol(a) * lsb, std::stol(bb) * lsb});
    }
    return out;
}

static void write_hex_codes(const std::string &path, const std::vector<C> &x, int elast) {
    const double s = pow(2.0, elast);
    std::ofstream f(path);
    for (const C &v : x) {
        int i = (int)lround(v.re / s);
        int q = (int)lround(v.im / s);
        unsigned w = (((unsigned)i & 0xFFFF) << 16) | ((unsigned)q & 0xFFFF);
        char buf[16]; std::snprintf(buf, sizeof(buf), "%08x\n", w);
        f << buf;
    }
}

int main(int argc, char **argv) {
    if (argc < 5) {
        std::fprintf(stderr, "usage: %s N in.hex twiddle.csv out.hex [data_bits] [tw_bits]\n"
                             "  data_bits/tw_bits must match fft_golden.py --bits/--tw-bits\n",
                     argv[0]);
        return 2;
    }
    const int n = std::atoi(argv[1]);
    if (argc >= 6) NBITS = std::atoi(argv[5]);
    if (argc >= 7) NBITS_TW = std::atoi(argv[6]);
    std::vector<C> x = read_hex_codes(argv[2]);
    std::vector<C> tw = read_twiddle_csv(argv[3]);
    if ((int)x.size() != n) {
        std::fprintf(stderr, "input has %zu samples, expected N=%d\n", x.size(), n);
        return 2;
    }
    if ((int)tw.size() != n / 2) {
        std::fprintf(stderr, "twiddle has %zu entries, expected N/2=%d\n", tw.size(), n / 2);
        return 2;
    }
    int bfp_shift = fft1d_bfp_ref(x, tw);     // <-- swap for the kernel under test
    write_hex_codes(argv[4], x, bfp_shift);
    std::printf("wrote %s  N=%d  BFP_SHIFT=%d\n", argv[4], n, bfp_shift);
    return 0;
}
