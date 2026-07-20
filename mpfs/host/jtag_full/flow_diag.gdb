# NOTE: paths below are RELATIVE to mpfs/host/jtag_full -- run gdb with that as the
# working directory (the run_*.sh drivers cd there for you).
set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
set logging file gdb_diag.log
set logging overwrite on
set logging on
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe wait_port.py
target extended-remote localhost:3333
monitor mpfs.hart0_e51 arp_halt
monitor mpfs.hart1_u54_1 arp_halt
thread 2
echo \n>>> sar_form_image(0x02000000) bounded ~10s/stage; returns failing stage\n
p (int)sar_form_image(0x02000000)
printf ">>> RETURN=%d  (0 OK,2 RESAMPLE,3 WINDOW,4 FFT1-feeder,5 CORNER,6 FFT2-feeder,7 DETECT,8 DMA)\n", (int)$
printf ">>> STATUS 0x60000004 = 0x%08x\n", *(unsigned int*)0x60000004
echo \n=== DIAG DONE ===\n
