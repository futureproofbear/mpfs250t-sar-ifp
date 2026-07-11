# dbg_fft.gdb -- read the range-FFT timeout diagnostic left by fft_pass @0xB0059200 and the
# live feeder/unloader busy state, after the pipeline stalled at range-FFT. No reset (preserve
# the stalled fabric state). dbg[0]=feeder busy, [1]=unloader busy, [2]=feeder nbeats,
# [3]=unloader nbeats, [4]=src, [5]=dst.
set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe C:/Users/lkwangsi/Documents/github/sarProcessor/mpfs/host/jtag_full/wait_port.py
target extended-remote localhost:3333
monitor mpfs.hart1_u54_1 arp_halt
printf ">>> FFT timeout snapshot @0xB0059200:\n"
printf ">>>   feeder_busy=0x%08x  unloader_busy=0x%08x\n", *(unsigned int*)0xB0059200, *(unsigned int*)0xB0059204
printf ">>>   feeder_nbeats=%u  unloader_nbeats=%u\n", *(unsigned int*)0xB0059208, *(unsigned int*)0xB005920C
printf ">>>   src=0x%08x  dst=0x%08x\n", *(unsigned int*)0xB0059210, *(unsigned int*)0xB0059214
printf ">>> LIVE now: feeder START(0x60004008)=0x%08x  unloader START(0x60005008)=0x%08x\n", *(unsigned int*)0x60004008, *(unsigned int*)0x60005008
printf ">>> SCRATCH(range-FFT src 0x98000000)[0..3]: %08x %08x %08x %08x\n", *(unsigned int*)0x98000000, *(unsigned int*)0x98000004, *(unsigned int*)0x98000008, *(unsigned int*)0x9800000C
printf ">>> SIG(range-FFT dst 0x88000000)[0..3]:     %08x %08x %08x %08x\n", *(unsigned int*)0x88000000, *(unsigned int*)0x88000004, *(unsigned int*)0x88000008, *(unsigned int*)0x8800000C
monitor resume
monitor shutdown
quit
