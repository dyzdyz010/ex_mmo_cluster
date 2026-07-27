# 实现状态速查

> 本文件只做实现入口速查；设计解释见 `docs/00-current-truth/design/**`。

## 服务端

| 领域 | 入口文件/目录 | 当前用途 |
| --- | --- | --- |
| Gate 协议 | `apps/gate_server/lib/gate_server/codec.ex` | 自定义 wire codec |
| Gate TCP | `apps/gate_server/lib/gate_server/worker/tcp_connection.ex` | TCP `{packet,4}` connection、dispatch、forward |
| Gate WS | `apps/gate_server/lib/gate_server/worker/ws_connection.ex` | WebSocket connection 镜像路径 |
| Voxel routing | `apps/gate_server/lib/gate_server/voxel/routing.ex` | Gate → World route/lease helper |
| Subscription worker | `apps/gate_server/lib/gate_server/voxel/subscription_worker.ex` | per-connection 订阅所有者 |
| World region grid | `apps/world_server/lib/world_server/voxel/region_grid.ex` | `chunk_coord -> region_id` |
| World ledger | `apps/world_server/lib/world_server/voxel/map_ledger.ex` | route、lease、migration、materialization |
| Scene node registry | `apps/world_server/lib/world_server/voxel/scene_node_registry.ex` | live scene node registry / reassignment |
| Chunk directory | `apps/scene_server/lib/scene_server/voxel/chunk_directory.ex` | chunk process route/start/lookup/subscribe |
| Chunk process | `apps/scene_server/lib/scene_server/voxel/chunk_process.ex` | chunk hot truth / edit / field / fan-out |
| Voxel codec | `apps/scene_server/lib/scene_server/voxel/codec.ex` | chunk snapshot/delta/object/field payload codec |
| Legacy LOD projection | `apps/scene_server/lib/scene_server/voxel/lod_projection.ex` + `apps/data_service/lib/data_service/voxel/lod_heightmap_store.ex` | 0x6A/0x6B 历史 decoder/offline regression；不得作为新 runtime/default/production LOD |
| Field runtime | `apps/scene_server/lib/scene_server/voxel/field/` | field region/layer/kernel/runtime |
| Data chunk store | `apps/data_service/lib/data_service/voxel/chunk_snapshot_store.ex` | canonical chunk snapshot CAS |
| Data region dir | `apps/data_service/lib/data_service/voxel/region_directory_store.ex` | durable region directory |
| Data write token | `apps/data_service/lib/data_service/voxel/write_token_store.ex` | write fence |

## 客户端

| 客户端 | 入口 | 当前用途 |
| --- | --- | --- |
| Voxia UE | `clients/Voxia/README.md` | 唯一现役 UE5.8 product client；阶段 1 lifecycle/ownership/active-near 活性、阶段 2 与 Far LOD 外露材质归约已完成；Patch-diff 无空洞交接、真实 renderer proof 与完整 XYZ 移动安全门已落地，发布级全方向、性能与长稳仍待刷新；阶段 3 prefab 尚未启动，Online 后置 |
| Web | `clients/web_client/README.md` | 归档；仅显式点名时使用 |
| Bevy | `clients/bevy_client/README.md` | 归档；仅显式点名时使用 |
| Voxia milestone status | `docs/10-active/voxel-far-field/2026-07-12-pure-3d-voxel-shell-migration.md` | A8/A10 跨 LOD 表面材质语义保持完成；2026-07-26 无空洞呈现的实现与定向跨 RHI 证据已完成，发布级全方向、性能与长稳仍待刷新；阶段 3、Online provider 与 B/C 未开始 |
| Voxia Near Patch stream | `clients/Voxia/Source/Voxia/Gameplay/VoxiaNearPatchBuildIndex.*` + `VoxiaNearPatchAssembler.*` + `VoxiaWorldActor.*` | 27 tiles/9261 chunks；固定 `4³ chunks` Patch 与 `3³=27` source stencil；相邻窗口共享编号但边缘范围不同时先提交新旧 chunks 并集，精确 Far 接管后再原子收窄；confirmed 单 Chunk edit 固定原子提交 1–8 Patch，不等待完整 Tile |
| Voxia Patch target / transition | `clients/Voxia/Source/Voxia/Presentation/VoxiaPatchStreamingContract.*` + `VoxiaPatchTransitionPlan.*` + `Gameplay/VoxiaUnifiedVoxelWorldActor.*` | 唯一 TargetKey；Bootstrap/AdjacentStep/Relocate；Adjacent 先保留旧 Far、新 Near 完整后只发布退场所需 Far，再收窄/移除旧 Near；`playable`、`handoff_complete`、`settled` 分离；Relocate 显式 loading；无 latch、动态 atlas 或 full fallback |
| Voxia presentation ledger | `clients/Voxia/Source/Voxia/Presentation/VoxiaPresentationCommitLedger.*` + `VoxiaRendererCoverage.*` + `Gameplay/VoxiaVoxelPresentationSceneHost.*` | 唯一 live Near/Far Patch、exact ownership、canonical boundary slots、真实 renderer component receipt 与 staging/post-visibility fence truth；覆盖证明按事务影响集增量维护并显式统计完整重建/回退；当前 receipt 尚未证明 Near/Far 朝内竖墙具有非零且实际可见的三角形，用户实跑仍见缺墙 |
| Voxia movement coverage guard | `clients/Voxia/Source/Voxia/Movement/VoxiaMovementCoverageGuard.*` + `Gameplay/VoxiaPawn.*` | 只读最后完整 Near 与真实 renderer coverage；完整 XYZ 任一轴最多越出 3 chunks，阻止继续向外进入第 4 个 chunk，返回和沿边界移动放行；不读取等待时长或队列长度 |
| Voxia shared appearance | `clients/Voxia/Source/Voxia/Voxel/VoxiaVoxelAmbientLighting.*` + `VoxiaVoxelMaterialFamily.h` + `FarField/VoxiaVoxelSurfaceLightingArtifact.*` | near/far opaque 共用 `M_VoxelWorldAligned`、稳定 UV0 与 canonical `UV1=(AO,sky)`；UE/canonical 轴角点显式映射 |
| Voxia confirmed world model | `clients/Voxia/Source/Voxia/Voxel/WorldModel/` | 唯一 confirmed aggregate、candidate-then-publish reducer、三态 sparse overlay、完整 XYZ conflict algebra 与只读 query |
| Voxia authority boundary | `clients/Voxia/Source/Voxia/Authority/` | intent ledger、确定性 Mock adapter、类型化事件 correlation、presentation work/ack history 与 session reset |
| Voxia 宏格交互 | `clients/Voxia/Source/Voxia/Gameplay/VoxiaBuildInteractionController.*` | 真实鼠标/Automation/CLI 共用 signed64 XYZ selection/gateway；只支持完整宏格 place/break，拒绝普通微格编辑 |
| Voxia confirmed presentation | `clients/Voxia/Source/Voxia/Gameplay/VoxiaUnifiedVoxelWorldActor.*` | freeze frame、exact near/far owner reservation、fence、receipt ack、finalize/recovery 的单一有序事务 |
| Voxia 3D shell planner | `clients/Voxia/Source/Voxia/FarField/VoxiaFarFieldCubeShellPlanner.*` | 纯 XYZ cell/span/LOD 规划、量化、唯一 owner 与预算；已由 A10 开发根消费，不读取 WorldGen 或 renderer |
| Voxia canonical voxel source | `clients/Voxia/Source/Voxia/Voxel/VoxiaCanonicalVoxelSource.*` | WorldGen 无关只读源；SVO confirmed-store 采样已接入，missing 不等于 air |
| Voxia canonical pages VXP5 | `clients/Voxia/Source/Voxia/Voxel/VoxiaCanonicalVoxelPages.*` | XYZ brick + span + LOD、X-fastest coarse occupancy、cell/face/regional-fallback exact-surface semantics；`LoadExpectedBatch` 以外部 manifest SHA-256 + expected identity/set 原子加载，旧 VXP2/3/4/schema 显式拒绝，失败 batch 为空 |
| Voxia canonical page providers | `clients/Voxia/Source/Voxia/Voxel/VoxiaCanonicalVoxelPageProvider.*` | WorldGen、scripted memory 与 H-gated `local_disk` 共用 request/result 契约；本地 provider 冻结经外部 H+identity 验证的 manifest entry table，只读请求子集，逐页校验且整批原子发布 |
| Voxia dev WorldGen materializer | `clients/Voxia/Source/Voxia/Voxel/VoxiaWorldGenCanonicalPageMaterializer.*` + `VoxiaWorldGenSurfaceMaterialSource.*` | 只消费 WorldGen 的 XYZ material volume 并适配为 identity-bound VXP5 batch；粗 occupancy 可中心降采样，外露 material 由 source-neutral exact surface coverage reducer 归约 |
| Voxia 3D material mip | `clients/Voxia/Source/Voxia/Voxel/VoxiaVoxelMaterialMip.*` | 六向 empty/uniform/mixed face material 归约；mixed 不提供 fallback material |
| Voxia exact material surface | `clients/Voxia/Source/Voxia/Voxel/VoxiaCanonicalVoxelSurfaceMaterial.*` + `VoxiaVoxelSurfaceArtifact.*` | reducer 从 exact source coverage 生成 VXP5 surface layer；artifact 用 coarse occupancy 决定实体/空气、只从该层取最终面材质，greedy 只合并同朝向同材质面 |
| Voxia live surface material receipt | `clients/Voxia/Source/Voxia/Voxel/VoxiaSurfaceMaterialObservation.*` + `Gameplay/VoxiaPure3DVoxelWorldActor.*` | 随 live generation 原子提交 owner/ring/LOD、六向 histogram 与 representative exact→LOD→final witness；stdio 只读，不触发重建 |
| Voxia shell artifact staging | `clients/Voxia/Source/Voxia/FarField/VoxiaVoxelShellArtifactStager.*` + `VoxiaVoxelShellResolvedSurfaceStager.*` | plan + page gate + material mip + generation-wide owner 邻域解析的全有或全无 staging；不创建 renderer/UObject |
| Voxia source-neutral scene builder | `clients/Voxia/Source/Voxia/Gameplay/VoxiaCanonicalVoxelShellSceneBuilder.*` + `VoxiaFarPatchBuildStream.*` | required far+near page request、identity/coverage gate、resolved artifact；先发布完整 Far Patch 目标计划，再逐 Patch 发布 ready mesh；不知道 WorldGen/磁盘/网络 |
| Voxia surface renderer adapter | `clients/Voxia/Source/Voxia/FarField/VoxiaVoxelSurfaceMeshAdapter.*` | canonical X/Y(up)/Z → UE X/Z/Y；局部顶点，大世界位置留给 transform |
| Voxia surface Real-RHI preview | `clients/Voxia/Source/Voxia/Gameplay/VoxiaVoxelSurfacePreviewActor.*` | 独立 debug DynamicMesh + `M_VoxelWorldAligned`；±8km/洞穴可视验收，尚未切生产 WorldActor |
| Voxia presentation generation | `clients/Voxia/Source/Voxia/Presentation/VoxiaVoxelPresentationGeneration.*` + `VoxiaVoxelCoverageOwnership.*` | renderer/source 无关的 generation readiness、stale 拒绝与 XYZ 唯一 owner 契约 |
| Voxia presentation resource host | `clients/Voxia/Source/Voxia/Gameplay/VoxiaVoxelPresentationSceneHost.*` | SceneHost ledger 是唯一 live truth；Near move/edit/trim/remove、Far Patch+26 boundary slots 均走隐藏准备与固定事务，旧资源经真实 fence 退役；逐帧累计 gap/overlap/orphan 证明不允许轮询漏检 |
| Voxia world composition selection | `clients/Voxia/Source/Voxia/Gameplay/VoxiaVoxelWorldComposition.*` | 唯一正式根 / legacy probe / Pure3D probe / online compatibility 的纯选择契约；冲突 selector 与缺 provider 硬失败 |
| Voxia 唯一联合根 | `clients/Voxia/Source/Voxia/Gameplay/VoxiaUnifiedVoxelWorldActor.*` | `-VoxiaWorldGenPreview` 默认启动 `production_all_features`；一个顶层 root 只拥有 TargetKey、Far 可见发布优先级、移动安全门观察与派生 readiness，组合 Near/Far BuildIndex 与 SceneHost renderer receipt |
| Voxia pure-3D far module / standalone probe | `clients/Voxia/Source/Voxia/Gameplay/VoxiaWorldGenVoxelShellBuilder.*` + `VoxiaPure3DVoxelWorldActor.*` + `VoxiaFarPatchBuildStream.*` | Far diff/residency/artifact/cancellation 保留；完整目标 metadata 先发布，每个 `8³ tiles` Patch ready 即提交，不等待完整 BuildFuture。standalone 只作 probe，Online provider 后置 |
| Voxia far rendering | `clients/Voxia/Source/Voxia/Rendering/` + `FarField/VoxiaVoxelSurfaceLightingArtifact.*` | RG0–RG6 已完成：原子 generation 可见提交、source UV、不可变 AO/sky、唯一环境光、自然材质、冻结质量档与 Real-RHI/30 分钟时序门禁 |
| Voxia movement coverage | `clients/Voxia/Source/Voxia/Movement/VoxiaMovementCoverageGuard.*` | 无状态完整 XYZ 安全门；只允许进入最后完整 Near 外已由真实 Near/Far renderer coverage 证明的 3-chunk 保护带，第 4 格按距离上限阻止，返回与沿边允许 |
| Voxia gameplay | `clients/Voxia/Source/Voxia/Gameplay/README.md` | pawn、streaming、HUD、LOD debug |
| Voxia net | `clients/Voxia/Source/Voxia/Net/README.md` | transport、protocol decode、authority update |
| Voxia debug | `clients/Voxia/Source/Voxia/Debug/README.md` | stdio CLI |

## 验证入口

- 根常规：`mix compile`、`mix test`
- Phoenix app：`cd apps/auth_server && mix precommit`、`cd apps/visualize_server && mix precommit`
- 归档 Web / Bevy：不进入默认验证；显式点名后按各自 README 选择历史测试入口
- Voxia client CLI：`node clients/Voxia/scripts/voxia_stdio_cli.js --cmd "..."`
  - 唯一联合根：传 `-VoxiaWorldGenPreview`（可再显式传 `-VoxiaUnifiedVoxelWorld`），`--cmd "until_voxel_world_root_ready 300000; voxel_world_composition_state; voxel_world_root_state"`
  - Pure3D 增量状态：`--cmd "until_pure3d_stream_settled 300000 1; pure3d_stream_state"`；隔离 probe 另传 `-VoxiaPure3DProbe -VoxiaWorldGenPreview`
  - Near XYZ：`--cmd "until_near_patch_idle;near_mesh;snapshot"`，检查 `footprint_contract=xyz_cube`、9261、Near Patch target/ready/fatal 与 exact ownership
  - 无空洞逐帧证明：`--cmd "presentation_coverage;movement_coverage_guard"`，检查最后完整 Near、完整 XYZ 安全门、真实 Far 组件数与累计 gap/overlap/orphan
  - Cube shell probes：`--cmd "voxel_shell_plan;voxel_pages_v2_probe;voxel_shell_stage_probe"`；这些只证明组件，不能替代联合根 readiness，更不能替代在线 authority cutover
- Voxia 竖直同管线 smoke：`node clients/Voxia/scripts/run_phase1_world_lifecycle_smoke.js --nullrhi --vertical-only --short`
- Voxia 三格移动门 smoke：`node clients/Voxia/scripts/run_phase1_world_lifecycle_smoke.js --movement-guard-only`
- Voxia 阶段 2 联合 smoke：`node clients/Voxia/scripts/run_phase2_macro_interaction_smoke.js --nullrhi --resolution 1280x720`
- Voxia 世界只读诊断：`world intent-status <id>`、`world macro-inspect <x> <y> <z>`、`world transaction-inspect <revision>`、`world parity-check`
- Voxia 定向 automation：`Automation RunTests Voxia.Voxel`、`Automation RunTests Voxia.Gameplay`、`Automation RunTests Voxia.Presentation`
- Voxia server CLI：`elixir --sname voxia_server_cli --cookie mmo scripts/voxia_server_stdio_cli.exs --cmd "..."`
  - Legacy heightmap/projection 命令只用于 archived/offline regression，不是 full-3D 验收入口

## 注意

阶段 1 仍保留其 1920×1080 Null-RHI、Real-RHI 完整生命周期、RG6 七路线和两项 30 分钟
长稳证据；阶段 2 保留 1920×1080 D3D12 30 分钟长稳、49 个样本、105 次 far commit 与有界
artifact cache。当前源码的 Far LOD surface material、最终 ownership parent、边界包络、
completed-successor 活性、同窗口 candidate refresh 与 exact far live identity 已共同收口：
Development build success，完整 Voxia Automation `155/155` 无失败、Node `84/84`，Phase 1/2
Null-RHI 均 `passed=true`。

最终可见 D3D12 唯一根主动跨轴并快速反向，实际触发 near candidate `6→7`；最终 near/far
generation=`7/6`、center=`[12,0,-51]`、Tile=`27/0/0/27`，desired/in-flight/live count 与
fingerprint 精确一致，root ready/session_ready=true。LOD0–4 live histogram 只含 material 1，
30 个 witness 的 unresolved/exact→LOD/LOD→final 均为 0；gap/seam/orphan 与 far release pending
为 0。同机位 Lit 与关闭 Lighting/Fog/PostProcessing 的截图已保存。near-only/far-only 仍只能作为
probe，质量档仍只属于同一生产根策略。

完整 3D 的“离线 Mock 客户端 lifecycle/ownership、阶段 2 与 surface semantic repair”及
“Online production authority”必须分开表述：前者已经完成；后者仍需要服务端 H-gated pages、
subscription/delta、续租、重连和默认在线切流，不能用本地 WorldGen/Mock 成果冒充。
