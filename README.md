# xdp-recon

XDP packet drop reconciliation test harness. Reconciles three counter
sources across a veth pair: pktgen TX, kernel link stats, and a per CPU
BPF map.
