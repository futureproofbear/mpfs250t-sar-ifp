---
marp: true
theme: default
paginate: true
size: 16:9
title: A SAR Image-Formation Processor on PolarFire SoC
description: From CPHD phase history to a detected 8192x8192 image in under 15 s on an MPFS250T, with the mathematics of each stage and how it maps onto fabric.
style: |
  section {
    font-family: Helvetica, Arial, sans-serif;
    font-size: 24px;
    padding: 48px 64px;
    justify-content: flex-start;
  }
  section > * { max-width: 100%; }
  section p, section ul, section ol, section blockquote { width: 100%; }
  section table { font-size: 16px; }
  section pre { font-size: 18px; }
  section h1 { font-size: 40px; }
  section h2 { font-size: 32px; }
---

# A SAR Image-Formation Processor on PolarFire SoC

From CPHD phase history to a detected image, on an MPFS250T

**Part 1** — the problem
**Part 2** — the mathematics, stage by stage
**Part 3** — how it maps onto fabric

---

# Part 1 — Problem statement

Take **CPHD phase-history data** and produce a **detected image**, on one MPFS250T.

| requirement | target |
|---|---|
| Input | complex phase history, **≤ 8192 × 8192** samples — **int16 I + int16 Q**, 4 B/sample (256 MB) |
| Output | detected magnitude, **8192 × 8192** — **uint16**, 2 B/pixel (128 MB) |
| Internal | int16 complex throughout, **block floating point** across the FFTs |
| Wall-clock | **≤ 15 s** per frame |
| Chip resources | minimise power and area |
| Interpolation | **baseline: linear** · **variant: 32-tap sinc** |

- Two interpolation variants: 
  - linear kernel provides a low resource implementation 
  - sinc kernel for higher image quality at expense of more fabric resources

---

# Resource constraints on the MPFS250T

A 8192 × 8192 complex frame is **256 MB** at 4 B/sample. The whole device does not have enough memory to process fully on chip:

| on-chip memory | MPFS250T |
|---|---|
| LSRAM | 812 × 20 Kb = **~2.0 MB** |
| µSRAM | 2,352 × 768 b = **~0.2 MB** |
| MSS L2 (as scratchpad) | **2 MiB** |
| **Total** | **~4.4 MB — about 1/58th of one frame** |

No processing stage can be held on chip, and every stage needs to stream through DDR. This constraint drives the whole processing architecture:
- the design is **bandwidth-bound, not compute-bound**
- the fabric↔DDR port (FIC_0, 64-bit @ 100 MHz ≈ **800 MB/s**) is the scarce resource
- **every DDR round-trip costs more than any arithmetic optimisation**

The engineering approach is therefore *fewer passes over the data*, not faster maths.

---

# Part 2 — The Python reference pipeline

<br>

![w:1150](diagrams/fig-sar-python.drawio.svg)

<br>

`src/form_image_pfa.py` — python implementation of the **Polar Format Algorithm (PFA)**.

---

# PFA geometry — polar in, rectangular out

![w:1020](diagrams/fig-sar-kspace.drawio.svg)

Middle panel — **pass 1** resamples every pulse onto the common grid $K_R$. Because $p_r[i]$ is a
projection onto the mean look direction, $k_r$ is the $k_y$ component, so this makes $k_y$ uniform. $k_x$ still carries an angular increment, leaving a **trapezoid**.
Right panel — **pass 2** resamples along the pulse axis onto $K_C$, making $k_x$ uniform too.
<!--Not clear what is k_y and k_x-->
---

# ① Range resample — keystone, fast-time

Each pulse $i$ samples the range-frequency axis on **its own grid** — uniform in $j$, but with an
origin and a spacing unlike any other pulse's, and unlike the common output grid $K_R$. What varies
pulse to pulse is the **look angle**: $p_r[i]=\cos\phi_i$ projects the frequency ramp onto the mean
look direction, so a pulse seen further off boresight lands its samples closer together.

$$k_r[i,j] \;=\; p_r[i]\,\bigl(f_0[i] + j\,\Delta f[i]\bigr) \;=\; x_{0,i} + j\,\Delta x_i$$

| symbol | implementation | meaning |
|---|---|---|
| $f_0[i]$ | `freq[i,0]` | first RF frequency of pulse $i$ |
| $\Delta f[i]$ | `freq[i,1] - freq[i,0]` | step per sample — the ramp is linear, so one difference defines it |
| $p_r[i]$ | `ax[i]*(dx/dn) + ay[i]*(dy/dn)` | $\hat a_i\cdot\hat d=\cos\phi_i$ — projection on the **mean** look direction $\hat d=(dx,dy)/dn$. (`dx,dy` are that mean vector; nothing to do with $\Delta x_i$). $p_r[i]$ is what makes $k_r$ the $k_y$ component, which is why pass ① lines the rows up. |
| $x_{0,i}$ | `a*f0[i]`, with `a = 2*pr[i]/c` | this pulse's grid origin |
| $\Delta x_i$ | `a*df[i]` | its spacing — the value ① divides by |

---

# ① Range resample — finding $(k,\mu)$

For each pulse $i$, we want to find the data value at the output sample location $K_R[q]$, where $q = 0\ldots N_p-1$, $N_p = 8192$. By setting $K_R[q]=x_{0,i}+t\,\Delta x_i$, and solving for $t$:

$$t \;=\; \frac{K_R[q] - x_{0,i}}{\Delta x_i},\qquad k=\lfloor t \rfloor,\qquad \mu = t-k$$

We can then find the $q^{th}$ output sample value:

$$\text{out}[q] \;=\; (1-\mu)\,\text{in}[k] \;+\; \mu\,\text{in}[k{+}1]
\qquad\text{(2-tap, baseline)}$$
$$\text{out}[q] \;=\; \textstyle\sum_{n=0}^{31} c_n(\mu)\,\text{in}[k{-}15{+}n]
\qquad\text{(32-tap sinc, variant)}$$

with the taps spanning $k{-}15 \ldots k{+}16$, so tap $n$ sits at offset $n-15-\mu$ from the
interpolation point:

$$c_n(\mu) \;=\; \frac{\operatorname{sinc}(n-15-\mu)}{\sum_{m=0}^{31}\operatorname{sinc}(m-15-\mu)}$$

---

# ② Azimuth resample — finding $(k,\mu)$

After pass ①, a sample from pulse $i$ sits in k-space at $k_y = k \cdot \cos \phi_i$ → resampled onto the uniform grid.

After the transpose a row is one range bin $r$. So along row $r$ the source abscissa in $k_x$ units is $K_R[r] \cdot \tau[m]$ where $\tau = \tan \phi$ sorted. Pass ② wants output at uniform $K_C[q]$. 

$M$ pulses, to be resampled onto the uniform cross-range grid $K_C[q]$. The source abscissa is the sorted aspect-angle tangent τ = tan φ = $\tau[0\ldots M{-}1]$ — and unlike ①, it is **not uniform**.

, so for row $r$ it is exactly $K_R[r]$
k_x = k·sin φᵢ = k_y·tan φᵢ = K_R[r]·tan φᵢ. 


So solving $K_C[q] = K_R[r] \cdot \tan \phi$ → $\tan \phi = K_C[q]/K_R[r] ≡ u$. u is just the desired location expressed as a tangent instead of a frequency — which lets the search run against τ directly.

$$u \;=\; \frac{K_C[q]}{K_R[r]},\qquad
k \;=\; \max\{\,m : \tau[m] \le u\,\},\qquad
\mu \;=\; \frac{u - \tau[k]}{\tau[k{+}1]-\tau[k]}$$

$K_R[r]$, not a per-pulse $k_r$: after ① every pulse shares one range grid. Its reciprocal is the
**only divide in the row**.

So $k$ must be *found*, not computed — but $\tau$ and $K_C$ are both sorted, which turns the search
into a merge scan: one pointer that only ever moves forward.

```c
while (k+2 < M && tau[k+1] <= u) k++;   /* never retreats */
```

Then the same gather kernel as ①. Together the two passes map the polar-sampled phase history onto
a **rectangular** $k$-space grid.

---



That matters because τ is row-invariant: the same 705-entry table for all 8192 rows. Search in k_x units instead and the source abscissa K_R[r]·τ[m] changes every row, so you'd rebuild or rescale the whole table 8192 times.

One wrinkle worth knowing: the code doesn't literally divide. sar_coeffs_pass2_range brackets in k_x — SRC(k) = kr*tan_s[k] against KC[q] — and forms μ = (q − x0)·inv with inv = s_inv_tan[k]·(1/kr). Expand it and you get (u − τ[k])/(τ[k+1] − τ[k]), identical to the slide. The rearrangement is the point: s_inv_tan[k] = 1/(τ[k+1] − τ[k]) stays line-invariant and precomputed once per scene, so the row costs one divide (1/kr) instead of one per query

---

# ③ Window · ④ FFT · ⑤ Detect

**Window** — separable Hamming, suppressing sidelobes from the finite aperture:

$$w[r,c] = w_r[r]\,w_c[c],\qquad w[n] = 0.54 - 0.46\cos\!\left(\tfrac{2\pi n}{N-1}\right)$$

**FFT** — a 2-D transform takes rectangular $k$-space to the image. It is separable, which is
the entire reason the hardware can do it in two 1-D passes with a transpose between:

$$I[y,x] = \sum_{r}\sum_{c} S[r,c]\;e^{-2\pi i (ry/N_p + cx/M_p)}$$

$S[r,c]$ is the **windowed, rectangular $k$-space array** produced by stages ①–③: row $r$ is a
range-frequency bin, column $c$ a cross-range (Doppler) bin, each entry a complex int16 sample.
It is what the polar-to-rectangular resampling exists to construct — the FFT is only valid on a
*uniformly* sampled grid, which the raw phase history is not.

**Detect** — discard phase, keep brightness: 
$$\text{OUT}[y,x] = \sqrt{\Re^2 + \Im^2}$$

---

# Part 3 — MPFS250T Architecture and Resources

![w:1080](diagrams/fig-sar-mpfs.drawio.svg)

---
# DDR memory map — the allocation

![w:900](../img/sar_ddr_map.svg)

---

# DDR memory map and why it is laid out this way

SIG and SCRATCH are 256 MB as the complex data is 4 B/sample. `OUT` is half the size of the others because the detected image is **uint16**, 2 B/px, plus a small geometry/telemetry block .  

| buffer | address | size | role |
|---|---|---|---|
| `SIG` | `0x8800_0000` | 256 MB | phase history in, then ping-pong |
| `SCRATCH` | `0x9800_0000` | 256 MB | resample out, then FFT ping-pong |
| `OUT` | `0xA800_0000` | 128 MB | detected image, 2 B/px |
| geometry | `0xB000_0000`+ | ~1 MB | `f0`, `df`, `pr`, `tan_s`, `KR`, `KC`, `invorder` |
| knobs / telemetry | `0xB005_9xxx` | words | runtime mode + per-stage timing |

**Buffers are 256 MB apart on purpose.** An in-place FFT stalls: the DMA is still flushing transform *t* while the feeder pulls *t+1* over the shared interconnect, CoreFFT drops `BUF_READY` and the pipeline locks. Ping-ponging `SCRATCH`↔`SIG` keeps read and write on  **separate 256 MB pages** — validated on silicon after an in-place build hung at transform 1.

---

# Fabric-to-DDR routing

![w:1000](../img/sar_fabric_ddr_routing.svg)

Every fabric master reaches DDR through **one** FIC_0 port. The interconnect is single-outstanding,
so concurrency between masters buys far less than it appears to — measured overlap between
independent kernels on the shared port is ~81%, not 2×.

---

# AXI beat packing — why the gather reads full-width

![w:1080](diagrams/fig-axi-packing.drawio.svg)

Every remaining DDR stream runs at the full 64-bit width. A pulse row is `N·4` bytes with `N` odd,
so alternate rows start mid-beat — the gather still reads `AxSIZE 3'd3` from `IN_BASE & ~7` and
absorbs the offset into the sample **index**, discarding one leading word per row.

The coefficient streams were not made faster — they were **deleted**. `idx` and `wq` are generated
on fabric from three scalars per line, so 48 KB per line no longer crosses DDR at all.

---

# CoreFFT streaming chain

![w:1000](../img/sar_corefft_chain.svg)

`feeder → gearbox → CoreFFT → unloader`, crossing from the 100 MHz fabric domain into CoreFFT's
12.5 MHz `SLOWCLK`. The feeder is where the azimuth gather and the window are fused in; the
unloader is where detect is fused. Two such chains run in parallel, splitting rows.

---

# Dataflow — the unfused pipeline

![w:1150](diagrams/fig-sar-dataflow-unfused.drawio.svg)

Eight operators, eight full-frame DDR passes. Nothing here is wrong — it is just paying bus time
for work that could ride along inside a pass already moving the data.

---

# Dataflow — one frame, as built

![w:1150](diagrams/fig-sar-dataflow.drawio.svg)

Each arrow is a full pass over 256 MB. Eight stages become **five** passes; window, azimuth gather
and detect add no traffic at all, and CT#2 hides under FFT-2. The count of arrows is the design.

---

# Mapping onto fabric

Write the pipeline as a composition of operators on the $8192^2$ array:

$$I \;=\; D\,\circ\,F_2\,\circ\,T\,\circ\,F_1\,\circ\,W\,\circ\,G_{az}\,\circ\,T\,\circ\,G_{rg}\;(S)$$

If done naively, **every operator is one pass over 256 MB** — eight passes, and at FIC_0's ~800 MB/s. Each pass costs at least 0.6 s of data transfer.

**Design approach.** An operator can be **fused** into a neighbouring streaming pass iff it is local in the streaming index.

| operator | form | local? |
|---|---|---|
| $W$ window | diagonal: $(Ws)[n]=w[n]s[n]$ | yes — pointwise |
| $G$ **gather** — the resample's inner op | $(Gs)[q]=\sum_{t}c_t\,s[k_q+t]$, $t$ finite | yes — finite support. Note: *Resample* is the intent — put the samples on a new grid; *gather* names the operation the fabric performs — an indexed read of a few neighbouring samples plus a weighted blend, $2$ taps for the linear kernel, $32$ for sinc. |
| $D$ detect | $(Dz)[n]=\lvert z[n]\rvert$ | yes — pointwise |
| $F$ FFT | every output depends on **all** inputs | **no** — needs its own pass |
| $T$ transpose | output $(r,c)$ from input $(c,r)$ | **no** — the access pattern *is* the cost |


---

# Stage fusion — mathematical equivalent

Four stages have **no independent pass** over DDR. Each fusion is justified by an algebraic
identity, not by convenience:

| fusion | the identity that makes it exact |
|---|---|
| **window → FFT-1 feeder** | $F_1(Ws)$ with $W$ diagonal. The feeder emits $w[n]s[n]$ as it reads $s[n]$: a diagonal operator commutes with the read order, so no reordering and no second pass. |
| **azimuth gather → FFT-1 feeder** | $F_1(G_{az}s)$. The feeder is already an *addressing* engine; $G$ only changes **which** index it presents and adds a finite-tap blend. Support is $O(1)$ per output. |
| **detect → FFT-2 unloader** | $D$ is pointwise on $F_2$'s output, so $\lvert z\rvert$ is computed as samples drain. Reading 256 MB back merely to square-and-add would be pure waste. |
| **corner-turn #2 ∥ FFT-2** | $F_2=\bigoplus_r F_2^{(r)}$ — rows are **independent**, so strip $s$ may be transposed while strip $s-1$ transforms. Overlap, not elimination. |

**What it buys.** Eight conceptual stages become **five** full-frame DDR passes, and four of them —
window, azimuth gather, detect, CT#2 — cost **zero** extra traffic. Only the two FFTs and the two
transposes, the operators that are *not* local, still need passes of their own.

---

# Coefficient generation — the largest single win

Per line the 2-tap gather needs $(k,\mu)$ for all 8192 outputs — **32 KB `idx` + 16 KB `wq`**.
Computing that on the MSS and publishing it to DDR cost more than the gather itself: bus
telemetry showed **~40 %** of the 5.21 s range gather was the port sitting *idle*, waiting on CPU
coefficients.

Because the range grid is uniform, $(k,\mu)$ is closed-form in fixed point:

$$v = \frac{(Q[q]\cdot A) \gg S}{} + B,\qquad k = v \gg 24,\qquad \mu = v[23{:}9]$$

with $A \approx 2^{S}/\Delta x$ and $B \approx -x_0/\Delta x$ — **three scalars per line**, not
8192 coefficients. The CPU writes 3 registers; the fabric generates the rest.

**5.21 s → 3.74 s**, and the coefficient traffic disappears from DDR entirely.

---

# Resource utilisation and timing closure

| resource | used | device | % | note |
|---|---|---|---|---|
| 4LUT | 124,380 | 254,196 | 49 % | |
| DFF | 86,910 | 254,196 | 34 % | |
| **LSRAM** | **537** | **812** | **66 %** | line buffers, FFT ping-pong, 2×32 sinc banks |
| uSRAM | 1,620 | 2,352 | 69 % | polyphase coefficient tables |
| **MACC** | **202** | **784** | **26 %** | still *not* compute-bound |
| User I/O | 11 | 144 | 8 % | |

| clock domain | period | setup slack | verdict |
|---|---|---|---|
| **fabric 100 MHz** | 10.000 ns | **+0.151 ns** | multi-corner `VIOLRPT` clean |
| CoreFFT 12.5 MHz | 80.000 ns | +67.784 ns | clean |

The 100 MHz domain is down to **1.5 % margin** from 2.6 % — the two sinc cores consumed 40 % of the
remaining headroom, and it stays the binding constraint. The critical path is `COEFG`'s multiplier,
**not** the interpolator: the sinc did not create the critical path, congestion degraded an existing
one.

---

# Pipeline timing — where the 14.17 s goes

Measured on Centerfield (5,634 × 4,319 → 8192 grid), both 32-tap sinc interpolators armed.

| stage | time | share | limited by |
|---|---|---|---|
| Resample — range gather | **1.67 s** | 12 % | DDR read latency |
| Resample — corner-turn #1 | **2.06 s** | 15 % | global transpose, not parallelisable |
| FFT-1 (+ azimuth gather, window) | **4.65 s** | 33 % | CoreFFT `SLOWCLK` |
| FFT-2 (+ detect, CT#2 overlapped) | **5.78 s** | 41 % | CoreFFT `SLOWCLK` |
| Window, azimuth gather, detect, CT#2 | **0 s** | — | fused / overlapped |
| **Total** | **14.17 s** | | **within the 15 s budget** |

The FFTs are **74 %** of the frame and their domain has 85 % timing margin, so the CoreFFT clock —
not the resample — remains the clearest lever.

**Both sincs are faster than the 2-tap baseline was** (14.95 s), which was not the expected trade.
The 0.78 s came from a memory-map fix, not the interpolator: a coefficient table had been mapped
across `SAR_CWRK`, the multi-hart coefficient-worker region that paces FFT-1.

---

# Correctness — how the fabric build is trusted

Fusion and fixed point both change the arithmetic, so *matching the Python* has to be proven,
not assumed:

- **Value-level, not correlation.** Correlation is scale-, phase- and orientation-invariant; it
  passes on a conjugated or bin-reversed FFT. Stages are compared **sample by sample** against a
  bit-accurate model.
- **Bit-exact anchor.** The linear build reproduces a fixed crop CRC from a cold start.
- **Stage isolation.** Any stage can be halted and its DDR buffer dumped for a value diff —
  pass 1 measured **99.19 % exact** against the model on silicon.

---

# The interpolation variant — 32-tap sinc

The 2-tap kernel is cheap but lossy where this data lives (≈ 97.8 % of Nyquist):

| kernel | scalloping @ 0.978 Nyq | complex error |
|---|---|---|
| **2-tap linear** (baseline) | **29.2 dB** | −4.0 dB |
| **32-tap sinc** (variant) | **3.5 dB** | −13.6 dB |

**Scalloping** is peak-to-peak gain variation with sub-sample position: at $\mu=0.5$ the 2-tap
gain collapses to $|\cos(\pi f/2)|\!\to\!0.034$, so a scatterer's brightness depends on where it
lands *between* samples by up to 29 dB.

Cost: 32 banks (mod-32 banking makes each bank hit exactly once → single-port), 64 MACs/stage,
a 5-level pipelined adder tree. **Resources fit; timing is the risk** at 2.6 % slack.

---

# Realised bandwidth — the bus is *not* the limit any more

FIC_0 is 64-bit @ 100 MHz ≈ **800 MB/s**. Bytes actually moved per frame, against measured stage time:

| arrow | MB | s | MB/s | % of FIC_0 |
|---|---|---|---|---|
| range gather `SIG → SCRATCH` | 281.9 | 1.675 | 168.4 | 21 % |
| corner-turn #1 `SCRATCH → SIG` | 536.9 | 2.064 | **260.1** | **33 %** |
| FFT-1 (+ gather, window) | 536.9 | 4.646 | 115.6 | 14 % |
| CT#2 + FFT-2 (+ detect) | 939.5 | 5.781 | 162.5 | 20 % |
| **whole frame** | **2,295** | **14.17** | **162.0** | **20 %** |

Nothing exceeds a third of the bus. Deleting DDR passes worked so well that **the bottleneck moved**:
FFT-1's 4.65 s sits within 0.3 % of the CoreFFT `SLOWCLK` transform floor, so the design is now
transform-clock bound, not bandwidth bound. The busiest arrow is the corner-turn — the one operator
that is neither fusable nor local.

---

# Summary

| | |
|---|---|
| **Problem** | CPHD → detected 8192×8192 image, ≤ 15 s, minimum silicon |
| **Approach** | PFA; delete DDR passes rather than accelerate arithmetic |
| **Key moves** | fuse window/gather/detect into the FFT feeders and unloader; overlap CT#2 with FFT-2; generate coefficients on fabric from 3 scalars per line |
| **Achieved** | **14.17 s**, 202/784 MACC, 537/812 LSRAM, timing MET (+0.151 ns) |
| **Interpolation** | 32-tap polyphase sinc in **both** resample passes — scalloping 29.2 dB → 3.5 dB |
| **Verified** | each arm matches a Python reference running the *same* interpolator; bench gated against silicon parameters |

The budget was met by **moving less data**, not by computing faster — the frame now runs at 20 % of
the available bus bandwidth and is limited by the 12.5 MHz transform clock.
