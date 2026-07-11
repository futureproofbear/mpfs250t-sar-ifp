set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe C:/Users/lkwangsi/Documents/github/sarProcessor/mpfs/host/jtag_full/wait_port.py
target extended-remote localhost:3333
monitor mpfs.hart1_u54_1 arp_halt
thread 2
printf ">>> SAR_PROG pass=%u idx=%u/%u hb=%u\n", *(unsigned int*)0xB0059100, *(unsigned int*)0xB0059104, *(unsigned int*)0xB0059108, *(unsigned int*)0xB005910C
set $i = 0
while $i < 8192
  set $a = 0x98000000 + $i*0x8000
  if *(unsigned int*)$a != 0xDEADBEEF
    set $i = $i + 1
  else
    printf ">>> first UNWRITTEN transform = %u (slot 0x%08x = 0x%08x)\n", $i, $a, *(unsigned int*)$a
    loop_break
  end
end
printf ">>> transforms WRITTEN (DC-spike, not sentinel) = %u of 8192\n", $i
printf ">>> spot: xfrm0=%08x xfrm1=%08x xfrm2=%08x xfrm100=%08x xfrm8000=%08x xfrm8191=%08x\n", *(unsigned int*)0x98000000, *(unsigned int*)0x98008000, *(unsigned int*)0x98010000, *(unsigned int*)(0x98000000+100*0x8000), *(unsigned int*)(0x98000000+8000*0x8000), *(unsigned int*)(0x98000000+8191*0x8000)
monitor resume
monitor shutdown
quit
