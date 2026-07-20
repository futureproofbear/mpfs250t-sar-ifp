# NOTE: paths below are RELATIVE to mpfs/host/jtag_full -- run gdb with that as the
# working directory (the run_*.sh drivers cd there for you).
# flow_hold.gdb -- arm the FFT feeder and HOLD the stall live in fabric for SmartDebug.
# Calls sar_fft_hold() (arms DMA + starts feeder from BUF_SCRATCH, returns immediately),
# then detaches. The feeder runs/stalls autonomously in fabric while OpenOCD is killed
# and SmartDebug takes the FlashPro6. No SIG/geometry load -> fast.
set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe wait_port.py
echo \n>>> attached; halting hart0 + U54_1\n
target extended-remote localhost:3333
monitor mpfs.hart0_e51 arp_halt
monitor mpfs.hart1_u54_1 arp_halt
thread 2
echo \n>>> arming feeder-hold: sar_fft_hold()\n
p (void)sar_fft_hold()
# give the feeder a moment to start + attempt its first reads
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time; time.sleep(1)"
printf ">>> FEED ap_ctrl @0x60004000 = 0x%08x (b0 start b1 done b2 idle)\n", *(unsigned int*)0x60004000
printf ">>> DMA I0ST  @0x60005010 = 0x%08x (b0 CPLT b1 DWERR b2 DRERR b3 INVDESC)\n", *(unsigned int*)0x60005010
echo \n>>> feeder armed + running in fabric; clean shutdown (leaves fabric running)\n
monitor resume
monitor shutdown
quit
