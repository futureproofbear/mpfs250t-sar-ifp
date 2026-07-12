# flow_pipe_mode0_sig.gdb -- run the FULL pipeline in CPU-FFT mode (mode=0, the known-good FFT) and
# dump the azimuth-output SIG at the SAME band as the fabric run (rows 1008..1071, 0x89F80000, 2MB).
# Comparing this CPU-SIG to the fabric-SIG (sig_point.bin) isolates whether the fabric FFT path has a
# real range-amplitude bug (fabric != CPU) or it's a golden-reference artifact (fabric == CPU).
set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
set logging file C:/Users/lkwangsi/Tools/openocd-new/mode0_sig_gdb.log
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
cd C:/Users/lkwangsi/Documents/github/mpfs250t-sar-ifp/mpfs/host/jtag_stage_small
source load.gdb
set *(unsigned int*)0xB0059110 = 0
printf ">>> fft_mode=%u (0=CPU FFT, known-good)\n", *(unsigned int*)0xB0059110
set *(unsigned int*)0xB005910C = 0
set *(unsigned int*)0xB0058008 = 0
set *(unsigned int*)0xB005800C = 0
set *(unsigned int*)0xB0058010 = 0
set *(unsigned int*)0xB0058000 = 0x50495045
echo >>> PIPE (mode 0) issued; polling to done (CPU FFT is slow, up to 300s)...\n
monitor resume
set $done = 0
set $i = 0
while $i < 100
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
  echo >>> raw-dumping CPU-path SIG rows 1008..1071 (2MB) -> sig_point_cpu.bin\n
  dump binary memory C:/Users/lkwangsi/Documents/github/mpfs250t-sar-ifp/mpfs/host/jtag_stage_small/sig_point_cpu.bin 0x89F80000 (0x89F80000 + 0x200000)
  echo >>> dump done\n
end
if $done == 0
  echo >>> mode0 PIPE DID NOT COMPLETE\n
end
monitor resume
monitor shutdown
quit
