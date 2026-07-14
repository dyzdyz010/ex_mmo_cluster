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
| Voxia UE | `clients/Voxia/README.md` | 唯一现役 UE5.8 product client；Milestone A / A10 本地完善中 |
| Web | `clients/web_client/README.md` | 归档；仅显式点名时使用 |
| Bevy | `clients/bevy_client/README.md` | 归档；仅显式点名时使用 |
| Voxia milestone status | `docs/10-active/voxel-far-field/2026-07-12-pure-3d-voxel-shell-migration.md` | 扩展后的里程碑 A 进行中；B/C 未开始 |
| Voxia near XYZ cube | `clients/Voxia/Source/Voxia/Voxel/VoxiaNearVoxelWindow.*` + `VoxiaNearFarPresentationPolicy.*` | 27 tiles/9261 chunks；任一单轴换窗进出9 tiles/3087 chunks；完整 XYZ readiness |
| Voxia near/far transaction | `clients/Voxia/Source/Voxia/Presentation/VoxiaNearFarHandoffCoordinator.*` | 成熟 near 的 XYZ ownership atlas、逐 chunk transaction、lease/generation/epoch barrier；A10 根级共享 transaction 尚未完成 |
| Voxia 3D shell planner | `clients/Voxia/Source/Voxia/FarField/VoxiaFarFieldCubeShellPlanner.*` | 纯 XYZ cell/span/LOD 规划、量化、唯一 owner 与预算；已由 A10 开发根消费，不读取 WorldGen 或 renderer |
| Voxia canonical voxel source | `clients/Voxia/Source/Voxia/Voxel/VoxiaCanonicalVoxelSource.*` | WorldGen 无关只读源；SVO confirmed-store 采样已接入，missing 不等于 air |
| Voxia canonical pages v2 | `clients/Voxia/Source/Voxia/Voxel/VoxiaCanonicalVoxelPages.*` | XYZ brick + span + LOD、X-fastest dense material `u16` codec；`LoadExpectedBatch` 以外部 manifest SHA-256 + expected identity/set 原子加载，失败 batch 为空 |
| Voxia canonical page providers | `clients/Voxia/Source/Voxia/Voxel/VoxiaCanonicalVoxelPageProvider.*` | WorldGen、scripted memory 与 H-gated `local_disk` 共用 request/result 契约；本地 provider 冻结经外部 H+identity 验证的 manifest entry table，只读请求子集，逐页校验且整批原子发布 |
| Voxia dev WorldGen materializer | `clients/Voxia/Source/Voxia/Voxel/VoxiaWorldGenCanonicalPageMaterializer.*` | 只消费 WorldGen 的 XYZ material volume 并适配为 identity-bound canonical page batch；column cache 留在生成器内部 |
| Voxia 3D material mip | `clients/Voxia/Source/Voxia/Voxel/VoxiaVoxelMaterialMip.*` | 六向 empty/uniform/mixed face material 归约；mixed 不提供 fallback material |
| Voxia exact material surface | `clients/Voxia/Source/Voxia/Voxel/VoxiaVoxelSurfaceArtifact.*` | 从 canonical XYZ page 精确提取实体/空气边界；greedy 只合并同朝向同材质面，coverage 外可显式 unresolved |
| Voxia shell artifact staging | `clients/Voxia/Source/Voxia/FarField/VoxiaVoxelShellArtifactStager.*` + `VoxiaVoxelShellResolvedSurfaceStager.*` | plan + page gate + material mip + generation-wide owner 邻域解析的全有或全无 staging；不创建 renderer/UObject |
| Voxia source-neutral scene builder | `clients/Voxia/Source/Voxia/Gameplay/VoxiaCanonicalVoxelShellSceneBuilder.*` | required far+near page request、identity/coverage gate、resolved artifact 与 near/far scene stage；不知道 WorldGen/磁盘/网络 |
| Voxia surface renderer adapter | `clients/Voxia/Source/Voxia/FarField/VoxiaVoxelSurfaceMeshAdapter.*` | canonical X/Y(up)/Z → UE X/Z/Y；局部顶点，大世界位置留给 transform |
| Voxia surface Real-RHI preview | `clients/Voxia/Source/Voxia/Gameplay/VoxiaVoxelSurfacePreviewActor.*` | 独立 debug DynamicMesh + `M_VoxelWorldAligned`；±8km/洞穴可视验收，尚未切生产 WorldActor |
| Voxia presentation generation | `clients/Voxia/Source/Voxia/Presentation/VoxiaVoxelPresentationGeneration.*` + `VoxiaVoxelCoverageOwnership.*` | renderer/source 无关的 generation readiness、stale 拒绝与 XYZ 唯一 owner 契约 |
| Voxia presentation resource host | `clients/Voxia/Source/Voxia/Gameplay/VoxiaVoxelPresentationResourceSet.*` + `VoxiaVoxelPresentationSceneHost.*` | 真实 render fence；hidden/live/retiring near/far DynamicMesh 生命周期与原子晋升 |
| Voxia world composition selection | `clients/Voxia/Source/Voxia/Gameplay/VoxiaVoxelWorldComposition.*` | 唯一正式根 / legacy probe / Pure3D probe / online compatibility 的纯选择契约；冲突 selector 与缺 provider 硬失败 |
| Voxia 唯一联合根 | `clients/Voxia/Source/Voxia/Gameplay/VoxiaUnifiedVoxelWorldActor.*` | `-VoxiaWorldGenPreview` 默认启动 `production_all_features`；一个顶层 root 组合成熟 near-only 流送与 Pure3D far-only，维护 near settled + far live + XYZ center aligned 的根级 readiness |
| Voxia pure-3D far module / standalone probe | `clients/Voxia/Source/Voxia/Gameplay/VoxiaWorldGenVoxelShellBuilder.*` + `VoxiaPure3DVoxelWorldActor.*` | 统一根中只显示 far；`-VoxiaPure3DProbe`/旧 `-VoxiaPure3DWorld` 可独立验证。WorldGen/本地磁盘 provider 共用 request Build 路径，已接 page diff/residency、cooperative cancellation、source-bound shared artifact cache、并行 resolved surface、worker coverage plan、预算化 lease 回收与绝对 XYZ stable patch transaction；相邻 Real-RHI worker 约 `0.91-0.95s`。仍缺 near/far 共享 transaction、反向依赖索引/full oracle和完整 route。服务器/HTTP/在线 authority provider 后置 |
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
  - Near XYZ：`--cmd "until_near_full;near_mesh;snapshot"`，检查 `footprint_contract=xyz_cube`、9261 与 handoff tile/chunk 统计
  - Cube shell probes：`--cmd "voxel_shell_plan;voxel_pages_v2_probe;voxel_shell_stage_probe"`；这些只证明组件，不能替代联合根 readiness，更不能替代在线 authority cutover
- Voxia 定向 automation：`Automation RunTests Voxia.Voxel`、`Automation RunTests Voxia.Gameplay`、`Automation RunTests Voxia.Presentation`
- Voxia server CLI：`elixir --sname voxia_server_cli --cookie mmo scripts/voxia_server_stdio_cli.exs --cmd "..."`
  - Legacy heightmap/projection 命令只用于 archived/offline regression，不是 full-3D 验收入口

## 注意

当前工作树中存在多处未提交 Voxia 代码与文档变更。现有日志证明对应工作树时点的自动化/Real-RHI 结果；交付前仍需在最终工作树重跑受影响测试，不能把“文档已治理”等同于“代码已提交”。
完整 3D 总任务只有在 production near subscription、v2 canonical materialization、共享 near/far transaction、在线 authority provider 与 combined near+far Real-RHI 全部通过后才能完成；A10 开发根、hidden probe 或 near-only 只算 checkpoint。
