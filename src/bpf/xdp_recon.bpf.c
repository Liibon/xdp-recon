// SPDX-License-Identifier: GPL-2.0
//
// xdp-recon: ingress XDP program. Counts every received packet, parses
// Ethernet, IPv4, TCP, applies a per-destination-port drop filter via
// a userspace-populated array map, optionally submits a metadata event
// to userspace via ringbuf, and returns XDP_PASS or XDP_DROP. Counter
// semantics:
//
//   rx_total            every packet
//   rx_parsed_ipv4      IPv4 but not TCP
//   rx_parsed_tcp       IPv4 and TCP
//   parse_errors        truncated, non IPv4, or IPv4 with options
//   xdp_pass_count      packet was returned XDP_PASS
//   xdp_drop_count      packet was returned XDP_DROP by the filter
//   events_submitted    ringbuf reserve and submit both succeeded
//   events_failed       ringbuf reserve returned NULL
//
// Filter contract: the BPF_MAP_TYPE_ARRAY drop_ports is indexed by L4
// destination port (key __u32). A non-zero byte at that index causes
// XDP_DROP for TCP packets only. Map is array-backed and preallocated;
// kernel allocates 8-byte-aligned slots, so the actual map footprint
// is on the order of 512 KiB.

#include <linux/bpf.h>
#include <linux/if_ether.h>
#include <linux/ip.h>
#include <linux/tcp.h>
#include <linux/in.h>
#include <bpf/bpf_helpers.h>
#include <bpf/bpf_endian.h>

#define STAT_RX_TOTAL          0
#define STAT_RX_PARSED_IPV4    1
#define STAT_RX_PARSED_TCP     2
#define STAT_PARSE_ERRORS      3
#define STAT_XDP_PASS_COUNT    4
#define STAT_XDP_DROP_COUNT    5
#define STAT_EVENTS_SUBMITTED  6
#define STAT_EVENTS_FAILED     7
#define STAT_MAX               8

struct flow_event {
    __u64 ts_ns;
    __u32 saddr;
    __u32 daddr;
    __u16 sport;
    __u16 dport;
    __u16 pkt_len;
    __u16 _pad;
};

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, STAT_MAX);
    __type(key, __u32);
    __type(value, __u64);
} xdp_stats SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_RINGBUF);
    __uint(max_entries, 1 << 20); // 1 MiB
} events SEC(".maps");

struct {
    __uint(type, BPF_MAP_TYPE_ARRAY);
    __uint(max_entries, 65536);
    __type(key, __u32);
    __type(value, __u8);
} drop_ports SEC(".maps");

static __always_inline void stat_inc(__u32 idx)
{
    __u64 *v = bpf_map_lookup_elem(&xdp_stats, &idx);
    if (v)
        (*v)++;
}

static __always_inline int parse_outcome(void *data, void *data_end,
                                         struct iphdr **ip_out,
                                         struct tcphdr **tcp_out)
{
    *ip_out = NULL;
    *tcp_out = NULL;

    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return STAT_PARSE_ERRORS;

    if (eth->h_proto != bpf_htons(ETH_P_IP))
        return STAT_PARSE_ERRORS;

    struct iphdr *ip = (void *)(eth + 1);
    if ((void *)(ip + 1) > data_end)
        return STAT_PARSE_ERRORS;

    if (ip->ihl != 5)
        return STAT_PARSE_ERRORS;

    *ip_out = ip;

    if (ip->protocol != IPPROTO_TCP)
        return STAT_RX_PARSED_IPV4;

    struct tcphdr *tcp = (struct tcphdr *)(ip + 1);
    if ((void *)(tcp + 1) > data_end)
        return STAT_PARSE_ERRORS;

    *tcp_out = tcp;
    return STAT_RX_PARSED_TCP;
}

static __always_inline void submit_event(struct xdp_md *ctx,
                                         struct iphdr *ip,
                                         struct tcphdr *tcp)
{
    struct flow_event *ev = bpf_ringbuf_reserve(&events, sizeof(*ev), 0);
    if (!ev) {
        stat_inc(STAT_EVENTS_FAILED);
        return;
    }
    ev->ts_ns = bpf_ktime_get_ns();
    ev->saddr = ip->saddr;
    ev->daddr = ip->daddr;
    ev->sport = bpf_ntohs(tcp->source);
    ev->dport = bpf_ntohs(tcp->dest);
    ev->pkt_len = (__u16)(ctx->data_end - ctx->data);
    ev->_pad = 0;
    bpf_ringbuf_submit(ev, 0);
    stat_inc(STAT_EVENTS_SUBMITTED);
}

SEC("xdp")
int xdp_recon(struct xdp_md *ctx)
{
    void *data_end = (void *)(long)ctx->data_end;
    void *data = (void *)(long)ctx->data;
    struct iphdr *ip = NULL;
    struct tcphdr *tcp = NULL;

    stat_inc(STAT_RX_TOTAL);

    int outcome = parse_outcome(data, data_end, &ip, &tcp);
    stat_inc(outcome);

    if (outcome == STAT_RX_PARSED_TCP) {
        __u32 dport = bpf_ntohs(tcp->dest);
        __u8 *should_drop = bpf_map_lookup_elem(&drop_ports, &dport);
        if (should_drop && *should_drop) {
            stat_inc(STAT_XDP_DROP_COUNT);
            return XDP_DROP;
        }
        submit_event(ctx, ip, tcp);
    }

    stat_inc(STAT_XDP_PASS_COUNT);
    return XDP_PASS;
}

char _license[] SEC("license") = "GPL";
