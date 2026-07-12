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
echo >>> arming transform-1 stall via sar_fft_pass_test (returns ~4s)...\n
set $r = (int)sar_fft_pass_test()
printf ">>> RETURN=%d  SAR_PROG idx=%u/%u  feeder=%08x  INTR0=%08x  desc-dst=%08x\n", $r, *(unsigned int*)0xB0059104, *(unsigned int*)0xB0059108, *(unsigned int*)0x60004008, *(unsigned int*)0x60005010, *(unsigned int*)0xB0059008
echo >>> HELD: fabric is in the transform-1 stall. Leaving hart running, releasing JTAG.\n
monitor resume
monitor shutdown
quit
