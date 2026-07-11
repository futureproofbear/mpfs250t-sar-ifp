set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe C:/Users/lkwangsi/Documents/github/sarProcessor/mpfs/host/jtag_full/wait_port.py
target extended-remote localhost:3333
monitor mpfs.hart1_u54_1 arp_halt
thread 2
printf ">>> SAR_PROG pass=%u idx=%u/%u hb=%u\n", *(unsigned int*)0xB0059100, *(unsigned int*)0xB0059104, *(unsigned int*)0xB0059108, *(unsigned int*)0xB005910C
printf ">>> x0=%08x x1=%08x x2=%08x x3=%08x x5=%08x x10=%08x\n", *(unsigned int*)0x98000000, *(unsigned int*)0x98008000, *(unsigned int*)0x98010000, *(unsigned int*)0x98018000, *(unsigned int*)0x98028000, *(unsigned int*)0x98050000
printf ">>> x100=%08x x500=%08x x1000=%08x x4000=%08x x8000=%08x x8191=%08x\n", *(unsigned int*)0x98500000, *(unsigned int*)0x99900000, *(unsigned int*)0x9B000000, *(unsigned int*)0xA0000000, *(unsigned int*)0xA7C00000, *(unsigned int*)0xA7FF8000
printf ">>> (0x20002000=written/DC-spike, 0xDEADBEEF=never written)\n"
monitor resume
monitor shutdown
quit
