# AXI-Lite Moving Average Accelerator — Register Map

**Block:** `axi_moving_avg`  
**Interface:** AXI4-Lite Subordinate  
**Data width:** 32-bit  
**Address width:** 5-bit (covers 5 registers)  
**Clock:** 100 MHz (same as system AXI clock)  
**Reset:** Active-low synchronous (`aresetn`)  
**RTL:** `axi_moving_avg.v` (Verilog-2005)  
**Driver:** `moving_avg_drv.h` (header-only C)

---

## Implementation Results (xc7a200t-fbg676-2)

| Resource     | Used | Available | Util % |
|--------------|------|-----------|--------|
| Slice LUTs   | 162  | 134,600   | 0.12%  |
| Slice FFs    | 339  | 269,200   | 0.13%  |
| BRAM         | 0    | 365       | 0.00%  |
| DSPs         | 0    | 740       | 0.00%  |

**Estimated timing (unconstrained, from routed paths):**  
Longest data path: 4.38 ns — comfortably meets 100 MHz (10 ns period).  
Add a clock constraint (`.xdc`) to get exact WNS/TNS numbers.

---

## Register Summary

| Offset | Name     | Access | Reset       | Description                         |
|--------|----------|--------|-------------|-------------------------------------|
| 0x00   | CTRL     | R/W    | 0x0000_0000 | Control: enable, clear              |
| 0x04   | CONFIG   | R/W    | 0x0000_0007 | Window size configuration           |
| 0x08   | DATA_IN  | W      | —           | Write a new ADC sample (triggers HW)|
| 0x0C   | RESULT   | R      | 0x0000_0000 | Filtered output (12-bit)            |
| 0x10   | STATUS   | R      | 0x0000_0000 | Engine status and fill count        |

---

## Register Details

---

### 0x00 — CTRL (Control Register)

| Bits | Field  | Access | Description                                                                 |
|------|--------|--------|-----------------------------------------------------------------------------|
| 31:2 | —      | —      | Reserved, write 0                                                           |
| 1    | CLEAR  | R/W    | **1** = flush sample buffer and accumulator to zero. Hold high for at least 1 cycle, then release. Does not disable the accelerator. |
| 0    | ENABLE | R/W    | **1** = accelerator active, DATA_IN writes are processed. **0** = DATA_IN writes are ignored. |

**Firmware sequence to reset without disabling:**
```c
mavg_write(base, MAVG_REG_CTRL, MAVG_CTRL_ENABLE | MAVG_CTRL_CLEAR);
mavg_write(base, MAVG_REG_CTRL, MAVG_CTRL_ENABLE);
```

---

### 0x04 — CONFIG (Configuration Register)

| Bits | Field              | Access | Description                                  |
|------|--------------------|--------|----------------------------------------------|
| 31:4 | —                  | —      | Reserved, write 0                            |
| 3:0  | WINDOW_SIZE_MINUS1 | R/W    | Selects averaging window (power-of-2 decode) |

**Window size decode table:**

| WINDOW_SIZE_MINUS1 | Effective Window N | Divides by |
|--------------------|--------------------|------------|
| 0x0                | 1                  | 1          |
| 0x1                | 2                  | 2          |
| 0x2 – 0x3          | 4                  | 4          |
| 0x4 – 0x7          | 8                  | 8          |
| 0x8 – 0xF          | 16                 | 16         |

> **Note:** The hardware rounds down to the nearest power of 2, enabling division
> via a single arithmetic right-shift. Non-power-of-2 windows require an integer
> divider and are left as a future extension.

**Default reset value:** `0x7` → Window N = 8.

---

### 0x08 — DATA_IN (Sample Input — Write Only)

| Bits  | Field  | Access | Description             |
|-------|--------|--------|-------------------------|
| 31:12 | —      | —      | Ignored on write        |
| 11:0  | SAMPLE | W      | 12-bit ADC sample value |

Writing to this register when `CTRL[0]=1` (enabled):

1. Pushes `SAMPLE` into the circular buffer
2. Computes `accum_next` combinationally:
   - If buffer full: `accum_next = accumulator - oldest + SAMPLE`
   - If warming up:  `accum_next = accumulator + SAMPLE`
3. Computes `RESULT = accum_next >> shift_amount` where `shift_amount`
   is derived from `fill_next` (see warmup behaviour below)
4. Latches RESULT and pulses `irq_result_valid` for 1 clock cycle

Writing when `CTRL[0]=0` has no effect.  
Reading this register always returns `0x00000000`.

---

### 0x0C — RESULT (Filtered Output — Read Only)

| Bits  | Field  | Access | Description                              |
|-------|--------|--------|------------------------------------------|
| 31:12 | —      | R      | Always 0                                 |
| 11:0  | RESULT | R      | Moving average output, updated each push |

- Holds the most recent computed average. Stable between DATA_IN writes.
- Valid 1 clock cycle after the AXI write to DATA_IN completes.
- During warmup, reflects the average of however many samples are buffered
  so far (see warmup behaviour below).

---

### 0x10 — STATUS (Status Register — Read Only)

| Bits | Field        | Access | Description                                                     |
|------|--------------|--------|-----------------------------------------------------------------|
| 31:6 | —            | R      | Reserved, reads 0                                               |
| 5:2  | FILL_COUNT   | R      | Samples currently in buffer (0 to N)                           |
| 1    | BUSY         | R      | Always 0 (single-cycle engine, reserved for future pipelining) |
| 0    | RESULT_VALID | R      | 1-cycle pulse on each new result. Likely missed by polling — use IRQ instead. |

**Checking if window is fully primed:**
```c
bool primed = moving_avg_fill_count(&dev) >= (uint8_t)dev->window;
```

---

## Warmup Behaviour

> **This section reflects a deliberate design choice made during simulation.**

During the warmup period (before `fill_count` reaches the configured window size N),
the hardware divides by the **current fill count** rather than N. This produces a
true average of however many samples have arrived so far.

**Example — window = 4, samples = [100, 200, 300, 400, 500...]:**

| Push # | Sample | Fill count | Divisor | RESULT |
|--------|--------|------------|---------|--------|
| 1      | 100    | 1          | 1       | 100    |
| 2      | 200    | 2          | 2       | 150    |
| 3      | 300    | 3          | 4 *     | 150    |
| 4      | 400    | 4 (full)   | 4       | 250    |
| 5      | 500    | 4 (full)   | 4       | 350    |

\* Fill count 3 rounds down to nearest power-of-2 → divides by 4.  
This is a consequence of the shift-only divider. An exact integer divider
would give 200 at push #3 instead of 150.

**Implementation detail:** The hardware computes `fill_next = fill_count + 1`
combinationally before committing the new sample, then selects `shift_amount`
based on `fill_next`. This ensures the result is always consistent with the
number of samples actually contributing to the average.

---

## Interrupt

| Signal             | Type                       | Description                              |
|--------------------|----------------------------|------------------------------------------|
| `irq_result_valid` | Active-high, 1-cycle pulse | Fires every time a new result is latched |

Connect to an interrupt controller for event-driven firmware instead of polling STATUS[0].
On Zynq: connect to `IRQ_F2P`. On Artix-7 + MicroBlaze: connect to `mb_intc` interrupt input.

---

## Timing Diagram — Single Sample Push

```
aclk             __|‾|_|‾|_|‾|_|‾|_
                          
DATA_IN write    __|‾‾‾‾‾|__________   (AXI write, ~2 cycles for handshake)
sample_we        _________|‾|_______   (internal 1-cycle trigger)
accum_next       ---------[comb]----   (combinational, resolves same cycle as sample_we)
RESULT reg       ___________|‾‾‾‾‾‾   (latched on clock edge after sample_we)
irq_result_valid ___________|‾|_____   (1-cycle pulse, same edge as RESULT latch)
```

Latency from DATA_IN write completing → RESULT valid: **1 clock cycle (10 ns @ 100 MHz)**

---

## Integration Checklist

- [ ] Add `axi_moving_avg.v` and `axil_master_stub.v` to Vivado project sources
- [ ] Set `top.v` as the top module
- [ ] Add `.xdc` clock constraint: `create_clock -period 10.000 [get_ports clk]`
- [ ] Assign physical pins for `filtered_result[11:0]` and `filter_valid` if observing output
- [ ] Call `moving_avg_init()` in firmware before entering sample loop
- [ ] Feed the same ADC sample to both FIFO (`wr_data`) and accelerator (`DATA_IN`)

---

## Register Quick Reference

```
Offset  Name      Bits   Field              R/W  Description
------  --------  -----  -----------------  ---  ----------------------------------
0x00    CTRL      [0]    ENABLE             R/W  1 = active
                  [1]    CLEAR              R/W  1 = flush buffer (release after 1 cycle)
0x04    CONFIG    [3:0]  WINDOW_SIZE_MINUS1 R/W  see decode table above
0x08    DATA_IN   [11:0] SAMPLE             W    write triggers computation
0x0C    RESULT    [11:0] FILTERED_OUT       R    latest moving average output
0x10    STATUS    [0]    RESULT_VALID       R    1-cycle pulse per result
                  [1]    BUSY               R    always 0
                  [5:2]  FILL_COUNT         R    samples buffered (0 to N)
```