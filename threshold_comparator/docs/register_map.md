# AXI-Lite Threshold Comparator with IRQ — Register Map

**Block:** `axi_thresh_cmp`  
**Interface:** AXI4-Lite Subordinate  
**Data width:** 32-bit  
**Address width:** 5-bit (covers 5 registers)  
**Clock:** 100 MHz  
**Reset:** Active-low synchronous (`aresetn`)  
**RTL:** `axi_thresh_cmp.v` (Verilog-2005)  
**Driver:** `thresh_cmp_drv.h` (header-only C)

---

## Register Summary

| Offset | Name     | Access | Reset       | Description                          |
|--------|----------|--------|-------------|--------------------------------------|
| 0x00   | CTRL     | R/W    | 0x0000_0000 | Enable, IRQ clear, direction         |
| 0x04   | THRESH_H | R/W    | 0x0000_0E00 | High threshold (3584 default)        |
| 0x08   | THRESH_L | R/W    | 0x0000_0200 | Low threshold  (512 default)         |
| 0x0C   | DATA_IN  | W      | —           | Write sample, triggers comparison    |
| 0x10   | STATUS   | R      | 0x0000_0000 | IRQ state, zone flags, last sample   |

---

## Register Details

---

### 0x00 — CTRL (Control Register)

| Bits | Field     | Access | Description                                               |
|------|-----------|--------|-----------------------------------------------------------|
| 31:4 | —         | —      | Reserved, write 0                                         |
| 3:2  | DIRECTION | R/W    | Which crossing fires the IRQ — see table below            |
| 1    | IRQ_CLEAR | R/W    | Write **1** to clear latched IRQ, then write **0** to re-arm. Must return to 0 before next IRQ can latch. |
| 0    | ENABLE    | R/W    | **1** = active. **0** = DATA_IN writes ignored.           |

**Direction encoding:**

| CTRL[3:2] | Mode      | IRQ fires when…                          |
|-----------|-----------|------------------------------------------|
| 2'b00     | ABOVE     | Sample transitions into ABOVE zone       |
| 2'b01     | BELOW     | Sample transitions into BELOW zone       |
| 2'b10     | BOTH      | Sample transitions into either zone      |
| 2'b11     | OFF       | Comparison active, no IRQ generated      |

**Firmware IRQ clear sequence:**
```c
// Assert clear (keep enabled)
tcmp_write(base, THRESH_REG_CTRL,
           THRESH_CTRL_ENABLE | THRESH_CTRL_IRQ_CLEAR | (dir << 2));
// Release clear so future IRQs can latch
tcmp_write(base, THRESH_REG_CTRL,
           THRESH_CTRL_ENABLE | (dir << 2));
```

---

### 0x04 — THRESH_H (High Threshold)

| Bits  | Field   | Access | Description                       |
|-------|---------|--------|-----------------------------------|
| 31:12 | —       | —      | Reserved, write 0                 |
| 11:0  | THRESH_H| R/W    | Upper boundary of the normal zone |

Samples **strictly greater than** THRESH_H enter the ABOVE zone.  
Default: `0xE00` = 3584.

---

### 0x08 — THRESH_L (Low Threshold)

| Bits  | Field   | Access | Description                       |
|-------|---------|--------|-----------------------------------|
| 31:12 | —       | —      | Reserved, write 0                 |
| 11:0  | THRESH_L| R/W    | Lower boundary of the normal zone |

Samples **strictly less than** THRESH_L enter the BELOW zone.  
Must satisfy `THRESH_L <= THRESH_H` — driver enforces this.  
Default: `0x200` = 512.

---

### 0x0C — DATA_IN (Sample Input — Write Only)

| Bits  | Field  | Access | Description             |
|-------|--------|--------|-------------------------|
| 31:12 | —      | —      | Ignored                 |
| 11:0  | SAMPLE | W      | 12-bit ADC sample value |

Writing when `CTRL[0]=1` immediately evaluates the sample against the
threshold band and updates zone state. If the zone transitions into a
triggering zone, `irq_latched` is set and the `irq` output goes high.

Reading returns `0x00000000`.

---

### 0x10 — STATUS (Status Register — Read Only)

| Bits  | Field       | Access | Description                                          |
|-------|-------------|--------|------------------------------------------------------|
| 31:28 | —           | R      | Reserved                                             |
| 27:16 | LAST_SAMPLE | R      | The most recent sample written to DATA_IN            |
| 15:3  | —           | R      | Reserved                                             |
| 2     | BELOW_LOW   | R      | 1 = current zone is BELOW (sample < THRESH_L)        |
| 1     | ABOVE_HIGH  | R      | 1 = current zone is ABOVE (sample > THRESH_H)        |
| 0     | IRQ_LATCHED | R      | 1 = IRQ is pending, clear via CTRL[1]                |

**Reading LAST_SAMPLE from firmware:**
```c
thresh_status_t s = thresh_cmp_read_status(&dev);
uint16_t sample_that_triggered = s.last_sample;
```

---

## Zone State Machine

```
              sample > THRESH_H
    ┌─────────────────────────────────────────┐
    │                                         ▼
 ┌──┴──────┐   sample > THRESH_H        ┌─────────┐
 │  BELOW  │──────────────────────────▶ │  ABOVE  │
 │(irq if  │                            │(irq if  │
 │DIR_BELOW│◀──────────────────────────│DIR_ABOVE│
 │or BOTH) │   sample < THRESH_L        │or BOTH) │
 └──┬──────┘                            └────┬────┘
    │                                        │
    │  sample >= THRESH_L      sample <= THRESH_H
    │                                        │
    │            ┌──────────┐               │
    └──────────▶ │  NORMAL  │ ◀─────────────┘
                 │ (no IRQ) │
                 └──────────┘
```

**Key properties:**
- IRQ fires only on **entry** into a triggering zone, not while staying there
- Direct ABOVE ↔ BELOW transitions are allowed (skips NORMAL)
- Zone state persists between samples — hysteresis is inherent to the state machine

---

## Timing Diagram — IRQ Latch and Clear

```
aclk          __|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_|‾|_
DATA_IN write  __|‾‾‾|_______________|‾‾‾|___   (sample=3500, then irq_clear)
zone           --[NORMAL]--[ABOVE]----------    (transition fires IRQ)
irq_latched    ____________|‾‾‾‾‾‾‾‾‾‾‾‾|___   (held until firmware clears)
irq pin        ____________|‾‾‾‾‾‾‾‾‾‾‾‾|___
```

Latency from DATA_IN write completing → `irq` asserted: **1 clock cycle**

---

## Hysteresis Example

Configuration: `THRESH_H = 3000`, `THRESH_L = 500`, `DIR_BOTH`

| Sample | Zone transition    | IRQ fires? | Reason                              |
|--------|--------------------|------------|-------------------------------------|
| 1000   | NORMAL → NORMAL    | No         | Within band                         |
| 3500   | NORMAL → ABOVE     | **Yes**    | Entry into ABOVE zone               |
| 3600   | ABOVE  → ABOVE     | No         | Already in ABOVE, hysteresis holds  |
| 2800   | ABOVE  → NORMAL    | No         | Re-entering band, not a crossing    |
| 2800   | NORMAL → NORMAL    | No         | Within band                         |
| 100    | NORMAL → BELOW     | **Yes**    | Entry into BELOW zone               |
| 200    | BELOW  → BELOW     | No         | Already in BELOW, hysteresis holds  |

---

## Integration Checklist

- [ ] Add `axi_thresh_cmp.v` to Vivado project sources
- [ ] Wire `irq` output to interrupt controller input
- [ ] Call `thresh_cmp_init()` before entering sample loop
- [ ] Feed same ADC sample to `DATA_IN` alongside FIFO and moving average
- [ ] Implement IRQ handler: read STATUS → handle event → call `thresh_cmp_clear_irq()`
- [ ] Verify `THRESH_L <= THRESH_H` before writing (driver enforces this)

---

## Register Quick Reference

```
Offset  Name      Bits    Field        R/W  Description
------  --------  ------  -----------  ---  --------------------------------
0x00    CTRL      [0]     ENABLE       R/W  1 = active
                  [1]     IRQ_CLEAR    R/W  pulse 1 then 0 to clear IRQ
                  [3:2]   DIRECTION    R/W  00=above 01=below 10=both 11=off
0x04    THRESH_H  [11:0]  THRESH_H     R/W  high threshold boundary
0x08    THRESH_L  [11:0]  THRESH_L     R/W  low threshold boundary
0x0C    DATA_IN   [11:0]  SAMPLE       W    write triggers comparison
0x10    STATUS    [0]     IRQ_LATCHED  R    1 = IRQ pending
                  [1]     ABOVE_HIGH   R    1 = currently above THRESH_H
                  [2]     BELOW_LOW    R    1 = currently below THRESH_L
                  [27:16] LAST_SAMPLE  R    last sample written
```