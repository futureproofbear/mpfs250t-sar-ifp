@echo off
rem ============================================================================
rem  SAR board bring-up launcher (Windows). Starts OpenOCD (gdb server) then
rem  runs GDB with jtag_full\sar_debug.gdb to load firmware, stage DDR, and run.
rem  PREREQUISITE: program the FPGA first (FlashPro Express -> SAR_TOP.job, ES).
rem ============================================================================
setlocal
set "SC=C:\Microchip\SoftConsole-v2022.2-RISC-V-747"
set "ELF=C:\Users\lkwangsi\Documents\github\sarProcessor\mpfs\fpga\libero_sar\softconsole\mpfs-hal-ddr-demo\Icicle-Kit-DDR-666MHz-eNVM-Scratchpad-Release\mpfs-hal-ddr-demo.elf"
set "JTAG=%~dp0jtag_full"

if not exist "%ELF%" ( echo ERROR: .elf not found: %ELF% & exit /b 1 )
if not exist "%JTAG%\sar_debug.gdb" ( echo ERROR: jtag_full\sar_debug.gdb not found & exit /b 1 )

echo Starting OpenOCD (gdb server on localhost:3333)...
start "OpenOCD-MPFS" "%SC%\openocd\bin\openocd.exe" -s "%SC%\openocd\share\openocd\scripts" --command "set DEVICE MPFS" --file board/microsemi-riscv.cfg --command "adapter speed 1000"
echo Waiting for OpenOCD...
timeout /t 4 /nobreak >nul

cd /d "%JTAG%"
echo Launching GDB (load .elf -> stage DDR -> run)...
"%SC%\riscv-unknown-elf-gcc\bin\riscv64-unknown-elf-gdb.exe" -iex "set pagination off" -iex "set height 0" "%ELF%" -x sar_debug.gdb

echo.
echo Done. SAR status + BFP shift were printed in the GDB console above,
echo and OUT was dumped to jtag_full\out.bin over JTAG (no UART used).
echo Close the OpenOCD window when finished.
endlocal
