# sig_band_dump.gdb -- attach-only (NO reset: preserves the pipeline's DDR result). Raw-dump the
# azimuth-FFT output (SIG) rows 896..1023 so the host can compute |SIG| CORRECTLY and correlate to
# golden. If host-|SIG| corr ~0.99 while fabric OUT corr ~0, the detect kernel (unsigned-I sign bug)
# is the SOLE remaining fault. SIG rows 896.. = 0x89C00000; 128 rows *8192*4 = 0x400000 (4 MB).
set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe C:/Users/lkwangsi/Documents/github/sarProcessor/mpfs/host/jtag_full/wait_port.py
target extended-remote localhost:3333
monitor mpfs.hart1_u54_1 arp_halt
echo >>> raw-dumping SIG rows 896..1023 (azimuth-FFT output, 4 MB) -> sig_band.bin ...\n
dump binary memory C:/Users/lkwangsi/Documents/github/sarProcessor/mpfs/host/jtag_stage_small/sig_band.bin 0x89C00000 (0x89C00000 + 0x400000)
echo >>> SIG band dump done\n
monitor resume
monitor shutdown
quit
