use anyhow::{anyhow, bail, Context, Result};
use libbpf_rs::skel::{OpenSkel, SkelBuilder};
use libbpf_rs::{Map, MapFlags};
use std::fs;
use std::io::Write;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

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

fn dump_counters(map: &Map, out: Option<&str>) -> Result<()> {
    let mut json = String::from("{\n");
    for (i, (name, idx)) in COUNTERS.iter().enumerate() {
        let v = read_counter(map, *idx)?;
        let sep = if i + 1 == COUNTERS.len() { "" } else { "," };
        json.push_str(&format!("  \"{name}\": {v}{sep}\n"));
    }
    json.push_str("}\n");
    match out {
        Some(p) => fs::write(p, json).with_context(|| format!("write {p}"))?,
        None => std::io::stdout().write_all(json.as_bytes())?,
    }
    Ok(())
}

fn main() -> Result<()> {
    let ifname = std::env::var("XDP_RECON_IFACE")
        .context("set XDP_RECON_IFACE to an interface name, e.g. veth1")?;
    let out_path = std::env::var("XDP_RECON_OUT").ok();

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

    eprintln!("attached xdp_recon to {ifname} (ifindex={ifindex}); waiting for SIGINT");

    let running = Arc::new(AtomicBool::new(true));
    let r = running.clone();
    ctrlc::set_handler(move || {
        r.store(false, Ordering::SeqCst);
    })
    .context("install signal handler")?;

    while running.load(Ordering::SeqCst) {
        std::thread::sleep(std::time::Duration::from_millis(200));
    }

    eprintln!("draining counters");
    let maps = skel.maps();
    dump_counters(&maps.xdp_stats(), out_path.as_deref())?;
    eprintln!("detaching");
    Ok(())
}
