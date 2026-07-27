# Hand-written corner-turn (`corner_turn_v.v`) — design

Replaces the SmartHLS `corner_turn_top`, the last HLS block on the datapath. Target: the two
corner-turns are **~11 s of the 25.16 s frame**.

## 1. The contract (unchanged — this is what must stay bit-identical)

From `corner_turn.cpp`, which is the verified model:

```
dst[(c)*H + r] = src[(r)*W + c]        element = uint32 = complex int16 packed (I<<16)|Q
```

Tiled T×T: read `th` rows of `tw` contiguous elements from src (stride W), transpose on-chip,
write `tw` rows of `th` contiguous elements to dst (stride H). Ragged edges via `min()`. Current
`CT_T = 128`.

## 2. What silicon actually says (E4, 2026-07-27)

`ELAPSED` 5.974 s for one full-frame turn — 85.7 MB/s both ways against a **800 MB/s** FIC_0
ceiling (64 bit × 100 MHz).

| | share |
|---|---:|
| moving data (`TOTAL_ACTIVE`) | 22.7% |
| asked, DDR didn't deliver (`R_DATAWAIT`) | 35.8% |
| not even asking (idle) | 41.5% |

`MAX_R_DATAWAIT` 87 cyc (870 ns). 524,288 write bursts × 128 beats = 67.1 M beats.

**Three separate defects, and the beat count exposes the one nobody had spotted:** 67.1 M beats is
512 MiB of 64-bit beat *capacity* to move a 256 MiB frame, so the HLS kernel is writing **one
uint32 per beat — half the data bus wasted**. That is consistent with 128 beats per 512 B burst.

## 3. What the rewrite fixes, and what it does not

| defect | measured | fix | expected |
|---|---:|---|---|
| half-width beats | 512 MiB capacity for 256 MiB | pack 2 elements per 64-bit beat | ~2× |
| idle 41.5% | read tile, *then* write tile | double-buffer: read tile n+1 while writing tile n | overlaps read stalls under writes |
| `R_DATAWAIT` 35.8% | strided reads, page miss per row | **not directly fixable** — the stride is inherent to a transpose | hidden, not removed |

The third is the honest limit. Each tile row is a separate DRAM page (stride W = 32 KB), and the
interconnect caps outstanding reads at 2 (`OPEN_RDTRANS_MAX = max(MAX_OUTSTNDG_TRANS,2)`), so the
page-miss latency cannot be pipelined away. Double-buffering does not *remove* that 35.8%, it
**hides it under write traffic**. Any projection that assumes it disappears is wrong.

`CT_T` 32→128 previously bought only ×1.23, which is exactly what you would expect if the burst
size was never the binding constraint.

## 4. The one non-obvious piece: bank the tile buffer

Full-width beats need **two elements per cycle on both sides**, but they are two *different*
adjacencies:

- filling from src: `(i,j)` and `(i,j+1)` — same row, adjacent columns
- draining to dst: `(i,j)` and `(i+1,j)` — same column, adjacent rows

A plain two-port RAM cannot serve either pair in one cycle. Store element `(i,j)` in

```
bank = (i ^ j) & 1
```

- fill pair: `(i^j)&1` vs `(i^(j+1))&1` → always differ ✓
- drain pair: `(i^j)&1` vs `((i+1)^j)&1` → always differ ✓

One XOR gives conflict-free access in both directions. Two banks of `T*T/2` words each.

## 5. Sizing

T = 128 → 128×128 uint32 = 64 KiB per tile buffer. In RAM1K20: ⌈16384/1024⌉ × ⌈32/20⌉ = 16 × 2 =
**32 blocks**, ×2 for double buffering = **64 blocks**. LSRAM is at 327/812, so 485 free — it fits
with room to spare. (Estimate, per [[lsram-estimates-unreliable]]: re-derive from synthesis before
believing it.)

## 6. Interface

Keep the SmartHLS control contract exactly, so `sar_kernels.h`, the firmware and every `.gdb`
script are untouched:

```
+0x08  START / STATUS   write 1 = start, reads 0 when idle
+0x0c  ARG0 = src_base
+0x10  ARG1 = dst_base
+0x14  ARG2 = c_base     (strip column base)
+0x18  ARG3 = c_count    (0 => full frame)
```

`ct2_strip_arm()` already drives exactly these, and the strip form is what `fft2_ct_overlap` needs,
so the strip path must work from day one — not be added later.

## 7. Verification order (do not reorder)

1. **Host model already exists and is verified** — `corner_turn.cpp` self-test vs numpy `.T`.
2. Unit TB: transpose a frame through the RTL against that model, bit-exact, for square, ragged and
   strip (`c_base`/`c_count`) shapes.
3. **Mutation-test the TB** — at minimum: swap the bank XOR, drop the ragged `min()`, off-by-one the
   dst stride, and drop the second element of a packed beat. A TB that cannot fail proves nothing.
4. Only then build.
5. Silicon: **one ELOD per PIPE run**; gate is CRC equality at `0x319037b2`, plus E4 re-measured to
   confirm the utilisation actually moved.

## 8. What would make this a bad idea

If E4 after the rewrite shows `R_DATAWAIT` still ~36% and utilisation still low, the transpose is
DDR-page-bound and no amount of RTL fixes it — the answer would then be a different *algorithm*
(e.g. avoiding one of the two corner-turns entirely), not a better kernel. Re-measure before
declaring victory.

**A NEW MODULE, NOT AN EDIT.** `corner_turn_v.v` is instantiated in place of `corner_turn_top`;
nothing proven is modified. Adding pass-1 as a second mode inside the proven `sar_coeffgen.v`
regressed the shipping path on silicon while its unit TB passed 12/12 with 4/4 mutants caught —
that is the precedent this rule comes from.
