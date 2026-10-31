# Voxim 在线世界生成内核

`world.rs` 移植 Voxim `VoxelWorldGen.cpp` 的列画像、气候、洞口、洞穴、矿脉和列聚合金字塔。
`noise.rs` 保留整数 wrapping、浮点运算顺序和逐 octave 严格上界；`skin.rs` 实现全局系统功能 `ReduceCellV2`：
L1 花草先过滤，旧严格多数和 L1 树干规则优先；旧主体为空时，仅保留一个完整水平干实体半层且另一半全空的薄片。
排除液体、透明、叶/花草、树干、植物装饰，与正式 `VoxelMaterialCatalog.lod_dry_sheet?/1` 及客户端目录逐项一致。
非零众数平局取最小 ID；六向表皮仍按 `ReduceSkinsV1`，不从表皮反推实体。写出既有 `SerializeRegionBody` 的 cells + CSR。
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
F2a 手算样本在 `skin.rs` 与 `test/reducer_v2_test.exs` 各自冻结，含两种 Y 相位、四角排除、旧规则优先级、
Y504–507/负 XYZ 的 16 m² 递归薄片；Elixir 另经 World 编辑、payload 与文件恢复检验。旧 UE 粗 oracle 须由 V2 重新导出。
内核源码身份会变化；pinned 世界不自动换目录，因此上线须重建 baseline/overlay 粗层及客户端派生缓存，不能只替换 NIF。

## 新世界权威气候取样

`climate.rs`拥有生成覆盖层与物理气候共用的 `temperature_score`、雪线`.10`和暖区边界`.22`。
`ground`与 `Native.climate_samples/3` 调用同一分数规则，不在Elixir复制噪声或按当前材料推断气候。
取样是同序纯XYZ函数；每点两个noise2 octave，不计算列高/完整region，不访问页面或运行配置。

`ClimateConfig::new`接纳显式 `{cold_kelvin, warm_kelvin, sample_height_offset_m, wind_mps}`，无Kelvin默认值。
原生边界一次拒绝非法参数或i32高度算术溢出；新source v1固定以格上表面（偏移1m）对应生成雪的height参考。
批次DirtyCpu只负责调度，批次边界不改变每个点的值。温度差不产生绝热边界。

生成store通过 `GeneratedStore.climate_source/2`构造不可变 `Climate.Source`；其schema、world CV、kernel/config
与作者参数共同确定source摘要，`Climate.bind/2` / `at_many/2`只消费已接纳版本。详见
`lib/voxel_region/climate/README.md`。已有源的空间样本可在同一版本有效期复用，continuation不读取新目录。

此源码增加会改变 `build.rs` 的kernel身份，旧pinned manifest仍必须精确匹配expected identity。
新世界独立descriptor可接纳新内核；旧世界需离线副本、明确cut及背景热参考账的迁移，不自动覆盖旧清单/存档。
sampler可用不等于初态活动登记完成：自然温度梯度仍可传热，发布owner须主动登记真实前沿。

最小验证为 `tests/climate_samples.rs`、`tests/climate_initialization.rs`及Elixir `climate_source_test.exs`。
后者包含不读取生成页的新世界manifest/source入口；有限patch包含真实六邻初始通量与有限潜热账，
不代表正式World接纳、玩家入口、冷恢复、整世界初始化成本或旧世界迁移已验收。

有限patch的ignored验收必须显式提供 `VOXIM_CLIMATE_BASELINE`（既有改前两份body）和
`VOXIM_CLIMATE_OUTPUT`（新的独占候选输出目录）。缺文件/未启比较直接失败，不自动创建旧基底；
验收runner记录两份old/new SHA256、字节数与 `bytes_equal`，不能只用单测通过推断比较已启用。
