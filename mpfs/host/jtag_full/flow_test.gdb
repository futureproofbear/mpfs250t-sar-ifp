set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
set logging file C:/Users/lkwangsi/Documents/github/sarProcessor/mpfs/host/jtag_full/gdb_test.log
set logging overwrite on
set logging on
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe C:/Users/lkwangsi/Documents/github/sarProcessor/mpfs/host/jtag_full/wait_port.py
echo \n>>> attaching\n
target extended-remote localhost:3333
monitor mpfs.hart0_e51 arp_halt
monitor mpfs.hart1_u54_1 arp_halt
thread 2
p/x $pc
echo \n>>> staging SIG + geometry + job into DDR (slow JTAG load)...\n
source load.gdb
echo \n>>> RUNNING FULL PIPELINE sar_form_image(0) [CT->WIN->DET->RES->FFT->feeder]...\n
p (int)sar_form_image(0)
printf ">>> sar_form_image RETURN = %d  (0=OK, else failing stage number)\n", (int)$
printf ">>> fabric STATUS @0x60000004 = 0x%08x\n", *(unsigned int*)0x60000004
printf ">>> BFP shift @0x6000001C = %d\n", *(int*)0x6000001C
echo \n>>> output spot-check @0xA8000000 (detected magnitude uint16):\n
x/16hx 0xA8000000
dump binary memory out_head.bin 0xA8000000 0xA8004000
echo \n=== PIPE TEST DONE ===\n
