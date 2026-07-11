# fabric-range-fft Specification

## Purpose
Move a complex SAR range line from DDR through an on-fabric 8192-point FFT and back to DDR,
offloading the range transform from the MSS CPU. The path is:

    DDR --(fft_feeder_v, AXI read master)--> AXI4-Stream --(gearbox)--> CoreFFT (in-place, 8192,
    MEMBUF=0, conditional block-floating-point) --(gearbox)--> AXI4-Stream --(fft_unloader,
    AXI write master)--> DDR

Correctness is measured against the bit-accurate BFP golden (`mpfs/host/fft_golden.py`) with a
scale-invariant metric (corr >= 0.999), because CoreFFT's block exponent differs by a power of 2.

## Requirements

### Requirement: Read a complex frame from DDR into the FFT
The feeder SHALL read `nbeats` 64-bit beats (two 16-bit complex samples each) from a DDR base
address via an AXI4 read-burst master and present them as an AXI4-Stream to the FFT input, with
backpressure honored so no beat is issued that cannot be buffered.

#### Scenario: Feed one 8192-point frame
- **WHEN** the feeder is armed with `src_base` and `nbeats = 4096` (8192 samples) and started
- **THEN** it issues INCR read bursts (4KB-boundary-aware), streams all 4096 beats to the FFT,
  drains its FIFO, and reports `busy = 0`.

### Requirement: Lossless output rate-matching under DDR backpressure
The gearbox SHALL rate-match the CoreFFT output to a downstream sink that applies arbitrary
backpressure WITHOUT losing any output sample and WITHOUT reordering or mis-pairing the
real/imaginary halves. Because CoreFFT's `DATAO_VALID` trails `READ_OUTP` by a fixed pipeline
latency, the gearbox SHALL capture every asserted-`DATAO_VALID` sample regardless of the current
`READ_OUTP` level, and SHALL de-assert `READ_OUTP` early enough (reserving at least the pipeline
latency of buffer slots) that no in-flight sample arrives to a full buffer.

#### Scenario: Sink backpressures mid-unload
- **WHEN** the downstream sink de-asserts `tready` for extended, arbitrary spans during the
  unload of an 8192-point frame (forcing the gearbox output FIFO toward full)
- **THEN** every one of the 8192 samples the FFT emits is delivered to the sink, in order, with
  correct re/im pairing (verified by `mpfs/fpga/sim/corefft_stream64_lossck_tb.v`: samples
  received == samples emitted, zero mismatch, even though `READ_OUTP` drops many times).

#### Scenario: Backpressure via READ_OUTP is spec-legal
- **WHEN** the gearbox pauses the read by de-asserting `READ_OUTP`
- **THEN** the CoreFFT in-place core (MEMBUF=0) SHALL cleanly pause its output-address counter and
  hold `OUTP_READY`, per CoreFFT UG §3.1 / Table 2-2 ("the recipient can insert arbitrary breaks
  in the burst by deasserting READ_OUTP"); the pause only lengthens the FFT cycle, never truncates.

### Requirement: Write the transformed frame back to DDR
The unloader SHALL consume the gearbox output AXI4-Stream and write exactly `nbeats` beats to a
DDR destination base via an AXI4 write master, completing (`busy = 0`) once the whole frame is
written.

#### Scenario: Unload one frame
- **WHEN** the unloader is armed with `dst_base` and `nbeats = 4096` and the gearbox delivers a
  full frame
- **THEN** SCRATCH DDR holds the 8192 transformed samples and the unloader reports `busy = 0`.

### Requirement: Single-frame quiescence during unload
The data path SHALL NOT initiate a new FFT input frame while the current frame is being unloaded
(no `DATAI_VALID`/`BUF_READY`-gated load overlapping the output phase), so that the in-place
memory being read out is never overwritten.

#### Scenario: Continuous feeder during unload
- **WHEN** the feeder continues to present stream data while the FFT is in its output phase
- **THEN** the gearbox holds the FFT input off (`s_axis_tready` low while `buf_ready` is low) so
  no new frame preempts the unload.

### Requirement: Silicon iso-testability
The path SHALL be drivable over JTAG (feeder @0x60004000, unloader @0x60005000; +0x08 START/STATUS,
+0x0c ARG0=base, +0x10 ARG1=nbeats) with results read back from DDR SCRATCH under FIC_0
non-coherent flush discipline, so each stage can be validated in isolation on silicon.

#### Scenario: One-frame iso-test
- **WHEN** `CASES=impulse bash mpfs/host/run_corefft_iso.sh` runs against the programmed fabric
- **THEN** it reports feeder busy, unloader busy, and the per-row correlation vs the BFP golden.
