fn main() {
    // Give the Linux shared library a SONAME so dependents record `libiroh_shim.so`
    // (found via rpath) instead of the absolute build path.
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("linux") {
        println!("cargo:rustc-cdylib-link-arg=-Wl,-soname,libiroh_shim.so");
    }
}
