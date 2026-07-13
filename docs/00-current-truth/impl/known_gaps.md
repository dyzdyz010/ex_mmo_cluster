# 当前已知缺口

> 本文是缺口的合并态 snapshot。已完成能力见 [`impl/README.md`](README.md) 与各 current-truth 文档；历史过程见 [`source_index.md`](../source_index.md)。

## 服务端控制面

- **SceneNodeRegistry HA**：缺容量感知 failover、自动迁移和多节点容量调度完整方案。
- **Subscription liveness**：缺由服务端自维护的订阅续租、超时、重连和 stale lease 修复闭环；客户端静止时也不能依赖一次性建立的订阅。
- **大范围 region/materialization 调度**：缺异步背压、预算、跨节点调度和队列可观测，不能让离线/大范围物化抢占在线 Scene 热路径。

## 体素 baseline、launcher 与生产 pages

- **8km 生产权威 pages**：缺服务端纯 3D canonical page writer、bounded materialization、delta dirty 聚合、mip 基准与 `source_revision/diff_chain_hash` 真值。客户端 fixture 不能替代服务端 source。
- **生产持久化 artifact**：缺 source pages / mesh artifact 的持久化、版本、容量淘汰和重拉策略；旧 SVDAG/raymarch artifact 不再是当前必需交付物。
- **launcher/update 完整流程**：缺包下载、安装、release manifest/index、diff-chain、required-set 差集下载、传送前补拉与可诊断 UI。
- **runtime diff budget**：缺远景 page 失效的通道、优先级、合并频率、背压和最终一致性上界。
- **32km/稀疏世界/真实地图导入**：缺大世界生成预算、稀疏 chunk 策略、地图 migration 与完整 dirty/rebuild scheduler。
- **服务端 material 派生**：现有 NIF 仍暴露 `column_height/heightmap_region`；缺 `chunk_xyz -> canonical 3D material page` 及与 1m truth 的一致性验证。

## Voxia 里程碑 A（当前进行中）

原 A1-A5 已收口：显式 7/14/28/56m tiers、3.5m collar、分组件 DynamicMesh StaticDraw、per-cell greedy merge、seam/fade、紧凑顶点、cache 卫生和原始 8km 长巡航均已有证据。A 已扩展为完整 3D near/far LOD 与客户端数据流送生产化，因此不能再写成“A 完成、开始 B”。

已经完成的扩展成果：

- near 连续 generate/apply、compact confirmed store、per-chunk 可复用组件、patch-native far、后台 patch/mesh prepare 与 bounded GameThread submit；
- XYZ ownership、near retirement lease、垂直呈现带活性、快速折返和完整场景约 137 FPS 的兼容路径证据；
- XYZ cube-shell、v2 canonical pages、六向 material mip、coverage-resolved exact surface、source-neutral scene builder；
- generation barrier、真实 render fence、scene host、显式 dev composition root 与高空 Real-RHI 切代；
- `LoadExpectedBatch` 的 H-gated 原子磁盘 batch：外部 manifest SHA-256、expected identity/set、page hash/size/decode/空间身份全部通过才发布。
- H-gated 本地磁盘 request provider：`OpenExpectedManifest` 冻结外部 H+expected identity 校验后的 manifest 超集，`FVoxiaLocalDiskCanonicalVoxelPageProvider` 每代只读 `enter/dirty` 请求页并逐页复核，候选批全成功后才发布；唯一根已以 default 包完成冷启动和相邻 +X 实跑，错误 H 根级硬失败且无 WorldGen fallback。
- 唯一 `production_all_features` WorldGen 组合根：GameMode 只生成 `AVoxiaUnifiedVoxelWorldActor` 顶层 root，成熟 near 滑窗/数据泵与 Pure3D far 同场运行；legacy/Pure3D standalone 降为显式 probe/compatibility。根级 CLI 要求 near settled、far live 与 XYZ center 一致；地面与高空 Real-RHI 均已通过。
- Pure3D far 的 A10 S2-S5 首轮增量链：request-oriented WorldGen/scripted provider、required/keep/enter/exit diff、immutable page residency/lease/LRU、cooperative cancellation、material/surface dependency cache、绝对 XYZ `32³` stable patch registry 与 retained/rebuilt/removed real-fence transaction。相邻 default 实跑只请求 `1517/33752` 页，复用 `32199` material、`29533` surface 和 `175/216` far patch；统一根不再创建隐藏 Pure3D near mesh/component。
- S4 性能收敛首轮：resolved surface 按 page 使用后台优先级并行构建；material/surface cache 改为 source-bound immutable shared refs，stage 映射直接转交；`TFuture::Consume()` 消除完整 generation 复制；coverage diff 在 worker 运行，旧 coverage 在 worker 析构，page lease 以每 tick `1024` 页预算回收。相邻 Real-RHI worker 约 `0.91-0.95s`，far GameThread prepare/finalize/publish 分段约 `4.5-7.5ms`。

当前 A 的剩余门槛：

1. **统一 lifecycle / transaction 尚未完成**：唯一根已完成正常 WorldGen 入场、自动 pawn XYZ 跟随和 near/far 联合 readiness；Pure3D far 已有完整 scene phase、失败保留旧 live、latest-only cancel 与 EndPlay 回收，但当前仍以 near-only `AVoxiaWorldActor` + far-only `AVoxiaPure3DVoxelWorldActor` 两个迁移期子模块组成。两侧没有共享 source identity、coverage generation、page residency 和原子 scene transaction。需抽取成熟 near 能力并补根级 HUD，不能长期把 actor 组合当终态。
2. **第二轮增量 DAG 与统一 near 数据源**：far 已不再全量请求/提交，共享 artifact ref、并行 surface、异步 coverage plan 和预算化 lease 回收已经落地；但相邻一 tile 仍扫描完整 dependency fingerprint，并重建 `4219` 个 dirty-closure surface。当前 Real-RHI desired→live 约 `0.91-0.95s`，完整移动 p50/p95/p99 约 `4.5/5.6/6.3ms`，不同运行仍出现少量 `16ms+` 离群帧。需补反向依赖索引、增量/full oracle、持续巡航分位数与尖峰归因；near 还未消费同一 request provider/residency。正式作战任务见 [`A10 WorldGen 驱动的完整客户端 3D 滑动世界`](../../10-active/voxel-far-field/2026-07-12-a10-cancellable-incremental-voxel-shell-streaming.md)。
3. **三轴用户流送验收**：尚缺出生、X/Y/Z、对角、连续移动、快速折返、传送、高空再回地面的同口径 `frame_perf + generation trace + Real-RHI` 长巡航；需证明无需 CLI recenter、desired/live 收敛、每帧无 gap/overlap、无 stale commit，并报告构建延迟和 GT 分位数。
4. **完整材质族**：`M_VoxelWorldAligned` 已在 debug fixture 与 dev pure-3D world 通过；完整 WorldGen material palette、opaque/dither/透明/发光变体及同点 near/far material audit 尚未统一，全白调试壳不能作为完整场景收口。
5. **本地连续世界、在线 provider 与兼容实现退役**：H-gated `local_disk` request provider 已用于客户端开发包，但当前 `stationary/adjacent_x/six_axis` 包仍是有限 route fixture；真实用户飞出 manifest 覆盖会显式缺页、保留旧 far live 并使根因 center 失配降为 not-ready，尚不能称为任意方向连续本地世界。成熟 near 也尚未消费同一 provider；服务器/HTTP/在线 authority provider、delta/失效与默认在线接线均未实现并后置。旧 `AVoxiaWorldActor` 的 `svo_source_pages_v1`、heightmap/VHI、`SurfaceMaterialId`、`CenterTile.Y=0` 与二维 near-skip 在统一根中已关闭远场职责，但代码仍存在；A10 应先补本地连续 route/按需 resolver 并抽取 near 模块，后续 authority provider 切流后再删除兼容 far。
6. **硬件与长巡航矩阵**：唯一根已 settle 的默认 Real-RHI 稳定 5 秒 p50/p95/p99/max=`5.385/6.705/7.368/7.761ms`；最新完整相邻移动 p50/p95/p99/max=`4.507/5.591/6.260/19.767ms`，另一次 far-only 采样出现两个最高 `38.258ms` 离群帧。当前只覆盖一台验证机与单次 +X；低端硬件、长时段、持续多 tile 增量构建及稳定的尖峰上界仍未形成生产门槛证据。

**raymarch 不再是 backlog**：D3D12 3D/Compute 队列超时已经复现，当前路线严格禁用；不得把历史 L4/raymarch A/B 重新列为 B 的任务。

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

- Voxia 当前代码有未提交改动；交付前需重跑受影响的 `Voxia.Voxel`、`Voxia.Gameplay`、`Voxia.Presentation` 与纯 3D Real-RHI 三轴 smoke。
- 协议改动仍须区分 Web parity oracle、Voxia 实跑焦点和 Bevy 参考实现，不能把单客户端结果当 wire 唯一真值。
- `docs/00-current-truth/**` 必须保持合并态；完成阶段归 `20-archive`，被推翻路线归 `90-obsolete`，不得把历史进度日志继续留在 active/current-truth 充当 resume。
