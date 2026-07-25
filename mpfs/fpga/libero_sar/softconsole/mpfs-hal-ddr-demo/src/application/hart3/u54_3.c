/* hart3 (U54_3) -- coefficient-generation worker 2.  See hart2/u54_2.c and
 * sar/sar_coeff_workers.h for the rationale, safety properties and the bit-exactness proof. */
#include "mpfs_hal/mss_hal.h"
#include "../../sar/sar_coeff_workers.h"

void u54_3(void)
{
    while (0u == (read_csr(mip) & MIP_MSIP)) {
        ;
    }
    sar_coeff_worker_main(2u);      /* never returns */
}
