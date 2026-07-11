set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe C:/Users/lkwangsi/Documents/github/sarProcessor/mpfs/host/jtag_full/wait_port.py
target extended-remote localhost:3333
monitor mpfs.hart1_u54_1 arp_halt

# ---- CRC SIG (0x88000000, 16MB) = azimuth-FFT output (detect input) ----
set *(unsigned int*)0xB0058004 = 0x88000000
set *(unsigned int*)0xB0058008 = 0x01000000
set *(unsigned int*)0xB0058010 = 0
set *(unsigned int*)0xB0058000 = 0x43524333
monitor resume
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(2)"
monitor mpfs.hart1_u54_1 arp_halt
printf ">>> CRC SIG      (0x88M,16MB) = 0x%08x  status=0x%08x  [zero=0xa47ca14a]\n", *(unsigned int*)0xB005800C, *(unsigned int*)0xB0058010

# ---- CRC SCRATCH (0x98000000, 16MB) = last corner-turn output ----
set *(unsigned int*)0xB0058004 = 0x98000000
set *(unsigned int*)0xB0058008 = 0x01000000
set *(unsigned int*)0xB0058010 = 0
set *(unsigned int*)0xB0058000 = 0x43524333
monitor resume
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(2)"
monitor mpfs.hart1_u54_1 arp_halt
printf ">>> CRC SCRATCH  (0x98M,16MB) = 0x%08x  status=0x%08x  [zero=0xa47ca14a]\n", *(unsigned int*)0xB005800C, *(unsigned int*)0xB0058010

# ---- CRC OUT (0xA8000000, 16MB) = detected magnitude image ----
set *(unsigned int*)0xB0058004 = 0xA8000000
set *(unsigned int*)0xB0058008 = 0x01000000
set *(unsigned int*)0xB0058010 = 0
set *(unsigned int*)0xB0058000 = 0x43524333
monitor resume
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(2)"
monitor mpfs.hart1_u54_1 arp_halt
printf ">>> CRC OUT      (0xA8M,16MB) = 0x%08x  status=0x%08x  [zero=0xa47ca14a]\n", *(unsigned int*)0xB005800C, *(unsigned int*)0xB0058010

monitor resume
monitor shutdown
quit
