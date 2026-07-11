set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
set logging file C:/Users/lkwangsi/Tools/openocd-new/pipe_live_gdb.log
set logging overwrite on
set logging on
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe C:/Users/lkwangsi/Documents/github/sarProcessor/mpfs/host/jtag_full/wait_port.py
target extended-remote localhost:3333
monitor reset halt
monitor mpfs.hart0_e51 arp_halt
monitor mpfs.hart1_u54_1 arp_halt
thread 2
echo \n>>> booting firmware (reset) -> run M2 battery -> mailbox loop ...\n
monitor resume
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(30)"
monitor mpfs.hart1_u54_1 arp_halt
echo >>> loading geometry (no SIG)...\n
source load_geom.gdb
printf ">>> pre-PIPE mbx.cmd=0x%08x (0=mailbox-loop-ready)\n", *(unsigned int*)0xB0058000
set *(unsigned int*)0xB005910C = 0
set *(unsigned int*)0xB0058008 = 0
set *(unsigned int*)0xB005800C = 0
set *(unsigned int*)0xB0058010 = 0
set *(unsigned int*)0xB0058000 = 0x50495045
echo >>> PIPE issued (non-blocking full pipeline); polling SAR_PROG live...\n
monitor resume
set $i = 0
while $i < 75
  shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(4)"
  monitor mpfs.hart1_u54_1 arp_halt
  printf ">>> %3ds  pass=%u idx=%u/%u hb=%u  status=0x%08x result=%d\n", $i*4, *(unsigned int*)0xB0059100, *(unsigned int*)0xB0059104, *(unsigned int*)0xB0059108, *(unsigned int*)0xB005910C, *(unsigned int*)0xB0058010, *(int*)0xB005800C
  if *(unsigned int*)0xB0058010 == 0xC0FFEE03
    printf ">>> PIPE DONE  RETURN=%d (0 OK,2 RESAMPLE,3 WINDOW,4 FFT1,5 CORNER,6 FFT2,7 DETECT,8 DMA)\n", *(int*)0xB005800C
    loop_break
  end
  monitor resume
  set $i = $i + 1
end
monitor shutdown
quit
