/**
 * @file  moving_avg_drv.h
 * @brief Firmware driver for the AXI-Lite Moving Average Accelerator
 *
 * Usage:
 *   MovingAvgDev dev;
 *   moving_avg_init(&dev, 0x43C00000, 8);   // base addr, window size
 *   moving_avg_push_sample(&dev, adc_val);
 *   uint16_t result = moving_avg_read_result(&dev);
 */

#ifndef MOVING_AVG_DRV_H
#define MOVING_AVG_DRV_H

#include <stdint.h>
#include <stdbool.h>

// -----------------------------------------------------------------------------
// Register Offsets (byte addresses from base)
// -----------------------------------------------------------------------------
#define MAVG_REG_CTRL       0x00U
#define MAVG_REG_CONFIG     0x04U
#define MAVG_REG_DATA_IN    0x08U
#define MAVG_REG_RESULT     0x0CU
#define MAVG_REG_STATUS     0x10U

// -----------------------------------------------------------------------------
// CTRL Register Bits
// -----------------------------------------------------------------------------
#define MAVG_CTRL_ENABLE    (1U << 0)   // 1 = accelerator active
#define MAVG_CTRL_CLEAR     (1U << 1)   // 1 = flush buffer & accumulator

// -----------------------------------------------------------------------------
// STATUS Register Bits
// -----------------------------------------------------------------------------
#define MAVG_STATUS_VALID   (1U << 0)   // result_valid pulse
#define MAVG_STATUS_BUSY    (1U << 1)   // engine busy (reserved, always 0)
#define MAVG_STATUS_FILL_SHIFT  2       // [5:2] = current buffer fill count
#define MAVG_STATUS_FILL_MASK   0x3CU

// -----------------------------------------------------------------------------
// Supported window sizes (must be power-of-2, max 16)
// -----------------------------------------------------------------------------
typedef enum {
    MAVG_WIN_1  = 1,
    MAVG_WIN_2  = 2,
    MAVG_WIN_4  = 4,
    MAVG_WIN_8  = 8,
    MAVG_WIN_16 = 16
} MovingAvgWindow;

// -----------------------------------------------------------------------------
// Device handle
// -----------------------------------------------------------------------------
typedef struct {
    uintptr_t base_addr;        // AXI-Lite base address (from address editor)
    MovingAvgWindow window;     // configured window size
} MovingAvgDev;

// -----------------------------------------------------------------------------
// Low-level register access (platform-specific — adapt for your BSP)
// -----------------------------------------------------------------------------
static inline void mavg_write(uintptr_t base, uint32_t offset, uint32_t val) {
    *((volatile uint32_t *)(base + offset)) = val;
}

static inline uint32_t mavg_read(uintptr_t base, uint32_t offset) {
    return *((volatile uint32_t *)(base + offset));
}

// -----------------------------------------------------------------------------
// API
// -----------------------------------------------------------------------------

/**
 * @brief Initialize and enable the accelerator.
 *
 * @param dev       Pointer to device handle to populate
 * @param base_addr AXI-Lite base address (set in Vivado Address Editor)
 * @param window    Averaging window size (must be 1, 2, 4, 8, or 16)
 * @return          0 on success, -1 if window is invalid
 */
static inline int moving_avg_init(MovingAvgDev *dev,
                                   uintptr_t     base_addr,
                                   MovingAvgWindow window)
{
    // Validate window is power-of-2 and ≤ 16
    if (window == 0 || window > 16 || (window & (window - 1)) != 0)
        return -1;

    dev->base_addr = base_addr;
    dev->window    = window;

    // Step 1: Disable and clear first
    mavg_write(base_addr, MAVG_REG_CTRL, MAVG_CTRL_CLEAR);

    // Step 2: Write CONFIG — store (window - 1) in [3:0]
    mavg_write(base_addr, MAVG_REG_CONFIG, (uint32_t)(window - 1));

    // Step 3: Clear the clear bit, then enable
    mavg_write(base_addr, MAVG_REG_CTRL, MAVG_CTRL_ENABLE);

    return 0;
}

/**
 * @brief Push a new ADC sample into the accelerator.
 *        The hardware computes a new filtered result immediately.
 *
 * @param dev    Device handle
 * @param sample 12-bit ADC sample (values 0–4095)
 */
static inline void moving_avg_push_sample(MovingAvgDev *dev, uint16_t sample)
{
    mavg_write(dev->base_addr, MAVG_REG_DATA_IN, (uint32_t)(sample & 0xFFFU));
}

/**
 * @brief Read the most recent filtered result.
 *
 * @param dev Device handle
 * @return    12-bit filtered output
 */
static inline uint16_t moving_avg_read_result(const MovingAvgDev *dev)
{
    return (uint16_t)(mavg_read(dev->base_addr, MAVG_REG_RESULT) & 0xFFFU);
}

/**
 * @brief Read the raw STATUS register.
 *
 * @param dev Device handle
 * @return    STATUS register value (use MAVG_STATUS_* masks to decode)
 */
static inline uint32_t moving_avg_read_status(const MovingAvgDev *dev)
{
    return mavg_read(dev->base_addr, MAVG_REG_STATUS);
}

/**
 * @brief Return number of samples currently buffered (fill count).
 *        Useful to know when the window is fully primed.
 *
 * @param dev Device handle
 * @return    Fill count (0 to window size)
 */
static inline uint8_t moving_avg_fill_count(const MovingAvgDev *dev)
{
    uint32_t status = moving_avg_read_status(dev);
    return (uint8_t)((status & MAVG_STATUS_FILL_MASK) >> MAVG_STATUS_FILL_SHIFT);
}

/**
 * @brief Check if the buffer is fully primed (fill_count == window).
 *        Results before this point are valid but based on fewer samples.
 *
 * @param dev Device handle
 * @return    true if window is full
 */
static inline bool moving_avg_is_primed(const MovingAvgDev *dev)
{
    return moving_avg_fill_count(dev) >= (uint8_t)dev->window;
}

/**
 * @brief Flush the sample buffer and accumulator without disabling.
 *        Use this to restart averaging (e.g. after a sensor event).
 *
 * @param dev Device handle
 */
static inline void moving_avg_clear(MovingAvgDev *dev)
{
    mavg_write(dev->base_addr, MAVG_REG_CTRL, MAVG_CTRL_ENABLE | MAVG_CTRL_CLEAR);
    mavg_write(dev->base_addr, MAVG_REG_CTRL, MAVG_CTRL_ENABLE);
}

/**
 * @brief Disable the accelerator (ignores further DATA_IN writes).
 *
 * @param dev Device handle
 */
static inline void moving_avg_disable(MovingAvgDev *dev)
{
    mavg_write(dev->base_addr, MAVG_REG_CTRL, 0U);
}

// -----------------------------------------------------------------------------
// Example usage (integration with a UART pipeline)
// -----------------------------------------------------------------------------
/*
    #include "moving_avg_drv.h"

    #define MAVG_BASE_ADDR  0x43C00000  // from Vivado Address Editor

    MovingAvgDev mavg;

    void system_init(void) {
        moving_avg_init(&mavg, MAVG_BASE_ADDR, MAVG_WIN_8);
    }

    // Call from your 1 kHz sample ISR (same tick as your SPI ADC read)
    void sample_isr(void) {
        uint16_t raw = spi_adc_read();         // your existing ADC read
        fifo_push(raw);                         // your existing FIFO push
        moving_avg_push_sample(&mavg, raw);     // also feed the accelerator

        uint16_t filtered = moving_avg_read_result(&mavg);
        uart_send_filtered(filtered);           // or log alongside raw
    }
*/

#endif // MOVING_AVG_DRV_H