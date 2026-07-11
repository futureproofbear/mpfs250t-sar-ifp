set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe C:/Users/lkwangsi/Documents/github/sarProcessor/mpfs/host/jtag_full/wait_port.py
target extended-remote localhost:3333
monitor reset halt
monitor mpfs.hart1_u54_1 arp_halt
thread 2
monitor resume
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(20)"
monitor mpfs.hart1_u54_1 arp_halt
echo >>> loading 1 known FFT row (const re=1000) to SIG 0x88000000\n
restore C:/Users/lkwangsi/Documents/github/sarProcessor/mpfs/host/jtag_stage_small/fft_test_row.bin binary 0x88000000
printf ">>> SIG[0..3] after load (expect 0x03e80000 = re1000,im0):
"
x/4xw 0x88000000
echo >>> arming K_FFT (0x60004000): src=SIG dst=SCRATCH nrows=1, start\n
set *(unsigned int*)0x6000400c = 0x88000000
set *(unsigned int*)0x60004010 = 0x98000000
set *(unsigned int*)0x60004014 = 1
set *(unsigned int*)0x60004008 = 1
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(8)"
monitor mpfs.hart1_u54_1 arp_halt
printf ">>> K_FFT busy(0=done)=%u\n", *(unsigned int*)0x60004008
echo >>> SCRATCH row0 [0..7] (DC should be large, rest ~0):\n
x/8xw 0x98000000
echo >>> dumping SCRATCH row0 (32KB) for analysis\n
dump binary memory C:/Users/lkwangsi/Documents/github/sarProcessor/mpfs/host/jtag_stage_small/fft_iso_out.bin 0x98000000 0x98008000
monitor resume
monitor shutdown
quit
