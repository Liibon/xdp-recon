use libbpf_cargo::SkeletonBuilder;
use std::env;
use std::path::PathBuf;
use std::process::Command;

const SRC: &str = "src/bpf/xdp_recon.bpf.c";

fn multiarch_triple() -> Option<String> {
    let out = Command::new("dpkg-architecture")
        .args(["-q", "DEB_HOST_MULTIARCH"])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let s = String::from_utf8(out.stdout).ok()?.trim().to_string();
    if s.is_empty() {
        None
    } else {
        Some(s)
    }
}

fn main() {
    let mut out = PathBuf::from(env::var_os("OUT_DIR").expect("OUT_DIR not set"));
    out.push("xdp_recon.skel.rs");

    let mut builder = SkeletonBuilder::new();
    builder.source(SRC);

    // On Debian and Ubuntu the kernel uapi headers under linux/ pull in
    // <asm/types.h>, which lives in a multiarch path like
    // /usr/include/aarch64-linux-gnu. clang -target bpf does not see
    // that path by default, so add it explicitly.
    if let Some(triple) = multiarch_triple() {
        builder.clang_args([format!("-I/usr/include/{triple}")]);
    }

    builder
        .build_and_generate(&out)
        .expect("failed to build BPF skeleton");

    println!("cargo:rerun-if-changed={SRC}");
}
