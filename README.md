# xdp-recon

![xdp-recon architecture: use cases, userspace harness, kernel pktgen and XDP](docs/architecture.jpg)

XDP packet drop reconciliation test harness. Built around a veth pair.

Three counter sources are reconciled at the end of each run:

- pktgen authoritative TX count from `/proc/net/pktgen/veth0`
- kernel link stats from `ip -s link show` on both legs
- per CPU BPF map populated by the XDP program on veth1 ingress

The claim is `no observed packet drops` under stated conditions. That is
what the harness defends. Absolute zero loss in arbitrary environments
is not claimed.

## Stated conditions

- one veth pair in the default namespace, no host bridge
- pktgen with packet size 64, count 10000000
- two run modes, one unrestricted and one rate limited to 100 Kpps
- minimum 60s per run
- BPF runtime stats enabled via sysctl
- generic offloads (tx, rx, gso, gro, tso, lro) disabled on both legs

## Reconciliation

A run passes when all of these hold:

```
offered_packets  == veth0_tx_packets
veth0_tx_packets == veth1_rx_packets
veth1_rx_packets == xdp_rx_total
veth1_rx_dropped == 0
xdp_parse_errors == 0
```

Telemetry loss is tracked separately. `ringbuf_lost_events` is reported
but does not affect pass or fail.

## Chaos validation

The reconciler is only useful if it can detect loss. Set `CHAOS_LOSS_PCT`
to a positive integer to inject `netem` loss on the generator leg before
pktgen starts. The expected outcome is FAIL, and the harness exits 0 on
the expected FAIL. A chaos run that reports PASS is a harness bug.

```
sudo CHAOS_LOSS_PCT=1 EVIDENCE=evidence-chaos PKT_COUNT=1000000 ./run-test.sh
```

## Stack

- BPF program: C, compiled with clang
- Userspace loader: Rust, libbpf-rs plus libbpf-cargo
- Generator: kernel pktgen
- Reconciliation: scripts/reconcile.py

## Build

Linux host required. macOS users see the Lima section below.

```
sudo apt-get install -y \
  clang llvm libbpf-dev libelf-dev zlib1g-dev pkg-config build-essential \
  linux-tools-common linux-tools-generic ethtool iproute2 python3
cargo build --release
```

`build.rs` invokes the libbpf-cargo skeleton builder. The BPF program
uses kernel uapi headers. On Debian and Ubuntu the multiarch include
path under `/usr/include/<triple>` is added automatically via
`dpkg-architecture`. No vmlinux.h required.

## Run

Build first as your normal user, then invoke the harness with sudo. The
harness intentionally does not run `cargo build` itself because sudo
does not inherit rustup state.

```
cargo build --release
sudo ./run-test.sh
```

The script clears `evidence/` at start. On any step failure it exits
non zero and leaves whatever evidence was already captured in place.

All knobs are env vars. No CLI flags. No config file.

| Var | Read by | Default | Effect |
|---|---|---|---|
| `PKT_COUNT` | run-test.sh | 10000000 | packets per run |
| `PKT_SIZE` | run-test.sh | 64 | byte size |
| `RATE_PPS` | run-test.sh | 0 | 0 means unrestricted; 100000 for the 100 Kpps run |
| `MIN_DURATION` | run-test.sh | 60 | warning emitted if run finishes faster |
| `EVIDENCE` | run-test.sh | evidence | output directory |
| `CHAOS_LOSS_PCT` | run-test.sh | 0 | inject netem loss on veth0 to validate the reconciler |
| `XDP_RECON_IFACE` | loader | required | interface for XDP attach |
| `XDP_RECON_OUT` | loader | stdout | path for the JSON counter dump |

Two specified run modes are invoked as separate harness runs:

```
sudo RATE_PPS=0      EVIDENCE=evidence-unrestricted ./run-test.sh
sudo RATE_PPS=100000 EVIDENCE=evidence-100kpps      ./run-test.sh
```

## results.md

Two sections. First is a fixed width counter table. Second is each pass
condition with PASS or FAIL, then the overall verdict, then
`mean_runtime_ns`, then `ringbuf_lost_events`. No prose. Screenshot
target.

## Lima quickstart

For macOS hosts.

```
limactl create --name=xdp --tty=false
limactl start xdp
limactl shell xdp -- sudo apt-get update
limactl shell xdp -- sudo apt-get install -y \
  clang llvm libbpf-dev libelf-dev zlib1g-dev pkg-config build-essential \
  linux-tools-common linux-tools-generic ethtool iproute2 python3
limactl shell xdp
cd ~/xdp-recon
cargo build --release
sudo ./run-test.sh
```

Lima default Ubuntu ships kernel 6.14. BPF, ringbuf, XDP, and pktgen
are all built in. Default instance is 4GB RAM and 4 CPUs.

The default `/Users/<user>` mount inside Lima is read only. Copy or
rsync the project to a writable path inside the VM (for example
`/tmp/work/xdp-recon`) before building.

## Design notes

- `xdp_drop_count` exists in the schema for symmetry. It never
  increments. Every packet returns XDP_PASS. Zero drop is asserted at
  the link layer via `veth1_rx_dropped == 0`.
- `ringbuf_lost_events` is derived as `events_submitted - events_received`.
  `BPF_MAP_TYPE_RINGBUF` has no kernel side lost sample callback (unlike
  perfbuf). BPF side reserve failures are tracked separately in
  `events_failed`.
- pktgen sends UDP by default. The parser classifies UDP packets as
  `rx_parsed_ipv4`, not as parse errors. `rx_parsed_tcp` and the
  ringbuf event path stay at zero in the standard run.
- The IPv4 header check enforces `ihl == 5`. That gives the verifier a
  constant offset to the TCP header. pktgen does not emit IP options
  so this is sufficient.
