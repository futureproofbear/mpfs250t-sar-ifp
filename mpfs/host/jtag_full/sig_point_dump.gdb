# NOTE: paths below are RELATIVE to mpfs/host/jtag_full -- run gdb with that as the
# working directory (the run_*.sh drivers cd there for you).
# sig_point_dump.gdb -- attach-only (no reset). Dump SIG (azimuth output) rows 1008..1071 (64 rows,
# 2 MB) which BRACKET the golden's focused point at row 1039, so host-|SIG| can be correlated to
# golden where the energy actually is. SIG row 1008 = 0x88000000 + 1008*8192*4 = 0x89F80000.
set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe wait_port.py
target extended-remote localhost:3333
monitor mpfs.hart1_u54_1 arp_halt
echo >>> raw-dumping SIG rows 1008..1071 (2 MB) -> sig_point.bin ...\n
dump binary memory ../jtag_stage_small/sig_point.bin 0x89F80000 (0x89F80000 + 0x200000)
echo >>> done\n
monitor resume
monitor shutdown
quit
