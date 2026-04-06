#!/usr/bin/env python3
"""Reconcile counters from evidence/ and emit results.md.

Reads:
  evidence/generator-output.txt   pktgen proc file or mausezahn stdout
  evidence/generator-name.txt     "pktgen" or "mausezahn"
  evidence/expected_drops.txt     int; non-zero when XDP filter is active
  evidence/veth0-before.txt       ip -s link veth0 before
  evidence/veth0-after.txt        ip -s link veth0 after
  evidence/veth1-before.txt       ip -s link veth1 before
  evidence/veth1-after.txt        ip -s link veth1 after
  evidence/loader-counters.json   per CPU map sums and ringbuf counters
  evidence/prog-runtime.json      bpftool prog show -j

Writes results.md to stdout. Exit status: 0 on PASS, 1 on FAIL.

Pass conditions (always evaluated):
  offered_packets    == veth0_tx_packets
  xdp_parse_errors   == 0
  xdp_pass + xdp_drop == xdp_rx_total
  xdp_drop_count     == expected_drops
  veth0_tx_packets   == xdp_rx_total      (every TX packet was seen by XDP)

We deliberately do NOT assert veth1_rx_packets equals anything specific.
veth driver behavior with XDP_DROP varies between generic and native
attach paths and is empirically observed, not asserted.
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
    m = re.search(r"pkts-sofar:\s+(\d+)", text)
    if not m:
        m = re.search(r"Result:\s+OK:.*?,\s+(\d+)\s+\(", text)
    if not m:
        raise RuntimeError("could not find pktgen TX count in generator-output.txt")
    return int(m.group(1))


def parse_mausezahn(text, fallback_tx):
    """Mausezahn does not print a definitive count. Use the veth0 TX delta
    as the authoritative offered count for mausezahn runs."""
    return fallback_tx


def main():
    evdir = Path(sys.argv[1])

    v0_before = parse_iplink_stats((evdir / "veth0-before.txt").read_text())
    v0_after = parse_iplink_stats((evdir / "veth0-after.txt").read_text())
    v1_before = parse_iplink_stats((evdir / "veth1-before.txt").read_text())
    v1_after = parse_iplink_stats((evdir / "veth1-after.txt").read_text())

    v0_tx = v0_after["tx_packets"] - v0_before["tx_packets"]
    v1_rx = v1_after["rx_packets"] - v1_before["rx_packets"]
    v1_drop = v1_after["rx_dropped"] - v1_before["rx_dropped"]

    generator = (evdir / "generator-name.txt").read_text().strip() if (evdir / "generator-name.txt").exists() else "pktgen"
    gen_text = (evdir / "generator-output.txt").read_text()
    if generator == "mausezahn":
        offered = parse_mausezahn(gen_text, v0_tx)
    else:
        offered = parse_pktgen(gen_text)

    expected_drops = 0
    ed_path = evdir / "expected_drops.txt"
    if ed_path.exists():
        expected_drops = int(ed_path.read_text().strip())

    counters = json.loads((evdir / "loader-counters.json").read_text())
    xdp_rx = counters["rx_total"]
    parse_err = counters["parse_errors"]
    xdp_pass = counters["xdp_pass_count"]
    xdp_drop = counters["xdp_drop_count"]
    lost = counters["ringbuf_lost_events"]

    prog = json.loads((evdir / "prog-runtime.json").read_text())
    if isinstance(prog, list):
        prog = prog[0] if prog else {}
    run_time_ns = int(prog.get("run_time_ns", 0))
    run_cnt = int(prog.get("run_cnt", 0))
    mean_runtime_ns = (run_time_ns / run_cnt) if run_cnt else 0.0

    rows = [
        ("generator",             generator),
        ("offered_packets",       offered),
        ("veth0_tx_packets",      v0_tx),
        ("veth1_rx_packets",      v1_rx),
        ("veth1_rx_dropped",      v1_drop),
        ("xdp_rx_total",          xdp_rx),
        ("xdp_pass_count",        xdp_pass),
        ("xdp_drop_count",        xdp_drop),
        ("xdp_parse_errors",      parse_err),
        ("expected_drops",        expected_drops),
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
        ("veth0_tx_packets == xdp_rx_total",         v0_tx == xdp_rx),
        ("xdp_pass + xdp_drop == xdp_rx_total",      xdp_pass + xdp_drop == xdp_rx),
        ("xdp_drop_count   == expected_drops",       xdp_drop == expected_drops),
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
