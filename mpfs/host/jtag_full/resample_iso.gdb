set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe C:/Users/lkwangsi/Documents/github/mpfs250t-sar-ifp/mpfs/host/jtag_full/wait_port.py
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

echo >>> loading const-1000 source row -> SIG 0x88000000 ...\n
restore C:/Users/lkwangsi/Documents/github/mpfs250t-sar-ifp/mpfs/host/jtag_stage_small/fft_test_row.bin binary 0x88000000
echo >>> loading IDENTITY idx (i) -> COEF_IDX 0xB0148000, wq=0 -> COEF_WQ 0xB0158000 ...\n
restore C:/Users/lkwangsi/Documents/github/mpfs250t-sar-ifp/mpfs/host/jtag_stage_small/idx_identity.bin binary 0xB0148000
restore C:/Users/lkwangsi/Documents/github/mpfs250t-sar-ifp/mpfs/host/jtag_stage_small/wq_zero.bin binary 0xB0158000
echo >>> pre-clear SCRATCH[0..3]:\n
set *(unsigned int*)0x98000000 = 0
set *(unsigned int*)0x98000004 = 0
set *(unsigned int*)0x98000008 = 0
set *(unsigned int*)0x9800000C = 0

echo >>> flush all L2 -> physical DDR (scene + coeffs) ...\n
call (void) flush_l2_cache(1)

echo >>> arming K_RESAMPLE (0x60003000): ARG0=in=SIG, ARG1=idx, ARG2=wq, ARG3=out=SCRATCH, START ...\n
set *(unsigned int*)0x6000300C = 0x88000000
set *(unsigned int*)0x60003010 = 0xB0148000
set *(unsigned int*)0x60003014 = 0xB0158000
set *(unsigned int*)0x60003018 = 0x98000000
set *(unsigned int*)0x60003008 = 1
monitor resume
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(6)"
monitor mpfs.hart1_u54_1 arp_halt
thread 2
printf ">>> K_RESAMPLE busy(0=done) = %u\n", *(unsigned int*)0x60003008

echo >>> flush/evict SCRATCH L2 so host read fetches physical DDR ...\n
call (void) flush_l2_cache(1)
echo >>> SCRATCH[0..7] (expect 0x03e80000 = passthrough of const-1000 if gather WORKS; 0 if BROKEN):\n
x/8xw 0x98000000
printf ">>> VERDICT: SCRATCH[0]=0x%08x  (0x03e80000 => resample gather OK, pipeline zero is BAD COEFFS; 0 => gather BROKEN)\n", *(unsigned int*)0x98000000

monitor resume
monitor shutdown
quit
