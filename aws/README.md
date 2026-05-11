# AWS EC2 ENI corroboration

Two t4g instances in the same VPC. Target attaches XDP to its primary
ENI; generator sends sustained TCP SYN traffic across the VPC.
CloudWatch observes the result from outside the VM.

## What you need

- AWS account with EC2 + CloudWatch permissions
- AWS CLI configured (`aws configure`)
- An SSH key pair in the region you launch in

## Target setup

Cloud-init runs `target-userdata.sh` on first boot, which:

- installs clang, libbpf-dev, build tools, netsniff-ng
- installs rustup as the `ubuntu` user
- clones this repo and `cargo build --release`
- sets MTU on the primary ENI to 1500 (required for generic XDP on ENA
  without multi-buffer support)
- enables `kernel.bpf_stats_enabled`

If cloud-init fails (it can, depending on shell quirks), finish manually:

```
sudo apt-get install -y clang libbpf-dev libelf-dev zlib1g-dev pkg-config build-essential ethtool iproute2 python3 git curl netsniff-ng
curl --proto =https --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --profile minimal
source ~/.cargo/env
rustup component add rustfmt
git clone https://github.com/Liibon/xdp-packet-drop-reconciliation.git
cd xdp-packet-drop-reconciliation
cargo build --release
```

## Attach XDP in generic mode

The libbpf-rs link-based attach was rejected by the ENA driver on this
kernel. Attach via `ip link` in generic mode instead, using a standalone
BPF object compiled with clang:

```
INC=$(dpkg-architecture -q DEB_HOST_MULTIARCH)
clang -O2 -g -target bpf -I/usr/include/$INC \
  -c src/bpf/xdp_recon.bpf.c -o /tmp/xdp_recon.bpf.o
sudo ip link set dev ens5 xdpgeneric obj /tmp/xdp_recon.bpf.o sec xdp
```

## PASS window

No drop port configured. Kernel emits TCP RSTs to closed-port SYNs:

```
# target: XDP attached, no filter set
sudo bpftool map dump name drop_ports | head -3   # all zeros

# generator
sudo nping --tcp -p 5000 --flags syn --rate 20000 --count 3600000 <TARGET_PRIVATE_IP>
```

CloudWatch: `NetworkIn` and `NetworkOut` both elevated and roughly equal.

## DROP window

```
# target: turn on the filter (key = u32 5000 little-endian)
sudo bpftool map update name drop_ports key hex 88 13 00 00 value hex 01

# generator (same command)
sudo nping --tcp -p 5000 --flags syn --rate 20000 --count 3600000 <TARGET_PRIVATE_IP>
```

CloudWatch: `NetworkIn` stays lit, `NetworkOut` collapses to baseline
because XDP_DROP frees the SYN before TCP can RST it.

## Dashboard

`dashboard.json` is the CloudWatch dashboard body used for the
screenshot in `docs/aws-cloudwatch-corroboration.png`. Substitute your
target's `InstanceId` and the four window timestamps, then:

```
aws cloudwatch put-dashboard \
  --dashboard-name xdp-recon-eni-corroboration \
  --dashboard-body file://dashboard.json
```

## Teardown

```
sudo ip link set dev ens5 xdpgeneric off
aws ec2 terminate-instances --instance-ids <target> <generator>
aws cloudwatch delete-dashboards --dashboard-names xdp-recon-eni-corroboration
```

CloudWatch retains 1-minute metrics for 15 days after the instance is
terminated, so the dashboard graph stays viewable as long as you don't
delete it.
