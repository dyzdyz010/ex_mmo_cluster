# 当前已知缺口

> 当前唯一事实中的“未完成 / 待迁移 / 待验证”集中列表。这里不是 backlog 全量，只记录会影响架构判断的缺口。

## 服务端控制面

- SceneNodeRegistry 仍不是完整 HA：当前有 stale owner repair，但不是容量感知 failover / 自动迁移完整方案。
- Subscription liveness 的长期正交设计仍需继续：当前已有 worker 化和多项修复，但“服务端透明维护订阅活性、客户端无感”仍是待收口方向。
- 大范围 region/materialization 的异步背压、预算和跨节点调度仍需继续工程化。

## 体素真值与基线

- **baseline 形态与流送边界决策已定（2026-06-29），实现处于全量物化过渡 → delta 边界迁移中**：目标态为确定性 WorldGen + 设计师 delta D + hash 凭证 H，storage ∝ 修改量；当前仍是 WorldPackBootstrapper/shard 装全量 chunk payload。迁移钥匙是 WorldGen 跨端 bit-exact 确定性。见 [`voxel-server-authority/2026-06-29-voxel-baseline-streaming-boundary.md`](../../../voxel-server-authority/2026-06-29-voxel-baseline-streaming-boundary.md)。
- WorldGen 噪声降级为 migration 已开始落地：`0x6A` 远景 LOD 不再重跑噪声，默认读 `LodHeightmapStore` 持久化 projection；chunk snapshot 写入可同事务 upsert projection；`LodProjection.Rebuilder` 可显式 backfill projection；`ChunkProcess` 生产默认缺 authoritative snapshot 即失败并输出 `voxel_chunk_materialization_failed`。`DefaultRegionBootstrapper` 开发/demo 可通过 `DevSeed` 写 starter chunk snapshots 并 rebuild LOD projection；WorldGen / empty chunk 仅保留为显式 dev/test materialization 辅助路径。
- 服务端真实 WorldGen world-pack 生成入口已补：`WorldPackBootstrapper` 可在启动时按显式 chunk bounds 批量写 canonical snapshots 并发布 ready manifest。仍缺 launcher/update 层的包下载、hash 校验、region manifest/index 和 diff chain 完整校验 UI/流程。
- runtime diff 的 channel/priority/budget 还未形成最终设计；当前 snapshot 仍可能成为 bulk 数据来源。
- 稀疏 chunk、完整 32km 生成预算/调度、真实地图导入 migration、launcher 包管理和完整 dirty/rebuild 调度仍未完成。LOD material 已从服务端 projection row 进入 0x6B material section，并被 Voxia decode/debug/heightmap vertex-color 表现消费；后续剩余是 catalog 驱动 palette 和完整 dirty scheduler。

## Voxia 近远景

- 远景 LOD inner skirt 已实现并补 AutomationTest，仍待 UE Automation / 实机截图验证。
- 多 tier LOD 级联配置已改为 `{2,256},{4,256},{8,256},{16,1000}`，仍待实机性能和画面验证。
- 近场 fill 期间可能出现短暂真空环。
- 远程 detail-on-demand / 服务端长程 raycast / 远程实体 AOI 仍是设计方向。

## 局部场 / 涌现

- Generic persistent FieldSource owner 存活探测、预算消耗、自动续租、跨 chunk lifecycle 未完成。
- FieldEffect dispatcher 仍需 batch mutation，避免单 tick 多次 version bump / fan-out / persist enqueue。
- Phase 8 effect 边界未落地：ignite/freeze/melt/damage/object/combat/source effect 仍需统一 dispatcher。
- 完整电路仿真、材料熔断破坏、tick-by-tick 能量扣减未完成。
- SurfaceElement 物理参与、客户端完整渲染/解码、delta 专用 op 未完成。
- Prefab/object 统一 field participant projection 尚未覆盖所有局部场。
- 深半导体 C4b（二极管/三极管完整玩法与物理模型）仍待专门设计。

## 客户端 / 验证

- `docs/current_status` 的当前事实文档是本轮治理新增，需要后续随代码变更持续维护。
- Web/Voxia/Bevy 三条客户端的验收角色需要在后续 PR 说明中持续区分，避免把 Voxia 实跑资料误当协议唯一 oracle。
- 本轮文档治理没有跑测试；它是文档整理，不证明运行时状态变化。
