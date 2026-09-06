# Voxim 在线世界生成内核

`world.rs` 移植 Voxim `VoxelWorldGen.cpp` 的列画像、气候、洞口、洞穴、矿脉和列聚合金字塔。
`noise.rs` 保留整数 wrapping、浮点运算顺序和逐 octave 严格上界；`skin.rs` 保留严格多数占用、
非零优先材质众数和六向表皮 mip，并写出既有 `SerializeRegionBody` 的 cells + CSR。
数据始终为 canonical Y-up，66³ 含 ring，原点为 `(region × 64 − 1) × 2^level`。
粗层先证明空气/均匀岩带/无洞穴与矿脉，再递归剩余子树，不展开整个 L5 体积。

`Elixir.VoxelRegion.Native.generate_region/3` 使用 Rustler 0.37.3 的 `DirtyCpu` 调度，
参数为 level（0–5）、XYZ 三元组和八元组：
`{seed, min_height, sea_level, max_height, soil_depth, lowland_amplitude, mountain_amplitude, cave_max_depth}`。
结果直接是未压缩 binary body；MapHashes 写空，由现有 UE codec 重建。
NIF 只处理生成；编辑、seq、持久化和订阅仍由 Elixir World 拥有。

`kernel_identity/0` 返回 `worldgen_density_v3@1+sha256:<64hex>`。
构建时对 NIF 入口、三个纯模块与构建脚本的路径及归一换行源码做 SHA256；服务端将完整 identity 纳入 content_version。
算法与常量变化会自动切换缓存身份。该源码身份也包含注释和测试变动，宁可重新生成也不会复用旧基底。
Rustler 调度依据为仓库已有 `scene_server/native/world_gen_noise/src/lib.rs` 同版本用法，
以及本机锁定版本 `rustler-0.37.3` 的 `types/tuple.rs`：默认 tuple Decoder 仅到七项，八项在 NIF 边界解码一次。

验证：

```powershell
cargo test --manifest-path apps/voxel_region/native/voxim_worldgen/Cargo.toml
$env:VOXIM_ORACLE_MANIFEST = '<Voxim>/Saved/S4Oracle/manifest.json'
cargo test --release --manifest-path apps/voxel_region/native/voxim_worldgen/Cargo.toml --test oracle -- --ignored --nocapture
```

oracle 由 UE Automation 导出，manifest 每项提供 file/config/level/coord。
比较全部 66³ 材质，以及两侧表皮记录并集的六向 Id 和逐 texel 内容；不依赖 CSR 字典顺序或 hash。
测试输出每个 fixture 的生成毫秒与 body 字节数。默认测试同时锁定深层基岩、全部 256 个占用组合与噪声盒上界。
