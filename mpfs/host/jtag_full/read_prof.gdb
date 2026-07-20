# NOTE: paths below are RELATIVE to mpfs/host/jtag_full -- run gdb with that as the
# working directory (the run_*.sh drivers cd there for you).
# read_prof.gdb -- read the azimuth-resample profiling counters (mcycle sums)
# written by resample_2pass at 0xB0059120: [tc coeff][tw kernel-wait][tf flush], each uint64.
# Attach-only (no reset) so the just-run pipeline's DDR scratch persists.
set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe wait_port.py
target extended-remote localhost:3333
monitor mpfs.hart1_u54_1 arp_halt
printf ">>> azimuth-pass mcycle split:\n"
printf ">>> tc (coeff-compute) = %llu\n", *(unsigned long long*)0xB0059120
printf ">>> tw (kernel-wait)   = %llu\n", *(unsigned long long*)0xB0059128
printf ">>> tf (flush)         = %llu\n", *(unsigned long long*)0xB0059130
printf ">>> tw1 (pass1 kernel-wait, M lines) = %llu\n", *(unsigned long long*)0xB0059140
monitor resume
monitor shutdown
quit
