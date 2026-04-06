use anyhow::{anyhow, bail, Context, Result};
use libbpf_rs::skel::{OpenSkel, SkelBuilder};
use libbpf_rs::{Map, MapFlags, RingBufferBuilder};
use std::fs;
use std::io::Write;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

mod skel {
    #![allow(clippy::all)]
    include!(concat!(env!("OUT_DIR"), "/xdp_recon.skel.rs"));
}
use skel::*;

const COUNTERS: &[(&str, u32)] = &[
    ("rx_total", 0),
    ("rx_parsed_ipv4", 1),
    ("rx_parsed_tcp", 2),
    ("parse_errors", 3),
    ("xdp_pass_count", 4),
    ("xdp_drop_count", 5),
    ("events_submitted", 6),
    ("events_failed", 7),
];

fn read_counter(map: &Map, idx: u32) -> Result<u64> {
    let key = idx.to_ne_bytes();
    let per_cpu = map
        .lookup_percpu(&key, MapFlags::ANY)
        .with_context(|| format!("lookup_percpu idx {idx}"))?
        .ok_or_else(|| anyhow!("missing counter idx {idx}"))?;
    let mut sum: u64 = 0;
    for cpu in per_cpu {
        if cpu.len() < 8 {
            bail!("per cpu value too short: {} bytes", cpu.len());
        }
        let bytes: [u8; 8] = cpu[..8].try_into().expect("8 bytes");
        sum = sum.saturating_add(u64::from_ne_bytes(bytes));
    }
    Ok(sum)
}

fn dump_counters(
    map: &Map,
    events_received: u64,
    ringbuf_lost_events: u64,
    out: Option<&str>,
) -> Result<()> {
    let mut json = String::from("{\n");
    for (name, idx) in COUNTERS {
        let v = read_counter(map, *idx)?;
        json.push_str(&format!("  \"{name}\": {v},\n"));
    }
    json.push_str(&format!("  \"events_received\": {events_received},\n"));
    json.push_str(&format!("  \"ringbuf_lost_events\": {ringbuf_lost_events}\n"));
    json.push_str("}\n");
    match out {
        Some(p) => fs::write(p, json).with_context(|| format!("write {p}"))?,
        None => std::io::stdout().write_all(json.as_bytes())?,
    }
    Ok(())
}

fn populate_drop_ports(map: &Map, ports_csv: &str) -> Result<usize> {
    let mut populated = 0;
    for piece in ports_csv.split(',') {
        let trimmed = piece.trim();
        if trimmed.is_empty() {
            continue;
        }
        let port: u16 = trimmed
            .parse()
            .with_context(|| format!("parse port: {trimmed}"))?;
        let key: u32 = port as u32;
        map.update(&key.to_ne_bytes(), &[1u8], MapFlags::ANY)
            .with_context(|| format!("update drop_ports[{port}]"))?;
        populated += 1;
    }
    Ok(populated)
}

fn main() -> Result<()> {
    let ifname = std::env::var("XDP_RECON_IFACE")
        .context("set XDP_RECON_IFACE to an interface name, e.g. veth1")?;
    let out_path = std::env::var("XDP_RECON_OUT").ok();
    let drop_ports_csv = std::env::var("XDP_RECON_DROP_PORTS").unwrap_or_default();

    let ifindex = nix::net::if_::if_nametoindex(ifname.as_str())
        .with_context(|| format!("if_nametoindex({ifname})"))?
        as i32;

    let skel_builder = XdpReconSkelBuilder::default();
    let open_skel = skel_builder.open().context("open skel")?;
    let mut skel = open_skel.load().context("load skel")?;

    let _link = skel
        .progs_mut()
        .xdp_recon()
        .attach_xdp(ifindex)
        .with_context(|| format!("attach xdp to ifindex {ifindex}"))?;

    eprintln!("attached xdp_recon to {ifname} (ifindex={ifindex})");

    let maps = skel.maps();
    let events_map = maps.events();
    let stats_map = maps.xdp_stats();
    let drop_ports_map = maps.drop_ports();

    if !drop_ports_csv.is_empty() {
        let n = populate_drop_ports(&drop_ports_map, &drop_ports_csv)?;
        eprintln!("filter: drop_ports populated with {n} entries ({drop_ports_csv})");
    }

    let received = Arc::new(AtomicU64::new(0));
    let received_cb = received.clone();

    let mut rb_builder = RingBufferBuilder::new();
    rb_builder
        .add(&events_map, move |_data: &[u8]| {
            received_cb.fetch_add(1, Ordering::Relaxed);
            0
        })
        .context("ringbuf add events")?;
    let rb = rb_builder.build().context("ringbuf build")?;

    let running = Arc::new(AtomicBool::new(true));
    let r = running.clone();
    ctrlc::set_handler(move || {
        r.store(false, Ordering::SeqCst);
    })
    .context("install signal handler")?;

    eprintln!("waiting for SIGINT");
    while running.load(Ordering::SeqCst) {
        let _ = rb.poll(Duration::from_millis(200));
    }

    eprintln!("draining ringbuf");
    let _ = rb.consume();

    // BPF_MAP_TYPE_RINGBUF has no kernel side lost sample callback (unlike
    // perfbuf). The gap between BPF submitted and userspace received is
    // the best userspace signal we have, so derive ringbuf_lost_events
    // from that delta. BPF side reserve failures are tracked separately
    // in events_failed.
    let events_received = received.load(Ordering::Relaxed);
    let events_submitted = read_counter(&stats_map, 6)?;
    let ringbuf_lost_events = events_submitted.saturating_sub(events_received);

    eprintln!("draining counters");
    dump_counters(&stats_map, events_received, ringbuf_lost_events, out_path.as_deref())?;
    eprintln!("detaching");
    Ok(())
}
