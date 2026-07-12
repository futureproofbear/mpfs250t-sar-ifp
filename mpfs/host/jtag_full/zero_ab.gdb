# zero_ab.gdb -- is an ALL-ZERO transform the trigger? Fresh single transform, feeder reads SCRATCH
# row0 preloaded with zeros (A) vs ones (B), unloader -> SIG. A stall + B complete => all-zero wedges the chain.
set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe C:/Users/lkwangsi/Documents/github/mpfs250t-sar-ifp/mpfs/host/jtag_full/wait_port.py
target extended-remote localhost:3333
define run_one
  monitor reset halt
  monitor mpfs.hart0_e51 arp_halt
  monitor mpfs.hart1_u54_1 arp_halt
  thread 2
  monitor resume
  shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(32)"
  monitor mpfs.hart1_u54_1 arp_halt
  restore $arg0 binary 0x98000000
  printf ">>> SCRATCH[0..1]=%08x %08x\n", *(unsigned int*)0x98000000, *(unsigned int*)0x98000004
  set *(unsigned int*)0x60005010 = 4096
  set *(unsigned int*)0x6000500c = 0x88000000
  set *(unsigned int*)0x60005008 = 1
  set *(unsigned int*)0x60004010 = 4096
  set *(unsigned int*)0x6000400c = 0x98000000
  set *(unsigned int*)0x60004008 = 1
  shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(10)"
  printf ">>> feeder=0x%08x unloader=0x%08x  (0/0=COMPLETE 1/1=STALL)\n", *(unsigned int*)0x60004008, *(unsigned int*)0x60005008
end
echo \n===== TEST A: SCRATCH row0 = ALL ZERO =====\n
run_one zero32k.bin
echo \n===== TEST B: SCRATCH row0 = NON-ZERO (ones) =====\n
run_one ones32k.bin
monitor resume
monitor shutdown
quit
