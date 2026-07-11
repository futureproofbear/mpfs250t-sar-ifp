# debug_mbx.gdb -- attach-only diagnosis: is the firmware servicing the mailbox (seq incrementing?),
# where is hart1 (PC), and is the loaded sig data intact at 0x88000000?
set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe C:/Users/lkwangsi/Documents/github/sarProcessor/mpfs/host/jtag_full/wait_port.py
target extended-remote localhost:3333
monitor mpfs.hart1_u54_1 arp_halt
printf ">>> mbx cmd=0x%08x status=0x%08x seq=0x%08x  hart1 pc=%p\n", *(unsigned int*)0xB0058000, *(unsigned int*)0xB0058010, *(unsigned int*)0xB0058018, $pc
printf ">>> sig[0..3] @0x88000000 = 0x%08x 0x%08x 0x%08x 0x%08x (want 0x004a0041 0xff60ffd9 0x00b5fffa 0xff7b0030)\n", *(unsigned int*)0x88000000, *(unsigned int*)0x88000004, *(unsigned int*)0x88000008, *(unsigned int*)0x8800000c
printf ">>> sig[last-ish] @0x8D800000 = 0x%08x 0x%08x\n", *(unsigned int*)0x8D800000, *(unsigned int*)0x8D800004
monitor resume
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(3)"
monitor mpfs.hart1_u54_1 arp_halt
printf ">>> after 3s: mbx seq=0x%08x (if changed vs above, firmware IS looping)\n", *(unsigned int*)0xB0058018
monitor resume
monitor shutdown
quit
