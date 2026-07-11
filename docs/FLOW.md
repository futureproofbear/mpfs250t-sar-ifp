# DDR Test-Packet Flow — PolarFire SoC Icicle Kit (MPFS-ICICLE-KIT-ES)

Goal: send a structured test data packet into the LPDDR4 (DDR) address space of
the MPFS250T, read it back, and prove the data landed intact.

Board page: https://www.microchip.com/en-us/development-tool/mpfs-icicle-kit-es

---

## 0. Key idea

By the time *your* application code runs, the **MPFS HAL has already initialised
and trained the LPDDR4**. So "sending a packet to DDR" is simply writing a buffer
to a DDR address window and reading it back. The MSS exposes DDR through several
address windows; this demo uses the **cached 32-bit window at `0x8000_0000`**.

| Window                 | 32-bit base   | 64-bit base      | Use                                  |
|------------------------|---------------|------------------|--------------------------------------|
| Cached (via L2)        | `0x8000_0000` | `0x10_0000_0000` | normal app memory (default here)     |
| Non-cached             | `0xC000_0000` | `0x14_0000_0000` | prove data physically reached DRAM   |
| Non-cached write-combine | `0xD000_0000` | `0x18_0000_0000` | streaming writes                     |

To *guarantee* the write reached the DRAM (not just L2 cache), retarget
`DDR_TEST_BASE` to `DDR_NONCACHED_BASE_32` in [e51.c](src/application/hart0/e51.c).

---

## 1. Tools you need

1. **Libero SoC** + the Icicle Kit **reference design** programmed into the FPGA
   (provides the trained-DDR MSS configuration). Microchip ships a prebuilt
   `MPFS_ICICLE_KIT_BASE_DESIGN` job file you can flash with **FlashPro Express**.
2. **SoftConsole** (Microchip's Eclipse-based RISC-V IDE + GCC toolchain).
3. The **`mpfs-hal`** embedded platform — bundled in Microchip's
   `mpfs-hal-ddr-demo` / `platform` repo on GitHub
   (`github.com/polarfire-soc/...`). This supplies `mpfs_hal/`, the MMUART
   driver, linker scripts, and the boot code that trains DDR.
4. A **serial terminal** (PuTTY / Tera Term / minicom), **115200 8N1**.
5. Optional: a **debugger** (the on-board **FlashPro6** on connector **J33** / J-Link)
   for `load + run`.

---

## 2. Create the project

1. In SoftConsole: **File → New → PolarFire SoC project** (or import the
   `mpfs-hal-ddr-demo` example as a starting template — it already has the
   platform tree, linker scripts, and boot mode set up).
2. Replace / add these files into the project's `src/`:

   ```
   src/application/hart0/e51.c        <- the demo (this repo)
   src/application/hart1/u54_1.c      <- parked stubs (this repo)
   src/application/hart2/u54_2.c
   src/application/hart3/u54_3.c
   src/application/hart4/u54_4.c
   src/ddr_test/ddr_packet_test.h     <- portable send/verify logic
   src/ddr_test/ddr_packet_test.c
   ```

3. Make sure `src/ddr_test` and the `platform` include paths are on the
   compiler include path (Project → Properties → C/C++ Build → Settings →
   Includes). The platform tree gives you `mpfs_hal/mss_hal.h` and
   `drivers/mss/mss_mmuart/mss_uart.h`.
4. Pick the **build configuration** that matches where you want the code to run:
   - `LIM-Debug` / `DDR-Release` etc. For first bring-up use a **debug, run-from-
     LIM** config so you can load over the debugger without programming eNVM.

---

## 3. Build, load, run

1. **Program the FPGA** with the Icicle reference design (once per board) so the
   MSS + DDR are configured. *Without this the DDR windows are not trained and
   every packet will fail.*
2. **Build** the SoftConsole project (Project → Build).
3. Open the serial terminal on the kit's USB-UART COM port @ 115200 8N1.
4. **Debug → run** the `*-Debug` launch config. The ELF loads to LIM/DDR and the
   E51 starts at `e51()`.

---

## 4. What you should see

```
=====================================================
 PolarFire SoC Icicle Kit -- DDR test-packet demo
=====================================================
 Target DDR window : 0x80000000 (cached)
 Packet size       : 272 bytes (header+payload+crc)
 Packets           : 8, 4096 bytes apart

 [seq  0] @ 0x80000000  crc=0x........  -> OK
 [seq  1] @ 0x80001000  crc=0x........  -> OK
 ...
 [seq  7] @ 0x80007000  crc=0x........  -> OK
-----------------------------------------------------
 RESULT: 8 passed, 0 failed -- DDR DATA INTEGRITY OK
-----------------------------------------------------
```

A failing line names the **first mismatching byte offset** and whether the
header, the payload, or the CRC broke — enough to start root-causing (stuck data
line, wrong window, untrained DDR, etc.).

---

## 5. How the verification works (`ddr_test/`)

- **`ddr_pkt_build()`** fills a `ddr_test_packet_t` (magic + length + sequence +
  256-byte payload) with a position+sequence-dependent pattern, then appends a
  **CRC-32** over the whole header+payload.
- **`ddr_pkt_send_and_verify()`** writes the packet **byte-by-byte through
  `volatile` pointers** into the DDR window (the "send"), reads it back into a
  local buffer (the "receive"), then checks: header fields, every payload byte,
  and recomputes the CRC over the read-back data. `volatile` is essential — it
  stops the compiler from optimising the round-trip away.

Three independent checks (header, byte compare, CRC) mean a single stuck bit,
an address-aliasing fault, or a stale packet all show up as a failure.

---

## 6. Going further

- **Prove it hit DRAM, not cache:** set `DDR_TEST_BASE = DDR_NONCACHED_BASE_32`.
- **64-bit address space / >2 GB:** use `DDR_CACHED_BASE_64` (`0x10_0000_0000`).
- **Soak test:** raise `NUM_PACKETS`, randomise the sequence seed, and walk the
  whole DDR range to turn this into a memory-integrity sweep.
- **Real packet source:** instead of `ddr_pkt_build()`, receive the packet bytes
  over MMUART/Ethernet into the same struct, DMA it to DDR, then verify — the
  verify half is unchanged.
