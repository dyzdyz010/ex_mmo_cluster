# 实现状态速查

> 本文件只做实现入口速查；设计解释见 `docs/current_status/design/**`。

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
| LOD projection | `apps/scene_server/lib/scene_server/voxel/lod_projection.ex` + `apps/scene_server/lib/scene_server/voxel/lod_projection/rebuilder.ex` + `apps/data_service/lib/data_service/voxel/lod_heightmap_store.ex` | authoritative chunk truth 派生 / rebuild heightmap projection；runtime 投影先一次读取 16x16 fine heightmap，再本地聚合各 stride cell |
| Field runtime | `apps/scene_server/lib/scene_server/voxel/field/` | field region/layer/kernel/runtime |
| Data chunk store | `apps/data_service/lib/data_service/voxel/chunk_snapshot_store.ex` | canonical chunk snapshot CAS |
| Data region dir | `apps/data_service/lib/data_service/voxel/region_directory_store.ex` | durable region directory |
| Data write token | `apps/data_service/lib/data_service/voxel/write_token_store.ex` | write fence |

## 客户端

| 客户端 | 入口 | 当前用途 |
| --- | --- | --- |
| Web | `clients/web_client/README.md` | 默认端到端验证/parity 主线 |
| Bevy | `clients/bevy_client/README.md` | 参考实现 / stdio / Rust parity |
| Voxia UE | `clients/Voxia/README.md` | UE5.8 native/product client |
| Voxia gameplay | `clients/Voxia/Source/Voxia/Gameplay/README.md` | pawn、streaming、HUD、LOD debug |
| Voxia net | `clients/Voxia/Source/Voxia/Net/README.md` | transport、protocol decode、authority update |
| Voxia debug | `clients/Voxia/Source/Voxia/Debug/README.md` | stdio CLI |

## 验证入口

- 根常规：`mix compile`、`mix test`
- Phoenix app：`cd apps/auth_server && mix precommit`、`cd apps/visualize_server && mix precommit`
- Web client：`cd clients/web_client && npm test`，必要时 `npm run build`
- WS smoke：`node scripts/run_ws_dual_smoke_supervised.js`
- Voxia client CLI：`node clients/Voxia/scripts/voxia_stdio_cli.js --cmd "..."`
  - LOD client dirty/refresh：`--cmd "break;wait 1500;lod"`，查看 `lod_dirty_revision` 与 observe 的 `voxel_lod_dirty` / `voxel_lod_refresh_requested`
- Voxia server CLI：`elixir --sname voxia_server_cli --cookie mmo scripts/voxia_server_stdio_cli.exs --cmd "..."`
  - LOD projection coverage：`--cmd "lod_status 1"`
  - Runtime heightmap read sample：`--cmd "lod_sample 1 0 0 16 4 4"`
  - Explicit materialization/backfill：`--cmd "lod_rebuild 1 2,4,8,16 5000"`

## 注意

当前工作树中存在多处未提交代码/文档变更。本轮文档治理只新增/更新 `docs/current_status/**`，不代表这些代码变更已完成或已验证。
