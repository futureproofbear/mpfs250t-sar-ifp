set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe C:/Users/lkwangsi/Documents/github/sarProcessor/mpfs/host/jtag_full/wait_port.py
target extended-remote localhost:3333
monitor mpfs.hart1_u54_1 arp_halt
echo === mailbox @0xB0058000 (cmd,status,result,seq) ===\n
x/4xw 0xB0058000
echo === fft dbg snapshot @0xB0058020 (busy,src,dst,nrows) ===\n
x/4xw 0xB0058020
echo === SAR_PROG @0xB0059100 (pass,idx,total,hb) ===\n
x/4xw 0xB0059100
echo === OUT @0xA8000000 [0..7] (cached view) ===\n
x/8xw 0xA8000000
echo === SIG @0x88000000 [0..7] (cached view, = azimuth-FFT out post-run) ===\n
x/8xw 0x88000000
echo === SCRATCH @0x98000000 [0..7] (cached view) ===\n
x/8xw 0x98000000
monitor resume
monitor shutdown
quit
