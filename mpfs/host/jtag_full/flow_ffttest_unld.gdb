# flow_ffttest_unld.gdb -- verify the range-FFT now COMPLETES with the fft_unloader (HLS AXI
# write master) replacing the deadlocking CoreAXI4DMAController. Arms sar_fft_hold (feeder +
# CoreFFT + unloader over the whole frame, NO firmware timeout) and samples FEEDER-busy and
# UNLOADER-busy over ~90s. Fix works => BOTH go to 0 (done). Still hung => they stay busy.
#
# Control-plane (AXIIC_CTRL SLAVE windows, +0x08 = START/STATUS: read 1=busy, 0=idle/done):
#   FEEDER   START @ 0x60004008
#   UNLOADER START @ 0x60005008   (was the DMA slave; now the fft_unloader HLS kernel)
# Progress (DDR, JTAG-pollable): SAR_PROG @ 0xB0059100 = [pass, idx, total, heartbeat].
set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe C:/Users/lkwangsi/Documents/github/sarProcessor/mpfs/host/jtag_full/wait_port.py
target extended-remote localhost:3333
monitor mpfs.hart0_e51 arp_halt
monitor mpfs.hart1_u54_1 arp_halt
thread 2
echo \n>>> arming sar_fft_hold (whole-frame FFT stream: feeder + CoreFFT + unloader, no wait)\n
p (void)sar_fft_hold()
printf ">>> t0   FEED=0x%08x  UNLD=0x%08x  PROG idx=%u/%u hb=%u\n", *(unsigned int*)0x60004008, *(unsigned int*)0x60005008, *(unsigned int*)0xB0059104, *(unsigned int*)0xB0059108, *(unsigned int*)0xB005910C
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time; time.sleep(15)"
printf ">>> t15  FEED=0x%08x  UNLD=0x%08x  PROG idx=%u/%u hb=%u\n", *(unsigned int*)0x60004008, *(unsigned int*)0x60005008, *(unsigned int*)0xB0059104, *(unsigned int*)0xB0059108, *(unsigned int*)0xB005910C
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time; time.sleep(15)"
printf ">>> t30  FEED=0x%08x  UNLD=0x%08x  PROG idx=%u/%u hb=%u\n", *(unsigned int*)0x60004008, *(unsigned int*)0x60005008, *(unsigned int*)0xB0059104, *(unsigned int*)0xB0059108, *(unsigned int*)0xB005910C
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time; time.sleep(30)"
printf ">>> t60  FEED=0x%08x  UNLD=0x%08x  PROG idx=%u/%u hb=%u\n", *(unsigned int*)0x60004008, *(unsigned int*)0x60005008, *(unsigned int*)0xB0059104, *(unsigned int*)0xB0059108, *(unsigned int*)0xB005910C
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time; time.sleep(30)"
printf ">>> t90  FEED=0x%08x  UNLD=0x%08x  PROG idx=%u/%u hb=%u\n", *(unsigned int*)0x60004008, *(unsigned int*)0x60005008, *(unsigned int*)0xB0059104, *(unsigned int*)0xB0059108, *(unsigned int*)0xB005910C
echo \n>>> FEED/UNLD b0: 1=busy 0=done. BOTH 0 => range-FFT stream completed (fix works).\n
echo >>> SCRATCH[0..3] (0x98000000, FFT output data -- nonzero/changed => beats were written):\n
x/4xw 0x98000000
monitor resume
monitor shutdown
quit
