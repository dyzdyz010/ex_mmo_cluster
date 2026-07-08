# 涌现光学 增量1:热致白炽(emissive 从温度黑体派生)

日期:2026-06-21
状态:决策稿(待逐 step 实现)
范围:`clients/bevy_client`(纯客户端,零服务端改动)

## 背景与拍板

用户洞察:**把「光」做成涌现的一部分**——光从物理态派生,而非按 material id 硬编码
(否则同 R9a「powered_heater 凭空发热」之误)。增量1=**热致白炽(incandescence)**:
任何 cell 温度过 Draper 点(固体开始可见发光,~525℃)就自发光,颜色随温度爬
暗红→橙→黄→白(黑体辐射)。统一:加热的铁、熔铁、熔岩、余烬、燃烧的木、被 I²R 烤热的
power_block——全因「热」发光,零 per-material 授权。power_block 只在真热/通电时发光
(比 web 永远金色更原理一致,有意偏离)。

用户拍板:**纯客户端**(温度场 0x73 已流式下行,client field store 已持有),复用 field overlay
基建,additive emissive 层(always-on,非 debug overlay)。吃掉原 #24 power_block/ember/
熔铁/熔岩辉光目标(它们因热发光)。

## 关键事实(复用基建)

- `VoxelFieldStore`(field_view.rs)已持温度场快照,`take_dirty` 标脏。**坑:overlay 已 drain
  take_dirty**——incandescence 不能也 drain(mem::take 争用,同 discharge/heat_smoke 教训)→
  加**独立 incandescence_dirty 通道**(apply_snapshot/destroy 同时标,take_incandescence_dirty 漏)。
- overlay 渲染机制:per-cell marker cube(`overlay_from_values`,私有)→ baked marker id →
  `build_mesh_with_colors(data, color_fn)` 映 id→色。incandescence 复用此核(需 pub(crate)),
  自带 blackbody 色函数。
- `FieldDepthDisable` 扩展(pub(crate))+ `FieldOverlayMaterial` 类型已注册 MaterialPlugin;
  incandescence 复用**同类型**material 但 `AlphaMode::Add`(加性辉光)而非 Blend。
  depth-disable 必需:marker inset 在 cell 内、被自身不透明面遮挡(同 overlay 理由)。

## 设计

### incandescence.rs(纯)
- `DRAPER_C = 525.0`(发光起点)、`WHITE_HOT_C ≈ 2200.0`(饱和白)、`INCANDESCENCE_BUCKET_COUNT = 12`、
  `INCANDESCENCE_MATERIAL_BASE = 10_400`(保留 marker id 段,避开 heat 10000/ionization 10300)。
- `blackbody_color(temp_c) -> Option<[f32;3]>`:< Draper → None;否则按归一 t∈[0,1] 在黑体锚点
  (暗红→红→橙→黄→白)分段 lerp。RGB 量级即亮度(additive 下越热越亮)。
- `incandescence_material(temp_c) -> Option<u32>`:温度→bucket→marker id。
- `incandescence_color(id) -> [f32;4]`:marker id→bucket 代表温度的 blackbody RGB(alpha=1,additive)。
- `incandescence_mesh(field, voxel_size) -> ChunkMeshData`:复用 `overlay_from_values` +
  incandescence_material(无温度层 mask → 空)。
- 单测:Draper 阈下 None、阈上 Some;温度升 → 色向白移 + 亮度增(R+G+B 单调增);bucket 单调;
  mesh 仅含过阈 cell。

### incandescence_render.rs(Bevy 适配器)
- `IncandescencePlugin`:Startup 建 additive emissive material(unlit + AlphaMode::Add +
  FieldDepthDisable);Render 系统 drain **incandescence_dirty** → 每温度区 incandescence_mesh →
  `build_mesh_with_colors(data, incandescence_color)` → upsert/despawn emissive 实体(键 region_id,
  无温度/过阈空 → despawn)。镜像 VoxelFieldRenderPlugin 但加性辉光 + 独立通道 + 独立 entity map。
- 接入 BevyClientPlugins。

### Layer-3 像素测试
- 热区(如 900℃)渲出暖辉光(R 主导、加性提亮);更热区(如 1800℃)渲得更白更亮
  (G/B 通道随温度升、整体更亮)——证辉光从温度涌现、色随温度移。

## 测试计划
- incandescence 纯单测(Draper 阈、色/亮度单调、bucket、mesh 过阈)。
- incandescence_render 单测(热区生辉光实体、冷区/destroy despawn、独立通道不与 overlay 争用)。
- Layer-3 像素:暖辉光 + 温度→更白更亮。
- 全 Layer-3 套件单线程回归。

## 逐 step 提交
1. incandescence.rs 纯核心 + field_view pub(crate) 暴露 + store incandescence_dirty 通道 + 单测
2. incandescence_render.rs 适配器 + 接入 + 单测
3. Layer-3 像素测试 + 全套单线程回归

不 push;cargo 在 clients/bevy_client;Layer-3 须 --test-threads=1(见 layer3-gpu-pixel-harness)。

## 后续增量(本稿外)
化学/放电发光(burning tag→火焰光)、光成真机制(影响可见度/感光元件/光合)。
