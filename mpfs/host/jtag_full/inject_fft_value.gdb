# inject_fft_value.gdb -- A2 VALUE test (decisive exponent-capture check). Inject 8 KNOWN rows into
# SIG, run the fabric range-FFT (FTES = fft_pass SIG->SCRATCH, NO slow on-chip zeroing), read
# sar_row_exp[0..7] and diff vs the model's per-row exponents [11,7,13,12,13,7,1,13]. Uniform/zero
# readback => SCALE_EXP capture is broken on silicon. Also dumps SCRATCH rows 0..7. Needs fft_mode=1.
set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
set logging file C:/Users/lkwangsi/Tools/openocd-new/inject_value_gdb.log
set logging overwrite on
set logging on
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe C:/Users/lkwangsi/Documents/github/mpfs250t-sar-ifp/mpfs/host/jtag_full/wait_port.py
target extended-remote localhost:3333
monitor reset halt
monitor mpfs.hart0_e51 arp_halt
monitor mpfs.hart1_u54_1 arp_halt
thread 2
echo \n>>> booting firmware ...\n
monitor resume
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(30)"
monitor mpfs.hart1_u54_1 arp_halt
set *(unsigned int*)0xB0059110 = 1
set *(unsigned int*)0xB0059114 = 0
printf ">>> fft_mode=%u (1=fabric)\n", *(unsigned int*)0xB0059110
# --- load 8 known rows over SIG rows 0..7 (rest of SIG is stale; irrelevant to the per-row exp read) ---
echo >>> loading inject_rows.bin (8 rows, 256 KB) -> SIG 0x88000000 ...\n
restore C:/Users/lkwangsi/Documents/github/mpfs250t-sar-ifp/mpfs/host/jtag_stage_small/inject_rows.bin binary 0x88000000
printf ">>> SIG row0[0]=0x%08x row7[0]=0x%08x\n", *(unsigned int*)0x88000000, *(unsigned int*)0x88038000
call (void)flush_l2_cache(1)
# --- FTES = fft_pass(SIG->SCRATCH) on the injected rows ---
set *(unsigned int*)0xB005800C = 0
set *(unsigned int*)0xB0058010 = 0
set *(unsigned int*)0xB0058000 = 0x46544553
echo >>> FTES issued (fabric range-FFT); polling to done (up to 240s)...\n
monitor resume
set $done = 0
set $j = 0
while $j < 80
  shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(3)"
  monitor mpfs.hart1_u54_1 arp_halt
  if *(unsigned int*)0xB0058010 == 0xC0FFEE03
    printf ">>> FTES DONE fft_pass_return=%d at ~%ds\n", *(int*)0xB005800C, $j*3
    set $done = 1
    loop_break
  end
  monitor resume
  set $j = $j + 1
end
if $done == 1
  printf ">>> sar_row_exp[0..7] = %u %u %u %u %u %u %u %u\n", sar_row_exp[0], sar_row_exp[1], sar_row_exp[2], sar_row_exp[3], sar_row_exp[4], sar_row_exp[5], sar_row_exp[6], sar_row_exp[7]
  printf ">>>                MODEL = 11 7 13 12 13 7 1 13  (uniform/zero readback => capture BROKEN)\n"
  call (void)flush_l2_cache(1)
  dump binary memory C:/Users/lkwangsi/Documents/github/mpfs250t-sar-ifp/mpfs/host/jtag_stage_small/scratch_inject.bin 0x98000000 (0x98000000 + 0x40000)
  echo >>> dump done\n
end
if $done == 0
  echo >>> FTES DID NOT COMPLETE -- fabric likely wedged; power-cycle the board and retry\n
end
monitor resume
monitor shutdown
quit
