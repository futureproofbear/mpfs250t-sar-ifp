# Fabric reference clock for the CCC (board 50 MHz oscillator on W12).
create_clock -name {REF_CLK_50MHz} -period 20.000 [ get_ports { REF_CLK_50MHz } ]
