# Voxia 远景公共组件抽取 + VHI 2.5D baseline 定位 — 决策稿

> 当前决策稿。目标：把 VHI / SVO（/heightmap-LOD）三条远景路线里**逐行重复的编排逻辑**抽成正交公共组件，同时把 VHI 的定位明确为「廉价 2.5D 地表 baseline」、把 3D 远景（浮空岛 / 洞穴 / 悬崖背面）的职责归给 SVO。**抽编排，不抽算法。**
>
> 上游证据源：本目录 `2026-06-30-voxia-vhi-experiment-plan.md`、`2026-06-30-voxia-svo-preview-design.md`、`2026-06-30-voxia-near-window-kernel-and-svo-roadmap.md`、`2026-06-29-voxel-sync-window-and-render-design.md`（W-Q6=A：当前世界 2.5D 锁定、3D 归 delta）、`2026-06-28-体素世界与远景渲染-当前真相(整合).md`（权威体素=全生命周期唯一真值）。

## 1. 背景与问题

2026-06-30 一批落地了三条窗口外远景路线，均为 **visual-only 派生物**（绝不进 confirmed truth / 碰撞 / 编辑 / H gate）：

- **VHI**（`VoxiaVhiImpostor`）：按 XZ tile 生成连续 top surface + 高差 riser；已有最完整的工程链路（tile artifact 增量复用 + 分帧 patch 上传）。
- **SVO**（`VoxiaSvoPreview`）：3D occupancy octree，按 macro-cell 递归 empty/solid/mixed 导出 leaf surface。2026-07-01 证据复核后，上传已从单 section 改为按 patch 分帧上传，builder-side macro-cell artifact/cache/reuse 已落地；仍无持久化 artifact、服务端 materialization 或 H gate 集成。
- **heightmap-LOD**：服务端 push 的多 tier 2.5D 曲面（0x6B），被动覆盖存储。

测绘（5-agent workflow，2026-06-30）暴露三类**逐行重复**：

| 类别 | 重复点 | 严重度 |
| --- | --- | --- |
| transport 异步生命周期 | VHI `RequestVhiImpostorsAround/StartVhiBuildAsync/完成回调`（`VoxiaTransportSubsystem.cpp:1352-1633`）与 SVO 对应路径（1648-1859）**逐行镜像**：serial guard + pending coalesce/supersede + ThreadPool 后台 + GameThread 发布 `++Revision` + observe，连 6 个 pending 成员都成对复制 | 极高 |
| WorldActor mesh 上传 | 4 个 ProcMesh component 的属性初始化仍有重复；VHI 有完整分帧 patch 上传框架，SVO 已在 2026-07-01 接入 patch 分帧上传，LOD 仍是每 tier section 上传 | 高 / 分歧 |
| tile / macro-cell 流式增量 | VHI 有 tile artifact dirty/reuse/remove；SVO 已补 builder-side macro-cell artifact/cache/reuse，但上传层仍按 patch 重传，不是持久化 artifact 或服务端 materialization | 中 |
| 坐标 / coverage / snapshot | `Same*WorldGenConfig` 8 字段逐字相同；coverage/near-skip Chebyshev 判定同构；snapshot 头部字段共通；各自又重定义 `GVoxia*TileMacros` 常量 | 中—高 |

**核心判断**：重复集中在「编排 / 生命周期 / 上传」层，抽取收益最高且**不碰确定性算法**；算法层（VHI 的 top+riser vs SVO 的 octree 递归）本质不同，**不抽模板**（会产出"参数比函数体还长"的伪共享）。

## 2. 3D vs 2.5D 的关键澄清（拍板背景）

世界的**权威真值是 3D voxel**（baseline + delta，全生命周期唯一真值）。"2.5D" 不是世界模型，只是**当前 baseline 生成器 WorldGen v1 现在只吐高度场地形**这一事实；玩家 delta 已是 3D，未来浮空岛 / 地下洞穴也都是 3D。

两条远景路线本质不同，不可混为一谈：

- **VHI = 高度场 impostor**：一列一高（`z=f(x,y)`，单曲面）。结构上**表达不了**浮空岛（一列多段实心）和洞穴（实心内空腔）；即便补"六向 face envelope"也只是给 blob 包外壳，仍无"列内多段 / 内部空腔"概念。要 VHI 变 3D 必须换多段 column（RLE 分层）模型——那是另一个算法。
- **SVO = occupancy octree**：结构上**天生** 3D，能表达浮空岛 / 洞穴 / 悬崖背面 / 体积遮挡。它现在只显示 2.5D 地形，唯一原因是**它现在也取 WorldGen v1（2.5D）源**；一旦源换成权威 3D voxel store / D-delta，SVO 立刻能显示 3D 特征。

→ **3D 远景的真正杠杆是切换远景数据源（WorldGen-2.5D → 权威 3D voxel），交给 SVO 表达；不是去补 VHI 的结构体。** VHI 与 SVO 是设计分工（VHI 廉价 baseline，SVO 3D 生产级），不是替代关系。

## 3. 拍板决策项

| # | 决策项 | 拍板 | 理由 |
| --- | --- | --- | --- |
| D-1 | VHI 定位 | **廉价 2.5D 地表 baseline；3D（浮空岛/洞穴）交 SVO** | VHI 高度场本质决定它只擅长"实心地表"主流场景；强行 3D 化与 SVO 职责重叠 |
| D-2 | `FVoxiaVhiFaceLayer` 六面结构 | **砍到只剩 top（NegY/4 侧面删除）** | 2.5D 源下 5 面无数据可填、NegY 永填不了；遵「不留未用结构 / 不留向后兼容」铁律 |
| D-3 | 本轮范围 | **稳健分阶段 S1–S6**：三公共组件落地 + VHI 全接入 + VHI P0 完善 | S1-S10 完整重构跨多会话；先吃低风险高收益的编排抽取 |
| D-4 | SVO 本轮参与 | **共享 CoveragePlanner + BuildPipeline + PatchUploader**；MeshComponentDesc 收敛 ProcMesh 属性 | SVO 改 mesh layout 已由 patch grid 小步落地；公共层仍不碰 SVO 算法 |
| D-5 | 3D 源切换时机 | **本轮抽取先行（公共组件全部 3D-ready / Y-aware 设计），切 SVO 源到权威 3D voxel 作为下个里程碑** | 公共层不锁 2.5D，下轮接 3D 源不返工 |
| D-6 | 公共组件落点 | 新建 `Source/Voxia/FarField/`（与 `Voxel/` 平级），前缀 `FVoxiaFarField*` | 明确「visual-only 远景编排」边界，与权威近场层物理隔离 |
| D-7 | heightmap-LOD 是否接入统一抽象 | **不接入**，保持独立 `TMap<stride>` 路径；若后续落地 `MeshComponentDesc`，只允许复用组件属性工具 | LOD 是被动 push / 多 tier，强套引入恒空状态机 |
| D-8 | near-skip 参数命名 | 统一 `NearSkipRadiusTiles`，删 VHI `InnerSkipRadiusTiles` 别名 | 同概念两名违显式契约；未上线无兼容包袱 |
| D-9 | 重构「行为等价」验收口径 | snapshot JSON **字节级不变**（除显式新增字段）+ 既有 12 个 `Voxia.Voxel` automation 绿 + S6 过 Layer-3 像素回归 | 给重构机械可判定的安全网 |
| D-10 | 远景路线收敛（2026-07-01 拍板） | **SVO 转主力，VHI 冻结当过渡基线**：VHI 不删（零维护安全网）、**停止一切投入**（取消原 §6 的 P0/P1/P2）；SVO 接分帧上传（原 S8 提前）+ RHI 实测 8km FPS，达标后再议是否退役 VHI | VHI 无持久优势：现在与 SVO 同显 2.5D、几何更贵（8km 933k vs 155k quad）、3D 死路；唯一优势分帧上传是 SVO 迟早要做的活。一条远景路=系统正交+维护减半，公共组件全服务 SVO。不盲删=SVO 站稳前留安全网 |

## 4. 3D-ready 硬约束（D-5 落实）

公共组件**必须**按 3D 可扩展设计，即便当前数据源是 2.5D：

- **Coverage 必须 Y-aware**：coverage 描述不能只有 XZ 半径；需保留垂直方向（Y）覆盖维度（v1 可只用单一 Y band，但接口/数据结构留 Y），否则远处高空/地下的浮空岛、深洞会被 XZ-only 规划漏掉。
- **数据模型不假设"一列一高"**：已落地的 CoveragePlanner 只认 `FIntVector Tile`（含 Y），BuildPipeline 只认 route config + source revision；PatchUploader 只认 patch key + mesh payload + section 池，不内嵌高度场假设。SVO 接 3D 源时只换算法实现，公共层不动。
- **patch 是上传分组单位、不绑算法 tile**：粒度由配置决定（VHI `PatchTiles=8`，SVO 未来 `PatchTiles=MacroCellTiles`）。

## 5. 公共组件架构

```
Source/Voxia/
  Voxel/        ← 权威近场 + 算法 mesher（VHI/SVO/Heightmap mesher 留这里，只是「算法」）
  FarField/     ← 新：远景编排层（规划 / 生命周期 / 上传，全部 visual-only、3D-ready）
  Net/          ← transport（已持有 BuildPipeline 实例，仍保留路线各自 Async/merge）
  Gameplay/     ← WorldActor/Pawn（已持有 PatchUploader 实例）
```

### 5.1 `FVoxiaFarFieldCoveragePlanner` — 纯函数规划器（S1）

纯 C++（无 UObject / 无线程 / 无 IO）。当前 v1 吃「near-window 契约 + coverage 配置」，吐「coverage∖near-skip tile 集合」。它已收编 VHI/SVO 共通 coverage/near-skip 判定；VHI 的 dirty/reuse/remove 仍留在 VHI tile artifact 层，后续若抽增量计划再单独演进。**纯函数 → automation 直接断言、golden fixture 化。**

```cpp
struct FVoxiaFarFieldCoverageConfig {
    FIntVector CoverageCenterTile;        // 远景覆盖中心，可与近场中心分离
    FIntVector NearCenterTile;            // 来自 FVoxiaNearVoxelWindow snapshot
    int32 RadiusTiles = 0;               // XZ 覆盖半径
    int32 NearSkipRadiusTiles = 0;       // 统一命名
    int32 StepTiles = 1;                 // SVO=MacroCellTiles
    int32 VerticalRadiusTiles = 0;       // 【3D-ready】Y 覆盖半径，v1=0 表示单 Y band
};

struct FVoxiaFarFieldCoveragePlan {
    TArray<FIntVector> Tiles;            // coverage∖near-skip 全集
    TSet<FIntVector> TileSet;            // remove/reuse 侧可直接查 membership
    void Reset();
};

namespace FVoxiaFarFieldCoveragePlanner {
    int32 Chebyshev2D(const FIntVector& A, const FIntVector& B);
    bool ShouldCover(const FVoxiaFarFieldCoverageConfig&, const FIntVector& Tile);
    FVoxiaFarFieldCoveragePlan PlanFull(const FVoxiaFarFieldCoverageConfig&);
}
```

注入差异：VHI / SVO 都用 `PlanFull`；VHI 继续在本地 tile artifact 层用 `TileBoundarySignature` 做 dirty/reuse/remove，SVO 用 `StepTiles=MacroCellTiles`；LOD 不接入。

### 5.2 `FVoxiaFarFieldBuildPipeline<TConfig>` — 异步生命周期 helper（已落地）

模板 struct（值语义，非 UObject），作为 transport 成员（每路线一个实例）。封装 revision / serial guard / in-flight / pending coalesce / pending supersede；`Async(ThreadPool)` 和 GameThread 发布 observe 仍留在 transport，结果 merge 也仍由路线各自处理。**只管生命周期状态，不管 merge 内容、不管算法。**

```cpp
enum class EVoxiaFarFieldBuildRequestDecision {
    UseCompleted,
    StartBuild,
    QueuePending,
    PendingAlreadyQueued
};

template<typename TConfig>
struct FVoxiaFarFieldBuildPipeline {
    EVoxiaFarFieldBuildRequestDecision DecideRequest(...);
    uint64 BeginBuild();
    void FinishCurrentBuild();
    bool ConsumeSupersedingPending(...);
    uint64 MarkApplied();
    void ResetRevision();
    void ResetInFlight();
};
```

注入差异：VHI 完成后仍执行 tile 集合 merge+sort；SVO 完成后仍直接 `Move` build result。LOD 不接入（被动 push 无 serial/pending）。

### 5.3 `FVoxiaFarFieldPatchUploader` — 分帧上传服务（已落地）

纯 C++ struct（持上传队列 + section 池），作为 WorldActor 成员。已把 VHI/SVO 现有 section 池复用、bulk-hide 阈值、pending patch queue、上传统计与完成态收敛到同一服务；patch 构建与距离+朝向排序仍由调用方准备，避免把 VHI tile artifact 与 SVO mesh 算法塞进公共层。

```cpp
struct FVoxiaFarFieldUploadConfig {
    int32 PatchTiles = 8;
    uint64 BuildRevision = 0;
    int32 TotalItems = 0;
    int32 TotalQuads = 0;
    int32 RemovedPatches = 0;
    int32 BulkHideThresholdPatches = 0;
};
struct FVoxiaFarFieldPatchUploader {
    void ResetAll();
    void RemovePatches(const TArray<FIntVector>& Patches, TArray<int32>& OutSections);
    void BeginUpload(TArray<FVoxiaFarFieldPatchMesh>&& Patches, const FVoxiaFarFieldUploadConfig& Config);
    bool PopNextUpload(FVoxiaFarFieldPatchMesh& OutPatch, int32& OutSection);
    void MarkUploadFinished();
    bool IsBulkHidden() const;
};
```

注入差异：VHI 仍先用 tile artifact 计算 dirty/reuse/remove，再合批成 patch mesh；SVO 由 `FVoxiaFarFieldPatchGrid` 把整块 SVO mesh 拆成 patch mesh；LOD 不接入（每 tier 一 section）。

### 5.4 `FVoxiaFarFieldMeshComponentDesc` — 远景 ProcMesh 属性（已落地）

纯 C++ struct，统一远景 `UProceduralMeshComponent` 的 no-collision、async cooking、禁 ray tracing/reflection/sky capture、禁阴影与初始可见性。当前只接 LOD/VHI/SVO 三个远景 component，近场主 mesh 不接入，避免 FarField helper 反向拥有近场语义。

### 5.5 不抽取（保留算法专属）

VHI top+riser 分解 vs SVO octree 遍历；SVO 节点结构 / macro-cell 分块 / seam check；算法层 `MeshEmitter` / `ConfigNormalizer` 模板（过度工程，不抽，仅把 `SameWorldGenConfig` 收成一个 free function）。

## 6. VHI 完善范围（⚠️ 2026-07-01 起冻结，见 D-10）

> **D-10 后 VHI 停止投入**：下表 P0/P1/P2 全部取消，VHI 保持现状当过渡基线。SVO 转主力，远景投入转向「SVO 接分帧上传 + 8km FPS 实测」。下表保留作历史记录。

### 6.1 现在能做（2.5D 源下真完善）

| 优先级 | Task | 说明 | 锚点 |
| --- | --- | --- | --- |
| P0 | 首轮 bulk-reveal 单帧尖峰治理 | bulk-hide（64）现是「全隐→全显」二态；改分帧逐 patch 揭示，消首帧毛刺 | `VoxiaWorldActor.cpp:683-694,781-785` |
| P0 | patch 上传抽出后 VHI 自身瘦身 | S6 后 VHI 删本地 Pending* 成员 + Queue/Continue 两大函数，回归「只产 tile 数据」 | `VoxiaWorldActor.cpp:98-111,568-796` |
| P1 | seam skirt 加固 | 远景 tile 边界加 skirt 锚（呼应 far-lod-heightmap-seam：缺 skirt 致近/远拼接破洞） | `VoxiaVhiImpostor.cpp:84-92,103-159` |
| P1 | material / 法线一致性 | 统一走 `FVoxiaMaterialPalette`；riser 侧面法线校验 | `VoxiaVhiImpostor.cpp:94-101` |
| P2 | 复用率观测 | reuse/upsert/remove 命中率纳入 SnapshotJson，对齐 SVO 监控丰度 | `VoxiaVhiImpostor.cpp:574-598` |

> 本轮 S1–S6 内只做 P0；P1/P2 在 S9（下轮）。

### 6.2 冻结（必须等 canonical 3D voxel 源，不在本轮）

NegY 底面 / 完整 3D occupancy / 列内多段 / 六向 envelope 真正启用——这些都不属于 VHI（按 D-1 归 SVO）。

## 7. 迁移 step（每 step 独立 Build + Automation + commit）

UE 验证回路（关编辑器）：`Build.bat VoxiaEditor Win64 Development -Project=... -WaitMutex -NoLiveCoding`；`UnrealEditor-Cmd.exe ... -ExecCmds="Automation RunTests Voxia.Voxel; Quit" -unattended -nullrhi -nosound` → 读 `Saved\AutomationReport\index.json`。

| Step | 内容 | 验证 | 风险 |
| --- | --- | --- | --- |
| **S1（已落地）** | 建 `FarField/` + `FVoxiaFarFieldCoveragePlanner`（纯函数，含 Y-aware 字段），提供 `PlanFull` 并接入 VHI/SVO coverage 枚举；VHI 的 dirty/reuse 判定仍留在 VHI tile artifact 逻辑 | 新 `Voxia.Voxel.FarFieldCoveragePlanner` 绿；VHI/SVO CLI smoke 计数不退化 | 低 |
| **S2（已落地）** | 抽 `FVoxiaFarFieldBuildPipeline<>`，收编 VHI/SVO transport 中重复的 serial guard + pending coalesce/supersede + revision 发布语义 | 新 `Voxia.Voxel.FarFieldBuildPipeline` 绿；VHI/SVO `until_*` smoke 计数不退化 | 高 |
| **S3（已落地）** | 抽通用 `FVoxiaFarFieldPatchUploader` + `MeshComponentDesc`，把 VHI/SVO 现有 patch section 上传状态机收敛到同一服务，并收敛远景 ProcMesh 属性 | 新 `Voxia.Voxel.FarFieldPatchUploader` / `FarFieldMeshComponentDesc` 绿；VHI/SVO CLI smoke 计数和上传行为不退化 | 高 |
| **S4（已落地）** | SVO builder-side macro-cell artifact/cache/reuse：构建结果保留 per macro-cell mesh/count artifact；中心移动后复用重叠 macro-cell，并在 snapshot / observe 暴露 built/reused/removed/dirty/cache_hit_rate | 新 `Voxia.Voxel.SvoPreview` 复用用例绿；移动 CLI smoke 复用率 `0.958` | 中 |
| **S5（第一片已落地）** | SVO confirmed-store source 边界：`-VoxiaSvoConfirmedSource` 可从客户端 confirmed `FVoxiaVoxelStore` 快照构建；缺 coverage 硬失败并暴露诊断，不 fallback 到 WorldGen/空气 | `Voxia.Voxel.SvoPreview` source 用例绿；confirmed source CLI 完整/缺覆盖 smoke | 高 |
| **S6a（第一片已落地）** | SVO confirmed-source coverage preflight + dev-only 小范围 preload：snapshot/observe 暴露 expected/present/missing source chunks；WorldGen preview 可按 `-VoxiaSvoConfirmedSourceMaxChunks` 预加载缺失 source chunks，8km 超预算时 build 前拒绝 | `Voxia.Voxel.SvoPreview` coverage 用例绿；radius=1 preload smoke 绿；8km budget gate smoke 给出 7,208,488 missing | 中 |
| **S6b（第一片已落地）** | 服务端 SVO source 级 canonical coverage/materialization：`WorldPackSvoSourceMaterializer` 按同构 tile/macro-cell coverage 统计 `expected/present/missing`，`world_pack_svo_source_materialize.exs` 支持 dry-run 与 bounded materialization，预算内通过 `WorldPackBootstrapper` 写 snapshots 并复查 ready | ExUnit 3 tests 绿；8km dry-run 返回 7,208,488 missing；单 tile 343 chunks materialize smoke ready | 中 |
| **S6c（第一片已落地）** | 客户端 baseline pack 本地 H gate：`world_pack_index_v1` window load 读取 `scene_<id>_world_pack_release_manifest.json`，校验窗口 `.vxpack` shard manifest entry、`size_bytes`、`sha256` 后才应用 0x62 payload；缺 manifest、缺 entry、size/hash mismatch 均硬失败 | `Voxia.Net.TerrainBaselinePackIndex` 新增 manifest hash mismatch 用例绿；`Build.bat VoxiaEditor ... -NoLiveCoding` 绿 | 中 |
| **S6f（第一片已落地）** | 客户端 entry gate：`ConnectGate` / `EnterScene` 在 `entry_gate_ready=false` 时硬拒绝，observe 写 `tcp_connect_rejected` / `enter_scene_rejected`，不会打开 socket bootstrap；完整 launcher/update 包下载/安装 UI 仍不在本片范围 | `Voxia.Net.TerrainBaselineGate` 红绿；`Build.bat VoxiaEditor ... -NoLiveCoding` 绿；pack-index automation 复跑绿 | 中 |
| **S6d（第一片已落地）** | SVO upload-level section 复用：`FVoxiaFarFieldPatchUploader` 记录 live patch mesh fingerprint，SVO 不再每次 `ClearAllMeshSections`，跨 tile 更新只上传变化 patch，未变 patch 保留原 section | `Voxia.Voxel.FarFieldPatchUploader` 红绿；8km SVO CLI move smoke 为 39 uploaded / 322 reused / 361 live sections | 中 |
| **S6e（第一片已落地）** | CPU SVDAG artifact 统计：按当前 occupancy SVO 递归生成子树 signature，统计 `svdag_node_count` / `svdag_unique_node_count` / `svdag_merged_node_count` / `svdag_compression_ratio`，为后续 GPU resource 做数据面起点 | `Voxia.Voxel.SvoPreview` 红绿；8km SVO CLI smoke 为 189144 / 70085 / 119059 / 0.371 | 中 |
| **S6g（第一片已落地）** | runtime SVDAG resource 数据面：SVO builder 输出 CPU 侧 root table + 去重 node buffer，并在 snapshot/observe 暴露 ready/root/node/child-ref/GPU-byte/compression 字段；RHI buffer / shader / raymarch 尚未接入 | `Voxia.Voxel.SvoPreview` 红绿；8km SVO CLI smoke 为 ready=true / 21016 roots / 3627 nodes / 1240896 bytes | 中 |
| S6+（下一步） | 8km 生产级权威 3D 源全量调度、持久化 artifact、完整 launcher/update 包下载/安装 UI 与 diff-chain 可视化流程、GPU raymarch renderer / RHI buffer / global shader path；VHI 冻结为过渡 baseline。当前用户要求先不碰服务端，后续仅继续客户端侧渲染生产化 | 分阶段 CLI + real RHI + 服务端 materialization 验收 | 高 |

> 注：2026-07-01 证据复核后，本节不再按旧 S1–S6 一次性完成叙事推进；当前以小步可验证落地为准，实际进度见下方日志。D-2/D-8 这类宽 blast cleanup 延后到对应公共组件有明确第二消费者时再做。

## 8. 风险与对抗式批判处置

- **过度工程**：只抽编排（A.2/A.3 逐行重复），算法层不抽模板。`SameWorldGenConfig` 收 free function。
- **LOD 强套**：明确不接入（D-7），只共享 `MeshComponentDesc`。决策稿写死，避免后人"为对称而对称"。
- **SVO/VHI 粒度差异**：通用 uploader 只处理 patch mesh payload 与 section 池，VHI tile artifact 与 SVO mesh/macro-cell 粒度差异留给各自调用方，避免为形式统一搬算法状态。
- **不破坏自动化与 CLI smoke**：行为等价 step 先确认现有测试覆盖（tile 集合 / revision / snapshot）；不足处先补测试再重构；上传状态机变更必须补 real RHI smoke。
- **bevy/web parity**：无牵连——VHI/SVO/LOD 是 UE 专属远景视觉实验，不触线协议 / 权威态 / WorldGen 取样接口。

## 9. 不在本轮范围

- 切远景数据源到 8km 生产级权威 3D voxel store / D-delta（下个里程碑，D-5）；当前只落地客户端已有 confirmed store 的 source boundary 与覆盖硬失败。
- SVO 持久化 artifact、完整 launcher/update 包下载/安装 UI、GPU raymarch renderer / RHI buffer / global shader path；客户端本地 baseline pack release-manifest shard 校验和 `ConnectGate` / `EnterScene` entry gate 只覆盖已下载 `.vxpack` 与入场前硬拒，不等于完成包分发链路。runtime SVDAG resource 目前只是 CPU 侧 root/node 数据面，尚未创建 RHI buffer 或 shader 消费路径；upload-level section 复用目前只是在 ProceduralMesh patch section 层跳过未变化 mesh，尚未替换为 runtime mesh / HISM / Nanite-ready artifact。
- VHI P1/P2 完善已因 D-10 冻结取消；后续只做必要兼容维护。
- heightmap-LOD 接入统一抽象（永不，D-7）。

## 10. 进度日志

- 2026-06-30：落地决策稿。5-agent workflow 测绘三条远景路线重复面；用户拍板 D-1~D-9（VHI=2.5D baseline / 3D 归 SVO / 抽编排不抽算法 / 公共组件 3D-ready / 3D 源切换作下个里程碑 / 本轮 S1–S6）。下一步 S1：建 `FarField/` + `FVoxiaFarFieldCoveragePlanner` 纯函数 + golden automation。
- 2026-07-01：**证据复核纠偏**。此前关于 `FVoxiaFarFieldBuildPipeline`、`FVoxiaFarFieldMeshComponentDesc`、通用 `FVoxiaFarFieldPatchUploader`、S1-S6 全完成、15 个 automation、11.35s、191 FPS 的记录未被当前代码证实，不能作为当前事实；后续只按本日志中的可复现 build / automation / CLI / RHI 证据更新。
- 2026-07-01：**远景路线收敛拍板（D-10）**。对比数据坐实 VHI 无持久优势（8km：VHI 932,892 quad vs SVO 155,399 quad；现阶段两者同显 2.5D；VHI 唯一优势=已验证的分帧上传，恰是 SVO 迟早要做的活）。**SVO 转主力，VHI 冻结当过渡基线**（不删=安全网，停投入=取消 §6 P0/P1/P2）。下一步从「VHI 完善」转为 **SVO 接分帧上传**（把原延后的 S8 `FVoxiaFarFieldPatchUploader`/per-macro-cell 输出提前）→ RHI 实测 SVO 8km FPS 达 120 级 → 达标后再议 VHI 退役。届时 PatchUploader 自然获得第二消费者，section-pool 结构体搬迁不再是 1-消费者高风险。
- 2026-07-01：**证据复核纠偏 + SVO patch 分帧上传落地**。本节此前关于 `MacroCells`、15 个 automation、11.35s、191 FPS 的说法未被当前代码证实，不能作为当前事实。实际落地范围是：新增 `FarField/VoxiaFarFieldPatchGrid.{h,cpp}` 和 `Voxia.Voxel.FarFieldPatchGrid` automation；`AVoxiaWorldActor` 将 SVO mesh 按 `VoxiaSvoPatchTiles=8` 拆成 19×19 patch，并用 `VoxiaSvoUploadBudgetMs` / `VoxiaSvoUploadMaxPatchesPerFrame` 分帧上传。验证：`Build.bat VoxiaEditor ... -NoLiveCoding` 退出 0；`Automation RunTests Voxia.Voxel` 退出 0，13 个测试全 Success；null RHI CLI smoke 产出 `quad_count=155399`、`seam_check.status=pass`、`uploaded_patches=361`、`live_sections=361`、`elapsed_ms=537.6`；real RHI smoke 产出 `build_ms=571.910`、`uploaded_patches=361`、`live_sections=361`、`elapsed_ms=1365.0`，上传完成后 FPS 样本约 104-115。
- 2026-07-01：**CoveragePlanner 第一片落地**。新增 `FarField/VoxiaFarFieldCoveragePlanner.{h,cpp}` 和 `Voxia.Voxel.FarFieldCoveragePlanner` automation；`FVoxiaFarFieldCoveragePlanner::PlanFull` 统一 VHI/SVO 远景覆盖枚举，VHI 的 dirty/reuse/remove 仍在 VHI tile artifact 逻辑里处理，SVO 用 `StepTiles=MacroCellTiles` 维持 21016 macro-cell 覆盖。验证：先写测试并确认缺 header 编译失败；实现后 `Build.bat VoxiaEditor ... -NoLiveCoding` 退出 0；`Automation RunTests Voxia.Voxel` 退出 0，14 个测试全 Success；VHI null RHI CLI smoke 为 `tile_count=21024` / `face_sample_count=336384` / `quad_count=932892` / `build_elapsed_ms=899.1`；SVO null RHI CLI smoke 为 `macro_cell_count=21016` / `node_count=189144` / `leaf_count=168128` / `quad_count=155399` / `seam_check.status=pass`，上传 `uploaded_patches=361` / `live_sections=361` / `elapsed_ms=341.5`。
- 2026-07-01：**BuildPipeline 第二片落地**。新增 `FarField/VoxiaFarFieldBuildPipeline.h` 和 `Voxia.Voxel.FarFieldBuildPipeline` automation；`UVoxiaTransportSubsystem` 用两个 `FVoxiaFarFieldBuildPipeline<TConfig>` 实例替代 VHI/SVO 各自的 revision / in-flight / pending / serial 散落成员，保留 VHI 结果 merge+sort 与 SVO result move 的路线差异。验证：先写测试并确认缺 header 编译失败；实现后 `Build.bat VoxiaEditor ... -NoLiveCoding` 退出 0；`Automation RunTests Voxia.Voxel` 退出 0，当时 15 个测试全 Success；VHI null RHI CLI smoke `until_vhi` 通过，最终 `tile_count=21024` / `face_sample_count=336384` / `quad_count=932892` / `vhi_revision=1`；SVO null RHI CLI smoke `until_svo` 通过，最终 `macro_cell_count=21016` / `quad_count=155399` / `seam_check.status=pass` / `uploaded_patches=361` / `live_sections=361`。当时剩余：通用 `FVoxiaFarFieldPatchUploader`、per-macro-cell artifact/cache、权威 3D voxel 源、持久化 artifact、服务端 materialization、H gate；PatchUploader 已由下一条补齐。
- 2026-07-01：**PatchUploader + MeshComponentDesc 第三片落地**。新增 `FarField/VoxiaFarFieldPatchUploader.{h,cpp}`、`FarField/VoxiaFarFieldMeshComponentDesc.{h,cpp}` 以及 `Voxia.Voxel.FarFieldPatchUploader` / `Voxia.Voxel.FarFieldMeshComponentDesc` automation；`AVoxiaWorldActor` 用两个 `FVoxiaFarFieldPatchUploader` 实例替代 VHI/SVO 各自的 pending upload / section pool / bulk-hide 状态，并用 `FVoxiaFarFieldMeshComponentDesc::FarVisual` 收敛 LOD/VHI/SVO 远景 ProcMesh 属性。验证：先写测试并确认缺 header 编译失败；实现后 `Build.bat VoxiaEditor ... -NoLiveCoding` 退出 0；`Automation RunTests Voxia.Voxel` 退出 0，17 个测试全 Success；VHI CLI smoke `until_vhi 180000 20000; wait 12000; vhi` 通过，`tile_count=21024` / `face_sample_count=336384` / `quad_count=932892` / `build_elapsed_ms=889.7` / `uploaded_patches=361` / `live_sections=361` / `elapsed_ms=11355.1`；SVO CLI smoke `until_svo 180000 20000; wait 1000; svo` 通过，`macro_cell_count=21016` / `quad_count=155399` / `seam_check.status=pass` / `uploaded_patches=361` / `live_sections=361` / `elapsed_ms=266.5`。当时仍未落地：per-macro-cell artifact/cache（已由下一条补齐）、权威 3D voxel 源、持久化 artifact、服务端 materialization、H gate、GPU raymarch/SVDAG。
- 2026-07-01：**SVO macro-cell artifact/cache 第四片落地**。`FVoxiaSvoBuildResult` 新增 per macro-cell artifacts、dirty/removed macro-cell 列表和 `built/reused/removed/dirty/cache_hit_rate` 统计；`BuildWorldGenMacroCellUpdate` 在相同 worldgen/几何配置下复用重叠 macro-cell artifact，参数变化会强制全量重建；transport 的 WorldGen preview 路径用旧 build result 生成 reuse context，避免 tile window revision 变化误阻断同一 WorldGen 源的复用。验证：`Build.bat VoxiaEditor ... -NoLiveCoding` 退出 0；`Automation RunTests Voxia.Voxel` 退出 0，17 个测试全 Success；移动 CLI smoke 首次 build 为 `built_macro_cell_count=21016` / `reused_macro_cell_count=0` / `cache_hit_rate=0.000` / `build_ms=436.436`，移动到 `center_tile=[17,0,-51]` 后第二次 build 为 `built_macro_cell_count=879` / `reused_macro_cell_count=20137` / `removed_macro_cell_count=879` / `dirty_macro_cell_count=879` / `cache_hit_rate=0.958` / `build_ms=87.482` / `seam_check.status=pass`。当时仍未落地：权威 3D voxel 源、持久化 artifact、服务端 materialization、H gate、GPU raymarch/SVDAG、upload-level 增量 section 复用。
- 2026-07-01：**SVO confirmed-store source boundary 第五片落地**。`FVoxiaVoxelStore` 暴露 `SampleMacro`，SVO builder 新增 `EVoxiaSvoSourceKind` 与 `BuildConfirmedVoxelStoreMacroCellUpdate`；confirmed-store source 先检查 coverage，完整才构建 3D mesh，缺 chunk 直接 `source_complete=false` / `quad_count=0` / `build_error`，不能把 missing chunk 当空气。transport 新增 `-VoxiaSvoConfirmedSource`，后台构建复制当前 `FVoxiaVoxelStore` 快照，snapshot / observe 暴露 `source_kind`、`source_complete`、`missing_source_chunk_count`、`build_error`，actor 对 incomplete source 不上传 mesh。验证：`Build.bat VoxiaEditor ... -NoLiveCoding` 退出 0；`Automation RunTests Voxia.Voxel` 退出 0，17 个测试全 Success；默认 WorldGen 8km CLI smoke 仍为 `source_kind=worldgen` / `source_complete=true` / `macro_cell_count=21016` / `quad_count=155399` / `seam_check.status=pass`；confirmed-store 完整覆盖 smoke 为 `source_kind=confirmed_voxel_store` / `source_complete=true` / `missing_source_chunk_count=0` / `macro_cell_count=1` / `quad_count=28` / `seam_check.status=pass`；缺覆盖 smoke 为 `source_complete=false` / `missing_source_chunk_count=2744` / `quad_count=0` / `build_error="missing confirmed voxel chunk coverage for SVO source: 2744 chunks"`。
- 2026-07-01：**SVO confirmed-source coverage preflight / preload 第六片第一段落地**。新增 `FVoxiaSvoSourceCoverage` 与 `AnalyzeConfirmedSourceCoverage`，SVO snapshot/observe 增加 `expected_source_chunk_count` / `present_source_chunk_count` / `missing_source_chunk_count`。WorldGen preview 下，`-VoxiaSvoConfirmedSource` 会在 build 前按 coverage 缺口预加载 confirmed source chunks，但受 `-VoxiaSvoConfirmedSourceMaxChunks` 约束；超过预算时发布 diagnostic SVO snapshot，不启动巨量物化。验证：先写 coverage API automation 并确认编译红灯；实现后 `Build.bat VoxiaEditor ... -NoLiveCoding` 退出 0；`Automation RunTests Voxia.Voxel` 退出 0，17 个 voxel tests 全 Success；radius=1 preload smoke 为 `expected_source_chunk_count=3087` / `present_source_chunk_count=3087` / `missing_source_chunk_count=0` / `quad_count=174` / `seam_check.status=pass`；8km confirmed-source budget smoke 为 `expected_source_chunk_count=7208488` / `present_source_chunk_count=0` / `missing_source_chunk_count=7208488` / `quad_count=0` / `build_error="SVO confirmed source requires 7208488 missing chunks, above preload budget 3000"`；默认 WorldGen 8km smoke 仍为 `source_kind=worldgen` / `source_complete=true` / `macro_cell_count=21016` / `quad_count=155399` / `seam_check.status=pass`。仍未落地：8km 生产级权威源覆盖/物化、持久化 artifact、服务端 materialization、H gate、GPU raymarch/SVDAG、upload-level 增量 section 复用。
- 2026-07-01：**服务端 SVO source materialization 第六片第二段落地**。新增 `WorldServer.Voxel.WorldPackSvoSourceMaterializer` 与 `scripts/world_pack_svo_source_materialize.exs`：服务端按与客户端 SVO coverage 同构的 tile/macro-cell 规则统计 canonical `expected_source_chunk_count` / `present_source_chunk_count` / `missing_source_chunk_count`，预算内通过 `WorldPackBootstrapper` / `WorldGenMaterializer` 写 bounded canonical snapshots，并在写后复查仍 incomplete 时显式错误，不返回假绿。验证：先写 ExUnit 并确认缺模块/缺 `coverage/1` 红灯；实现后 `MIX_ENV=test mix test apps/world_server/test/world_server/voxel/world_pack_svo_source_materializer_test.exs --no-start` 退出 0，`3 passed`；`MIX_ENV=test mix run --no-start scripts/world_pack_svo_source_materialize.exs --dry-run --radius-tiles 72 --near-skip-radius-tiles 1 --macro-cell-tiles 1 --max-chunks 3000 --no-migrate` 返回非零，报告 `macro_cell_count=21016` / `expected_source_chunk_count=7208488` / `present_source_chunk_count=0` / `missing_source_chunk_count=7208488`；`MIX_ENV=test mix run --no-start scripts/world_pack_svo_source_materialize.exs --logical-scene-id 919998 --radius-tiles 0 --near-skip-radius-tiles -1 --macro-cell-tiles 1 --max-chunks 400 --batch-size 64 --no-migrate` 退出 0，报告单 tile `343` chunks inserted、final missing `0`、status `ready`。仍未落地：8km 生产级全量调度、持久化 artifact、H gate、GPU raymarch/SVDAG、upload-level 增量 section 复用。
- 2026-07-01：**客户端 baseline pack 本地 H gate 第一片落地**。`FVoxiaTerrainBaselinePackReleaseManifest` 支持解析 `world_pack_release_manifest_v1` 并校验 scene/content_version、shard entry、`size_bytes` 与 `sha256`；`UVoxiaTransportSubsystem::LoadTerrainBaselineWindowFromPackIndex` 现在要求本地 `scene_<id>_world_pack_release_manifest.json`，窗口 `.vxpack` shard 先过 manifest 校验，再读取 footer-table 和 0x62 payload。验证：先写 manifest-aware window-load automation 并确认缺类型/缺 overload 编译红灯；实现后曾因 UE Generic SHA256 path 在自动化中崩溃，最终改用 UE OpenSSL 依赖；`Build.bat VoxiaEditor Win64 Development ... -NoLiveCoding` 退出 0；`UnrealEditor-Cmd.exe ... Automation RunTests Voxia.Net.TerrainBaselinePackIndex; Quit` 退出 0，log 报 `Test Completed. Result={Success}`。仍未落地：完整 launcher/update 包下载与 release manifest 生成分发、SVO 持久化 artifact、GPU raymarch/SVDAG、upload-level 增量 section 复用。
- 2026-07-01：**客户端 entry gate 第一片落地**。`UVoxiaTransportSubsystem::ConnectGate` / `EnterScene` 现在复用同一个 terrain baseline entry gate；`TerrainBaselineSnapshot()` 暴露 `entry_gate_ready`，未 ready 时写 `LastError` / `LastTerrainBaselineRejectReason` 并 emit `tcp_connect_rejected` 或 `enter_scene_rejected`，不会调用 `Disconnect("reconnect")`、不会进入 socket connect。验证：先写 `Voxia.Net.TerrainBaselineGate` automation 并确认红灯中出现 `tcp_connect_started` / `SE_ECONNREFUSED`；实现后 `Build.bat VoxiaEditor Win64 Development ... -NoLiveCoding` 退出 0；`Automation RunTests Voxia.Net.TerrainBaselineGate; Quit` 日志报 `Test Completed. Result={Success}`，observe 为 `tcp_connect_rejected` / `entry_gate_ready=false`；复跑 `Automation RunTests Voxia.Net.TerrainBaselinePackIndex; Quit` 退出 0，log 报 `Test Completed. Result={Success}`。仍未落地：完整 launcher/update 包下载/安装 UI 与 diff-chain 可视化流程、SVO 持久化 artifact、GPU raymarch/SVDAG。
- 2026-07-01：**SVO upload-level section 复用第一片落地**。`FVoxiaFarFieldPatchUploader` 为 live patch 保存 mesh fingerprint，`BeginUpload` 会跳过 fingerprint 未变化的 live patch；`AVoxiaWorldActor::QueueSvoMeshUpdate` 不再对每次 SVO revision 全量 `ClearAllMeshSections`，只清除 stale patch section 并保留未变 section。验证：先写 `Voxia.Voxel.FarFieldPatchUploader` unchanged-live-patch 用例并确认缺 `GetReusedPatchCount` 编译红灯；实现后 `Build.bat VoxiaEditor ... -NoLiveCoding` 退出 0；`Automation RunTests Voxia.Voxel` 退出 0，17 个测试全 Success；8km null RHI SVO move smoke 首次上传 `uploaded_patches=361` / `reused_patches=0`，跨 1 tile 后第二次为 `uploaded_patches=39` / `reused_patches=322` / `live_sections=361`，SVO snapshot 为 `built_macro_cell_count=148` / `reused_macro_cell_count=20868` / `cache_hit_rate=0.993` / `seam_check.status=pass`。仍未落地：完整 launcher/update 包下载与 release manifest 生成分发、SVO 持久化 artifact、GPU raymarch/SVDAG、runtime mesh / HISM / Nanite-ready artifact。
- 2026-07-01：**CPU SVDAG artifact 统计第一片落地**。`FVoxiaSvoBuildResult` / macro-cell artifact 增加 `SVDag*` 统计；builder 用与现有 occupancy SVO 一致的分类/拆分规则生成子树 signature，并统计 unique/merged node 与 compression ratio。验证：先写 `Voxia.Voxel.SvoPreview` SVDAG 字段/确定性/snapshot 用例并确认缺字段编译红灯；实现后 `Build.bat VoxiaEditor ... -NoLiveCoding` 退出 0；`Automation RunTests Voxia.Voxel.SvoPreview` 退出 0；8km null RHI SVO smoke 首次为 `svdag_node_count=189144` / `svdag_unique_node_count=70085` / `svdag_merged_node_count=119059` / `svdag_compression_ratio=0.371` / `seam_check.status=pass`，跨 1 tile 后为 `70045` unique、`0.370` ratio，仍 `cache_hit_rate=0.993`。当时仍未落地：完整 launcher/update 包下载与 release manifest 生成分发、SVO 持久化 artifact、GPU raymarch renderer / runtime SVDAG resource、runtime mesh / HISM / Nanite-ready artifact；runtime SVDAG resource 数据面已由下一条补齐。
- 2026-07-01：**runtime SVDAG resource 数据面第一片落地**。`FVoxiaSvoBuildResult` 新增 `RuntimeResource`，SVO builder 以当前 occupancy 拆分规则生成 CPU 侧 root table + 去重 node buffer；`SvoSnapshot()` 暴露 `runtime_resource_ready` / `runtime_root_count` / `runtime_node_count` / `runtime_child_ref_count` / `runtime_gpu_bytes` / `runtime_compression_ratio`。验证：先写 `Voxia.Voxel.SvoPreview` runtime resource 断言并确认缺 `RuntimeResource` 编译红灯；实现后 `Build.bat VoxiaEditor ... -NoLiveCoding` 退出 0；`Automation RunTests Voxia.Voxel.SvoPreview` 退出 0；`Automation RunTests Voxia.Voxel` 退出 0，17 个测试全 Success；8km null RHI SVO smoke 为 `runtime_resource_ready=true` / `runtime_root_count=21016` / `runtime_node_count=3627` / `runtime_child_ref_count=24416` / `runtime_gpu_bytes=1240896` / `runtime_compression_ratio=0.019`，`seam_check.status=pass`。仍未落地：RHI buffer、global shader、GPU raymarch renderer、SVO 持久化 artifact、runtime mesh / HISM / Nanite-ready artifact。
