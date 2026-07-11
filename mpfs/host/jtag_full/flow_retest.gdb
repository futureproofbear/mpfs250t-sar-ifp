# flow_retest.gdb -- silicon re-test after the FFT gearbox fix.
# Loads geometry+job (NOT the 93MB SIG -- we're testing stage-5 control flow; the FFT
# completes regardless of data values), runs the full pipeline, reports the stage result.
# Expect RETURN != 4 now (stage 5 range-FFT should complete). RETURN=0 = full pipeline OK.
set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe C:/Users/lkwangsi/Documents/github/sarProcessor/mpfs/host/jtag_full/wait_port.py
target extended-remote localhost:3333
echo \n>>> attached; halting hart0 + U54_1\n
monitor mpfs.hart0_e51 arp_halt
monitor mpfs.hart1_u54_1 arp_halt
thread 2
echo \n>>> loading geometry + job (no SIG)\n
source load_geom.gdb
echo \n>>> running sar_form_image(0) on U54_1 (resample ~10min, then FFT stages)...\n
set $r = (int)sar_form_image(0)
printf ">>> RETURN=%d (0 OK, 2 RESAMPLE, 3 WINDOW, 4 FFT1/range, 5 CORNER, 6 FFT2/azimuth, 7 DETECT, 8 DMA)\n", $r
printf ">>> PROGRESS pass=%u idx=%u total=%u heartbeat=%u\n", *(unsigned int*)0xB0059100, *(unsigned int*)0xB0059104, *(unsigned int*)0xB0059108, *(unsigned int*)0xB005910C
printf ">>> DMADBG chunk=%u INTR0_STAT=0x%08x EXT_ADDR=0x%08x START_OP=0x%08x\n", *(unsigned int*)0xB0059200, *(unsigned int*)0xB0059204, *(unsigned int*)0xB0059208, *(unsigned int*)0xB005920C
printf ">>> DMADBG desc cfg=0x%08x bytes=0x%08x dst=0x%08x\n", *(unsigned int*)0xB0059210, *(unsigned int*)0xB0059214, *(unsigned int*)0xB0059218
printf ">>> DMADBG feeder_START=0x%08x INTR0_reread=0x%08x DMA_VER=0x%08x\n", *(unsigned int*)0xB005921C, *(unsigned int*)0xB0059220, *(unsigned int*)0xB0059224
echo \n>>> clean shutdown\n
monitor resume
monitor shutdown
quit
