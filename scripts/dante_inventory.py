#!/usr/bin/env python3
"""Throwaway, read-only Dante inventory using the netaudio CLI.

Lists every Dante device with its sample rate, encoding, lock state and clock
role, and flags anything that would affect automatic rate following. It never
changes a device.

Setup (once):
    python3 -m venv ~/.venvs/netaudio
    ~/.venvs/netaudio/bin/pip install netaudio==0.4.2

Run:
    python3 scripts/dante_inventory.py --netaudio ~/.venvs/netaudio/bin/netaudio
    python3 scripts/dante_inventory.py --dump inventory.json      # also save raw JSON
    python3 scripts/dante_inventory.py --interface en7            # pin to the Dante NIC
"""

import argparse
import ipaddress
import json
import shutil
import subprocess
import sys
import time
from pathlib import Path

LEADER_NAME_HINT = "PULSE"
ALL_RATES = [44100, 48000, 88200, 96000, 176400, 192000]


def run_netaudio(exe, global_args, command, timeout):
    """Run a netaudio command with -j and return (parsed_json_or_None, error_text, seconds)."""
    cmd = [exe, *global_args, "-j", *command]
    started = time.monotonic()
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return None, f"timed out after {timeout}s: {' '.join(command)}", timeout
    elapsed = time.monotonic() - started
    if proc.returncode != 0:
        tail = "\n".join(proc.stderr.strip().splitlines()[-3:])
        return None, f"exit {proc.returncode}: {' '.join(command)}\n{tail}", elapsed
    try:
        return json.loads(proc.stdout), None, elapsed
    except json.JSONDecodeError as exc:
        return None, f"bad JSON from {' '.join(command)}: {exc}", elapsed


def khz(hz):
    if not hz:
        return "—"
    value = hz / 1000
    return f"{value:g}k"


def lock_text(value):
    return {True: "LOCKED", False: "unlocked", None: "unknown"}[value]


def subnet(ip):
    try:
        return ipaddress.ip_network(f"{ip}/16", strict=False)
    except ValueError:
        return None


def is_virtual(device):
    text = " ".join(str(device.get(k) or "") for k in ("manufacturer", "product_name", "model", "name")).lower()
    if "virtual" in text or "via" in text.split() or device.get("kind") not in (None, "hardware"):
        return True
    # netaudio 0.4.2 can't parse DVS 4.5's model reply, so DVS shows up as Audinate with no product.
    return device.get("manufacturer") == "Audinate" and not (device.get("product_name") or device.get("model"))


def build_rows(devices, locks, clock):
    rows = []
    for key, dev in sorted(devices.items(), key=lambda kv: (kv[1].get("name") or kv[0]).lower()):
        lock = dev.get("is_locked")
        if lock is None and key in locks:
            lock = locks[key].get("is_locked")
        clock_status = dev.get("clock_status") or {}
        role = (clock.get(key) or {}).get("role") or "—"
        rows.append(
            {
                "key": key,
                "name": dev.get("name") or key,
                "ip": dev.get("ipv4") or "",
                "maker": dev.get("manufacturer") or "",
                "product": dev.get("product_name") or dev.get("model") or "",
                "kind": dev.get("kind") or "",
                "rate": dev.get("sample_rate_hz"),
                "requested_rate": dev.get("requested_sample_rate"),
                "supported_rates": dev.get("supported_sample_rates_hz") or [],
                "encoding": dev.get("encoding"),
                "supported_encodings": sorted(dev.get("supported_encodings") or []),
                "locked": lock,
                "preferred_leader": dev.get("preferred_leader"),
                "clock_source": dev.get("clock_source") or clock_status.get("clock_source"),
                "sync": clock_status.get("synchronization"),
                "role": role,
                "rx": dev.get("rx_count"),
                "tx": dev.get("tx_count"),
                "online": dev.get("online"),
                "virtual": is_virtual(dev),
            }
        )
    return rows


def warnings_for(row, leader_rates):
    notes = []
    if row["online"] is False:
        notes.append("offline")
    if row["locked"] is True:
        notes.append("Device Lock ON: rate changes will be rejected")
    elif row["locked"] is None:
        notes.append("lock state unknown")
    if row["rate"] is None:
        notes.append("no sample rate reported")
    if row["requested_rate"] and row["rate"] and row["requested_rate"] != row["rate"]:
        notes.append(f"pending change: requested {khz(row['requested_rate'])}")
    if row["supported_rates"]:
        missing = [r for r in (leader_rates or ALL_RATES) if r not in row["supported_rates"]]
        if missing:
            notes.append("can't follow " + ", ".join(khz(r) for r in missing))
    else:
        notes.append("no supported-rate list: must try-and-verify")
    if row["virtual"]:
        notes.append("virtual device: check channel count at high rates")
    return notes


def print_table(rows, leader_rates):
    headers = ["Device", "IP", "Maker / product", "Rate", "Supported", "Enc", "Lock", "Clock", "Rx/Tx"]
    table = []
    for r in rows:
        clock_bits = [r["role"]]
        if r["preferred_leader"]:
            clock_bits.append("pref")
        if r["clock_source"]:
            clock_bits.append(r["clock_source"])
        table.append(
            [
                r["name"],
                r["ip"],
                f"{r['maker']} {r['product']}".strip()[:34],
                khz(r["rate"]),
                ",".join(khz(x) for x in sorted(r["supported_rates"])) or "—",
                f"{r['encoding']}b" if r["encoding"] else "—",
                lock_text(r["locked"]),
                " ".join(clock_bits),
                f"{r['rx'] if r['rx'] is not None else '?'}/{r['tx'] if r['tx'] is not None else '?'}",
            ]
        )
    widths = [max(len(str(c)) for c in col) for col in zip(headers, *table)]
    line = "  ".join(h.ljust(w) for h, w in zip(headers, widths))
    print(line)
    print("-" * len(line))
    for row, r in zip(table, rows):
        print("  ".join(str(c).ljust(w) for c, w in zip(row, widths)))
        for note in warnings_for(r, leader_rates):
            print(f"    ! {note}")


def network_checks(rows):
    print("\nNetwork-level checks")
    leaders = [r for r in rows if r["preferred_leader"]]
    ptp_leaders = [r for r in rows if r["role"] == "Leader"]
    pulse = [r for r in rows if LEADER_NAME_HINT in r["name"].upper() or LEADER_NAME_HINT in r["product"].upper()]

    def report(ok, text):
        print(f"  [{'ok' if ok else '!!'}] {text}")

    report(len(leaders) == 1, f"preferred leaders: {', '.join(r['name'] for r in leaders) or 'none'}")
    report(len(ptp_leaders) == 1, f"current PTP leader: {', '.join(r['name'] for r in ptp_leaders) or 'none seen'}")
    if pulse:
        p = pulse[0]
        report(bool(p["preferred_leader"]), f"{p['name']} preferred leader = {p['preferred_leader']}")
        report(
            (p["clock_source"] or "internal") != "internal",
            f"{p['name']} clock source = {p['clock_source']} (expect external / Sync to External)",
        )
    else:
        report(False, f"no device matching '{LEADER_NAME_HINT}' found")

    rates = {r["rate"] for r in rows if r["rate"]}
    report(len(rates) <= 1, "rates in use: " + (", ".join(khz(x) for x in sorted(rates)) or "none reported"))

    nets = {}
    for r in rows:
        nets.setdefault(subnet(r["ip"]), []).append(r["name"])
    report(len(nets) == 1, "subnets: " + "; ".join(f"{n}: {', '.join(names)}" for n, names in nets.items()))
    if len(nets) > 1:
        print("       (DVS/Via share the Mac's hostname, so netaudio may list a non-Dante NIC's IP; try --interface)")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--netaudio", default=shutil.which("netaudio") or "netaudio", help="path to the netaudio executable")
    parser.add_argument("--timeout", type=float, default=5.0, help="mDNS discovery timeout passed to netaudio (s)")
    parser.add_argument("--interface", help="network interface to use for discovery, e.g. en7")
    parser.add_argument("--dump", type=Path, help="write the combined raw netaudio JSON here")
    args = parser.parse_args()

    if not shutil.which(args.netaudio) and not Path(args.netaudio).exists():
        sys.exit(f"netaudio not found at '{args.netaudio}'. Install it in a venv and pass --netaudio.")

    global_args = ["--timeout", str(args.timeout)]
    if args.interface:
        global_args += ["--interface", args.interface]
    budget = 30 + args.timeout * 12

    print(f"Discovering Dante devices (this takes ~30s)…", file=sys.stderr)
    listing, err, t_list = run_netaudio(args.netaudio, global_args, ["device", "list"], budget)
    if listing is None:
        sys.exit(f"device list failed: {err}")
    devices = listing.get("dante", listing)

    locks, lock_err, t_lock = run_netaudio(args.netaudio, global_args, ["lock", "status"], budget)
    clock, clock_err, t_clock = run_netaudio(args.netaudio, global_args, ["clock"], budget)

    rows = build_rows(devices, locks or {}, clock or {})
    pulse = next((r for r in rows if LEADER_NAME_HINT in r["name"].upper()), None)
    leader_rates = sorted(pulse["supported_rates"]) if pulse and pulse["supported_rates"] else None

    print(f"\n{len(rows)} Dante device(s)\n")
    print_table(rows, leader_rates)
    network_checks(rows)

    print(f"\nTimings: device list {t_list:.1f}s, lock status {t_lock:.1f}s, clock {t_clock:.1f}s")
    for label, e in (("lock status", lock_err), ("clock", clock_err)):
        if e:
            print(f"  {label} failed: {e}")

    if args.dump:
        args.dump.write_text(json.dumps({"device_list": listing, "lock_status": locks, "clock": clock}, indent=2))
        print(f"Raw JSON written to {args.dump}")


if __name__ == "__main__":
    main()
