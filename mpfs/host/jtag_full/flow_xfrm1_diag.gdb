set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe C:/Users/lkwangsi/Documents/github/mpfs250t-sar-ifp/mpfs/host/jtag_full/wait_port.py
target extended-remote localhost:3333
monitor mpfs.hart1_u54_1 arp_halt
thread 2
printf ">>> SAR_PROG pass=%u idx=%u/%u hb=%u\n", *(unsigned int*)0xB0059100, *(unsigned int*)0xB0059104, *(unsigned int*)0xB0059108, *(unsigned int*)0xB005910C
printf ">>> DMA  VER=0x%08x  INTR_0_STAT=0x%08x  EXT_ADDR=0x%08x  STR0ADDR=0x%08x\n", *(unsigned int*)0x60005000, *(unsigned int*)0x60005010, *(unsigned int*)0x6000501C, *(unsigned int*)0x60005460
printf ">>> stream-desc @B0059000: cfg=0x%08x bytes=0x%08x dst=0x%08x\n", *(unsigned int*)0xB0059000, *(unsigned int*)0xB0059004, *(unsigned int*)0xB0059008
printf ">>> feeder START(0x60004008)=0x%08x  DMA STROP(0x60005000+? ) \n", *(unsigned int*)0x60004008
printf ">>> (EXT_ADDR: 0x98000000=xfrm0-start, +0x8000=xfrm0-done/xfrm1-start, +0x10000=xfrm1-done)\n"
monitor resume
monitor shutdown
quit
