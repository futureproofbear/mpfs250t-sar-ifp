# flow_pipe_cpudetect.gdb -- run the full pipeline with the FABRIC FFT (mode=1) but CPU detect
# (detectmode=1, correct sqrt) to confirm the image reaches ~0.99 without a fabric rebuild -- i.e.
# that the fabric detect sign-bug is the sole blocker. Dumps the OUT band for correlate_cpufft.py.
set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
set logging file C:/Users/lkwangsi/Tools/openocd-new/cpudetect_gdb.log
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
set *(unsigned int*)0xB0059118 = 1
printf ">>> fft_mode=%u detect_mode=%u (1=fabric FFT + CPU detect)\n", *(unsigned int*)0xB0059110, *(unsigned int*)0xB0059118
set *(unsigned int*)0xB005910C = 0
set *(unsigned int*)0xB0058008 = 0
set *(unsigned int*)0xB005800C = 0
set *(unsigned int*)0xB0058010 = 0
set *(unsigned int*)0xB0058000 = 0x50495045
echo >>> PIPE issued (fabric FFT + CPU detect); polling to done (CPU detect ~tens of s)...\n
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
  echo >>> dumping OUT band [896:1152] (4 MB) -> out_bright.bin\n
  dump binary memory C:/Users/lkwangsi/Documents/github/sarProcessor/mpfs/host/jtag_stage_small/out_bright.bin 0xA8E00000 0xA9200000
  echo >>> dump done\n
end
if $done == 0
  echo >>> PIPE (cpu-detect) DID NOT COMPLETE\n
end
monitor resume
monitor shutdown
quit
