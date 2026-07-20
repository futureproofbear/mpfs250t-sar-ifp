# Milestone-1 eMMC self-test over JTAG -- MAILBOX trigger (PROVEN, verdict=PASS 2026-07-13).
#
# Why the mailbox (not `p sar_emmc_selftest(...)`):
#   - The gdb inferior-`call` path CRASHES under openocd `-rtos hwthread` SMP
#     ("RTOS: failed to get register 33" / find_inferior_pid assert). The firmware's
#     MBX_CMD_EMMC mailbox command is the working trigger.
#   - Do NOT read any SDHCI/SRS register (0x20008xxx) before the self-test runs -- the
#     block is clock-gated until sar_emmc_selftest enables MSS_PERIPH_EMMC; an unclocked
#     read dead-buses and wedges hart1 (power-cycle only). SRS reads are gated on
#     mailbox status == done below.
#   - Attach IN PLACE (no `monitor reset halt`): on this MPFS250T_ES the power-on eNVM
#     boot already lands hart1 in its u54_1() mailbox loop; a JTAG reset does NOT reliably
#     re-boot the U54 (see run_emmc_iso.sh / the layered notes).
# Mailbox m2_mbx_t @0xB0058000: cmd+0, base+4, len+8, result+0xC, status+0x10, seq+0x14.
# Writes issued with thread 2 (hart1) selected -> hart1's coherent progbuf store path.
set pagination off
set confirm off
set architecture riscv:rv64
set mem inaccessible-by-default off
shell C:/ProgramData/Anaconda3-2025.12-1/python.exe wait_port.py
target extended-remote localhost:3333
monitor mpfs.hart1_u54_1 arp_halt
thread 2
printf ">>> hart1 boot pc = 0x%016lx  (expect inside u54_1() mailbox loop, NOT reset_vector 0x20220100)\n", $pc
# arm the EMMC command: base = scratch LBA (SAR_EMMC_OUT_LBA), cmd LAST
set {unsigned int}0xB0058004 = 0x880000
set {unsigned int}0xB0058008 = 0
set {unsigned int}0xB005800C = 0
set {unsigned int}0xB0058010 = 0
set {unsigned int}0xB0058000 = 0x454D4D43
echo >>> EMMC command armed (base=0x880000). Resuming; self-test enables the eMMC clock then runs...\n
monitor resume
monitor sleep 20000
monitor mpfs.hart1_u54_1 arp_halt
thread 2
printf ">>> post-run hart1 pc = 0x%016lx\n", $pc
echo >>> mailbox @0xB0058000 (cmd base len result status seq):\n
x/6xw 0xB0058000
echo >>> result record @0xB005A000 (magic init wr rd crcE crcR memcmp lba verdict):\n
x/9xw 0xB005A000
printf ">>> magic=0x%08x init=%u write=%u read=%u crcE=0x%08x crcR=0x%08x memcmp=%u verdict=%u (0=PASS)\n", \
  *(unsigned int*)0xB005A000, *(unsigned int*)0xB005A004, *(unsigned int*)0xB005A008, \
  *(unsigned int*)0xB005A00C, *(unsigned int*)0xB005A010, *(unsigned int*)0xB005A014, \
  *(unsigned int*)0xB005A018, *(unsigned int*)0xB005A020
set $st = *(unsigned int *)0xB0058010
if $st == 0xC0FFEE03
  echo >>> selftest done (status=0xC0FFEE03); eMMC clock enabled -> SDHCI read is safe.\n
  printf ">>> SRS04 (OCR) @0x20008210 = 0x%08x  (nonzero = eMMC responded)\n", *(unsigned int*)0x20008210
  printf ">>> SRS09 (present) @0x20008224 = 0x%08x\n", *(unsigned int*)0x20008224
else
  printf ">>> selftest NOT complete (status=0x%08x != done); SKIPPING SDHCI read (dead-bus guard).\n", $st
end
echo >>> clean teardown: resume + openocd shutdown\n
monitor resume
monitor shutdown
quit
