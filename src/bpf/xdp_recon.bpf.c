// SPDX-License-Identifier: GPL-2.0
//
// xdp-recon: per CPU stats map and XDP_PASS skeleton. The full parser
// and ringbuf event submission come in later revisions.

#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>

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

SEC("xdp")
int xdp_recon(struct xdp_md *ctx)
{
    stat_inc(STAT_RX_TOTAL);
    stat_inc(STAT_XDP_PASS_COUNT);
    return XDP_PASS;
}

char _license[] SEC("license") = "GPL";
