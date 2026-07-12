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
echo \n>>> booting firmware (reset) -> mailbox loop ...\n
monitor resume
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(28)"
monitor mpfs.hart1_u54_1 arp_halt

echo >>> loading scene sig.bin -> cached SIG 0x88000000 (1522800 bytes) ...\n
restore C:/Users/lkwangsi/Documents/github/mpfs250t-sar-ifp/mpfs/host/jtag_stage_small/sig.bin binary 0x88000000
echo >>> SIG[0..3] cached readback:\n
x/4xw 0x88000000
echo >>> SIG[0..3] NON-CACHED alias 0xC8000000 readback (physical DDR / HLS view):\n
x/4xw 0xC8000000

# CRC cached SIG (hart view: L2 or DDR) -- expect 0x69dc6007 if load OK
set *(unsigned int*)0xB0058004 = 0x88000000
set *(unsigned int*)0xB0058008 = 0x00173c70
set *(unsigned int*)0xB0058010 = 0
set *(unsigned int*)0xB0058000 = 0x43524333
monitor resume
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(1)"
monitor mpfs.hart1_u54_1 arp_halt
printf ">>> CRC SIG CACHED     (0x88M) = 0x%08x  status=0x%08x  [scene=0x69dc6007 zero=0x98f097c3]\n", *(unsigned int*)0xB005800C, *(unsigned int*)0xB0058010

# CRC non-cached SIG alias (physical DDR = what the HLS FIC0 master reads)
set *(unsigned int*)0xB0058004 = 0xC8000000
set *(unsigned int*)0xB0058008 = 0x00173c70
set *(unsigned int*)0xB0058010 = 0
set *(unsigned int*)0xB0058000 = 0x43524333
monitor resume
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(1)"
monitor mpfs.hart1_u54_1 arp_halt
printf ">>> CRC SIG NON-CACHED (0xC8M) = 0x%08x  status=0x%08x  [scene=0x69dc6007 zero=0x98f097c3]\n", *(unsigned int*)0xB005800C, *(unsigned int*)0xB0058010

monitor resume
monitor shutdown
quit
