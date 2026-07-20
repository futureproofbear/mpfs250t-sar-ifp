# NOTE: paths below are RELATIVE to mpfs/host/jtag_full -- run gdb with that as the
# working directory (the run_*.sh drivers cd there for you).
# scle_value.gdb -- VALUE-level fabric range-FFT + SCALE_EXP-capture test. Triggers the 'SCLE'
# mailbox cmd (firmware fills SIG with 2 DC rows 16:1 on-chip, runs fabric fft_pass SIG->SCRATCH),
# reads sar_row_exp[0..3] (model predicts 11,7,0,0), and dumps SCRATCH rows 0..2 for a bit-exact
# value diff vs fabric_scale_value.py. Needs fft_mode=1 (fabric).
set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
set logging file ../../../scratch/scle_value_gdb.log
set logging overwrite on
set logging on
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe wait_port.py
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
# issue 'SCLE' (0x53434C45): clear status/result, write cmd
set *(unsigned int*)0xB005800C = 0
set *(unsigned int*)0xB0058010 = 0
set *(unsigned int*)0xB0058000 = 0x53434C45
echo >>> SCLE issued (on-chip 2-DC-row fabric range-FFT); polling to done (up to 360s)...\n
monitor resume
set $done = 0
set $i = 0
while $i < 120
  shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(3)"
  monitor mpfs.hart1_u54_1 arp_halt
  if *(unsigned int*)0xB0058010 == 0xC0FFEE03
    printf ">>> SCLE DONE fft_pass_return=%d at ~%ds\n", *(int*)0xB005800C, $i*3
    set $done = 1
    loop_break
  end
  monitor resume
  set $i = $i + 1
end
# flush/dump ONLY when the pass really finished (hart cleanly halted) -- else `call` crashes gdb
if $done == 1
  printf ">>> sar_row_exp[0..3] = %u %u %u %u   (model: 11 7 0 0)\n", sar_row_exp[0], sar_row_exp[1], sar_row_exp[2], sar_row_exp[3]
  call (void)flush_l2_cache(1)
  printf ">>> SCRATCH row0 bin0 = 0x%08x   row1 bin0 = 0x%08x   (re<<16|im)\n", *(unsigned int*)0x98000000, *(unsigned int*)0x98008000
  echo >>> dumping SCRATCH rows 0..2 (3*32KB) -> scratch_scle.bin\n
  dump binary memory ../jtag_stage_small/scratch_scle.bin 0x98000000 (0x98000000 + 0x18000)
  echo >>> dump done\n
end
if $done == 0
  echo >>> SCLE DID NOT COMPLETE in 360s -- hart still busy; skipping flush/dump (avoids gdb crash)\n
  printf ">>> mailbox status=0x%08x cmd=0x%08x (cmd!=0 => still processing)\n", *(unsigned int*)0xB0058010, *(unsigned int*)0xB0058000
end
monitor resume
monitor shutdown
quit
