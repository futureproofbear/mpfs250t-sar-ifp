set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe jtag_full/wait_port.py
target extended-remote localhost:3333
monitor mpfs.hart1_u54_1 arp_halt
thread 2
set *(unsigned int*)0xB005911C = 0
printf ">>> SAR_GATHERMODE = %u\n", *(unsigned int*)0xB005911C
monitor resume
monitor shutdown
quit
