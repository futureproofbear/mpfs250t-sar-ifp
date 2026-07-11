SRCS=fft_kernel.cpp
LOCAL_CONFIG = -shls-config=config.tcl
# sw-sim only: bundled mingw gcc 8.5.0 cc1plus crashes (silent, empty stderr,
# exit 1) at -O1 on the 8192-pt twiddle tables. USER_LINK_FLAG is emitted after
# the hardcoded -O1 in the single-command compile+link, so -O0 wins. No effect
# on `shls hw` (RTL synthesis path does not use this flag).
USER_LINK_FLAG = -O0
