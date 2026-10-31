#!/usr/bin/env python3
"""Throwaway test: set Dante Virtual Soundcard's sample rate the way Dante Controller does.

Sends the 40-byte settings packet captured from Dante Controller to DVS's settings
port (38700 on a Mac running DVS), then watches DVS's audio engine process
(`dvs_ape --currSrate=`) until it reports the new rate. Run it on the DVS Mac.

    python3 scripts/dvs_set_rate.py 44100
    python3 scripts/dvs_set_rate.py 48000
    python3 scripts/dvs_set_rate.py 44100 --src-port 8700   # if DVS ignores an ephemeral source port
"""

import argparse
import random
import re
import socket
import struct
import subprocess
import sys
import time

RATES = [44100, 48000, 88200, 96000, 176400, 192000]


def interface_info(interface):
    out = subprocess.run(["ifconfig", interface], capture_output=True, text=True, check=True).stdout
    mac = re.search(r"ether ([0-9a-f:]{17})", out)
    ip = re.search(r"inet (\d+\.\d+\.\d+\.\d+)", out)
    if not mac or not ip:
        sys.exit(f"couldn't read MAC/IPv4 for {interface}")
    return bytes.fromhex(mac.group(1).replace(":", "")), ip.group(1)


def dvs_current_rate():
    out = subprocess.run(["ps", "-axo", "args"], capture_output=True, text=True).stdout
    match = re.search(r"dvs_ape .*--currSrate=(\d+)", out)
    return int(match.group(1)) if match else None


def set_rate_packet(mac, rate, sequence):
    # Captured from Dante Controller 2026-10-16:
    # ffff 0028 <seq> 0000 <controller mac6> 0000 "Audinate" 073e 0081 00000064 00000001 <rate32>
    body = mac + b"\x00\x00" + b"Audinate" + bytes.fromhex("073e0081") + struct.pack(">III", 0x64, 1, rate)
    return struct.pack(">HHHH", 0xFFFF, 8 + len(body), sequence, 0) + body


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("rate", type=int, choices=RATES)
    parser.add_argument("--interface", default="en7", help="DVS's Dante interface")
    parser.add_argument("--port", type=int, default=38700, help="DVS settings port")
    parser.add_argument("--src-port", type=int, default=0, help="local source port (Dante Controller uses 8700)")
    parser.add_argument("--wait", type=float, default=30, help="seconds to wait for DVS to report the new rate")
    args = parser.parse_args()

    mac, ip = interface_info(args.interface)
    before = dvs_current_rate()
    print(f"DVS at {ip}:{args.port}, MAC {mac.hex(':')}, current rate {before}")
    if before is None:
        sys.exit("dvs_ape isn't running; start DVS first")
    if before == args.rate:
        print("already at that rate; nothing sent")
        return

    packet = set_rate_packet(mac, args.rate, random.randint(1, 0xFFFE))
    print(f"sending {packet.hex()}")
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind((ip, args.src_port))
        sock.sendto(packet, (ip, args.port))

    started = time.monotonic()
    rate = before
    while time.monotonic() - started < args.wait:
        time.sleep(0.5)
        rate = dvs_current_rate()
        if rate == args.rate:
            print(f"VERIFIED: DVS now at {rate} Hz after {time.monotonic() - started:.1f}s")
            return
    sys.exit(f"NOT CONFIRMED after {args.wait:.0f}s: dvs_ape reports {rate}")


if __name__ == "__main__":
    main()
