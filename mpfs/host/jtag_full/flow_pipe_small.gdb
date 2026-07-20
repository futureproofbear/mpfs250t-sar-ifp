# NOTE: paths below are RELATIVE to mpfs/host/jtag_full -- run gdb with that as the
# working directory (the run_*.sh drivers cd there for you).
# flow_pipe_small.gdb -- full sar_form_image on the DECIMATED small scene (705x540 padded to
# the fabric 8192x8192 grid). Boots fw, loads sig+geometry+job over JTAG, issues the PIPE
# mailbox command (non-blocking full pipeline), and polls SAR_PROG + status/result until done.
# Expect RETURN=0 (all stages incl the range-FFT that the fft_unloader unblocked).
set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
set logging file ../../../scratch/pipe_small_gdb.log
set logging overwrite on
set logging on
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe wait_port.py
target extended-remote localhost:3333
monitor reset halt
monitor mpfs.hart0_e51 arp_halt
monitor mpfs.hart1_u54_1 arp_halt
thread 2
echo \n>>> booting firmware (reset) -> M2 battery -> mailbox loop ...\n
monitor resume
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(30)"
monitor mpfs.hart1_u54_1 arp_halt
echo >>> loading small scene (sig 1.5MB + geometry + job) over JTAG ...\n
cd ../jtag_stage_small
source load.gdb
printf ">>> pre-PIPE mbx.cmd=0x%08x (0=mailbox-loop-ready)\n", *(unsigned int*)0xB0058000
set *(unsigned int*)0xB005910C = 0
set *(unsigned int*)0xB0058008 = 0
set *(unsigned int*)0xB005800C = 0
set *(unsigned int*)0xB0058010 = 0
set *(unsigned int*)0xB0058000 = 0x50495045
echo >>> PIPE issued (full pipeline); polling SAR_PROG live (~13 min budget)...\n
monitor resume
set $i = 0
while $i < 200
  shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(4)"
  monitor mpfs.hart1_u54_1 arp_halt
  printf ">>> %4ds  pass=%u idx=%u/%u hb=%u  status=0x%08x result=%d\n", $i*4, *(unsigned int*)0xB0059100, *(unsigned int*)0xB0059104, *(unsigned int*)0xB0059108, *(unsigned int*)0xB005910C, *(unsigned int*)0xB0058010, *(int*)0xB005800C
  if *(unsigned int*)0xB0058010 == 0xC0FFEE03
    printf ">>> PIPE DONE  RETURN=%d (0 OK,2 RESAMPLE,3 WINDOW,4 FFT1,5 CORNER,6 FFT2,7 DETECT)\n", *(int*)0xB005800C
    loop_break
  end
  monitor resume
  set $i = $i + 1
end
echo >>> OUT[0..3] @0xA8000000 (detected magnitude, uint16 pairs):\n
x/4xw 0xA8000000
monitor resume
monitor shutdown
quit
