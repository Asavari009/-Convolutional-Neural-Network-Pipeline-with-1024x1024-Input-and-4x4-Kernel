# Pipelined CNN Hardware Accelerator with DRAM Interface

A synthesizable SystemVerilog RTL implementation of a simplified CNN pipeline operating on a 1024×1024 input with a fixed 4×4 kernel, interfacing with DRAM for input/output and optionally using an on-chip SRAM scratchpad.

---

## Pipeline Overview

The design executes three sequential stages:

**1. Convolution** — Slides a fixed 4×4 kernel across the 1024×1024 input:

```
Y(i,j) = Σ Σ X(i+m, j+n) · K(m,n)   for m,n ∈ [0,3]
```

Fixed kernel used:
```
K = [ 1  0 -1  0 ]
    [ 1  0 -1  0 ]
    [ 1  0 -1  0 ]
    [ 1  0 -1  0 ]
```
Output: 1021×1021 matrix (20-bit intermediate, clamped to 8-bit signed)

**2. Leaky ReLU Activation**

```
LeakyReLU(x) = x        if x > 0
               0         if -4 < x ≤ 0
               floor(x/4) if x ≤ -4   (arithmetic right-shift)
```

**3. 2×2 Average Pooling** (ECE 564 only)

Operates on non-overlapping 2×2 blocks with stride 2. The 1021×1021 ReLU output is zero-padded to 1022×1022 before pooling:

```
Average(x) = floor(x/4)   if x ≥ 4
             0             if -4 < x < 4
             ceil(x/4)     if x ≤ -4
```
Output: 511×511 matrix, zero-padded to 512×512 for DRAM alignment

---

## Matrix Dimensions Summary

| Stage | ECE 464 | ECE 564 |
|---|---|---|
| Input | 1024×1024 | 1024×1024 |
| After Convolution | 1021×1021 | 1021×1021 |
| After Leaky ReLU | 1021×1021 | 1021×1021 (padded to 1022×1022) |
| Final Output | 1021×1021 (padded to 1024) | 511×511 (padded to 512×512) |

---

## Interface Signals

### Testbench ↔ DUT

| Signal | Direction | Description |
|---|---|---|
| `clk` | Input | Clock for all sequential logic |
| `reset_n` | Input | Active-low reset |
| `start` | Input | Asserted by testbench to begin processing |
| `ready` | Output | High when idle; de-asserts on `start`, re-asserts after final DRAM write |


## DRAM Memory Layout

Data is stored as 64-bit (8-byte) little-endian words. The 4×4 kernel occupies the first two addresses; input matrix follows in row-major order.

| DRAM Address | Contents |
|---|---|
| `0x00000000` | K[0,0] – K[1,3] |
| `0x00000008` | K[2,0] – K[3,3] |
| `0x00000010` onwards | Input matrix rows, 8 bytes per burst |
| `0x00100008` | Last input row: I[1023, 1016–1023] |

Output is written in row-major order. Each row is zero-padded to the nearest multiple of 8 bytes for address alignment.




## Report Checklist

- High-level logic diagram (down to register, mux, and operator level)
- FSM and datapath description
- Performance metrics: clock period, cycle count, cell area, setup/hold slack
- AI prompts and outputs documented in appendix (if applicable)
