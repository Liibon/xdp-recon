## counters

```
generator                    pktgen
offered_packets              10000000
veth0_tx_packets             10000000
veth1_rx_packets             10000000
veth1_rx_dropped             0
xdp_rx_total                 10000000
xdp_pass_count               10000000
xdp_drop_count               0
xdp_parse_errors             0
expected_drops               0
ringbuf_lost_events          0
```

## pass conditions

```
offered_packets  == veth0_tx_packets       PASS
veth0_tx_packets == xdp_rx_total           PASS
xdp_pass + xdp_drop == xdp_rx_total        PASS
xdp_drop_count   == expected_drops         PASS
xdp_parse_errors == 0                      PASS
overall                                    PASS
mean_runtime_ns                            23.84
ringbuf_lost_events                        0
```
