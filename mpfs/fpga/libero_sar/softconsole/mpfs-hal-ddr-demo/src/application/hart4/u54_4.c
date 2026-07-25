/* hart4 (U54_4) -- coefficient-generation worker 3.  See hart2/u54_2.c and
 * sar/sar_coeff_workers.h for the rationale, safety properties and the bit-exactness proof. */
#include "mpfs_hal/mss_hal.h"
#include "../../sar/sar_coeff_workers.h"

void u54_4(void)
{
    while (0u == (read_csr(mip) & MIP_MSIP)) {
        ;
    }
    sar_coeff_worker_main(3u);      /* never returns */
}
