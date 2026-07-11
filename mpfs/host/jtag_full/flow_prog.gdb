set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
set logging file C:/Users/lkwangsi/Documents/github/sarProcessor/mpfs/host/jtag_full/gdb_prog.log
set logging overwrite on
set logging on
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe C:/Users/lkwangsi/Documents/github/sarProcessor/mpfs/host/jtag_full/wait_port.py
target extended-remote localhost:3333
monitor mpfs.hart0_e51 arp_halt
monitor mpfs.hart1_u54_1 arp_halt
thread 2
echo \n>>> loading geometry (no SIG)...\n
source load_geom.gdb
set *(unsigned int*)0xB005910C = 0
echo \n>>> RUNNING sar_form_image(0) bounded ~20s/stage...\n
p (int)sar_form_image(0)
printf ">>> RETURN=%d (0 OK,2 RESAMPLE,3 WINDOW,4 FFT1,5 CORNER,6 FFT2,7 DETECT,8 DMA)\n", (int)$
printf ">>> PROGRESS pass=%u  idx=%u  total=%u  heartbeat=%u\n", *(unsigned int*)0xB0059100, *(unsigned int*)0xB0059104, *(unsigned int*)0xB0059108, *(unsigned int*)0xB005910C
printf ">>> RES ap_ctrl 0x60003000 = 0x%08x\n", *(unsigned int*)0x60003000
echo \n=== PROG TEST DONE ===\n
