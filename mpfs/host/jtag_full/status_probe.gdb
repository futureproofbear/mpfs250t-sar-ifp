# NOTE: paths below are RELATIVE to mpfs/host/jtag_full -- run gdb with that as the
# working directory (the run_*.sh drivers cd there for you).
set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe wait_port.py
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

# NOTE: an AXI master-id mis-delivery probe lived here and was REMOVED (874fefa). The HDL+
# initiator bus interface on the feeder/unloader carries NO id at all (fft_feeder_top.v:122
# discards m_arid and ties m_rid to 0), so the DIC routes by PHYSICAL PORT and an id-based
# check can only ever read back a constant. Do not re-add one without first extending the bus
# interface definition itself.
# ---- coeffgen wedge check (2026-07-26) ----
# CGEN_CTRL/STATUS @+0x00 bit0 = busy.  start_pulse is honoured ONLY in C_IDLE
# (sar_coeffgen.v:662), and C_DRAIN exits only once the feeder has drained every queued
# entry.  So busy==1 with the pipeline idle == the generator is WEDGED and every later
# row/run silently reuses stale coefficients.  STAT @+0x1c also carries emitted[29:16].
printf "\n=== coeffgen state (busy=1 while idle => WEDGED) ===\n"
printf "COEFG   ctrl=0x%08x busy=%u   stat=0x%08x emitted=%u\n", *(unsigned int*)0x60007000, (*(unsigned int*)0x60007000)&1, *(unsigned int*)0x6000701c, (*(unsigned int*)0x6000701c >> 16) & 0x3fff
printf "COEFG_B ctrl=0x%08x busy=%u   stat=0x%08x emitted=%u\n", *(unsigned int*)0x60008000, (*(unsigned int*)0x60008000)&1, *(unsigned int*)0x6000801c, (*(unsigned int*)0x6000801c >> 16) & 0x3fff

monitor resume
monitor shutdown
quit
