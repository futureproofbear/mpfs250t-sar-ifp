# sar_fft_cdc.sdc -- CoreFFT CLK<->SLOWCLK clock-domain-crossing false-path exceptions.
#
# REQUIRED by CoreFFT (see CoreFFT_UG.pdf section 5 "Design Constraints" and the
# core's own component/Actel/DirectCore/COREFFT/8.1.100/constraint/CoreFFT.sdc).
# The twiddle-LUT init logic crosses between CLK (OUT0, 125 MHz) and SLOWCLK
# (OUT1, 15.625 MHz = CLK/8); the boundary is synchronized in CoreFFT's logic, so
# these crossings MUST be declared false paths. They were NOT present in the
# auto-generated SAR_TOP_derived_constraints.sdc (which only pulled PF_CCC / AXIIC /
# ICICLE_MSS component SDCs -- CoreFFT.sdc was not propagated).
#
# Add this file to the project's timing constraints (Constraint Manager -> Timing ->
# associate for Synthesis + Place-and-Route), then re-run synth/P&R/export.
# Clock object names match SAR_TOP_derived_constraints.sdc (the CCC generated clocks).

set_false_path -from [ get_clocks { CCC/PF_CCC_C0_0/pll_inst_0/OUT1 } ] -to [ get_clocks { CCC/PF_CCC_C0_0/pll_inst_0/OUT0 } ]
set_false_path -from [ get_clocks { CCC/PF_CCC_C0_0/pll_inst_0/OUT0 } ] -to [ get_clocks { CCC/PF_CCC_C0_0/pll_inst_0/OUT1 } ]
