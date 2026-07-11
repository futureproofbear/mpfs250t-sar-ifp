/* hart3 (U54_3) -- parked. The DDR demo runs entirely on the E51 (hart0). */
#include "mpfs_hal/mss_hal.h"

void u54_3(void)
{
    while (0u == (read_csr(mip) & MIP_MSIP)) {
        ;
    }
    for (;;) {
        __asm volatile ("wfi");
    }
}
