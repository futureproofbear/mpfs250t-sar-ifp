# NOTE: paths below are RELATIVE to mpfs/host/jtag_full -- run gdb with that as the
# working directory (the run_*.sh drivers cd there for you).
set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe wait_port.py
target extended-remote localhost:3333
monitor mpfs.hart1_u54_1 arp_halt
thread 2
printf ">>> xfrm0 dst 0x98000000: %08x %08x %08x %08x\n", *(unsigned int*)0x98000000, *(unsigned int*)0x98000004, *(unsigned int*)0x98000008, *(unsigned int*)0x9800000C
printf ">>> xfrm0 dst +0x7FF0    : %08x %08x %08x %08x\n", *(unsigned int*)0x98007FF0, *(unsigned int*)0x98007FF4, *(unsigned int*)0x98007FF8, *(unsigned int*)0x98007FFC
printf ">>> xfrm1 dst 0x98008000: %08x %08x %08x %08x\n", *(unsigned int*)0x98008000, *(unsigned int*)0x98008004, *(unsigned int*)0x98008008, *(unsigned int*)0x9800800C
printf ">>> xfrm1 dst +0x7FF0    : %08x %08x %08x %08x\n", *(unsigned int*)0x9800FFF0, *(unsigned int*)0x9800FFF4, *(unsigned int*)0x9800FFF8, *(unsigned int*)0x9800FFFC
monitor resume
monitor shutdown
quit
