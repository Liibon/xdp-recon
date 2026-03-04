use anyhow::{Context, Result};
use libbpf_rs::skel::{OpenSkel, SkelBuilder};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

mod skel {
    #![allow(clippy::all)]
    include!(concat!(env!("OUT_DIR"), "/xdp_recon.skel.rs"));
}
use skel::*;

fn main() -> Result<()> {
    let ifname = std::env::var("XDP_RECON_IFACE")
        .context("set XDP_RECON_IFACE to an interface name, e.g. veth1")?;

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

    eprintln!("detaching");
    Ok(())
}
