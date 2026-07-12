# GDB pre-loads the ELF, then a synchronous `shell` waiter blocks until OpenOCD's
# telnet port (4444) binds, and GDB attaches to 3333 the instant it returns --
# zero connect delay, so the FlashPro HID never idles into a crash.
# Run from jtag_full so load.gdb's relative restores + out.bin resolve.
set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off

set logging file C:/Users/lkwangsi/Documents/github/mpfs250t-sar-ifp/mpfs/host/jtag_full/gdb_session.log
set logging overwrite on
set logging redirect off
set logging on
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe C:/Users/lkwangsi/Documents/github/mpfs250t-sar-ifp/mpfs/host/jtag_full/wait_port.py
echo \n>>> openocd up; attaching now\n

target extended-remote localhost:3333
echo \n>>> attached; halting hart0 + U54_1\n
monitor mpfs.hart0_e51 arp_halt
monitor mpfs.hart1_u54_1 arp_halt
info threads

echo \n>>> selecting U54_1 thread\n
thread 2
p/x $pc

echo \n>>> staging SIG + geometry + job into DDR over JTAG...\n
source load.gdb

echo \n>>> running sar_form_image(0) on U54_1 (FPU)...\n
p (int)sar_form_image(0)
printf ">>> fabric STATUS @0x60000004 = 0x%08x\n", *(unsigned int*)0x60000004
printf ">>> fabric BFP shift @0x6000001C = %d\n", *(int*)0x6000001C

echo \n>>> dumping OUT (128 MiB) over JTAG...\n
dump binary memory out.bin 0xA8000000 0xB0000000
echo \n=== SAR FLOW DONE ===\n
