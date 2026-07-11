set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
set logging file C:/Users/lkwangsi/Tools/openocd-new/fftinput_gdb.log
set logging overwrite on
set logging on
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe C:/Users/lkwangsi/Documents/github/sarProcessor/mpfs/host/jtag_full/wait_port.py
target extended-remote localhost:3333
monitor reset halt
monitor mpfs.hart0_e51 arp_halt
monitor mpfs.hart1_u54_1 arp_halt
thread 2
echo \n>>> booting firmware ...\n
monitor resume
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(30)"
monitor mpfs.hart1_u54_1 arp_halt
thread 2
echo >>> loading scene + geometry ...\n
cd C:/Users/lkwangsi/Documents/github/sarProcessor/mpfs/host/jtag_stage_small
source load.gdb
set *(unsigned int*)0xB005910C = 0
set *(unsigned int*)0xB0058008 = 0
set *(unsigned int*)0xB005800C = 0
set *(unsigned int*)0xB0058010 = 0
set *(unsigned int*)0xB0058000 = 0x50495045
echo >>> PIPE issued; polling for pass==3 (range-FFT running -> SCRATCH holds window output = range-FFT INPUT) ...\n
monitor resume
set $i = 0
while $i < 90
  shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(2)"
  monitor mpfs.hart1_u54_1 arp_halt
  thread 2
  printf ">>> %4ds pass=%u idx=%u status=0x%08x\n", $i*2, *(unsigned int*)0xB0059100, *(unsigned int*)0xB0059104, *(unsigned int*)0xB0058010
  if *(unsigned int*)0xB0059100 == 3
    loop_break
  end
  if *(unsigned int*)0xB0058010 == 0xC0FFEE03
    loop_break
  end
  monitor resume
  set $i = $i + 1
end
echo \n>>> HALTED at pass=3 (range-FFT stage). Reading SCRATCH = window output = RANGE-FFT INPUT.\n
echo >>> (no gdb call-flush: the pipeline's own per-line L2 evictions keep SCRATCH uncached, so a direct read fetches DDR)\n
echo >>> SCRATCH row 0   @0x98000000:\n
x/8xw 0x98000000
echo >>> SCRATCH row 100 @0x98320000:\n
x/8xw 0x98320000
echo >>> SCRATCH row 500 @0x98FA0000:\n
x/8xw 0x98FA0000
echo >>> SIG row 100 @0x88320000 (range-FFT OUTPUT so far, partial):\n
x/8xw 0x88320000
monitor resume
monitor shutdown
quit
