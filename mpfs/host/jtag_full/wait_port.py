import socket, time, sys
# Probe OpenOCD's telnet port 4444 directly. It binds last (full startup), and a
# TCP probe sees the bind instantly (no log buffering). Probing 4444 (not the gdb
# port 3333) avoids opening a spurious gdb connection.
for _ in range(8000):
    s = socket.socket(); s.settimeout(0.15)
    r = s.connect_ex(("127.0.0.1", 4444)); s.close()
    if r == 0:
        sys.exit(0)
    time.sleep(0.02)
sys.exit(1)
