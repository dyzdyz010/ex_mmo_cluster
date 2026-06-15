# bevy 客户端转主线 + 目标架构决策稿（2026-06-15）

- **状态**：定稿（2026-06-15 用户拍板：**首役 = 地基优先**；**meshing = 逐面剔除优先**，greedy 作 fast-follow）
- **决策人**：用户（2026-06-15「以 bevy_client 为后续主攻客户端，所有功能在 bevy 侧实现，设计合理可扩展高性能架构，参考 web_client」）
- **本决策稿是主记录**（跨仓 `TheWorldBook` 在本环境不可达，待其可用再镜像单页摘要）
- 调研依据：5 路并行 survey（bevy 现状 / web 可借鉴 / 线协议+体素快照 / 既有客户端文档 / 视频渲染技术→Bevy 0.18 映射），见本仓 session 工作流产物。

---

## 0. 决策摘要（TL;DR）

1. **`bevy_client` 转主线；`web_client` 降为参考 oracle**——撤销 2026-05-13「解冻 web_client」决策（当时定 web 主线 / bevy 参考），方向反转。
2. **bevy 现状**：网络 / 预测 / 插件**骨架优秀**（保留），但三处硬伤——
   - 体素渲染是 **naive per-voxel cube entity**（无 meshing / atlas / 面剔除，每帧全量 re-diff，refined cell 爆炸到 512 entity）；
   - 体素世界**纯离线本地，无任何服务器同步**；
   - 落后 web **一整个 voxel-authority gameplay 层**（fields / electric / thermal / power-block / ObjectStateDelta / debris / prefab-v2），自 2026-05-13 起 web 26 commits、bevy ≈0。
3. **三条主战线**：① 服务器体素同步 + chunk meshing 重写（P0 地基，让 bevy 真正渲染权威体素）；② gameplay 层补齐到 web parity；③ 渲染 / 视觉路线图（很多 Bevy 已内置 / 已开）。
4. **从 web 直接搬**：wire codec 1:1 纪律 + **golden-fixture 跨语言 parity 测试**（最高杠杆）+ 严格 server-authority + dirty-flag 异步 meshing + observe/CLI=测试面。

---

## 1. 背景与方向反转

- 服务器侧「涌现反应层」R1–R8 已告一段落（相变 / 燃烧 / 电→火 / 电路驱动负载 / 放电毁块，回路全闭合，scene 1001/0）。用户「告一段落」，重心转客户端。
- **撤销 2026-05-13 解冻决策**。当时把 `web_client` 设为体素权威化主线 Phase 1/2/3/5 的 decoder/parity 验收 oracle，`bevy_client` 降为参考实现「可滞后/暂缓」。现**对称反转**，逐条撤销当时四条纪律：
  - (a) decoder / parity 验收**口径从 web 移回 bevy**；
  - (b) 后续主线 Phase 客户端验收闸门**指向 bevy**，不再指向 web；
  - (c) 新协议字段须**先落 bevy decoder + 过 bevy parity / 字节序测试**；
  - (d) audit / sweep / 设计文档「客户端端到端验证」**默认指向 bevy**。
- **web_client 不"再冻结"**，而是变成**滞后的参考 oracle**（镜像它当初给 bevy 的角色）：它现在是 fields/electric/thermal/debris 唯一可用实现 + 字节级 parity 常量来源，是移植期的 **spec / 真值源**；移植完成后可滞后或暂缓，不主动开发新功能。

---

## 2. 现状评估（grounded，引文件）

### 2.1 强项（保留，不重新 litigate）
- **网络层堪称范本**：`net/thread.rs` 独占 OS 线程跑阻塞 TCP/UDP；`net/runtime.rs` 是**纯、详尽单测**的 `ClientRuntime` 状态机，经 `RuntimeOutcome { outbounds, events }` 与 socket I/O 解耦——握手 / UDP fast-lane（bootstrap→attach，退避 [250,1000,3000]ms + 15s cooldown）/ ack-stale 拒绝 / time-sync 全可无 socket 单测。
- **预测与服务器位级一致**：`sim/predictor.rs` 是 f32↔f64 薄适配，**复用与 server NIF 同一个 `movement_core` crate**（path dep）——消除一整类预测漂移。`sim/reconcile.rs` UE-CMC 风格语义校正旗标（Teleport/AntiCheatReject/StatusOverride/CollisionPush）+ 自适应 jitter 阈值；`world/remote_player.rs` Valve cl_interp 远端插值（Hermite + 限幅外推 + teleport reset）。
- **架构骨架**：`app/plugins.rs` 的 `BevyClientPlugins` PluginGroup + `app/schedule.rs` 的 `ClientSet`（Network→Stdio→Input→Logic→Sync→Render）确定序；纯逻辑模块（net/sim/voxel.core/prefab）与 `*.plugin.rs` ECS 适配清晰分离。2026-04-25 restructure 已落地。
- **测试 / 可观测**：`headless/runner.rs` 脚本+stdio headless；`observe.rs` 结构化日志；`tests/voxel_parity.rs` 锁 web 几何数（MICRO_PER_MACRO=8、sphere=280…）。
- **体素 core**：`voxel/core/mask.rs` 512-bit MicroMask（8×u64），parity 锁定——是建真渲染器的好底座。

### 2.2 短板（要修）
- **P0 体素渲染 = entity-per-voxel**：`voxel/plugin.rs::sync_voxel_visuals` 每帧调 `VoxelWorld::render_cells_3d()`（`world/store.rs`）建 HashMap diff，**每个占用 macro 块 / 每个占用 micro slot 一个 `Cuboid` entity**（refined cell 爆炸到 512）；无 mesh / 无面剔除 / 无 atlas / 无 instancing；4 material = 4 个独立 StandardMaterial。每帧 O(N) 全量重算（VoxelWorld 无脏检测）。
- **P0 无服务器体素同步**：体素世界 = `VoxelWorld` + `bootstrap_showcase(2)` **纯离线本地**，无协议、无 chunk-snapshot 摄入、无 adapter。对"服务器权威体素客户端"这是从零建。
- **picking/collision/grounding 线性扫**：`find_voxel_selection_from_ray` / camera 碰撞 / actor grounding 各自 O(all cells) AABB 扫，无空间结构（服务器有 octree crate 可借）。
- **次要债**：`WorldState` god-resource（restructure Phase5 未做，~30 字段跨域）；`InputPlugin`/`ObservePlugin` 空 stub（输入散落各 plugin 读裸 `ButtonInput`）；dev-only auth；net 线程 16ms sleep 轮询（非事件驱动）。

### 2.3 gameplay gap（决定性）
- 自 2026-05-13 解冻：`web_client` 26 commits、`bevy_client` ≈0（唯一改动是 1 行 profile.rs）。
- grep 确认 bevy `src/` **零** conduction/electric_field/thermal/power_block/ObjectStateDelta/part_destroyed 命中，web 大量命中。即 bevy **缺整个 post-thaw gameplay 层**：fields/电/热/power-block 渲染、ObjectStateDelta(0x6C) 消费、debris/part_destroyed、prefab catalog v2 + occupancy-reject、jump ground_z ack（96→104B）。约 3–4 周 web-only 协议+玩法演进待补。

---

## 3. 目标架构

### 3.1 保留的骨架
net `RuntimeOutcome` 纯状态机 + UDP fastlane；shared `movement_core`；`sim` 预测/reconcile + cl_interp；Plugin/ClientSet；headless/stdio/observe；voxel.core + 512-bit MicroMask + parity 测试。**新 gameplay 一律作新 domain Plugin 消费 event（FieldPlugin / ObjectTruthPlugin / VoxelAuthorityPlugin…）**，不动骨架。

### 3.2 体素渲染管线重写（P0 地基）
- **分 chunk**（16³ macro，对齐服务器 `ChunkSize`），**每 chunk 一个 `Mesh`**。
- **exposed-face culling 先行**（与 web `voxel/meshing/chunkMesher.ts` 的 `isMacroFaceOccluded` 语义 1:1，含跨 chunk 边界邻居遮挡）→ **greedy meshing 作 fast-follow**（合并共面同材质 quad）。
- **索引化 quad**（4 vert/face 共享 index buffer）替代 per-cube 24-vert cuboid——一个数量级的顶点/draw-call 削减。
- **texture array**（每 `VoxelMaterialId` 一层，优于 packed atlas 防 mip bleed）collapse 4 material → 每 chunk 1 draw batch；material id 烘进 vertex/UV；state-flag（damage/wet/freeze/burn）烘 per-vertex color（移植 web `material/catalog.resolveVoxelVisual`）。
- **烘焙 per-vertex voxel AO**（经典 3-邻角项，mesh-build 时算入 vertex color）——大视觉提升、运行期零成本。
- **dirty-flag 驱动 + `AsyncComputeTaskPool` 异步 meshing**：只重 mesh 脏 chunk（+ 边界受影响邻居），镜像 web `chunkMeshWorker.ts` 的 request/response + in-flight re-dirty（调度时消费脏标，build 中又被编辑则 follow-up）。
- `render_cells_3d()` 保留给 picking，但 picking/collision/grounding 改走 **chunk-hash 空间结构**。

### 3.3 服务器体素同步（P0 地基）
- `net/protocol.rs` 加体素 opcodes：`ChunkSubscribe(0x60)` / `Snapshot(0x62)` / `Delta(0x63)` / `ChunkInvalidate` / `CatalogPatch(0x71)` / `ObjectStateDelta(0x6C)` / `IntentResult`。
- **TLV section snapshot 解码**（镜像 Elixir `apps/scene_server/lib/scene_server/voxel/codec.ex`，字节偏移 1:1，含 duplicate-section / trailing-byte 守卫）；refined cell **直接消费 wire form `[u64;8]` occupancy**，**不抄 web 的 lossy `wireToRefinedCell` 桥**。
- **严格 server-authority**：`VoxelWorld` 从空开始，只 Snapshot/Delta 改；**version-gated**（`base == known chunk_version` 否则请求 invalidate/resync）；所有编辑 = **intent**（monotonic `client_intent_seq`），UI optimism 仅限 echo；绝不伪造权威写。
- 现**离线本地路径保留在 feature/mode 后**作 reference/debug build。
- 摄入作新 domain plugin（`VoxelAuthorityPlugin`），每帧 drain transport 队列 → 应用 → 标脏 chunk。

### 3.4 gameplay 层补齐（到 web parity，依赖序移植）
1. prefab micro-mask **v2** + occupancy reject + micro-wire preview（A1 D1–D4）。
2. jump **ground_z** end-to-end（A1 D5，ack 96→104B）。
3. **field / electric / thermal / power-block 渲染** + **ObjectStateDelta(0x6C) truth 消费**（含本主线刚加的 `:powered` tag / 放电毁块的客户端表现）。
4. skill→voxel **debris / part_destroyed**（A1 D6，接 `PartState`）。

每步用 **bevy-keyed parity 测试**锁（见 3.5）。

### 3.5 从 web 借鉴的模式（直接搬，去 TS 专属）
- **wire codec 显式手写 byte-offset** + size/section/trailing 守卫 + named error + 注释指向 Elixir 源（Rust 用 `byteorder`/cursor，禁 derive 魔法藏布局漂移）。
- **golden-fixture 跨语言 round-trip 测试**（**最高杠杆**）：Rust integration test 读 `apps/scene_server/priv/fixtures/voxel/*.golden`（已存在：`delta_cell_solid/refined/empty`、`catalog_patch_*`、`chunk_invalidate_*` 等），decode→re-encode→**断言字节相等**。使 bevy 成一等 parity target。
- **forward-compat CatalogPatch**：versioned op list，未知 op_kind / payload 存 opaque `Vec<u8>` 字节稳定 round-trip。
- **observe 结构化 ring-buffer logger**（`category/event/sorted-fields` 单行）+ **CLI/命令面 = smoke 测试驱动**（bevy 已有 stdio，扩成体素命令面，对齐 web `window.__voxelCli`）。
- **typed event vs pull 规则**：离散动作走 `Events<T>`，连续状态从 component/resource pull——防 event god-channel。
- **prefab rasterize**：旋转 occupancy words + part ids（quarter-turn），bitwise-AND overlap 拒绝 + disjoint-slot union；client 提议 anchor，server 拥有最终 rasterization。

### 3.6 扩展缝 + 性能预算
- 新功能 = 新 domain Plugin 消费 event；新协议消息 = opcode 表 + decoder + golden fixture；新渲染特性 = `MaterialExtension` / 独立 pass。
- 性能预算：目标 view distance N chunks，每 chunk ≤1 draw call（texture array），脏重 mesh 异步不掉帧（AsyncComputeTaskPool），picking O(1~log) via chunk hash，frustum culling 自动生效（chunk 化后每 chunk 一个 AABB-bounded mesh）。

---

## 4. 渲染 / 视觉路线图（技术 — Bevy 适配 — 工作量 — 优先级）

| 技术 | Bevy 0.18 适配 | 工作量 | 优先级 |
|---|---|---|---|
| 逐面可见性剔除 | 自研（mesh-build 时跳被遮挡 quad，镜像 web `isMacroFaceOccluded`） | S（有 mesher 后） | **P0** |
| 顶点冗余削减（索引 quad） | 自研（4 vert/face 共享 index，替 24-vert cube） | M | **P0** |
| chunk meshing（先 exposed-face） | 自研 | L | **P0** |
| 服务器增量更新（snapshot/delta + 脏重 mesh） | 自研（net handler + dirty HashSet + 异步 remesh） | L | **P0** |
| 贪婪网格化 Greedy Meshing | 自研（per-axis mask sweep 合并共面同材质） | L | P0/P1（exposed-face 后） |
| 素材图集 / texture array | 半内置（Bevy 给 texture array；图集作者自研） | M | **P1** |
| 多线程 + UI/逻辑线程分离 | **内置**（Bevy 并行 ECS，渲染独立 pipeline） | S | P1（基本满足） |
| 异步 meshing tasks | 内置原语（`AsyncComputeTaskPool`） | M | **P1** |
| 环境光遮蔽（per-vertex voxel AO） | 自研（3-邻角项烘 vertex color） | M | **P1** |
| 抗锯齿（FXAA/TAA/MSAA） | **内置**（当前未配；voxel 边缘锯齿重，性价比高） | S | **P1** |
| 视锥剔除 | **内置**（chunk 化后每 chunk 一 AABB mesh 才生效） | S（chunk 化即免费） | P1 |
| 雾效 + 视野边界渐变 | **内置**（`DistanceFog`，配 streaming 隐藏 pop-in） | S | P2 |
| 多级阴影 CSM | **内置且已开**（`DirectionalLight{shadows_enabled}`，仅调 cascade） | S | P2（基本完成） |
| 大气效果 | **内置且已开**（`Atmosphere::earthlike` + AtmosphereEnvironmentMapLight） | S | P2（已完成，仅调） |
| LOD（chunk 级） | 自研（远处粗 mesh，`VisibilityRange` crossfade） | L | P2 |
| 遮挡剔除 | 半内置/实验（Bevy 0.18 GPU 两阶段 occlusion，opt-in，需大遮挡体） | M | P2 |
| 快速径向体积光 / god rays | 自研（屏幕空间径向模糊 / 体积雾 pass） | L | P2 |
| 水着色器 | 自研（`MaterialExtension`：动法线 / 深度淡 / 透明 / 反射） | L | P2 |

> 注：`Bloom::NATURAL` + ACES tonemapping + HDR 已开。视频「柏林噪声优化」**N/A**——服务器权威，客户端不生成地形；「服务器-客户端增量更新」= snapshot delta（已列 P0）。

---

## 5. 迁移计划（有序、可逐步提交的增量；推荐 foundation-first）

- **M0 协议 drift audit**：`bevy protocol.rs` vs 当前 `GateServer.Codec` + `docs/2026-04-10-线协议规范.md`；接入 golden-fixture parity 测试脚手架。
- **M1 体素同步地基**：opcodes + TLV snapshot/delta decode + golden parity 测试 + `VoxelAuthorityPlugin` 摄入（**渲染先沿用现 naive**，先把权威数据喂进来跑通）。
- **M2 chunk meshing 重写**：chunk 化 + exposed-face cull + 索引 quad + texture array + dirty 异步 mesh（渲染 naive→真 mesh）。
- **M3 picking/collision/grounding** 走 chunk-hash 空间结构。
- **M4 gameplay port D1–D4**：prefab v2 + occupancy reject + micro-wire preview。
- **M5**：jump ground_z + fields/电/热/power-block + ObjectStateDelta + debris。
- **M6 渲染 P1**：per-vertex AO + AA + greedy meshing + fog/view-distance fade。
- **M7 P2 polish**：LOD + occlusion culling + water + god rays。
- **横切（按需，不阻塞主线）**：Phase5 拆 `WorldState` god-resource + 真 `InputPlugin`（action 映射 / rebinding）+ net 线程事件驱动 + 生产 auth。

每个 M 是可独立提交 + parity/test 闸门的增量，沿用本仓「逐 step commit / 决策稿先行 / 不留兼容 / 显式失败」纪律。

---

## 6. 拍板结果（2026-06-15）

1. **首役 sequencing = 地基优先**（foundation-first）。先 M0+M1+M2+M3，让 bevy 真正渲染服务器权威体素，再 M4/M5 补 gameplay。理由：bevy 当前连服务器体素都收不到，地基是其他一切前提。
2. **meshing 策略 = 逐面剔除优先**（exposed-face-first，与 web `chunkMesher.ts` 1:1 parity、去风险），greedy meshing 作 fast-follow（M6）。
3. **web_client = 滞后参考 oracle**（保留作 spec / parity 源，不主动开发新功能）。
4. **离线本地体素路径 = 保留**在 feature flag 后作 reference/debug build（不移除）。

→ 即刻开工 **M0 协议 drift audit**（`bevy protocol.rs`/`movement_codec.rs` vs 当前 `gate_server/codec.ex` + `scene_server/voxel/codec.ex` + `docs/2026-04-10-线协议规范.md`），产出 gap list 驱动 M1。

---

## 7. 范围外 / 不做

- 不重写网络 / 预测骨架（优秀，保留）。
- 不做客户端地形生成（server-authoritative，柏林噪声 N/A）。
- 不立刻做 P2 视觉 polish（water/god-rays/LOD）。
- 不"再冻结" web_client（它变参考 oracle，非冻结）。
- `TheWorldBook` 跨仓镜像：本环境无该 sibling repo，**本仓 doc 为主记录**，待其可用再镜像单页摘要。
