"""Accelerator seam for the MPFS SAR pipeline.

The pipeline calls ``backend.focus(signal, tables) -> detected`` where the
boundary is exactly the FPGA datapath boundary:

    signal (complex) + CPU-built tables  -->  [ resample -> window -> 2-D FFT
                                                -> detect |.| ]  -->  detected (float32)

Everything OUTSIDE this call (CPHD/metadata parsing, table preparation,
geocoding, GeoTIFF writing) stays on the CPU. Two interchangeable backends:

    NumpyBackend : pure-CPU reference. Reuses the laptop module
                   (src/form_image_pfa.py) so results are identical to it.
                   Runs anywhere, including the MPFS U54 cores (CPU-only mode).

    FpgaBackend  : drives the PolarFire SoC fabric over UIO + DMA. Board only;
                   the compute body is a documented stub until the bitstream
                   and kernel driver exist (see ../../docs/fpga/README.md, ../../docs/regmap.md).
"""
import numpy as np


class AccelBackend:
    name = "base"

    def focus(self, signal, tables):
        """signal: (M,N) complex64; tables: dict from prepare_tables().
        returns: (M,N) float32 detected magnitude image."""
        raise NotImplementedError


class NumpyBackend(AccelBackend):
    """CPU reference: delegates to the verified laptop implementation."""
    name = "numpy"

    def __init__(self, ref_module):
        self._ref = ref_module

    def focus(self, signal, tables):
        # The reference pfa() recomputes the KR/KC resample grids internally;
        # they equal the ones in `tables`, so the result matches the FPGA path.
        img, _ = self._ref.pfa(signal, tables["freq"], tables["ax"],
                               tables["ay"], tables["sgn"])
        return np.abs(img).astype(np.float32)          # detect on CPU here


class FpgaBackend(AccelBackend):
    """Drives the fabric accelerator on the PolarFire SoC. Board only.

    Intended sequence (see ../../docs/regmap.md for the register layout):
      1. Copy signal + KR grid + KC grid + window into CMA DMA buffers.
      2. Write buffer physical addresses + dims + FFT length to AXI4-Lite regs.
      3. Set CTRL.START; poll STATUS.DONE (or wait on the UIO irq).
      4. Read the detected buffer back into a NumPy view of the CMA region.
    """
    name = "fpga"

    def __init__(self, uio_dev="/dev/uio0", cma_dev="/dev/cma", regmap=None):
        self.uio_dev = uio_dev
        self.cma_dev = cma_dev
        self.regmap = regmap

    def focus(self, signal, tables):
        # NOTE: requires the MPFS bitstream + UIO/CMA driver. On a laptop this
        # raises clearly rather than pretending to run.
        raise NotImplementedError(
            "FpgaBackend runs on the PolarFire SoC. Wire it to the bitstream "
            "and UIO/CMA driver per ../../docs/fpga/README.md and ../../docs/regmap.md. "
            "Use --backend numpy for the CPU-only reference path."
        )


def make_backend(name, ref_module=None):
    if name == "numpy":
        return NumpyBackend(ref_module)
    if name == "fpga":
        return FpgaBackend()
    raise ValueError(f"unknown backend: {name}")
