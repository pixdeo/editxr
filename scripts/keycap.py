#!/usr/bin/env python3
# Captura los bytes crudos que manda la terminal para una tecla.
import sys, os, tty, termios, time

fd = sys.stdin.fileno()
old = termios.tcgetattr(fd)
tty.setraw(fd)
n = termios.tcgetattr(fd)
n[6][termios.VMIN] = 0
n[6][termios.VTIME] = 1
termios.tcsetattr(fd, termios.TCSANOW, n)

def grab(label, seconds=4):
    sys.stdout.write(f"\r\n>>> Apreta {label} (tenes {seconds}s)...\r\n")
    sys.stdout.flush()
    data = b""
    end = time.time() + seconds
    while time.time() < end:
        c = os.read(fd, 64)
        if c:
            data += c
    sys.stdout.write(f"    {label}: {data!r}\r\n")
    sys.stdout.flush()

try:
    grab("Ctrl+[")
    grab("Escape")
    grab("Ctrl+]")
finally:
    termios.tcsetattr(fd, termios.TCSADRAIN, old)
    print("\nListo.")
