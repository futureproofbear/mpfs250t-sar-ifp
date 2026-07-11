/*******************************************************************************
 * e51.c -- E51 monitor (hart 0).
 *
 * Minimal bring-up only: release the peripheral clocks/resets the SAR path
 * needs, then wake U54_1 (hart 1) and idle.
 *
 * The SAR pipeline was moved OFF the E51: on this MPFS250T_ES silicon the
 * E51's JTAG debug-halt path is unreliable (a running E51 ignores haltreq --
 * it runs away into an uninterruptible state with no clean instruction
 * boundary for the debugger to latch). U54_1 halts cleanly and has a hardware
 * FPU, so the float-heavy coefficient generation runs faster there too.
 ******************************************************************************/
#include "mpfs_hal/mss_hal.h"

void e51(void)
{
    /* Release peripheral subblock clocks/resets. The HAL already trained DDR
     * and brought up FIC_0 during system startup; this keeps the app
     * self-contained. */
    (void)mss_config_clk_rst(MSS_PERIPH_MMUART0, (uint8_t)MPFS_HAL_FIRST_HART,
                             PERIPHERAL_ON);

    /* Wake U54_1 (hart 1): it runs the SAR pipeline. The wake is a software
     * interrupt; U54_1 active-polls MIP.MSIP (no WFI) so it stays debuggable. */
    raise_soft_interrupt(1u);

    /* E51 idles. Debug + compute happen on U54_1. */
    for (;;) {
        ;
    }
}
