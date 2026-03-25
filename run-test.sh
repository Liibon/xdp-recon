#!/usr/bin/env bash
# xdp-recon test harness. Produces evidence/ from a real run.
#
# Topology is one veth pair in the default namespace. Generator transmits
# on veth0. XDP attaches to veth1 ingress.
#
# Requires root for XDP attach, pktgen, sysctl, ip link, and ethtool.
# Builds the Rust loader on demand. Exits non zero on any step failure
# and leaves partial evidence in place.

set -Eeuo pipefail

VETH0=veth0
VETH1=veth1
PKT_COUNT=${PKT_COUNT:-10000000}
PKT_SIZE=${PKT_SIZE:-64}
RUN_NAME=${RUN_NAME:-unrestricted}
RATE_PPS=${RATE_PPS:-0}
MIN_DURATION=${MIN_DURATION:-60}
EVIDENCE=${EVIDENCE:-evidence}
LOADER_BIN=${LOADER_BIN:-target/release/xdp-recon}

PKTGEN_THREAD=/proc/net/pktgen/kpktgend_0
PKTGEN_DEV=/proc/net/pktgen/$VETH0
PKTGEN_CTRL=/proc/net/pktgen/pgctrl

log() { printf '[%s] %s\n' "$(date -Iseconds)" "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "must run as root"; }
ensure_tool() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"; }

need_root
for t in ip ethtool sysctl bpftool clang cargo modprobe python3; do
    ensure_tool "$t"
done

log "clearing $EVIDENCE/"
rm -rf "$EVIDENCE"
mkdir -p "$EVIDENCE"

build_loader() {
    log "building loader"
    cargo build --release 2> "$EVIDENCE/build.log"
}

setup_veth() {
    log "tearing down stale veth (best effort)"
    ip link del "$VETH0" 2>/dev/null || true

    log "creating $VETH0 and $VETH1"
    ip link add "$VETH0" type veth peer name "$VETH1"
    ip link set "$VETH0" up
    ip link set "$VETH1" up
    # pktgen sends raw frames. Generic offloads only confuse the counters.
    for nic in "$VETH0" "$VETH1"; do
        ethtool -K "$nic" tx off rx off gso off gro off tso off lro off 2>/dev/null || true
    done
}

capture_env() {
    {
        echo "=== uname -a ==="; uname -a
        echo "=== /etc/os-release ==="; cat /etc/os-release
        echo "=== rustc --version ==="; rustc --version
        echo "=== clang --version ==="; clang --version
        echo "=== bpftool version ==="; bpftool version
        echo "=== ip -d link show $VETH0 ==="; ip -d link show "$VETH0"
        echo "=== ip -d link show $VETH1 ==="; ip -d link show "$VETH1"
        echo "=== ethtool -i $VETH1 ==="; ethtool -i "$VETH1" || true
        echo "=== sysctl kernel.bpf_stats_enabled ==="; sysctl kernel.bpf_stats_enabled
    } > "$EVIDENCE/env.txt"
}

pktgen_init() {
    log "loading pktgen"
    modprobe pktgen
    for _ in $(seq 1 20); do
        [[ -e $PKTGEN_THREAD ]] && break
        sleep 0.1
    done
    [[ -e $PKTGEN_THREAD ]] || die "pktgen did not expose /proc/net/pktgen"
}

pktgen_configure() {
    local dst_mac="$1"
    log "configuring pktgen on $VETH0 dst=$dst_mac count=$PKT_COUNT size=$PKT_SIZE rate=$RATE_PPS"
    echo "rem_device_all" > "$PKTGEN_THREAD"
    echo "add_device $VETH0" > "$PKTGEN_THREAD"

    {
        echo "reset"
        echo "count $PKT_COUNT"
        echo "pkt_size $PKT_SIZE"
        echo "clone_skb 0"
        echo "delay 0"
        echo "dst_mac $dst_mac"
        echo "src_min 10.10.0.1"
        echo "src_max 10.10.0.1"
        echo "dst_min 10.10.0.2"
        echo "dst_max 10.10.0.2"
        echo "udp_src_min 4000"
        echo "udp_src_max 4000"
        echo "udp_dst_min 5000"
        echo "udp_dst_max 5000"
        if [[ $RATE_PPS -gt 0 ]]; then
            echo "ratep $RATE_PPS"
        fi
    } > "$PKTGEN_DEV"
}

pktgen_start() {
    log "starting pktgen run"
    # The write blocks until the pktgen run completes.
    echo "start" > "$PKTGEN_CTRL"
}

capture_before() {
    ip -s link show "$VETH0" > "$EVIDENCE/veth0-before.txt"
    ip -s link show "$VETH1" > "$EVIDENCE/veth1-before.txt"
    ethtool -S "$VETH1" > "$EVIDENCE/ethtool-before.txt" 2>&1 || true
    bpftool map dump name xdp_stats > "$EVIDENCE/xdp-map-before.json" 2>/dev/null || true
}

capture_after() {
    ip -s link show "$VETH0" > "$EVIDENCE/veth0-after.txt"
    ip -s link show "$VETH1" > "$EVIDENCE/veth1-after.txt"
    ethtool -S "$VETH1" > "$EVIDENCE/ethtool-after.txt" 2>&1 || true
    bpftool map dump name xdp_stats > "$EVIDENCE/xdp-map-after.json" 2>/dev/null || true
    cp "$PKTGEN_DEV" "$EVIDENCE/generator-output.txt"
}

cleanup() {
    set +e
    [[ -n "${LOADER_PID:-}" ]] && kill -INT "$LOADER_PID" 2>/dev/null
    [[ -n "${LOADER_PID:-}" ]] && wait "$LOADER_PID" 2>/dev/null
    echo "rem_device_all" > "$PKTGEN_THREAD" 2>/dev/null
    ip link del "$VETH0" 2>/dev/null
}
trap cleanup EXIT

build_loader
setup_veth
sysctl -w kernel.bpf_stats_enabled=1 >/dev/null
capture_env

VETH1_MAC=$(cat /sys/class/net/$VETH1/address)
log "$VETH1 MAC: $VETH1_MAC"

log "attaching loader"
XDP_RECON_IFACE="$VETH1" XDP_RECON_OUT="$EVIDENCE/loader-counters.json" \
    "$LOADER_BIN" >/dev/null 2>"$EVIDENCE/loader.log" &
LOADER_PID=$!
sleep 1.5
if ! kill -0 "$LOADER_PID" 2>/dev/null; then
    die "loader exited before attach completed; see $EVIDENCE/loader.log"
fi

bpftool prog show > "$EVIDENCE/bpftool-prog-attached.txt"
bpftool net show > "$EVIDENCE/bpftool-net.txt"
PROG_ID=$(bpftool -j prog show | python3 -c "
import json, sys
for p in json.load(sys.stdin):
    if p.get('name') == 'xdp_recon':
        print(p['id']); break
")
[[ -n $PROG_ID ]] || die "could not find xdp_recon prog id"

capture_before
date +%s%N > "$EVIDENCE/test-start.txt"

pktgen_init
pktgen_configure "$VETH1_MAC"
START_EPOCH=$(date +%s)
pktgen_start
END_EPOCH=$(date +%s)
ELAPSED=$((END_EPOCH - START_EPOCH))
if [[ $ELAPSED -lt $MIN_DURATION ]]; then
    log "warning: run completed in ${ELAPSED}s, below ${MIN_DURATION}s minimum"
fi

date +%s%N > "$EVIDENCE/test-end.txt"

log "stopping loader so map counters settle"
kill -INT "$LOADER_PID"
wait "$LOADER_PID" 2>/dev/null || true
LOADER_PID=

bpftool prog show id "$PROG_ID" -j > "$EVIDENCE/prog-runtime.json" 2>/dev/null || true
capture_after

log "reconciliation"
python3 "$(dirname "$0")/scripts/reconcile.py" "$EVIDENCE" > "$EVIDENCE/results.md"
cat "$EVIDENCE/results.md"
