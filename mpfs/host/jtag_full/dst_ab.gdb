# NOTE: paths below are RELATIVE to mpfs/host/jtag_full -- run gdb with that as the
# working directory (the run_*.sh drivers cd there for you).
# dst_ab.gdb -- isolate whether the range-FFT stall is the DESTINATION ADDRESS (unloader writing
# SIG 0x88M) or the PRIOR-KERNEL STATE. Two FRESH single-transform FFTs driven directly through the
# feeder/unloader registers (no resample/window before them):
#   A) SCRATCH(0x98M) -> SIG(0x88M)     == the pipeline range-FFT config that stalls
#   B) SCRATCH(0x98M) -> SCRATCH(0x98M) == the standalone config that worked
# A stalls & B completes => the SIG WRITE is the trigger (isolated). Both complete => it's the
# pipeline prior-state. Both stall => the FIFO bitstream regressed the FFT path.
# Feeder K_FFT_FEEDER 0x60004000: start@+8 src@+0xc nbeats@+0x10 ; Unloader 0x60005000: start@+8 dst@+0xc nbeats@+0x10
set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe wait_port.py
target extended-remote localhost:3333

define run_one
  # $arg0 = unloader dst addr ; boots fresh, arms unloader then feeder (nbeats=4096=1 transform), samples
  monitor reset halt
  monitor mpfs.hart0_e51 arp_halt
  monitor mpfs.hart1_u54_1 arp_halt
  thread 2
  monitor resume
  shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(32)"
  monitor mpfs.hart1_u54_1 arp_halt
  set *(unsigned int*)0x60005010 = 4096
  set *(unsigned int*)0x6000500c = $arg0
  set *(unsigned int*)0x60005008 = 1
  set *(unsigned int*)0x60004010 = 4096
  set *(unsigned int*)0x6000400c = 0x98000000
  set *(unsigned int*)0x60004008 = 1
  shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(10)"
  printf ">>> dst=0x%08x : feeder=0x%08x unloader=0x%08x  (0/0=COMPLETE, 1/1=STALL)\n", $arg0, *(unsigned int*)0x60004008, *(unsigned int*)0x60005008
  printf ">>>   dst[0..3]: %08x %08x %08x %08x\n", *(unsigned int*)$arg0, *(unsigned int*)($arg0+4), *(unsigned int*)($arg0+8), *(unsigned int*)($arg0+12)
end

echo \n===== TEST A: SCRATCH(0x98000000) -> SIG(0x88000000)  [pipeline config] =====\n
run_one 0x88000000
echo \n===== TEST B: SCRATCH(0x98000000) -> SCRATCH(0x98000000)  [known-good config] =====\n
run_one 0x98000000
monitor resume
monitor shutdown
quit
