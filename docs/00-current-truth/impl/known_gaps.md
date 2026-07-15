# 当前已知缺口

> 本文是缺口的合并态 snapshot。已完成能力见 [`impl/README.md`](README.md) 与各 current-truth 文档；历史过程见 [`source_index.md`](../source_index.md)。

## 服务端控制面

- **SceneNodeRegistry HA**：缺容量感知 failover、自动迁移和多节点容量调度完整方案。
- **Subscription liveness**：缺由服务端自维护的订阅续租、超时、重连和 stale lease 修复闭环；客户端静止时也不能依赖一次性建立的订阅。
- **大范围 region/materialization 调度**：缺异步背压、预算、跨节点调度和队列可观测，不能让离线/大范围物化抢占在线 Scene 热路径。

## 体素 baseline、launcher 与生产 pages

- **3D cube-shell 生产权威 pages**：缺服务端按 XYZ brick/cube-shell expected set 生成的 canonical page writer、bounded materialization、六面 halo、delta dirty 聚合、mip 基准与 `source_revision/diff_chain_hash` 真值。客户端 fixture 不能替代服务端 source；旧 XZ `macro_cell_count=21016` 只属归档性能证据。
- **生产持久化 artifact**：缺 source pages / mesh artifact 的持久化、版本、容量淘汰和重拉策略；旧 SVDAG/raymarch artifact 不再是当前必需交付物。
- **launcher/update 完整流程**：缺包下载、安装、release manifest/index、diff-chain、required-set 差集下载、传送前补拉与可诊断 UI。
- **runtime diff budget**：缺远景 page 失效的通道、优先级、合并频率、背压和最终一致性上界。
- **32km/稀疏世界/真实地图导入**：缺大世界生成预算、稀疏 chunk 策略、地图 migration 与完整 dirty/rebuild scheduler。
- **服务端 material 派生**：现有 NIF 仍暴露 `column_height/heightmap_region`；缺 `chunk_xyz -> canonical 3D material page` 及与 1m truth 的一致性验证。

## Voxia 阶段 1 之后的缺口

> **离线 Mock 阶段 1 已完成，Online production 仍未开始。** 唯一生产根、同一只读 world
> snapshot、完整 XYZ、near/Pure3D far、safe-view、加载/恢复/菜单、材质族、full oracle、完整
> 三轴路线和 Real-RHI 长稳态已经通过。不得把下列 Online/内容/发布缺口倒写成阶段 1 未完成。

1. **阶段 2 体素交互**：挖掘/放置 intent、pending UI、confirmed overlay、会话 HUD 与错误恢复尚未
   实施；阶段 1 仍应隐藏编辑入口并返回 `feature_not_available_phase2`。
2. **Online authority provider**：缺服务端 bootstrap、production H-gated XYZ pages、snapshot/delta、
   source revision 失效、subscription lease、重连与默认在线切流。WorldGen/local pack 不能冒充
   confirmed truth，也不能在在线失败时 fallback。
3. **本地 production 包与 launcher**：现有 H-gated local request provider 可验证客户端边界，但开发
   route fixture 不是任意世界的发行包；仍需 launcher/update、release manifest、差集补拉与传送前
   coverage 检查。
4. **内容与美术丰富化**：opaque/translucent/emissive 三类 runtime slot 已完成，默认 WorldGen 内容
   仍以浅色 opaque terrain 为主。需要在不破坏 material-family、world snapshot 与原子提交契约的
   前提下丰富透明/发光内容和最终视觉层次。
5. **发布硬件矩阵**：本验收机 1280×720 与 1600×900 GameThread p95 均通过，30 分钟默认 GC
   长稳态无资源单调增长；低配置硬件、发布包、更多驱动与长时真实玩家输入仍未形成发布分档。
6. **兼容代码退役**：旧 heightmap/VHI/SVO/v1 column/raymarch 入口在正式根中已禁用或显式拒绝，
   代码级移除应与 Online provider/协议迁移一起进行，不能在当前客户端主线恢复使用。

**raymarch 不再是 backlog**：D3D12 3D/Compute 队列超时已经复现，当前路线严格禁用；不得把历史
L4/raymarch A/B 重新列为 B 的任务。

## 里程碑 B/C（均未开始）

- **B**：冻结 T-4 固定 far page/整数规约、T-11 失效与 HTTP 分发语义、T-12 required-set/shard manifest，并让客户端分别消费 1m near 与 7m far fixture projection。当前通用 v2 page、H-gated batch、本地 request provider 和 source-neutral builder只是 A 的客户端开发基础，不等于 B 已开工。
- **C**：实现服务端 pages writer、dirty/mip 聚合、失效 opcode、HTTP endpoint、launcher/update 真包与默认在线切流。当前任务不得修改 `apps/*` 来提前实现 C。

## 客户端-服务端 wire 契约

- **focus hydrate/promote**：缺正式 opcode、服务端租约/权限、长程命中和 authoritative payload。
- **far page invalidation**：缺正式 opcode 分配、HTTP locator、revision/manifest 滚动与端到端更新策略；`0x6D/0x6E` 已占用，不能复用。
- **remote action**：缺 action request/result、技能 authority、权限/租约和 authoritative result frame。

## 远程实体与对象 AOI

- **远程实体 AOI**：缺服务端兴趣规则、分发和真实服务器帧接入；客户端 loopback/proxy 不能证明在线 AOI。
- **对象 AOI / ObjectStateDelta**：缺正式属性/tag patch body 与对象兴趣分发规则。
- **正式表现资产与规模调参**：当前 static proxy/HISM 只验证 confirmed read model 和提交链路。

## 局部场与涌现

- **FieldSource 生命周期**：缺 persistent owner 存活、预算消耗、自动续租和跨 chunk lifecycle。
- **FieldEffect batch dispatcher**：缺批量 mutation；多次 version bump/fan-out/persist 会放大写入。
- **Phase 8 写回边界**：缺 ignite/freeze/melt/damage/object/combat/source effect 的统一 authority dispatcher。
- **电路与材料物理**：缺完整电路、熔断破坏和逐 tick 能量扣减。
- **SurfaceElement runtime**：缺完整物理参与、客户端 decode/render 与专用 delta op。
- **Prefab/object field projection**：缺统一 participant projection。
- **深半导体 C4b**：二极管/三极管仍需独立设计。

## 验证与文档治理

- Voxia 阶段 1 已在最终代码状态重跑 Development build、`Voxia` 68/68 automation、Null-RHI
  全路线、1280×720 Real-RHI 全路线与 1600×900/30 分钟 Real-RHI 长稳态；后续任何代码变化
  都必须按影响范围重新建立证据，不能沿用本次产物。
- wire codec 唯一真值仍是 `apps/gate_server/lib/gate_server/codec.ex`；默认协议门禁由服务端 codec / golden fixture 与 Voxia decoder 自动化、实跑共同承担。`clients/web_client` 与 `clients/bevy_client` 仅保留为逻辑归档历史证据，不再承担 current-truth parity oracle、参考实现或默认验收职责。
- `docs/00-current-truth/**` 必须保持合并态；完成阶段归 `20-archive`，被推翻路线归 `90-obsolete`，不得把历史进度日志继续留在 active/current-truth 充当 resume。
