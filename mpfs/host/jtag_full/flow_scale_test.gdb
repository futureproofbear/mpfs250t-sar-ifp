set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe C:/Users/lkwangsi/Documents/github/sarProcessor/mpfs/host/jtag_full/wait_port.py
target extended-remote localhost:3333
monitor reset halt
monitor mpfs.hart1_u54_1 arp_halt
thread 2
echo \n>>> booting firmware ...\n
monitor resume
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(30)"
monitor mpfs.hart1_u54_1 arp_halt
set *(unsigned int*)0xB0059110 = 1
set *(unsigned int*)0xB0059114 = 0
echo >>> running sar_fabric_scale_test (2 DC rows 16:1, fabric range-FFT) ...\n
call (int) sar_fabric_scale_test()
call (void) flush_l2_cache(1)
printf ">>> SCRATCH row0 bin0 = 0x%08x   row1 bin0 = 0x%08x\n", *(unsigned int*)0x98000000, *(unsigned int*)0x98008000
printf ">>> captured exp: row0=%u  row1=%u (expect 11 and 7)\n", *(unsigned char*)0x0A021B60, *(unsigned char*)0x0A021B61
monitor resume
monitor shutdown
quit
