# Dual-CoreFFT-chain silicon A/B -- ONE JTAG ATTACH for the whole experiment.
#
# Same bitstream, same binary, same scene, same session. The ONLY thing that changes between
# run A and run B is SAR_DUALFFT @0xB005913C. The split is bit-exact by construction (emax is a
# max, hence partition-independent), so:
#
#     THE GATE IS CRC EQUALITY.  crcA == crcB  => PASS.  A moved CRC is the H-2 signature.
#
# CRC-first, dump-only-on-mismatch (standing instruction): no image is dumped unless the CRCs
# differ, because a 1024x1024 dump over JTAG is minutes we do not spend on a passing run.
#
# TWO TRAPS THIS SCRIPT EXISTS TO AVOID (both cost a run on 2026-07-26):
#  1. ARMING BEFORE THE FIRMWARE IS READY. u54_1.c:339 does
#     `mbx->cmd = 0; mbx->status = 0; mbx->result = 0; mbx->seq = 0;` AFTER m2_run_tests() and
#     BEFORE the mailbox loop. A command armed during boot is silently ZEROED and the hart then
#     spins forever with cmd=0, which looks exactly like a hung command. So `runcmd` RE-ARMS
#     whenever it sees cmd==0 with status!=DONE, instead of arming once and hoping.
#  2. `monitor sleep` IN A LONG POLL LOOP. It crashed gdb with
#     "internal-error: find_inferior_pid: Assertion `pid != 0' failed" after ~12 iterations.
#     The proven pattern in this repo (flow_pipe_live.gdb, 75 iterations) is a SHELL sleep.
set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
set logging file ../../../scratch/dualfft_ab.log
set logging overwrite on
set logging on
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe wait_port.py
target extended-remote localhost:3333

# ---- arm a mailbox command and poll it to completion, re-arming through the boot race -------
# $arg0=cmd  $arg1=base  $arg2=len  $arg3=timeout(s)  $arg4="label"
# base/len are written FIRST and cmd LAST (the hart acks by clearing cmd), so the hart can never
# observe a command with stale arguments.
define runcmd
  set $done = 0
  set $el = 0
  while ($el < $arg3 && $done == 0)
    if (*(unsigned int*)0xB0058000 == 0 && *(unsigned int*)0xB0058010 != 0xC0FFEE03)
      set {unsigned int}0xB0058004 = $arg1
      set {unsigned int}0xB0058008 = $arg2
      set {unsigned int}0xB005800C = 0
      set {unsigned int}0xB0058010 = 0
      set {unsigned int}0xB0058000 = $arg0
      printf "    [arm] %s\n", $arg4
    end
    monitor resume
    shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(10)"
    monitor mpfs.hart1_u54_1 arp_halt
    thread 2
    set $el = $el + 10
    if (*(unsigned int*)0xB0058010 == 0xC0FFEE03)
      set $done = 1
    else
      printf "    ... %s %u s (cmd=0x%08x status=0x%08x)\n", $arg4, $el, *(unsigned int*)0xB0058000, *(unsigned int*)0xB0058010
    end
  end
  if $done == 1
    printf ">>> %s DONE after ~%u s, result=%d\n", $arg4, $el, *(int*)0xB005800C
  else
    printf ">>> %s TIMED OUT after %u s -- cmd=0x%08x status=0x%08x\n", $arg4, $el, *(unsigned int*)0xB0058000, *(unsigned int*)0xB0058010
  end
end

# ---- report one run's timing --------------------------------------------------------------
define report
  set $rp = (unsigned long long*)0xB0059180
  printf "    stages(us): resample=%llu rangeFFT(FFT-1,azimuth)=%llu cornerturn=%llu azFFT(FFT-2,range)=%llu detect=%llu\n", \
    (unsigned long long)(sar_stage_ts[1]-sar_stage_ts[0]), (unsigned long long)(sar_stage_ts[3]-sar_stage_ts[2]), \
    (unsigned long long)(sar_stage_ts[4]-sar_stage_ts[3]), (unsigned long long)(sar_stage_ts[5]-sar_stage_ts[4]), \
    (unsigned long long)(sar_stage_ts[6]-sar_stage_ts[5])
  printf "    TOTAL = %llu us = %llu ms\n", (unsigned long long)(sar_stage_ts[6]-sar_stage_ts[0]), (unsigned long long)((sar_stage_ts[6]-sar_stage_ts[0])/1000)
  printf "    RPROF[5](range gather)=%llu us  RPROF[8](renorm epilogue)=%llu us  RPROF[9](fabric wait)=%llu us\n", $rp[5], $rp[8], $rp[9]
  printf "    RPROF[11](chain status 0xC0EF|nch<<8|bad)=0x%llx\n", $rp[11]
end

monitor reset halt
monitor mpfs.hart0_e51 arp_halt
monitor mpfs.hart1_u54_1 arp_halt
thread 2
echo \n>>> booting firmware; M2 battery + eMMC init run first, so WAIT FOR THE MAILBOX LOOP\n
# Do NOT arm on a timer. A fixed 45 s wait left the hart still in eNVM boot code (pc=0x20220100)
# and produced a DEADLOCK that looked like a hung eMMC:
#   - we armed ELOD, so DDR@0xB0058000 = 'ELOD'
#   - the hart then reached u54_1.c:339 and wrote mbx->cmd = 0 -- into ITS CACHE
#   - the hart span forever reading its own cached 0, never dispatching
#   - gdb reads DDR PHYSICALLY, saw 'ELOD' still there, concluded the command was pending,
#     and so never re-armed either. Both sides waited on the other for 240 s.
# u54_1 links at 0x0a00_xxxx, eNVM boot at 0x2022_xxxx, so the pc alone tells us who is running.
set $boot = 0
while ($boot < 300 && ($pc < 0x0a000000 || $pc >= 0x0b000000))
  monitor resume
  shell C:/ProgramData/Anaconda3-2025.12-1/python.exe -c "import time;time.sleep(10)"
  monitor mpfs.hart1_u54_1 arp_halt
  thread 2
  set $boot = $boot + 10
  printf "    ... booting %u s, pc=0x%016lx\n", $boot, $pc
end
printf ">>> firmware READY after ~%u s: pc = 0x%016lx  mbx.cmd=0x%08x\n", $boot, $pc, *(unsigned int*)0xB0058000

echo \n===== ELOD: load scene 0 from eMMC (fabric programming wiped DDR) =====\n
runcmd 0x454C4F44 0 0 240 "ELOD"
printf ">>> LOAD rec: verdict=%u nseg=%u sig_crc exp=0x%08x got=0x%08x\n", \
  *(unsigned int*)0xB005E008, *(unsigned int*)0xB005E00C, *(unsigned int*)0xB005E010, *(unsigned int*)0xB005E014

# Fabric coefficient generator ON: dual REQUIRES it (on the CPU coeff path FFT-1 is already
# CPU-paced and a second chain has no CPU budget to feed it -- the firmware would silently drop
# back to one chain and record that in RPROF[11]).
set {unsigned int}0xB0059138 = 0x43474E31
# Renormalize-epilogue split OFF here -- one variable at a time.
set {unsigned int}0xB005912C = 0

echo \n===== RUN A: SAR_DUALFFT OFF (single chain) =====\n
set {unsigned int}0xB005913C = 0
runcmd 0x50495045 0 0 180 "PIPE(A)"
report
runcmd 0x45524F49 0x0E001200 0x0E001200 90 "EROI(A)"
set $crcA = *(unsigned int*)0xB005E220
printf ">>> CRC_A = 0x%08x\n", $crcA

echo \n===== RUN B: SAR_DUALFFT = 'DFF2' (two chains) =====\n
set {unsigned int}0xB005913C = 0x44464632
runcmd 0x50495045 0 0 180 "PIPE(B)"
report
runcmd 0x45524F49 0x0E001200 0x0E001200 90 "EROI(B)"
set $crcB = *(unsigned int*)0xB005E220
printf ">>> CRC_B = 0x%08x\n", $crcB

echo \n===================== VERDICT =====================\n
printf "  CRC_A (1 chain) = 0x%08x\n", $crcA
printf "  CRC_B (2 chains)= 0x%08x\n", $crcB
if $crcA == $crcB
  printf "  ==== PASS: CRC UNCHANGED -- the second chain is arithmetically transparent ====\n"
else
  printf "  ==== FAIL: CRC MOVED -- H-2 signature (exponent/coeff cross-wire or re-arm race) ====\n"
  printf "  (dump the crop from 0x%08x for a value-level diff)\n", *(unsigned int*)0xB005E21C
end
echo ===================================================\n

monitor resume
monitor shutdown
quit
