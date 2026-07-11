# SAR bring-up GDB batch -- JTAG ONLY, no UART.
# Stages DDR over JTAG, runs the pipeline, and reports status + BFP shift in the
# GDB console (the board's uart_print() output is irrelevant on this design).
# Run from this (jtag_full) directory so the bare-path restores/dump resolve:
#   riscv64-unknown-elf-gdb <path>/mpfs-hal-ddr-demo.elf -x sar_debug.gdb
# (OpenOCD must already serve :3333 -- see run_board.bat)

set pagination off
set confirm off

# fabric AXI-Lite control regs (SAR_ACCEL_BASE 0x60000000)
set $SAR_STATUS = 0x60000004
set $SAR_BFP    = 0x6000001C

# --- connect + reset + download firmware over JTAG ---
target extended-remote localhost:3333
monitor reset halt
load

# --- run through HAL DDR training + the DDR self-test; stop at the first read
#     of staged data (one-shot). DDR is trained + free at this point. ---
tbreak sar_job_load
continue

# --- stage SIG + geometry + job into DDR over JTAG ---
printf "\n>>> staging SAR inputs into DDR over JTAG...\n"
source load.gdb
printf ">>> staged. Running pipeline (full-res; may take a while)...\n"

# --- run the pipeline; capture the return status (RISC-V a0) ---
tbreak sar_form_image
continue
finish
set $st = $a0

printf "\n=================== SAR RESULT ===================\n"
printf ">>> sar_form_image status = %d   (0 = SAR_SEQ_OK)\n", $st
printf ">>> fabric STATUS @0x%08X = 0x%08X  (bit0 DONE, bit2 ERR)\n", $SAR_STATUS, *(unsigned int *)$SAR_STATUS
printf ">>> fabric BFP shift @0x%08X = %d\n", $SAR_BFP, *(int *)$SAR_BFP
printf "=================================================\n"

# --- dump the detected image (OUT, 128 MiB) over JTAG -> jtag_full/out.bin ---
printf ">>> dumping OUT (0xA8000000..0xB0000000) to out.bin over JTAG...\n"
dump binary memory out.bin 0xA8000000 0xB0000000
printf ">>> done.\n"
printf ">>> readback (from this jtag_full dir):\n"
printf "    python ../dump_output.py readback --stage . --file out.bin --bfp-shift %d --golden golden_fixed.npy\n", *(int *)$SAR_BFP
