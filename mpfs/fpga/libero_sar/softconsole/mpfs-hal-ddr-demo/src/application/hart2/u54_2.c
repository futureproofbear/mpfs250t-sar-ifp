/* hart2 (U54_2) -- coefficient-generation worker 1.
 *
 * Was a parked WFI stub. The range gather and FFT-1 are ~99.6% MSS coefficient generation
 * (RPROF[2]/RPROF[5] on silicon), and that loop is cache-miss-stall bound rather than issue
 * bound, so the idle harts are the lever: they overlap each other's stalls. Rationale, safety
 * properties and the board-free bit-exactness proof: sar/sar_coeff_workers.h.
 *
 * Parks in the worker spin loop and stays idle until hart1 dispatches a job. With the runtime
 * knob at SAR_CWRK_NW_ADDR left at 0/1 the dispatcher never releases one, so this is exactly the
 * old behaviour -- the change is A/B-able over JTAG without a reflash. */
#include "mpfs_hal/mss_hal.h"
#include "../../sar/sar_coeff_workers.h"

void u54_2(void)
{
    while (0u == (read_csr(mip) & MIP_MSIP)) {
        ;
    }
    sar_coeff_worker_main(1u);      /* never returns */
}
