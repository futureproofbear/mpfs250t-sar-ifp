# NOTE: paths below are RELATIVE to mpfs/host/jtag_full -- run gdb with that as the
# working directory (the run_*.sh drivers cd there for you).
# dump_out_band.gdb -- read back a contiguous horizontal band of the OUT image (detected
# magnitude, uint16) from DDR over JTAG. Rows [0:256] of the 8192-wide image = 256*8192*2 =
# 0x400000 bytes (4 MB) starting at OUT_ADDR 0xA8000000. Band 0 is the brightest (DC corner of
# the non-shifted FFT). Dumping the full 128 MB OUT is impractical over JTAG; a band suffices
# for a correlation check vs the golden. Run AFTER flow_pipe_small.gdb (OUT persists in DDR).
set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe wait_port.py
target extended-remote localhost:3333
monitor mpfs.hart1_u54_1 arp_halt
echo >>> dumping OUT rows [0:256] (4 MB) ...\n
dump binary memory ../jtag_stage_small/out_band.bin 0xA8000000 0xA8400000
echo >>> dump done\n
monitor resume
monitor shutdown
quit
