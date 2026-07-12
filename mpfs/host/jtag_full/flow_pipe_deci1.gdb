# flow_pipe_deci1.gdb -- run the pipeline on the ALREADY-LOADED deci-1 Centerfield (NO scene reload;
# the 97 MB sig + geometry are in DDR). reset+boot gives a clean firmware cache (attach-only warm cache
# doesn't service the mailbox). Sanity-check the sig survived the reboot, run PIPE (fabric FFT + CPU
# detect default), report per-stage MTIME timing, then dump 1/4 of OUT (rows 0:2048, 32 MB) in 4 banks.
set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
set logging file C:/Users/lkwangsi/Tools/openocd-new/pipe_deci1_gdb.log
set logging overwrite on
set logging on
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe C:/Users/lkwangsi/Documents/github/mpfs250t-sar-ifp/mpfs/host/jtag_full/wait_port.py
target extended-remote localhost:3333
monitor reset halt
monitor mpfs.hart0_e51 arp_halt
monitor mpfs.hart1_u54_1 arp_halt
thread 2
echo \n>>> booting firmware (clean cache) ...\n
monitor resume
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(30)"
monitor mpfs.hart1_u54_1 arp_halt
printf ">>> post-reboot sig sanity @0x88000000 = 0x%08x 0x%08x 0x%08x 0x%08x (want 0x004a0041 0xff60ffd9 0x00b5fffa 0xff7b0030)\n", *(unsigned int*)0x88000000, *(unsigned int*)0x88000004, *(unsigned int*)0x88000008, *(unsigned int*)0x8800000c
set *(unsigned int*)0xB0059110 = 1
set *(unsigned int*)0xB0059114 = 0
set *(unsigned int*)0xB0059118 = 0
printf ">>> fft_mode=%u detect_mode=%u (fabric FFT + CPU detect)\n", *(unsigned int*)0xB0059110, *(unsigned int*)0xB0059118
set *(unsigned int*)0xB005800C = 0
set *(unsigned int*)0xB0058010 = 0
set *(unsigned int*)0xB0058000 = 0x50495045
echo >>> PIPE issued (deci-1 full scene); polling to done ...\n
monitor resume
set $done = 0
set $i = 0
while $i < 200
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
  printf ">>> per-stage MTIME us: resample=%lu window=%lu rangeFFT=%lu cornerturn=%lu azFFT=%lu detect=%lu\n", sar_stage_ts[1]-sar_stage_ts[0], sar_stage_ts[2]-sar_stage_ts[1], sar_stage_ts[3]-sar_stage_ts[2], sar_stage_ts[4]-sar_stage_ts[3], sar_stage_ts[5]-sar_stage_ts[4], sar_stage_ts[6]-sar_stage_ts[5]
  call (void)flush_l2_cache(1)
  echo >>> dumping 1/4 OUT (rows 0:2048, 32 MB) in 4 banks ...\n
  dump   binary memory C:/Users/lkwangsi/Documents/github/mpfs250t-sar-ifp/mpfs/host/jtag_stage_deci1/out_q.bin 0xA8000000 0xA8800000
  echo >>>  bank 1/4 done (8 MB)\n
  append binary memory C:/Users/lkwangsi/Documents/github/mpfs250t-sar-ifp/mpfs/host/jtag_stage_deci1/out_q.bin 0xA8800000 0xA9000000
  echo >>>  bank 2/4 done (16 MB)\n
  append binary memory C:/Users/lkwangsi/Documents/github/mpfs250t-sar-ifp/mpfs/host/jtag_stage_deci1/out_q.bin 0xA9000000 0xA9800000
  echo >>>  bank 3/4 done (24 MB)\n
  append binary memory C:/Users/lkwangsi/Documents/github/mpfs250t-sar-ifp/mpfs/host/jtag_stage_deci1/out_q.bin 0xA9800000 0xAA000000
  echo >>>  bank 4/4 done (32 MB) -- DUMP COMPLETE\n
end
if $done == 0
  echo >>> PIPE DID NOT COMPLETE\n
end
monitor resume
monitor shutdown
quit
