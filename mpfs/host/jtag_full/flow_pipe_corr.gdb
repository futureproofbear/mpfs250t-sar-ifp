# NOTE: paths below are RELATIVE to mpfs/host/jtag_full -- run gdb with that as the
# working directory (the run_*.sh drivers cd there for you).
# flow_pipe_corr.gdb -- run the FULL SAR pipeline in FABRIC FFT mode (mode=1) on the current
# SCALE_EXP+renorm build, verify the scaleexp fabric is actually programmed (captured sar_row_exp[]
# must be nonzero/varying -- all-zero => gbxfix is live and the test is INVALID), then dump the full
# 4 MB OUT bright band [896:1152] to out_bright.bin for correlate_cpufft.py. Headroom set at 0xB0059114.
set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
set logging file ../../../scratch/pipe_corr_gdb.log
set logging overwrite on
set logging on
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe wait_port.py
target extended-remote localhost:3333
monitor reset halt
monitor mpfs.hart0_e51 arp_halt
monitor mpfs.hart1_u54_1 arp_halt
thread 2
echo \n>>> booting firmware ...\n
monitor resume
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(30)"
monitor mpfs.hart1_u54_1 arp_halt
echo >>> loading small scene ...\n
cd ../jtag_stage_small
source load.gdb
set *(unsigned int*)0xB0059110 = 1
set *(unsigned int*)0xB0059114 = @HR@
printf ">>> fft_mode=%u headroom=%u\n", *(unsigned int*)0xB0059110, *(unsigned int*)0xB0059114
set *(unsigned int*)0xB005910C = 0
set *(unsigned int*)0xB0058008 = 0
set *(unsigned int*)0xB005800C = 0
set *(unsigned int*)0xB0058010 = 0
set *(unsigned int*)0xB0058000 = 0x50495045
echo >>> PIPE issued; polling to done...\n
monitor resume
set $i = 0
while $i < 240
  shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(4)"
  monitor mpfs.hart1_u54_1 arp_halt
  if *(unsigned int*)0xB0058010 == 0xC0FFEE03
    printf ">>> PIPE DONE RETURN=%d at ~%ds\n", *(int*)0xB005800C, $i*4
    loop_break
  end
  monitor resume
  set $i = $i + 1
end
echo >>> captured per-row exponents (nonzero/varying => scaleexp fabric LIVE; all 0 => gbxfix, INVALID):\n
printf "  sar_row_exp[0..15] ="
set $k = 0
while $k < 16
  printf " %u", sar_row_exp[$k]
  set $k = $k + 1
end
printf "\n"
call (void)flush_l2_cache(1)
echo >>> dumping full OUT bright band [896:1152] (4 MB) -> out_bright.bin\n
dump binary memory ../jtag_stage_small/out_bright.bin 0xA8E00000 0xA9200000
echo >>> dump done\n
monitor resume
monitor shutdown
quit
