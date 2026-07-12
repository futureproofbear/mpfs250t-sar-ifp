# flow_pipe_trace.gdb -- run the full pipeline in a chosen FFT mode, then COHERENTLY dump a
# bright-band chunk (256 KB = 64k complex) from each stage buffer so the host can compare the
# per-stage dynamic range (peak |value|) of the CPU path vs the fabric path and localize where
# the fabric loses magnitude. After the run the buffers hold:
#   SCRATCH (0x98E00000 band) = corner-turn output (= range-FFT output, transposed)
#   SIG     (0x88E00000 band) = azimuth-FFT output (detect input)
#   OUT     (0xA8E00000 band) = detected magnitude
# @MODE@ = 0 (CPU) or 1 (fabric); @HR@ = renormalize headroom (fabric only).
set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
set logging file C:/Users/lkwangsi/Tools/openocd-new/pipe_trace_gdb.log
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
echo >>> loading small scene ...\n
cd C:/Users/lkwangsi/Documents/github/mpfs250t-sar-ifp/mpfs/host/jtag_stage_small
source load.gdb
set *(unsigned int*)0xB0059110 = @MODE@
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
echo >>> coherent flush + dump per-stage bright-band chunks (256 KB each)\n
call (void)flush_l2_cache(1)
dump binary memory @OUTDIR@/trace_scratch.bin 0x98E00000 (0x98E00000 + 0x40000)
dump binary memory @OUTDIR@/trace_sig.bin     0x88E00000 (0x88E00000 + 0x40000)
dump binary memory @OUTDIR@/trace_out.bin      0xA8E00000 (0xA8E00000 + 0x40000)
echo >>> stage dumps done\n
monitor resume
monitor shutdown
quit
