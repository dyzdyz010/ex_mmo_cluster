//! 将实际内核源码绑定到服务端内容身份，修改常量或算法会自动使旧缓存失效。
use sha2::{Digest, Sha256};
fn main() {
    let mut hash = Sha256::new();
    for file in [
        "build.rs",
        "src/lib.rs",
        "src/noise.rs",
        "src/skin.rs",
        "src/world.rs",
    ] {
        println!("cargo:rerun-if-changed={file}");
        let source = std::fs::read_to_string(file).unwrap().replace("\r\n", "\n");
        hash.update(file.as_bytes());
        hash.update([0]);
        hash.update(source.as_bytes());
    }
    println!(
        "cargo:rustc-env=VOXIM_KERNEL_IDENTITY=worldgen_density_v3@1+sha256:{:x}",
        hash.finalize()
    );
}
