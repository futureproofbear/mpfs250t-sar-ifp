set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
set logging file ffttest2_gdb.log
set logging overwrite on
set logging on
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe C:/Users/lkwangsi/Documents/github/sarProcessor/mpfs/host/jtag_full/wait_port.py
target extended-remote localhost:3333
monitor mpfs.hart0_e51 arp_halt
monitor mpfs.hart1_u54_1 arp_halt
thread 2
printf ">>> attached pc=0x%lx\n", $pc
printf ">>> sar_fft_pass_test @ %p\n", sar_fft_pass_test
echo \n>>> calling sar_fft_pass_test() ...\n
set $r = (int)sar_fft_pass_test()
printf ">>> FFT_TEST RETURN=%d\n", $r
printf ">>> DMADBG chunk=%u INTR0=0x%08x EXT=0x%08x STARTOP=0x%08x\n", *(unsigned int*)0xB0059200, *(unsigned int*)0xB0059204, *(unsigned int*)0xB0059208, *(unsigned int*)0xB005920C
printf ">>> DMADBG desc cfg=0x%08x bytes=0x%08x dst=0x%08x\n", *(unsigned int*)0xB0059210, *(unsigned int*)0xB0059214, *(unsigned int*)0xB0059218
printf ">>> DMADBG feeder=0x%08x INTR_reread=0x%08x VER=0x%08x\n", *(unsigned int*)0xB005921C, *(unsigned int*)0xB0059220, *(unsigned int*)0xB0059224
monitor resume
monitor shutdown
quit
