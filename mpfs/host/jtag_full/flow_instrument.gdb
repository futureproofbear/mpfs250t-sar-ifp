set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
set logging file C:/Users/lkwangsi/Tools/openocd-new/instrument_gdb.log
set logging overwrite on
set logging on
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe C:/Users/lkwangsi/Documents/github/mpfs250t-sar-ifp/mpfs/host/jtag_full/wait_port.py
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
echo >>> loading scene + geometry over JTAG ...\n
cd C:/Users/lkwangsi/Documents/github/mpfs250t-sar-ifp/mpfs/host/jtag_stage_small
source load.gdb
set *(unsigned int*)0xB005910C = 0
set *(unsigned int*)0xB0058008 = 0
set *(unsigned int*)0xB005800C = 0
set *(unsigned int*)0xB0058010 = 0
set *(unsigned int*)0xB0058000 = 0x50495045
echo >>> PIPE issued; polling until pass 2 is well underway ...\n
monitor resume
set $i = 0
while $i < 60
  shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(4)"
  monitor mpfs.hart1_u54_1 arp_halt
  thread 2
  printf ">>> %4ds pass=%u idx=%u status=0x%08x\n", $i*4, *(unsigned int*)0xB0059100, *(unsigned int*)0xB0059104, *(unsigned int*)0xB0058010
  if *(unsigned int*)0xB0059100 == 2 && *(unsigned int*)0xB0059104 > 3000
    loop_break
  end
  if *(unsigned int*)0xB0058010 == 0xC0FFEE03
    loop_break
  end
  monitor resume
  set $i = $i + 1
end
echo \n>>> HALT mid-pass-2. flush+read SIG = transposed PASS-1 output (read-only during pass 2):\n
call (void) flush_l2_cache(1)
echo >>> SIG[0..7] @0x88000000 (pass-1 resampled+transposed; NONZERO => pass1+transpose OK):\n
x/8xw 0x88000000
echo >>> SIG row 100 @ +100*8192*4=0x88320000:\n
x/8xw 0x88320000
echo >>> SCRATCH[0..7] @0x98000000 (pass-2 partial output so far):\n
x/8xw 0x98000000
echo \n>>> resume to completion ...\n
monitor resume
set $k = 0
while $k < 40
  shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(4)"
  monitor mpfs.hart1_u54_1 arp_halt
  thread 2
  printf ">>> fin %4ds pass=%u idx=%u status=0x%08x\n", $k*4, *(unsigned int*)0xB0059100, *(unsigned int*)0xB0059104, *(unsigned int*)0xB0058010
  if *(unsigned int*)0xB0058010 == 0xC0FFEE03
    loop_break
  end
  monitor resume
  set $k = $k + 1
end
call (void) flush_l2_cache(1)
echo >>> FINAL SIG[0..3] (azimuth-FFT out), SCRATCH[0..3] (corner-turn out), OUT[0..3] (detect):\n
x/4xw 0x88000000
x/4xw 0x98000000
x/4xw 0xA8000000
monitor resume
monitor shutdown
quit
