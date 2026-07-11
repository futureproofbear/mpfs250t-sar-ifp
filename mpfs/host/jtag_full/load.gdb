# load SAR inputs into DDR over JTAG, then `continue` the bare-metal app
restore sig.bin binary 0x88000000
restore f0.bin binary 0xB0100000
restore df.bin binary 0xB0108000
restore pr.bin binary 0xB0110000
restore tans.bin binary 0xB0118000
restore invorder.bin binary 0xB0120000
restore krgrid.bin binary 0xB0128000
restore kcgrid.bin binary 0xB0130000
restore hamr.bin binary 0xB0138000
restore hamc.bin binary 0xB0140000
restore job.bin binary 0xB0040000
