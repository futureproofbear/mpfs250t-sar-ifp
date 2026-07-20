# NOTE: paths below are RELATIVE to mpfs/host/jtag_full -- run gdb with that as the
# working directory (the run_*.sh drivers cd there for you).
set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe wait_port.py
target extended-remote localhost:3333
monitor reset halt
monitor mpfs.hart1_u54_1 arp_halt
thread 2
monitor resume
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(30)"
monitor mpfs.hart1_u54_1 arp_halt
echo >>> load const re=1000 row to SIG 0x88000000\n
restore ../jtag_stage_small/fft_test_row.bin binary 0x88000000
call (void) flush_l2_cache(1)
printf ">>> SIG[0]=0x%08x (expect 0x03e80000)\n", *(unsigned int*)0x88000000
printf ">>> BEFORE arm: FEED status=0x%08x  UNLD status=0x%08x\n", *(unsigned int*)0x60004008, *(unsigned int*)0x60005008
set *(unsigned int*)0x60005010 = 4096
set *(unsigned int*)0x6000500c = 0x98000000
set *(unsigned int*)0x60005008 = 1
set *(unsigned int*)0x60004010 = 4096
set *(unsigned int*)0x6000400c = 0x88000000
printf ">>> FEED READBACK: ARG0(src)=0x%08x  ARG1(nbeats)=0x%08x\n", *(unsigned int*)0x6000400c, *(unsigned int*)0x60004010
printf ">>> UNLD READBACK: ARG0(dst)=0x%08x  ARG1(nbeats)=0x%08x\n", *(unsigned int*)0x6000500c, *(unsigned int*)0x60005010
set *(unsigned int*)0x60004008 = 1
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(5)"
monitor mpfs.hart1_u54_1 arp_halt
printf ">>> AFTER start+5s: FEED busy=0x%08x  UNLD busy=0x%08x\n", *(unsigned int*)0x60004008, *(unsigned int*)0x60005008
monitor resume
monitor shutdown
quit
