# crc_check.gdb -- ATTACH-ONLY (no reset, preserves the loaded DDR + running firmware). Trigger the
# CRC32 mailbox on the ALREADY-LOADED sig region [0x88000000, +len) and read the result. len for the
# deci-1 sig = 97332984 = 0x05CD2EF8. Compare result to host zlib.crc32 (0x89fa12dc).
set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe C:/Users/lkwangsi/Documents/github/mpfs250t-sar-ifp/mpfs/host/jtag_full/wait_port.py
target extended-remote localhost:3333
monitor mpfs.hart1_u54_1 arp_halt
set *(unsigned int*)0xB0058004 = 0x88000000
set *(unsigned int*)0xB0058008 = 0x05CD2EF8
set *(unsigned int*)0xB005800C = 0
set *(unsigned int*)0xB0058010 = 0
set *(unsigned int*)0xB0058000 = 0x43524333
echo >>> CRC3 issued on [0x88000000, +97332984); waiting ...\n
monitor resume
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(12)"
monitor mpfs.hart1_u54_1 arp_halt
printf ">>> CRC status=0x%08x result=0x%08x  (want status=0xC0FFEE03 result=0x89fa12dc)\n", *(unsigned int*)0xB0058010, *(unsigned int*)0xB005800C
monitor resume
monitor shutdown
quit
