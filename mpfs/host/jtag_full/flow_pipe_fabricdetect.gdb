# flow_pipe_fabricdetect.gdb -- run the full pipeline with FABRIC FFT (mode=1) AND FABRIC detect
# (detect_mode=0) to confirm the REBUILT detect kernel (sign-ext fix) no longer saturates negative-I
# pixels. Peeks SIG vs OUT at row 896 (has negative-I samples) as a VALUE check, then dumps the OUT
# band for correlate_cpufft.py. Expect: OUT[neg-I pixel] == |SIG| (not 0xFFFF), corr ~0.97.
set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
set logging file C:/Users/lkwangsi/Tools/openocd-new/fabricdetect_gdb.log
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
cd C:/Users/lkwangsi/Documents/github/sarProcessor/mpfs/host/jtag_stage_small
source load.gdb
set *(unsigned int*)0xB0059110 = 1
set *(unsigned int*)0xB0059114 = 0
set *(unsigned int*)0xB0059118 = 0
printf ">>> fft_mode=%u detect_mode=%u (1=fabric FFT + FABRIC detect [rebuilt fix])\n", *(unsigned int*)0xB0059110, *(unsigned int*)0xB0059118
set *(unsigned int*)0xB005910C = 0
set *(unsigned int*)0xB0058008 = 0
set *(unsigned int*)0xB005800C = 0
set *(unsigned int*)0xB0058010 = 0
set *(unsigned int*)0xB0058000 = 0x50495045
echo >>> PIPE issued (fabric FFT + FABRIC detect); polling to done...\n
monitor resume
set $done = 0
set $i = 0
while $i < 120
  shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(3)"
  monitor mpfs.hart1_u54_1 arp_halt
  if *(unsigned int*)0xB0058010 == 0xC0FFEE03
    printf ">>> PIPE DONE RETURN=%d at ~%ds\n", *(int*)0xB005800C, $i*3
    set $done = 1
    loop_break
  end
  monitor resume
  set $i = $i + 1
end
if $done == 1
  echo >>> VALUE CHECK -- SIG (azimuth out, re<<16|im) vs OUT (fabric detect |.|) at row 896:\n
  echo    SIG rows896 [0..3]:\n
  x/4xw 0x89C00000
  echo    OUT rows896 [0..7] (two uint16 per word; OLD bug = 0xffff where re<0, FIXED = |SIG|):\n
  x/4xw 0xA8E00000
  echo >>> dumping OUT band [896:1152] (4 MB) -> out_bright.bin\n
  dump binary memory C:/Users/lkwangsi/Documents/github/sarProcessor/mpfs/host/jtag_stage_small/out_bright.bin 0xA8E00000 0xA9200000
  echo >>> dump done\n
end
if $done == 0
  echo >>> PIPE (fabric detect) DID NOT COMPLETE\n
end
monitor resume
monitor shutdown
quit
