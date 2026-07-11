/* hart4 (U54_4) -- parked. The DDR demo runs entirely on the E51 (hart0). */
#include "mpfs_hal/mss_hal.h"

void u54_4(void)
{
    while (0u == (read_csr(mip) & MIP_MSIP)) {
        ;
    }
    for (;;) {
        __asm volatile ("wfi");
    }
}
