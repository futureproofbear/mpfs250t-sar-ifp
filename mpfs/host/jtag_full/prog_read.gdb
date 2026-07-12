set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe C:/Users/lkwangsi/Documents/github/mpfs250t-sar-ifp/mpfs/host/jtag_full/wait_port.py
target extended-remote localhost:3333
monitor mpfs.hart1_u54_1 arp_halt
printf ">>> SAR_PROG @0xB0059100: pass=%u idx=%u total=%u hb=%u\n", *(unsigned int*)0xB0059100, *(unsigned int*)0xB0059104, *(unsigned int*)0xB0059108, *(unsigned int*)0xB005910C
printf ">>> mailbox result=%d status=0x%08x\n", *(int*)0xB005800C, *(unsigned int*)0xB0058010
printf ">>> K_RESAMPLE busy(0x60003008)=%u  K_FFT busy(0x60004008)=%u  K_WINDOW(0x60001008)=%u\n", *(unsigned int*)0x60003008, *(unsigned int*)0x60004008, *(unsigned int*)0x60001008
echo >>> M2 T4 record (tag 0x40, resample null-src) status:\n
x/5xw 0xB00500F0
monitor resume
monitor shutdown
quit
