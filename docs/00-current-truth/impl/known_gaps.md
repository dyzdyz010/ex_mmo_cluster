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

## Voxia 当前客户端缺口

> 唯一 `L_VoxiaProductionWorld`、默认 RuntimeMock、阶段 1/2/3、Far LOD exact-surface、Near/Far
> Patch-diff、完整 XYZ 移动安全门与编辑器作者态预览已经合入 Voxia 独立仓库 `master`。
> 2026-08-02 的完整 Phase 1 已覆盖长距离、负坐标、XYZ 对角移动、快速折返和显式阶段暂停；
> 1280×720 Real-RHI 严格门禁通过。此前 `diagonal_yz` 外露材质失败和 Patch GameThread
> 性能门未关闭的表述已被本次新鲜证据取代，不再是当前缺口。

相邻移动仍只让 Near、required handoff 与当前 Far 构建推进；Near 加载/清理或玩家持续移动且
下一窗口已预取完成时，只暂停投机 Far 的可见发布，停下后自动恢复。SceneHost 持续维护
Near 完整性与 renderer coverage 索引，每帧最多构建一个 boundary 物理批次；这两个不变量
都由所属系统自己维护，不依赖一次性外部唤醒。

当前剩余客户端缺口：

1. **层间墙人工视觉复验**：真实 `LayerFace`、跨 Patch 稳定发布者、逐 live-Far 凭证和最新
   完整 Real-RHI 结构化路线已经通过，但用户尚未在 2026-08-02 合并树上重新判断此前的
   “不该有墙/该有墙却缺失”现象。gap、slot、component 与 fence 计数不能替代该视觉验收；
   禁止用裙边、双面材质、默认墙、扩大半径或固定等待冒充关闭。
2. **发布硬件矩阵**：当前 Phase 3 树已经完成 1920×1080 30 分钟持续 XYZ 流送与资源零漂移门禁；
   低配置硬件、更多驱动、发布包与长时真实玩家输入仍未形成分档。
3. **Prefab Designer 与正式内容管线**：Phase 3 RuntimeMock 已完成 immutable catalog、24 orientation、
   PrefabInstanceDirectory、exact refined projection/raycast/collision、原子 place/remove/replace、CLI 与
   长稳；可视化 definition authoring、资产发布/版本迁移仍未开始。普通世界的
   `micro_edit_not_supported` 是稳定边界而非缺口。
4. **Online authority provider**：客户端 Phase 3 没有扩展 wire；仍缺服务端 bootstrap、production H-gated XYZ pages、snapshot/delta、
   source revision 失效、subscription lease、重连与默认在线切流。WorldGen/RuntimeMock/local pack
   不能冒充 confirmed truth，也不能在在线失败时 fallback。
5. **本地 production 包与 launcher**：现有 H-gated local request provider 可验证客户端边界，
   但开发 route fixture 不是任意世界的发行包；仍需 launcher/update、release manifest、差集补拉
   与传送前 coverage 检查。
6. **天气与内容美术**：UDS/UDW、雾、PostProcess 与补光已经进入唯一正式地图并可由编辑器调节；
   仍需正式天气内容策略，以及不破坏 material-family、world snapshot 和原子提交契约的透明/
   发光内容。
7. **归档 decoder 清理**：production legacy far runtime/probe/identity/uploader 已删除；append-only
   wire decoder 与 golden fixture 继续只作协议历史证据，不能恢复为 presentation owner。

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

- Voxia 阶段 3 已 fresh 通过 clean Development build、`213/213` automation（`0` failed/not-run；
  唯一 warning 为外部 `generate_204` HTTP 超时）、Node `124/124`、
  Null-RHI `18/18`、1920×1080 可见短路线与 30 分钟持续 XYZ 流送；阶段 1/2 与 RG6 证据仍有效。后续任何代码变化
  都必须按影响范围重新建立证据，不能沿用本次产物。
- wire codec 唯一真值仍是 `apps/gate_server/lib/gate_server/codec.ex`；默认协议门禁由服务端 codec / golden fixture 与 Voxia decoder 自动化、实跑共同承担。`clients/web_client` 与 `clients/bevy_client` 仅保留为逻辑归档历史证据，不再承担 current-truth parity oracle、参考实现或默认验收职责。
- `docs/00-current-truth/**` 必须保持合并态；完成阶段归 `20-archive`，被推翻路线归 `90-obsolete`，不得把历史进度日志继续留在 active/current-truth 充当 resume。
