#!/usr/bin/env python3
"""Reconcile counters from evidence/ and emit results.md.

Reads:
  evidence/generator-output.txt   pktgen authoritative TX count
  evidence/veth0-before.txt       ip -s link veth0 before
  evidence/veth0-after.txt        ip -s link veth0 after
  evidence/veth1-before.txt       ip -s link veth1 before
  evidence/veth1-after.txt        ip -s link veth1 after
  evidence/loader-counters.json   per CPU map sums and ringbuf counters
  evidence/prog-runtime.json      bpftool prog show -j

Writes results.md to stdout. Pass conditions follow the spec exactly.
Exit status: 0 on PASS, 1 on FAIL.
"""
import json
import re
import sys
from pathlib import Path


def parse_iplink_stats(text):
    """Extract tx and rx packet and drop counts from `ip -s link show`."""
    out = {"rx_packets": 0, "rx_dropped": 0, "tx_packets": 0, "tx_dropped": 0}
    lines = text.splitlines()
    for i, line in enumerate(lines):
        s = line.strip()
        if s.startswith("RX:") and i + 1 < len(lines):
            parts = lines[i + 1].split()
            if len(parts) >= 4:
                out["rx_packets"] = int(parts[1])
                out["rx_dropped"] = int(parts[3])
        if s.startswith("TX:") and i + 1 < len(lines):
            parts = lines[i + 1].split()
            if len(parts) >= 4:
                out["tx_packets"] = int(parts[1])
                out["tx_dropped"] = int(parts[3])
    return out


def parse_pktgen(text):
    """Pull the authoritative TX count from /proc/net/pktgen/<dev>."""
    m = re.search(r"pkts-so-far:\s+(\d+)", text)
    if not m:
        m = re.search(r"\bpkts:\s+(\d+)", text)
    if not m:
        raise RuntimeError("could not find pktgen TX count in generator-output.txt")
    return int(m.group(1))


def main():
    evdir = Path(sys.argv[1])

    pktgen_tx = parse_pktgen((evdir / "generator-output.txt").read_text())
    v0_before = parse_iplink_stats((evdir / "veth0-before.txt").read_text())
    v0_after = parse_iplink_stats((evdir / "veth0-after.txt").read_text())
    v1_before = parse_iplink_stats((evdir / "veth1-before.txt").read_text())
    v1_after = parse_iplink_stats((evdir / "veth1-after.txt").read_text())

    counters = json.loads((evdir / "loader-counters.json").read_text())

    offered = pktgen_tx
    v0_tx = v0_after["tx_packets"] - v0_before["tx_packets"]
    v1_rx = v1_after["rx_packets"] - v1_before["rx_packets"]
    v1_drop = v1_after["rx_dropped"] - v1_before["rx_dropped"]
    xdp_rx = counters["rx_total"]
    parse_err = counters["parse_errors"]
    lost = counters["ringbuf_lost_events"]

    prog = json.loads((evdir / "prog-runtime.json").read_text())
    if isinstance(prog, list):
        prog = prog[0] if prog else {}
    run_time_ns = int(prog.get("run_time_ns", 0))
    run_cnt = int(prog.get("run_cnt", 0))
    mean_runtime_ns = (run_time_ns / run_cnt) if run_cnt else 0.0

    rows = [
        ("offered_packets",       offered),
        ("veth0_tx_packets",      v0_tx),
        ("veth1_rx_packets",      v1_rx),
        ("veth1_rx_dropped",      v1_drop),
        ("xdp_rx_total",          xdp_rx),
        ("xdp_parse_errors",      parse_err),
        ("ringbuf_lost_events",   lost),
    ]

    print("## counters")
    print()
    print("```")
    for name, val in rows:
        print(f"{name:<28} {val}")
    print("```")
    print()

    checks = [
        ("offered_packets  == veth0_tx_packets",     offered == v0_tx),
        ("veth0_tx_packets == veth1_rx_packets",     v0_tx == v1_rx),
        ("veth1_rx_packets == xdp_rx_total",         v1_rx == xdp_rx),
        ("veth1_rx_dropped == 0",                     v1_drop == 0),
        ("xdp_parse_errors == 0",                     parse_err == 0),
    ]
    overall = all(ok for _, ok in checks)

    print("## pass conditions")
    print()
    print("```")
    for desc, ok in checks:
        print(f"{desc:<42} {'PASS' if ok else 'FAIL'}")
    print(f"{'overall':<42} {'PASS' if overall else 'FAIL'}")
    print(f"mean_runtime_ns                            {mean_runtime_ns:.2f}")
    print(f"ringbuf_lost_events                        {lost}")
    print("```")
    return 0 if overall else 1


if __name__ == "__main__":
    sys.exit(main())
