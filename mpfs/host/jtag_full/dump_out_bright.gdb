# dump_out_bright.gdb -- dump the OUT band at the golden's high-energy rows [896:1152]
# (0xA8E00000..0xA9200000, 4 MB) for a visual + non-zero check. Attach-only (no reset).
set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe C:/Users/lkwangsi/Documents/github/mpfs250t-sar-ifp/mpfs/host/jtag_full/wait_port.py
target extended-remote localhost:3333
monitor mpfs.hart1_u54_1 arp_halt
echo >>> dumping OUT rows [896:1152] (4 MB) ...\n
dump binary memory C:/Users/lkwangsi/Documents/github/mpfs250t-sar-ifp/mpfs/host/jtag_stage_small/out_bright.bin 0xA8E00000 0xA9200000
echo >>> dump done\n
monitor resume
monitor shutdown
quit
