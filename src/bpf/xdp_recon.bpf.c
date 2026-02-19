// SPDX-License-Identifier: GPL-2.0
//
// xdp-recon: ingress XDP program. Counts every received packet, parses
// Ethernet, IPv4, TCP, and always returns XDP_PASS so the host stack
// still drives the link. Counter semantics match the test contract:
//
//   rx_total            every packet
//   rx_parsed_ipv4      IPv4 but not TCP
//   rx_parsed_tcp       IPv4 and TCP
//   parse_errors        truncated, non IPv4, or IPv4 with options
//   xdp_pass_count      every packet
//   xdp_drop_count      never; kept for schema symmetry

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

struct {
    __uint(type, BPF_MAP_TYPE_PERCPU_ARRAY);
    __uint(max_entries, STAT_MAX);
    __type(key, __u32);
    __type(value, __u64);
} xdp_stats SEC(".maps");

static __always_inline void stat_inc(__u32 idx)
{
    __u64 *v = bpf_map_lookup_elem(&xdp_stats, &idx);
    if (v)
        (*v)++;
}

static __always_inline int parse_outcome(void *data, void *data_end)
{
    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return STAT_PARSE_ERRORS;

    if (eth->h_proto != bpf_htons(ETH_P_IP))
        return STAT_PARSE_ERRORS;

    struct iphdr *ip = (void *)(eth + 1);
    if ((void *)(ip + 1) > data_end)
        return STAT_PARSE_ERRORS;

    // pktgen does not emit IP options. Restricting ihl to 5 gives the
    // verifier a constant offset to the TCP header.
    if (ip->ihl != 5)
        return STAT_PARSE_ERRORS;

    if (ip->protocol != IPPROTO_TCP)
        return STAT_RX_PARSED_IPV4;

    struct tcphdr *tcp = (struct tcphdr *)(ip + 1);
    if ((void *)(tcp + 1) > data_end)
        return STAT_PARSE_ERRORS;

    return STAT_RX_PARSED_TCP;
}

SEC("xdp")
int xdp_recon(struct xdp_md *ctx)
{
    void *data_end = (void *)(long)ctx->data_end;
    void *data = (void *)(long)ctx->data;

    stat_inc(STAT_RX_TOTAL);
    stat_inc(parse_outcome(data, data_end));
    stat_inc(STAT_XDP_PASS_COUNT);

    return XDP_PASS;
}

char _license[] SEC("license") = "GPL";
