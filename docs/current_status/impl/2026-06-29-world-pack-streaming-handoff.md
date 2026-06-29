# 2026-06-29 体素 world-pack / streaming 当前交接

> 本文记录本次提交前的真实状态。它不是完整设计稿，只用于接手时快速判断已经做到哪里、验证到哪里、哪里还没有开始。

## 当前已落地

- 服务端已经有正式的 `WorldPackBootstrapper` / `WorldPackMaterializer` 路径，可在显式环境变量开启时按 chunk bounds 批量调用真实 `WorldGen`，写入 canonical chunk snapshot，并同步维护 LOD heightmap projection。
- world-pack 生成状态已进入 auth manifest：只有物化成功后发布 `ready`，失败或不可重试错误不会伪装成功。
- `DefaultRegionBootstrapper` 与 world-pack 生成路径已经拆开：开启正式 world-pack 生成时，默认 dev seed 不再抢占同一批 chunk。
- DataService 增加 LOD heightmap projection 存储；Scene 侧 chunk snapshot 写入可派生/刷新 LOD projection；远景 LOD 数据源已从运行时噪声迁移到持久化 projection。
- UE Voxia 客户端已接入本地 baseline chunk pack：启动/进场前可以从 `Saved/Voxia/Baseline/scene_<id>/chunks/*.vcsnap` 读取本地 pack，并预填 confirmed voxel store。
- UE Voxia debug/stdio CLI 已支持 baseline 与 streaming 相关观测命令，例如 `baseline_load`、near confirmed/missing 统计、LOD/overlay 状态检查。
- “缺本地包、hash 不匹配、diff chain 断裂”不允许靠 runtime snapshot/resync 兜底进场的要求已经写入当前事实文档和实现边界。

## 已验证证据

- `mix compile` 通过。
- `mix test apps/world_server/test/world_server/voxel/world_pack_materializer_test.exs --no-start` 通过。
- `mix test apps/auth_server/test/auth_server_web/controllers/voxel_world_manifest_controller_test.exs --no-start` 通过。
- `git diff --check` 通过。
- 真实临时服务端 smoke 使用 scene `940123`、1 个真实 worldgen chunk，生成结果为：
  - `voxel_world_pack_materialization inserted: 1 errors: 0`
  - `voxel_world_pack_generation_ready content_version: "worldgen-real-smoke-940123" chunk_count: 1`
  - manifest 与 world_diff HTTP 请求均返回 200。
- UE 客户端本地 baseline smoke 之前验证过 343 chunks 持久化/加载成功，near confirmed missing 为 0，命中区域可判定 editable。

## 当前未完成

- 用户要求的“完整生成大世界，量化真实压力”尚未开始执行；在用户要求先提交推送后已暂停。
- 32km 级世界不能直接盲跑全量 cuboid job：下一步应先用真实 worldgen 小/中窗口压力探针测量 chunk/s、DB 增量、LOD projection 写放大、内存峰值，再外推完整世界预算。
- launcher/update 层还没有完成真实 world-pack 下载、hash/index 校验、region manifest、diff chain 校验 UI 与流程。
- baseline JSONL/world_diff 与客户端长期随机访问 pack/index 的最终格式仍需补齐；当前 UE 已能加载本地 `.vcsnap` chunk pack，但完整 launcher pack storage 还不是最终形态。
- 运行时 streaming channel、diff priority、TCP/UDP 分流和移动同步优化仍是后续设计项，尚未按最终网络架构重排。

## 下一步建议

1. 新增可复现 pressure probe，使用真实 `WorldPackBootstrapper.materialize_once/1` 对 fresh scene 运行 1、64、256、垂直 100 chunk 等阶梯测试。
2. 记录每轮 wall time、chunk/s、`voxel_chunks` 增量、`voxel_lod_heightmap_cells` 增量、DB relation size 增量、observe 日志。
3. 根据实测结果判断 full 32km world-pack 应采用稀疏 terrain-aware 枚举、分区离线任务，还是需要先重构 LOD projection 写入策略。
4. 再补 launcher pack/index，确保“启动器更新全量体素包 -> 进场前校验 -> 进场后只流 runtime diff”的流程闭环。
