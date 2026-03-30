## counters

```
offered_packets              1000000
veth0_tx_packets             989998
veth1_rx_packets             989998
veth1_rx_dropped             0
xdp_rx_total                 989998
xdp_parse_errors             0
ringbuf_lost_events          0
```

## pass conditions

```
offered_packets  == veth0_tx_packets       FAIL
veth0_tx_packets == veth1_rx_packets       PASS
veth1_rx_packets == xdp_rx_total           PASS
veth1_rx_dropped == 0                      PASS
xdp_parse_errors == 0                      PASS
overall                                    FAIL
mean_runtime_ns                            24.66
ringbuf_lost_events                        0
```
