/**
 * @file  thresh_cmp_drv.h
 * @brief Firmware driver for the AXI-Lite Threshold Comparator with IRQ
 *
 * Usage:
 *   ThreshCmpDev dev;
 *   thresh_cmp_init(&dev, 0x43C10000, 3000, 500, THRESH_DIR_BOTH);
 *   thresh_cmp_push_sample(&dev, adc_val);
 *   if (thresh_cmp_irq_pending(&dev)) {
 *       thresh_status_t s = thresh_cmp_read_status(&dev);
 *       thresh_cmp_clear_irq(&dev);
 *   }
 */

#ifndef THRESH_CMP_DRV_H
#define THRESH_CMP_DRV_H

#include <stdint.h>
#include <stdbool.h>

// -----------------------------------------------------------------------------
// Register Offsets
// -----------------------------------------------------------------------------
#define THRESH_REG_CTRL     0x00U
#define THRESH_REG_THRESH_H 0x04U
#define THRESH_REG_THRESH_L 0x08U
#define THRESH_REG_DATA_IN  0x0CU
#define THRESH_REG_STATUS   0x10U

// -----------------------------------------------------------------------------
// CTRL bits
// -----------------------------------------------------------------------------
#define THRESH_CTRL_ENABLE      (1U << 0)
#define THRESH_CTRL_IRQ_CLEAR   (1U << 1)
#define THRESH_CTRL_DIR_SHIFT   2
#define THRESH_CTRL_DIR_MASK    (3U << 2)

// -----------------------------------------------------------------------------
// STATUS bits
// -----------------------------------------------------------------------------
#define THRESH_STATUS_IRQ_LATCHED  (1U << 0)
#define THRESH_STATUS_ABOVE_HIGH   (1U << 1)
#define THRESH_STATUS_BELOW_LOW    (1U << 2)
#define THRESH_STATUS_SAMPLE_SHIFT 16
#define THRESH_STATUS_SAMPLE_MASK  (0xFFFU << 16)

// -----------------------------------------------------------------------------
// Direction enum
// -----------------------------------------------------------------------------
typedef enum {
    THRESH_DIR_ABOVE = 0,
    THRESH_DIR_BELOW = 1,
    THRESH_DIR_BOTH  = 2,
    THRESH_DIR_OFF   = 3
} ThreshDirection;

// -----------------------------------------------------------------------------
// Status snapshot
// -----------------------------------------------------------------------------
typedef struct {
    bool     irq_latched;
    bool     above_high;
    bool     below_low;
    uint16_t last_sample;
} thresh_status_t;

// -----------------------------------------------------------------------------
// Device handle
// -----------------------------------------------------------------------------
typedef struct {
    uintptr_t       base_addr;
    uint16_t        thresh_h;
    uint16_t        thresh_l;
    ThreshDirection direction;
} ThreshCmpDev;

// -----------------------------------------------------------------------------
// Low-level access
// -----------------------------------------------------------------------------
static inline void tcmp_write(uintptr_t base, uint32_t off, uint32_t val) {
    *((volatile uint32_t *)(base + off)) = val;
}
static inline uint32_t tcmp_read(uintptr_t base, uint32_t off) {
    return *((volatile uint32_t *)(base + off));
}

// -----------------------------------------------------------------------------
// API
// -----------------------------------------------------------------------------

/**
 * @brief Initialise and enable the comparator.
 * @return 0 on success, -1 if thresh_l > thresh_h or values out of range
 */
static inline int thresh_cmp_init(ThreshCmpDev   *dev,
                                   uintptr_t       base_addr,
                                   uint16_t        thresh_h,
                                   uint16_t        thresh_l,
                                   ThreshDirection dir)
{
    if (thresh_l > thresh_h || thresh_h > 0xFFF)
        return -1;

    dev->base_addr = base_addr;
    dev->thresh_h  = thresh_h;
    dev->thresh_l  = thresh_l;
    dev->direction = dir;

    // Disable and clear first
    tcmp_write(base_addr, THRESH_REG_CTRL, THRESH_CTRL_IRQ_CLEAR);
    // Write thresholds
    tcmp_write(base_addr, THRESH_REG_THRESH_H, (uint32_t)thresh_h);
    tcmp_write(base_addr, THRESH_REG_THRESH_L, (uint32_t)thresh_l);
    // Enable
    tcmp_write(base_addr, THRESH_REG_CTRL,
               THRESH_CTRL_ENABLE | ((uint32_t)dir << THRESH_CTRL_DIR_SHIFT));
    return 0;
}

/** @brief Push a 12-bit ADC sample. Hardware compares immediately. */
static inline void thresh_cmp_push_sample(ThreshCmpDev *dev, uint16_t sample)
{
    tcmp_write(dev->base_addr, THRESH_REG_DATA_IN,
               (uint32_t)(sample & 0xFFFU));
}

/** @brief Return true if IRQ is currently latched. */
static inline bool thresh_cmp_irq_pending(const ThreshCmpDev *dev)
{
    return (tcmp_read(dev->base_addr, THRESH_REG_STATUS) &
            THRESH_STATUS_IRQ_LATCHED) != 0;
}

/** @brief Read full status snapshot. */
static inline thresh_status_t thresh_cmp_read_status(const ThreshCmpDev *dev)
{
    uint32_t raw = tcmp_read(dev->base_addr, THRESH_REG_STATUS);
    thresh_status_t s;
    s.irq_latched = (raw & THRESH_STATUS_IRQ_LATCHED) != 0;
    s.above_high  = (raw & THRESH_STATUS_ABOVE_HIGH)  != 0;
    s.below_low   = (raw & THRESH_STATUS_BELOW_LOW)   != 0;
    s.last_sample = (uint16_t)((raw & THRESH_STATUS_SAMPLE_MASK)
                                >> THRESH_STATUS_SAMPLE_SHIFT);
    return s;
}

/**
 * @brief Clear the latched IRQ. Call this at the end of your IRQ handler.
 *        Keeps the accelerator enabled with unchanged direction.
 */
static inline void thresh_cmp_clear_irq(ThreshCmpDev *dev)
{
    // Assert clear with enable still set
    tcmp_write(dev->base_addr, THRESH_REG_CTRL,
               THRESH_CTRL_ENABLE    |
               THRESH_CTRL_IRQ_CLEAR |
               ((uint32_t)dev->direction << THRESH_CTRL_DIR_SHIFT));
    // Release clear bit so future IRQs can latch again
    tcmp_write(dev->base_addr, THRESH_REG_CTRL,
               THRESH_CTRL_ENABLE |
               ((uint32_t)dev->direction << THRESH_CTRL_DIR_SHIFT));
}

/**
 * @brief Update thresholds at runtime without disabling the accelerator.
 * @return 0 on success, -1 if invalid
 */
static inline int thresh_cmp_set_thresholds(ThreshCmpDev *dev,
                                             uint16_t thresh_h,
                                             uint16_t thresh_l)
{
    if (thresh_l > thresh_h || thresh_h > 0xFFF)
        return -1;
    dev->thresh_h = thresh_h;
    dev->thresh_l = thresh_l;
    tcmp_write(dev->base_addr, THRESH_REG_THRESH_H, (uint32_t)thresh_h);
    tcmp_write(dev->base_addr, THRESH_REG_THRESH_L, (uint32_t)thresh_l);
    return 0;
}

/** @brief Disable the accelerator. DATA_IN writes are ignored. */
static inline void thresh_cmp_disable(ThreshCmpDev *dev)
{
    tcmp_write(dev->base_addr, THRESH_REG_CTRL, 0U);
}

// -----------------------------------------------------------------------------
// Example: ISR integration alongside moving average
// -----------------------------------------------------------------------------
/*
    #include "thresh_cmp_drv.h"
    #include "moving_avg_drv.h"

    #define THRESH_BASE 0x43C1_0000
    ThreshCmpDev tcmp;

    void system_init(void) {
        thresh_cmp_init(&tcmp, THRESH_BASE, 3000, 500, THRESH_DIR_BOTH);
    }

    void sample_isr(void) {              // 1 kHz
        uint16_t raw = spi_adc_read();
        fifo_push(raw);                  // raw → UART
        moving_avg_push_sample(&mavg, raw);
        thresh_cmp_push_sample(&tcmp, raw);
    }

    void thresh_irq_handler(void) {      // triggered by irq pin
        thresh_status_t s = thresh_cmp_read_status(&tcmp);
        if (s.above_high)
            log_event("OVER",  s.last_sample);
        else if (s.below_low)
            log_event("UNDER", s.last_sample);
        thresh_cmp_clear_irq(&tcmp);
    }
*/

#endif // THRESH_CMP_DRV_H