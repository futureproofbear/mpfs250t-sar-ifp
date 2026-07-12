set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe C:/Users/lkwangsi/Documents/github/mpfs250t-sar-ifp/mpfs/host/jtag_full/wait_port.py
target extended-remote localhost:3333
monitor mpfs.hart1_u54_1 arp_halt
echo === SIG 0x88M (azimuth-FFT output, detect reads this) at rows 0/1000/4096/7152 ===\n
x/6xw 0x88000000
x/6xw 0x88fa0000
x/6xw 0x8a000000
x/6xw 0x8efc0000
echo === SCRATCH 0x98M (corner-turn / range-FFT intermediate) ===\n
x/6xw 0x98000000
x/6xw 0x9a000000
echo === OUT 0xA8M (detect output = final image) ===\n
x/6xw 0xa8000000
x/6xw 0xaa000000
x/6xw 0xaefc0000
monitor resume
monitor shutdown
quit
