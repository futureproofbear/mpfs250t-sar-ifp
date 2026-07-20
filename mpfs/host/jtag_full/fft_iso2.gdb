# NOTE: paths below are RELATIVE to mpfs/host/jtag_full -- run gdb with that as the
# working directory (the run_*.sh drivers cd there for you).
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
echo \n>>> booting firmware ...\n
monitor resume
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(28)"
monitor mpfs.hart1_u54_1 arp_halt
thread 2

echo >>> loading 32KB const-1000 row -> cached SIG 0x88000000 ...\n
restore ../jtag_stage_small/fft_test_row.bin binary 0x88000000
echo >>> pre-clear SCRATCH[0..3]:\n
set *(unsigned int*)0x98000000 = 0
set *(unsigned int*)0x98000004 = 0
set *(unsigned int*)0x98000008 = 0
set *(unsigned int*)0x9800000C = 0

echo >>> flush scene L2 -> physical DDR ...\n
call (void) flush_l2_cache(1)

echo >>> arming K_FFT (0x60004000): ARG0=src=SIG, ARG1=dst=SCRATCH, ARG2=nrows=1, START ...\n
set *(unsigned int*)0x6000400C = 0x88000000
set *(unsigned int*)0x60004010 = 0x98000000
set *(unsigned int*)0x60004014 = 1
set *(unsigned int*)0x60004008 = 1
monitor resume
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(8)"
monitor mpfs.hart1_u54_1 arp_halt
thread 2
printf ">>> K_FFT busy(0=done) = %u\n", *(unsigned int*)0x60004008

echo >>> flush/evict SCRATCH L2 so host read fetches physical DDR ...\n
call (void) flush_l2_cache(1)
echo >>> SCRATCH row0 [0..7] (expect DC bin0 ~0x7D000000=32000, rest ~0 for const input):\n
x/8xw 0x98000000
printf ">>> VERDICT: SCRATCH[0]=0x%08x  (~0x7Dxx0000 => BFP FFT works; 0 => FFT emits zero)\n", *(unsigned int*)0x98000000

monitor resume
monitor shutdown
quit
