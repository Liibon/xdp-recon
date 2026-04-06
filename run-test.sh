#!/usr/bin/env bash
# xdp-recon test harness. Produces evidence/ from a real run.
#
# Topology is one veth pair in the default namespace. Generator transmits
# on veth0. XDP attaches to veth1 ingress.
#
# Requires root for XDP attach, pktgen, sysctl, ip link, ethtool, tc.
# Expects the loader binary at target/release/xdp-recon. Build it first
# as your normal user; the harness does not run cargo because sudo does
# not inherit rustup state.

set -Eeuo pipefail

VETH0=veth0
VETH1=veth1
PKT_COUNT=${PKT_COUNT:-10000000}
PKT_SIZE=${PKT_SIZE:-64}
RATE_PPS=${RATE_PPS:-0}
MIN_DURATION=${MIN_DURATION:-60}
EVIDENCE=${EVIDENCE:-evidence}
LOADER_BIN=${LOADER_BIN:-target/release/xdp-recon}
CHAOS_LOSS_PCT=${CHAOS_LOSS_PCT:-0}
GENERATOR=${GENERATOR:-pktgen}
FILTER_DPORTS=${FILTER_DPORTS:-}
TCP_DPORT=${TCP_DPORT:-5000}

PKTGEN_THREAD=/proc/net/pktgen/kpktgend_0
PKTGEN_DEV=/proc/net/pktgen/$VETH0
PKTGEN_CTRL=/proc/net/pktgen/pgctrl

log() { printf '[%s] %s\n' "$(date -Iseconds)" "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

need_root() { [[ $EUID -eq 0 ]] || die "must run as root"; }
ensure_tool() { command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"; }

need_root
for t in ip ethtool sysctl bpftool modprobe python3 tc; do
    ensure_tool "$t"
done
case "$GENERATOR" in
    pktgen)    ;;
    mausezahn) ensure_tool mausezahn ;;
    *)         die "unknown GENERATOR=$GENERATOR" ;;
esac

[[ -x "$LOADER_BIN" ]] || die "loader not built; run 'cargo build --release' first"

log "clearing $EVIDENCE/"
rm -rf "$EVIDENCE"
mkdir -p "$EVIDENCE"

setup_veth() {
    log "tearing down stale veth (best effort)"
    ip link del "$VETH0" 2>/dev/null || true

    log "creating $VETH0 and $VETH1"
    ip link add "$VETH0" type veth peer name "$VETH1"
    # Kill IPv6, ARP, and multicast on both legs before bringing them up.
    # Background ND, RA, and multicast packets otherwise contaminate the
    # link counters and trip xdp_parse_errors.
    for nic in "$VETH0" "$VETH1"; do
        echo 1 > /proc/sys/net/ipv6/conf/"$nic"/disable_ipv6 2>/dev/null || true
        ip link set "$nic" arp off
        ip link set "$nic" multicast off
    done
    ip link set "$VETH0" up
    ip link set "$VETH1" up
    # pktgen sends raw frames. Generic offloads only confuse the counters.
    for nic in "$VETH0" "$VETH1"; do
        ethtool -K "$nic" tx off rx off gso off gro off tso off lro off 2>/dev/null || true
    done

    if [[ $CHAOS_LOSS_PCT -gt 0 ]]; then
        log "chaos mode: injecting ${CHAOS_LOSS_PCT}% netem loss on $VETH0"
        tc qdisc add dev "$VETH0" root netem loss "${CHAOS_LOSS_PCT}%"
    fi
}

capture_env() {
    {
        echo "=== uname -a ==="; uname -a || true
        echo "=== /etc/os-release ==="; cat /etc/os-release || true
        echo "=== rustc --version ==="; rustc --version 2>&1 || echo "(rustc not in sudo PATH)"
        echo "=== clang --version ==="; clang --version 2>&1 || echo "(clang not in sudo PATH)"
        echo "=== bpftool version ==="; bpftool version || true
        echo "=== generator ==="; echo "$GENERATOR"
        echo "=== filter dports ==="; echo "${FILTER_DPORTS:-(none)}"
        echo "=== ip -d link show $VETH0 ==="; ip -d link show "$VETH0" || true
        echo "=== ip -d link show $VETH1 ==="; ip -d link show "$VETH1" || true
        echo "=== ethtool -i $VETH1 ==="; ethtool -i "$VETH1" 2>&1 || true
        echo "=== sysctl kernel.bpf_stats_enabled ==="; sysctl kernel.bpf_stats_enabled || true
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

pg_set() {
    local cmd="$1"
    if ! echo "$cmd" > "$PKTGEN_DEV" 2>/dev/null; then
        die "pktgen rejected: $cmd"
    fi
}

pktgen_configure() {
    local dst_mac="$1"
    log "configuring pktgen on $VETH0 dst=$dst_mac count=$PKT_COUNT size=$PKT_SIZE rate=$RATE_PPS"
    echo "rem_device_all" > "$PKTGEN_THREAD"
    echo "add_device $VETH0" > "$PKTGEN_THREAD"

    pg_set "count $PKT_COUNT"
    pg_set "pkt_size $PKT_SIZE"
    pg_set "clone_skb 0"
    pg_set "delay 0"
    pg_set "dst_mac $dst_mac"
    pg_set "dst 10.10.0.2"
    pg_set "src_min 10.10.0.1"
    pg_set "src_max 10.10.0.1"
    pg_set "udp_dst_min 5000"
    pg_set "udp_dst_max 5000"
    pg_set "udp_src_min 4000"
    pg_set "udp_src_max 4000"
    if [[ $RATE_PPS -gt 0 ]]; then
        pg_set "ratep $RATE_PPS"
    fi
    if [[ $CHAOS_LOSS_PCT -gt 0 ]]; then
        # start_xmit (default) bypasses qdisc and therefore bypasses netem.
        # Switch to queue_xmit so injected loss is visible.
        pg_set "xmit_mode queue_xmit"
    fi
}

run_pktgen() {
    pktgen_init
    pktgen_configure "$VETH1_MAC"
    log "starting pktgen run"
    # The write blocks until the pktgen run completes.
    echo "start" > "$PKTGEN_CTRL"
}

run_mausezahn() {
    log "running mausezahn: TCP to $VETH1_MAC dport=$TCP_DPORT count=$PKT_COUNT size=$PKT_SIZE"
    # mausezahn -c N sends N packets total. -a/-b set src/dst MAC.
    # -t tcp with dp= sets the L4 protocol and destination port.
    # The kernel's veth0 TX counter is the authoritative tx number for
    # this generator since mausezahn does not expose a proc-file count.
    local payload_bytes=$(( PKT_SIZE - 14 - 20 - 20 )) # eth + ip + tcp
    [[ $payload_bytes -lt 0 ]] && payload_bytes=0
    mausezahn "$VETH0" \
        -c "$PKT_COUNT" \
        -a "$(cat /sys/class/net/$VETH0/address)" \
        -b "$VETH1_MAC" \
        -A 10.10.0.1 \
        -B 10.10.0.2 \
        -t tcp "dp=$TCP_DPORT,sp=4000,flags=syn" \
        -p "$payload_bytes" \
        2>"$EVIDENCE/mausezahn.log" \
        > "$EVIDENCE/generator-output.txt" \
        || die "mausezahn failed (see $EVIDENCE/mausezahn.log)"
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
    if [[ "$GENERATOR" == "pktgen" ]]; then
        cp "$PKTGEN_DEV" "$EVIDENCE/generator-output.txt"
    fi
}

cleanup() {
    set +e
    [[ -n "${LOADER_PID:-}" ]] && kill -INT "$LOADER_PID" 2>/dev/null
    [[ -n "${LOADER_PID:-}" ]] && wait "$LOADER_PID" 2>/dev/null
    if [[ -e "$PKTGEN_THREAD" ]]; then
        echo "rem_device_all" > "$PKTGEN_THREAD" 2>/dev/null
    fi
    ip link del "$VETH0" 2>/dev/null
}
trap cleanup EXIT

setup_veth
sysctl -w kernel.bpf_stats_enabled=1 >/dev/null
capture_env

VETH1_MAC=$(cat /sys/class/net/$VETH1/address)
log "$VETH1 MAC: $VETH1_MAC"

log "attaching loader (generator=$GENERATOR filter=${FILTER_DPORTS:-none})"
XDP_RECON_IFACE="$VETH1" \
XDP_RECON_OUT="$EVIDENCE/loader-counters.json" \
XDP_RECON_DROP_PORTS="$FILTER_DPORTS" \
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

START_EPOCH=$(date +%s)
case "$GENERATOR" in
    pktgen)    run_pktgen ;;
    mausezahn) run_mausezahn ;;
esac
END_EPOCH=$(date +%s)
ELAPSED=$((END_EPOCH - START_EPOCH))
if [[ $ELAPSED -lt $MIN_DURATION ]]; then
    log "warning: run completed in ${ELAPSED}s, below ${MIN_DURATION}s minimum"
fi

date +%s%N > "$EVIDENCE/test-end.txt"

# Capture after-state BEFORE detaching the loader. Once the program
# exits, the map disappears from bpftool's view.
bpftool prog show id "$PROG_ID" -j > "$EVIDENCE/prog-runtime.json" 2>/dev/null || true
capture_after

log "stopping loader so map counters settle"
kill -INT "$LOADER_PID"
wait "$LOADER_PID" 2>/dev/null || true
LOADER_PID=

# Compute expected_drops for the reconciler.
# Filter contract: if FILTER_DPORTS is set and includes the TCP_DPORT
# used by mausezahn, all generated packets are expected to be dropped.
expected_drops=0
if [[ -n "$FILTER_DPORTS" && "$GENERATOR" == "mausezahn" ]]; then
    if [[ ",$FILTER_DPORTS," == *",$TCP_DPORT,"* ]]; then
        expected_drops=$PKT_COUNT
    fi
fi
echo "$expected_drops" > "$EVIDENCE/expected_drops.txt"
echo "$GENERATOR" > "$EVIDENCE/generator-name.txt"

log "reconciliation"
if python3 "$(dirname "$0")/scripts/reconcile.py" "$EVIDENCE" > "$EVIDENCE/results.md"; then
    RECONCILE_PASSED=1
else
    RECONCILE_PASSED=0
fi
cat "$EVIDENCE/results.md"

if [[ $CHAOS_LOSS_PCT -gt 0 ]]; then
    if [[ $RECONCILE_PASSED -eq 1 ]]; then
        die "chaos mode injected loss but reconciler reported PASS; harness bug"
    fi
    log "chaos mode: reconciler correctly reported FAIL"
    exit 0
else
    exit $((RECONCILE_PASSED == 1 ? 0 : 1))
fi
