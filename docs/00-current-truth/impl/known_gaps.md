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

> 阶段 1 lifecycle、阶段 2 与 Far LOD 表面材质语义修复的既有事实保持完成；Online production
> 仍未开始。Near/Far Patch-diff 无空洞交接已经取得新鲜 Development、完整 Automation、
> 水平 Null-RHI 与竖直 Null/Real-RHI 针对性证据；发布级全方向/长稳 closeout 尚未刷新。

相邻移动现在先启动 Required Patch 流送并继续可玩；独立 XYZ 安全门允许玩家离开最后完整
Near 最多 3 chunks，只阻止继续向外进入第 4 个 chunk，返回和沿边界移动始终允许。该门只读
真实 renderer coverage，不使用等待秒数或队列长度；SceneHost 把交接范围沿 XYZ 六面各外扩
3 chunks 核对，保护带必须由已验证 Far 版本与真实 renderer receipt 证明。第 4 格先按距离
上限拒绝，只有前三格内才检查画面覆盖。旧 Near 全退与根级画面证明推进前，
`handoff_complete` 保持 false；后台 speculative Far 不阻塞 `playable`。相邻窗口共享同一
Near Patch 编号但边缘范围不同时，先显示新旧范围并集；目标 Far 精确版本及其 renderer
receipt 就绪后再收窄到最终范围，不能用直接替换整个 Patch 的方式提前丢掉旧边缘。
2026-07-21 的旧架构基线曾关闭本机 Real-RHI 流式性能门禁：完整生命周期两窗 frame p99 均约
`7.69ms`，GPU p95 约 `3.2ms`，最大帧低于 `27.34ms`；30 分钟资源长稳无单调增长。该证据不能
替代 Patch-diff 无空洞交接后的重新验收。2026-07-27 新性能路线保持 gap/overlap/orphan 为 `0`，
但 frame p95=`17.378ms`、GameThread p95=`11.088ms`，当前严格性能门仍未关闭。

阶段 2 普通宏格交互已经 closeout：macro place/break intent、Mock authority、pending ledger、confirmed
overlay、near/far exact presentation、HUD/CLI 与 X/Y/Z unload/reload 均已实现并通过 fresh 验证。普通世界没有
微格编辑，`micro_edit_not_supported` 是稳定产品边界，不是缺口。

2026-07-23 已关闭 Far LOD 外露表面材质缺口：VXP5 surface-coverage v4 解耦粗 occupancy 与精确
外露材质，旧 page/schema/cache 显式拒绝；live owner/ring/LOD histogram、thin-stratum LOD0–4/
负坐标/六向/page-ring seam 测试、完整 Automation/Node/Null-RHI 与固定相机 D3D12 actual
material-id/像素对照均通过。禁止 shader/tint/增厚表土 workaround 的边界继续有效。

### 2026-07-27 用户可见验收失败：Near/Far 朝内竖墙仍缺失

- 用户实跑确认纵向移动与流送交接已经正常，但 Near/Far 接缝朝远景内部的竖墙仍不可见。
- 当前自动化和结构化观察证明 canonical boundary slot、boundary batch、组件注册、fence 与
  `gap=0`，却没有证明对应 slot 具有非零三角形、canonical→UE 朝向正确、材质有效并最终可见。
- 因此“真实边界几何已经完成”的旧表述撤回。该问题须沿 boundary profile → shell after-image
  → immutable geometry payload → SceneHost physical batch → renderer component 逐层取证，
  在根因确认前不得添加裙边、双面材质、默认墙或额外遮洞层。

### 2026-07-27 已确认缺口：跨 LOD 所有权边界会产生无材质的新增外露面

- 这不是贴图资产缺失，也不是 Near/Far 新旧代切换时序。广路线的 `diagonal_yz` 只是让目标
  `[13,4,-50]` 纳入了可稳定复现该问题的远景页。
- 第 12 代 Far 构建在 LOD1 页 `origin_tile=[9,-1,-54]`、`cell=[0,15,1]`、`face=pos_y`
  硬失败。该页在 canonical 归约时是位于地表下方的 uniform solid；归约器按精确 WorldGen
  邻居判断其顶面仍被实体遮挡，因此没有为该面记录外露材质。
- 最终拼壳时，这个顶面外侧由更细的 LOD0 页拥有。resolved sampler 读取的是 LOD0 coarse
  cell 自己的代表采样，而不是归约器曾读取的同一精确位置；代表点被判为空气，于是几何阶段
  要求新增顶面，但 `surface-coverage v4` 中没有这个面的材质事实。当前 schema 的
  `bComplete` 因而只对归约时的暴露判断完整，不对最终跨 LOD ownership cut 完整。
- 系统按显式失败原则拒绝猜材质：generation 12 未发布，旧 generation 11 继续可见，所以已观察
  帧的 gap/overlap/orphan 仍为 `0`；其外部表现是 Near 已推进而 Far 保持旧代，最终
  `handoff_wait_stalled`。原始证据位于
  `.demo/observe/voxia_phase1_2026-07-26T22-51-23-726Z_null_rhi_1280x720/engine.log:62863`。
- 架构修复必须让“最终是否外露”和“该面使用什么材质”消费同一份 resolved 邻居/所有权事实，
  或让 canonical 页携带所有可能因 ownership cut 外露的精确材质事实。禁止用默认材质、
  shader 染色、静默 fallback 或重试掩盖该契约缺口。

1. **Patch-diff 发布级完整 closeout**：Development build、完整 `Automation RunTests Voxia`
   `163/163`、原水平复现往返、Null/Real-RHI 的地面→全空气 Near→下降回地面路线均已通过，
   移动安全门的前三格/第四格/沿边界/返回也已通过，逐帧 gap/overlap/orphan 为 `0`；
   仍需关闭广路线后续 `diagonal_yz` 的 canonical 外露材质覆盖失败，刷新完整全方向、连续
   至少 10 Tile、Relocate，并压低 Patch 发布的 GameThread 尖峰后重跑 5 分钟以上固定资源
   平台、长稳和更多发布硬件证据。针对性路线不得冒充这些未执行门禁。
2. **阶段 3 Prefab 世界运行时**：设计与实施计划已经批准，但 immutable catalog、24 orientation、
   PrefabInstanceDirectory、精确 refined projection/raycast/collision、原子 place/remove/replace 尚未实施；
   阶段 2 与 Far LOD surface semantic 前置门禁已经满足，本轮没有启动阶段 3。
3. **Online authority provider**：缺服务端 bootstrap、production H-gated XYZ pages、snapshot/delta、
   source revision 失效、subscription lease、重连与默认在线切流。WorldGen/local pack 不能冒充
   confirmed truth，也不能在在线失败时 fallback。
4. **本地 production 包与 launcher**：现有 H-gated local request provider 可验证客户端边界，但开发
   route fixture 不是任意世界的发行包；仍需 launcher/update、release manifest、差集补拉与传送前
   coverage 检查。
5. **天气与内容美术**：远景自然材质、AO/sky、单太阳与 noon/dusk/night/sweep 已完成；仍需正式天气
   内容策略，并在不破坏 material-family、world snapshot 与原子提交契约的前提下丰富透明/发光内容。
6. **发布硬件矩阵**：本机 Patch-diff 1280×720 Real-RHI 竖直针对性路线已通过；历史验收机
   1920×1080 与阶段 1 长稳证据继续保留，但 Patch-diff 后仍需刷新同级长稳。低配置硬件、
   发布包、更多驱动与长时真实玩家输入仍未形成发布分档。
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

- Voxia 阶段 2 已 fresh 通过 Development build、`141/141` automation、Node `75/75`、Null-RHI
  联合闭环与 1920×1080 Real-RHI 30 分钟长稳；阶段 1 的 Real-RHI 生命周期、RG6 七路线及两项长稳仍有效。后续任何代码变化
  都必须按影响范围重新建立证据，不能沿用本次产物。
- wire codec 唯一真值仍是 `apps/gate_server/lib/gate_server/codec.ex`；默认协议门禁由服务端 codec / golden fixture 与 Voxia decoder 自动化、实跑共同承担。`clients/web_client` 与 `clients/bevy_client` 仅保留为逻辑归档历史证据，不再承担 current-truth parity oracle、参考实现或默认验收职责。
- `docs/00-current-truth/**` 必须保持合并态；完成阶段归 `20-archive`，被推翻路线归 `90-obsolete`，不得把历史进度日志继续留在 active/current-truth 充当 resume。
