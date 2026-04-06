## counters

```
generator                    pktgen
offered_packets              1000000
veth0_tx_packets             990020
veth1_rx_packets             990020
veth1_rx_dropped             0
xdp_rx_total                 990020
xdp_pass_count               990020
xdp_drop_count               0
xdp_parse_errors             0
expected_drops               0
ringbuf_lost_events          0
```

## pass conditions

```
offered_packets  == veth0_tx_packets       FAIL
veth0_tx_packets == xdp_rx_total           PASS
xdp_pass + xdp_drop == xdp_rx_total        PASS
xdp_drop_count   == expected_drops         PASS
xdp_parse_errors == 0                      PASS
overall                                    FAIL
mean_runtime_ns                            23.58
ringbuf_lost_events                        0
```
