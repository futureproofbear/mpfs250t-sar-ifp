# attach_sig_out.gdb -- attach-only (no reset) to the idle board after a pipeline run; dump SIG
# (azimuth-FFT output, complex) and OUT (detect, uint16) for the SAME rows 896.. so |SIG| can be
# compared pixel-for-pixel with OUT. SIG rows 896.. = 0x88000000 + 896*8192*4 = 0x89C00000.
# OUT rows 896.. = 0xA8000000 + 896*8192*2 = 0xA8E00000. Dump 32 rows each (aligned).
set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe C:/Users/lkwangsi/Documents/github/sarProcessor/mpfs/host/jtag_full/wait_port.py
target extended-remote localhost:3333
monitor mpfs.hart1_u54_1 arp_halt
# (flush omitted: pipeline already flushed; this gdb build crashes on call)
echo >>> SIG rows 896..903 [0..3] (azimuth out, re<<16|im):\n
x/4xw 0x89C00000
echo >>> OUT rows 896..903 [0..3] (detect |.|, two uint16 per word):\n
x/4xw 0xA8E00000
echo >>> dump SIG rows 896..927 (32 rows, 1MB) -> sig_r896.bin\n
dump binary memory C:/Users/lkwangsi/Documents/github/sarProcessor/mpfs/host/jtag_stage_small/sig_r896.bin 0x89C00000 (0x89C00000 + 0x100000)
echo >>> dump OUT rows 896..927 (32 rows, 512KB) -> out_r896.bin\n
dump binary memory C:/Users/lkwangsi/Documents/github/sarProcessor/mpfs/host/jtag_stage_small/out_r896.bin 0xA8E00000 (0xA8E00000 + 0x80000)
echo >>> dumps done\n
monitor resume
monitor shutdown
quit
