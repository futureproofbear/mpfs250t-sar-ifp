# peek_sig_out.gdb -- attach-only; read SIG (azimuth out, complex) + OUT (detect |.|) for the same
# rows 896.. via x/ (no slow bulk dump). Reveals whether detect saturates on a small |SIG| (detect
# bug) or a large |SIG| (azimuth over-scale) -- pixel by pixel.
set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
target extended-remote localhost:3333
monitor mpfs.hart1_u54_1 arp_halt
echo >>> SIG rows896 samples[0..15] (re<<16|im, complex azimuth-FFT output):\n
x/16xw 0x89C00000
echo >>> OUT rows896 samples[0..31] (two uint16 |.| per word):\n
x/16xw 0xA8E00000
monitor resume
monitor shutdown
quit
