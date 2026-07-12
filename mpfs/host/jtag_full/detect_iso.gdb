set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe C:/Users/lkwangsi/Documents/github/mpfs250t-sar-ifp/mpfs/host/jtag_full/wait_port.py
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

echo >>> loading 32KB const-1000 pattern -> cached SIG 0x88000000 ...\n
restore C:/Users/lkwangsi/Documents/github/mpfs250t-sar-ifp/mpfs/host/jtag_stage_small/fft_test_row.bin binary 0x88000000
echo >>> pre-clear OUT[0..3] so a stale non-zero can't fool us:\n
set *(unsigned int*)0xA8000000 = 0
set *(unsigned int*)0xA8000004 = 0
set *(unsigned int*)0xA8000008 = 0
set *(unsigned int*)0xA800000C = 0

echo >>> flush scene L2 -> physical DDR (so the FIC0 detect master can read it) ...\n
call (void) flush_l2_cache(1)

echo >>> arming K_DETECT (0x60002000): ARG0=in=SIG, ARG1=out=OUT, START ...\n
set *(unsigned int*)0x6000200C = 0x88000000
set *(unsigned int*)0x60002010 = 0xA8000000
set *(unsigned int*)0x60002008 = 1
monitor resume
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(10)"
monitor mpfs.hart1_u54_1 arp_halt
thread 2
printf ">>> K_DETECT busy(0=done) = %u\n", *(unsigned int*)0x60002008

echo >>> flush/evict OUT L2 so the host read fetches physical DDR ...\n
call (void) flush_l2_cache(1)
echo >>> OUT[0..7] (expect 0x03e803e8 = two uint16 mag=1000 if FIC0 SIG-read WORKS; 0 if BROKEN):\n
x/8xw 0xA8000000
printf ">>> VERDICT: OUT[0]=0x%08x  (0x03e803e8 => detect read SIG OK; 0 => FIC0 SIG-read broken)\n", *(unsigned int*)0xA8000000

monitor resume
monitor shutdown
quit
