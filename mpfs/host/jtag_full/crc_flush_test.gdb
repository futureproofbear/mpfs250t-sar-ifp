# NOTE: paths below are RELATIVE to mpfs/host/jtag_full -- run gdb with that as the
# working directory (the run_*.sh drivers cd there for you).
set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe wait_port.py
target extended-remote localhost:3333
monitor reset halt
monitor mpfs.hart0_e51 arp_halt
monitor mpfs.hart1_u54_1 arp_halt
thread 2
echo \n>>> booting firmware ...\n
monitor resume
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(28)"
monitor mpfs.hart1_u54_1 arp_halt
thread 2

echo >>> loading 32KB test pattern (const re=1000) -> cached SIG 0x88000000 ...\n
restore ../jtag_stage_small/fft_test_row.bin binary 0x88000000

# ---- CRC #1: cached read (L2, before flush) -- expect 0xecbfabd8 (pattern) ----
set *(unsigned int*)0xB0058004 = 0x88000000
set *(unsigned int*)0xB0058008 = 0x00008000
set *(unsigned int*)0xB0058010 = 0
set *(unsigned int*)0xB0058000 = 0x43524333
monitor resume
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(1)"
monitor mpfs.hart1_u54_1 arp_halt
thread 2
printf ">>> CRC #1 CACHED  (pre-flush, L2 view)  = 0x%08x  [pattern=0xecbfabd8 zero=0x011ffca6]\n", *(unsigned int*)0xB005800C

# ---- FLUSH L2 -> DDR (write-back + evict) via a direct firmware call ----
echo >>> calling flush_l2_cache(1) on hart1 (write-back + evict L2 -> DDR) ...\n
call (void) flush_l2_cache(1)
echo >>> flush returned\n

# ---- CRC #2: cached read AFTER flush -- L2 evicted, so this fetches PHYSICAL DRAM ----
set *(unsigned int*)0xB0058004 = 0x88000000
set *(unsigned int*)0xB0058008 = 0x00008000
set *(unsigned int*)0xB0058010 = 0
set *(unsigned int*)0xB0058000 = 0x43524333
monitor resume
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(1)"
monitor mpfs.hart1_u54_1 arp_halt
thread 2
printf ">>> CRC #2 CACHED  (POST-flush = PHYSICAL DRAM) = 0x%08x  [pattern=0xecbfabd8 zero=0x011ffca6]\n", *(unsigned int*)0xB005800C
printf ">>> VERDICT: if CRC#2==0xecbfabd8 flush DELIVERS scene to DDR (HLS would see it); if !=pattern flush FAILS -> coherency root cause\n"

monitor resume
monitor shutdown
quit
