# load_deci1.gdb -- load the FULL (deci-1) Centerfield board input: geometry + 97 MB sig.bin in
# 12 chunks with per-chunk progress (so a stall/wedge is visible), then flush L2->DDR. Leaves the
# firmware running for a later attach (run + dump). ~3 h over the ~84 kbit/s FlashPro6 link.
set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
set logging file C:/Users/lkwangsi/Tools/openocd-new/load_deci1_gdb.log
set logging overwrite on
set logging on
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe C:/Users/lkwangsi/Documents/github/sarProcessor/mpfs/host/jtag_full/wait_port.py
target extended-remote localhost:3333
monitor reset halt
monitor mpfs.hart0_e51 arp_halt
monitor mpfs.hart1_u54_1 arp_halt
thread 2
echo \n>>> booting firmware (for flush/CRC) ...\n
monitor resume
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(30)"
monitor mpfs.hart1_u54_1 arp_halt
cd C:/Users/lkwangsi/Documents/github/sarProcessor/mpfs/host/jtag_stage_deci1
echo >>> loading geometry tables ...\n
restore f0.bin binary 0xB0100000
restore df.bin binary 0xB0108000
restore pr.bin binary 0xB0110000
restore tans.bin binary 0xB0118000
restore invorder.bin binary 0xB0120000
restore krgrid.bin binary 0xB0128000
restore kcgrid.bin binary 0xB0130000
restore hamr.bin binary 0xB0138000
restore hamc.bin binary 0xB0140000
restore job.bin binary 0xB0040000
echo >>> geometry loaded; loading sig.bin (97 MB) as 12 chunk files (literal addrs) ...\n
restore sig_chunk_00 binary 0x88000000
echo >>>  sig chunk 1/12 loaded (8 MB)\n
restore sig_chunk_01 binary 0x88800000
echo >>>  sig chunk 2/12 loaded (16 MB)\n
restore sig_chunk_02 binary 0x89000000
echo >>>  sig chunk 3/12 loaded (24 MB)\n
restore sig_chunk_03 binary 0x89800000
echo >>>  sig chunk 4/12 loaded (32 MB)\n
restore sig_chunk_04 binary 0x8A000000
echo >>>  sig chunk 5/12 loaded (40 MB)\n
restore sig_chunk_05 binary 0x8A800000
echo >>>  sig chunk 6/12 loaded (48 MB)\n
restore sig_chunk_06 binary 0x8B000000
echo >>>  sig chunk 7/12 loaded (56 MB)\n
restore sig_chunk_07 binary 0x8B800000
echo >>>  sig chunk 8/12 loaded (64 MB)\n
restore sig_chunk_08 binary 0x8C000000
echo >>>  sig chunk 9/12 loaded (72 MB)\n
restore sig_chunk_09 binary 0x8C800000
echo >>>  sig chunk 10/12 loaded (80 MB)\n
restore sig_chunk_10 binary 0x8D000000
echo >>>  sig chunk 11/12 loaded (88 MB)\n
restore sig_chunk_11 binary 0x8D800000
echo >>>  sig chunk 12/12 loaded (97 MB)\n
echo >>> all sig chunks loaded; flush L2 -> DDR ...\n
call (void)flush_l2_cache(1)
printf ">>> SIG[0..3] = 0x%08x 0x%08x 0x%08x 0x%08x  (sanity)\n", *(unsigned int*)0x88000000, *(unsigned int*)0x88000004, *(unsigned int*)0x88000008, *(unsigned int*)0x8800000c
echo >>> LOAD COMPLETE (firmware left running for attach)\n
monitor resume
monitor shutdown
quit
