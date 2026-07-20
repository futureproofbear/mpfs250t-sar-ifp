# NOTE: paths below are RELATIVE to mpfs/host/jtag_full -- run gdb with that as the
# working directory (the run_*.sh drivers cd there for you).
# dump_out_rest.gdb -- ATTACH-ONLY raw dump of the REMAINING 3/4 of OUT (rows 2048:8192, 96 MB) that
# the pipeline already computed + flushed to DDR. rows 2048.. = 0xA8000000 + 2048*8192*2 = 0xAA000000;
# OUT ends at 0xB0000000. 12 x 8 MB banks with per-bank progress. ~3.4 h over FlashPro6.
set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
set logging file ../../../scratch/dump_rest_gdb.log
set logging overwrite on
set logging on
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe wait_port.py
target extended-remote localhost:3333
monitor mpfs.hart1_u54_1 arp_halt
echo >>> raw-dumping OUT rows 2048:8192 (96 MB) in 12 x 8 MB banks ...\n
dump   binary memory ../jtag_stage_deci1/out_rest.bin 0xAA000000 0xAA800000
echo >>>  bank 1/12 (8 MB)\n
append binary memory ../jtag_stage_deci1/out_rest.bin 0xAA800000 0xAB000000
echo >>>  bank 2/12 (16 MB)\n
append binary memory ../jtag_stage_deci1/out_rest.bin 0xAB000000 0xAB800000
echo >>>  bank 3/12 (24 MB)\n
append binary memory ../jtag_stage_deci1/out_rest.bin 0xAB800000 0xAC000000
echo >>>  bank 4/12 (32 MB)\n
append binary memory ../jtag_stage_deci1/out_rest.bin 0xAC000000 0xAC800000
echo >>>  bank 5/12 (40 MB)\n
append binary memory ../jtag_stage_deci1/out_rest.bin 0xAC800000 0xAD000000
echo >>>  bank 6/12 (48 MB)\n
append binary memory ../jtag_stage_deci1/out_rest.bin 0xAD000000 0xAD800000
echo >>>  bank 7/12 (56 MB)\n
append binary memory ../jtag_stage_deci1/out_rest.bin 0xAD800000 0xAE000000
echo >>>  bank 8/12 (64 MB)\n
append binary memory ../jtag_stage_deci1/out_rest.bin 0xAE000000 0xAE800000
echo >>>  bank 9/12 (72 MB)\n
append binary memory ../jtag_stage_deci1/out_rest.bin 0xAE800000 0xAF000000
echo >>>  bank 10/12 (80 MB)\n
append binary memory ../jtag_stage_deci1/out_rest.bin 0xAF000000 0xAF800000
echo >>>  bank 11/12 (88 MB)\n
append binary memory ../jtag_stage_deci1/out_rest.bin 0xAF800000 0xB0000000
echo >>>  bank 12/12 (96 MB) -- REST DUMP COMPLETE\n
monitor resume
monitor shutdown
quit
