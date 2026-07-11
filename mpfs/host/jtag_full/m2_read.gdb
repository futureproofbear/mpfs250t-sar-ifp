set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe C:/Users/lkwangsi/Documents/github/sarProcessor/mpfs/host/jtag_full/wait_port.py
target extended-remote localhost:3333
monitor mpfs.hart1_u54_1 arp_halt
echo >>> M2 results @0xB0050000 (tag,addr,obs,exp,status; status 0=PASS 1=FAIL 2=FAULT 3=HANG):\n
x/160xw 0xB0050000
monitor resume
monitor shutdown
quit
