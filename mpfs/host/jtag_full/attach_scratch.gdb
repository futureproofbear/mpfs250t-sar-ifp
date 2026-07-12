# attach_scratch.gdb -- attach to an ALREADY-RUNNING openocd (:3333), read the SCLE SCRATCH result
# + sar_row_exp with RAW reads (no gdb `call`, which crashed the prior session), dump SCRATCH rows
# 0..2, then shut openocd down cleanly. Recovers data after a gdb internal-error left openocd orphaned.
set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
target extended-remote localhost:3333
monitor mpfs.hart1_u54_1 arp_halt
printf ">>> sar_row_exp[0..3] = %u %u %u %u\n", sar_row_exp[0], sar_row_exp[1], sar_row_exp[2], sar_row_exp[3]
echo >>> RAW SCRATCH row0 [bin0..3]:\n
x/4xw 0x98000000
echo >>> RAW SCRATCH row1 [bin0..3]:\n
x/4xw 0x98008000
echo >>> RAW SCRATCH row2 [bin0..3] (zero-input row):\n
x/4xw 0x98010000
echo >>> dump SCRATCH rows 0..2 (raw) -> scratch_scle.bin\n
dump binary memory C:/Users/lkwangsi/Documents/github/mpfs250t-sar-ifp/mpfs/host/jtag_stage_small/scratch_scle.bin 0x98000000 (0x98000000 + 0x18000)
echo >>> dump done; shutting openocd down cleanly\n
monitor resume
monitor shutdown
quit
