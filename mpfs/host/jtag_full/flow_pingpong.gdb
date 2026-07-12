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
echo \n>>> booting...\n
monitor resume
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(25)"
monitor mpfs.hart1_u54_1 arp_halt
echo >>> fill SIG(0x88000000)=1s [input], SCRATCH(0x98000000)=0xDEADBEEF [output canvas]...\n
restore fill_ones.bin binary 0x88000000
restore fill_dead.bin binary 0x98000000
printf ">>> pre: SIG in[0]=%08x  SCRATCH out0[0]=%08x  out1[0x8000]=%08x\n", *(unsigned int*)0x88000000, *(unsigned int*)0x98000000, *(unsigned int*)0x98008000
echo >>> calling fft_pass(SIG=0x88000000 -> SCRATCH=0x98000000) DECOUPLED...\n
set $r = (int)fft_pass(0x88000000, 0x98000000, 0x00200000)
printf ">>> RETURN=%d  SAR_PROG idx=%u/%u hb=%u\n", $r, *(unsigned int*)0xB0059104, *(unsigned int*)0xB0059108, *(unsigned int*)0xB005910C
printf ">>> xfrm0 out 0x98000000: %08x %08x %08x %08x\n", *(unsigned int*)0x98000000, *(unsigned int*)0x98000004, *(unsigned int*)0x98000008, *(unsigned int*)0x9800000C
printf ">>> xfrm1 out 0x98008000: %08x %08x %08x %08x  (0xDEADBEEF=NOT written, 0x20002000=WRITTEN!)\n", *(unsigned int*)0x98008000, *(unsigned int*)0x98008004, *(unsigned int*)0x98008008, *(unsigned int*)0x9800800C
printf ">>> xfrm2 out 0x98010000: %08x   xfrm3 0x98018000: %08x\n", *(unsigned int*)0x98010000, *(unsigned int*)0x98018000
monitor resume
monitor shutdown
quit
