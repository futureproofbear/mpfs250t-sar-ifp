# flow_ffttest.gdb -- isolate whether the range-FFT now WORKS (just slow) vs still hung.
# Arms sar_fft_hold (feeder+FFT+DMA over the whole frame, NO firmware timeout), then
# samples the DMA completion + feeder-busy over ~60s. If the fix works, the DMA should
# make progress / complete (I0ST CPLT); if still hung, I0ST stays 0 and feeder stays busy.
set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe C:/Users/lkwangsi/Documents/github/sarProcessor/mpfs/host/jtag_full/wait_port.py
target extended-remote localhost:3333
monitor mpfs.hart0_e51 arp_halt
monitor mpfs.hart1_u54_1 arp_halt
thread 2
echo \n>>> arming sar_fft_hold (whole-frame FFT stream, no wait)\n
p (void)sar_fft_hold()
printf ">>> t0   FEED_START=0x%08x  DMA_I0ST=0x%08x\n", *(unsigned int*)0x60004008, *(unsigned int*)0x60005010
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time; time.sleep(15)"
printf ">>> t15  FEED_START=0x%08x  DMA_I0ST=0x%08x\n", *(unsigned int*)0x60004008, *(unsigned int*)0x60005010
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time; time.sleep(15)"
printf ">>> t30  FEED_START=0x%08x  DMA_I0ST=0x%08x\n", *(unsigned int*)0x60004008, *(unsigned int*)0x60005010
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time; time.sleep(30)"
printf ">>> t60  FEED_START=0x%08x  DMA_I0ST=0x%08x\n", *(unsigned int*)0x60004008, *(unsigned int*)0x60005010
echo \n>>> (FEED_START b0: 1=busy/running 0=done; DMA_I0ST b0=CPLT b1=DWERR b2=DRERR b3=INVDESC)\n
monitor resume
monitor shutdown
quit
