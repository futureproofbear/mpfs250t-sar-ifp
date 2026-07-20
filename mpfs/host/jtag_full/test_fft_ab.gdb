# NOTE: paths below are RELATIVE to mpfs/host/jtag_full -- run gdb with that as the
# working directory (the run_*.sh drivers cd there for you).
# test_fft_ab.gdb -- decisive test: does CoreFFT stall on an ALL-ZERO transform?
# Runs ONE 8192-pt transform (nbeats=4096) via direct feeder/unloader register control:
#   B) non-zero input (ones32k) -> expect COMPLETE (both START -> 0)
#   A) all-zero input (zero32k) -> hypothesis: STALL (both START stay 1)
# Feeder  K_FFT_FEEDER  0x60004000: start@+8, src@+0xc, nbeats@+0x10
# Unloader K_FFT_UNLOADER 0x60005000: start@+8, dst@+0xc, nbeats@+0x10
set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe wait_port.py
target extended-remote localhost:3333
monitor reset halt
monitor mpfs.hart0_e51 arp_halt
monitor mpfs.hart1_u54_1 arp_halt
thread 2
echo \n>>> booting (reset) -> M2 -> mailbox loop ...\n
monitor resume
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(32)"
monitor mpfs.hart1_u54_1 arp_halt

echo \n>>> ===== TEST B: ONE transform, NON-ZERO input (ones32k @ SCRATCH) =====\n
cd ../jtag_full
restore ones32k.bin binary 0x98000000
printf ">>> SCRATCH[0..1]=%08x %08x  (expect non-zero)\n", *(unsigned int*)0x98000000, *(unsigned int*)0x98000004
set *(unsigned int*)0x60005010 = 4096
set *(unsigned int*)0x6000500c = 0x88000000
set *(unsigned int*)0x60005008 = 1
set *(unsigned int*)0x60004010 = 4096
set *(unsigned int*)0x6000400c = 0x98000000
set *(unsigned int*)0x60004008 = 1
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(6)"
printf ">>> B result: feeder=0x%08x unloader=0x%08x  (0/0 => COMPLETE, 1/1 => STALL)\n", *(unsigned int*)0x60004008, *(unsigned int*)0x60005008
printf ">>> B dst SIG[0..1]=%08x %08x\n", *(unsigned int*)0x88000000, *(unsigned int*)0x88000004

echo \n>>> ===== TEST A: ONE transform, ALL-ZERO input (zero32k @ SCRATCH) =====\n
restore zero32k.bin binary 0x98000000
printf ">>> SCRATCH[0..1]=%08x %08x  (expect 0)\n", *(unsigned int*)0x98000000, *(unsigned int*)0x98000004
set *(unsigned int*)0x60005010 = 4096
set *(unsigned int*)0x6000500c = 0x88000000
set *(unsigned int*)0x60005008 = 1
set *(unsigned int*)0x60004010 = 4096
set *(unsigned int*)0x6000400c = 0x98000000
set *(unsigned int*)0x60004008 = 1
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(6)"
printf ">>> A result: feeder=0x%08x unloader=0x%08x  (0/0 => COMPLETE, 1/1 => STALL on all-zero)\n", *(unsigned int*)0x60004008, *(unsigned int*)0x60005008
monitor resume
monitor shutdown
quit
