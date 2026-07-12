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
echo \n>>> booting (battery)...\n
monitor resume
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(25)"
monitor mpfs.hart1_u54_1 arp_halt
echo >>> filling 0x98000000..+0x20000 with 0x00010001 (I=1,Q=1)...\n
restore fill_ones.bin binary 0x98000000
printf ">>> pre-run  in[0]=%08x in[1]=%08x  xfrm1in[0x8000]=%08x\n", *(unsigned int*)0x98000000, *(unsigned int*)0x98000004, *(unsigned int*)0x98008000
echo >>> calling sar_fft_pass_test() (returns ~4s at xfrm1 stall)...\n
set $r = (int)sar_fft_pass_test()
printf ">>> RETURN=%d\n", $r
printf ">>> SAR_PROG pass=%u idx=%u/%u hb=%u\n", *(unsigned int*)0xB0059100, *(unsigned int*)0xB0059104, *(unsigned int*)0xB0059108, *(unsigned int*)0xB005910C
printf ">>> xfrm0 out 0x98000000: %08x %08x %08x %08x %08x %08x\n", *(unsigned int*)0x98000000, *(unsigned int*)0x98000004, *(unsigned int*)0x98000008, *(unsigned int*)0x9800000C, *(unsigned int*)0x98000010, *(unsigned int*)0x98000014
printf ">>> xfrm1 out 0x98008000: %08x %08x %08x %08x %08x %08x\n", *(unsigned int*)0x98008000, *(unsigned int*)0x98008004, *(unsigned int*)0x98008008, *(unsigned int*)0x9800800C, *(unsigned int*)0x98008010, *(unsigned int*)0x98008014
monitor resume
monitor shutdown
quit
