# Voxia 远景公共组件抽取 + VHI 2.5D baseline 定位 — 决策稿

> 当前决策稿。目标：把 VHI / SVO（/heightmap-LOD）三条远景路线里**逐行重复的编排逻辑**抽成正交公共组件，同时把 VHI 的定位明确为「廉价 2.5D 地表 baseline」、把 3D 远景（浮空岛 / 洞穴 / 悬崖背面）的职责归给 SVO。**抽编排，不抽算法。**
>
> 上游证据源：本目录 `2026-06-30-voxia-vhi-experiment-plan.md`、`2026-06-30-voxia-svo-preview-design.md`、`2026-06-30-voxia-near-window-kernel-and-svo-roadmap.md`、`2026-06-29-voxel-sync-window-and-render-design.md`（W-Q6=A：当前世界 2.5D 锁定、3D 归 delta）、`2026-06-28-体素世界与远景渲染-当前真相(整合).md`（权威体素=全生命周期唯一真值）。

## 1. 背景与问题

2026-06-30 一批落地了三条窗口外远景路线，均为 **visual-only 派生物**（绝不进 confirmed truth / 碰撞 / 编辑 / H gate）：

- **VHI**（`VoxiaVhiImpostor`）：按 XZ tile 生成连续 top surface + 高差 riser；已有最完整的工程链路（tile artifact 增量复用 + 分帧 patch 上传）。
- **SVO**（`VoxiaSvoPreview`）：3D occupancy octree，按 macro-cell 递归 empty/solid/mixed 导出 leaf surface；但上传仍是单帧全量、无 cache。
- **heightmap-LOD**：服务端 push 的多 tier 2.5D 曲面（0x6B），被动覆盖存储。

测绘（5-agent workflow，2026-06-30）暴露三类**逐行重复**：

| 类别 | 重复点 | 严重度 |
| --- | --- | --- |
| transport 异步生命周期 | VHI `RequestVhiImpostorsAround/StartVhiBuildAsync/完成回调`（`VoxiaTransportSubsystem.cpp:1352-1633`）与 SVO 对应路径（1648-1859）**逐行镜像**：serial guard + pending coalesce/supersede + ThreadPool 后台 + GameThread 发布 `++Revision` + observe，连 6 个 pending 成员都成对复制 | 极高 |
| WorldActor mesh 上传 | 4 个 ProcMesh component 的 10 项属性初始化逐字重复（`VoxiaWorldActor.cpp:275-314`）；VHI 有完整分帧 patch 上传框架（568-796），SVO/LOD 贫血（单帧全量） | 极高 / 分歧 |
| tile 流式增量 | `dirty/upsert/remove` 复用计划**只有 VHI 有**（`BuildWorldGenTileUpdate`/`CanReuseVhiTile`/`TileBoundarySignature`），且与 VHI mesher 算法**耦合**，SVO 无法复用 | 能力缺口 |
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
| D-4 | SVO 本轮参与 | **共享 CoveragePlanner + BuildPipeline**；per-macro-cell 上传改造（接 PatchUploader）延后 | SVO 改 mesh layout 高风险，不阻塞前序收益 |
| D-5 | 3D 源切换时机 | **本轮抽取先行（公共组件全部 3D-ready / Y-aware 设计），切 SVO 源到权威 3D voxel 作为下个里程碑** | 公共层不锁 2.5D，下轮接 3D 源不返工 |
| D-6 | 公共组件落点 | 新建 `Source/Voxia/FarField/`（与 `Voxel/` 平级），前缀 `FVoxiaFarField*` | 明确「visual-only 远景编排」边界，与权威近场层物理隔离 |
| D-7 | heightmap-LOD 是否接入统一抽象 | **不接入**，保持独立 `TMap<stride>` 路径，仅复用 `MeshComponentDesc` 工具 | LOD 是被动 push / 多 tier，强套引入恒空状态机 |
| D-8 | near-skip 参数命名 | 统一 `NearSkipRadiusTiles`，删 VHI `InnerSkipRadiusTiles` 别名 | 同概念两名违显式契约；未上线无兼容包袱 |
| D-9 | 重构「行为等价」验收口径 | snapshot JSON **字节级不变**（除显式新增字段）+ 既有 12 个 `Voxia.Voxel` automation 绿 + S6 过 Layer-3 像素回归 | 给重构机械可判定的安全网 |

## 4. 3D-ready 硬约束（D-5 落实）

公共组件**必须**按 3D 可扩展设计，即便当前数据源是 2.5D：

- **Coverage 必须 Y-aware**：coverage 描述不能只有 XZ 半径；需保留垂直方向（Y）覆盖维度（v1 可只用单一 Y band，但接口/数据结构留 Y），否则远处高空/地下的浮空岛、深洞会被 XZ-only 规划漏掉。
- **数据模型不假设"一列一高"**：CoveragePlanner / BuildPipeline / PatchUploader 只认 `FIntVector Tile`（含 Y）与注入的算法回调，不内嵌高度场假设。SVO 接 3D 源时只换 `BuildOnThreadPool` 注入实现，公共层不动。
- **patch 是上传分组单位、不绑算法 tile**：粒度由配置决定（VHI `PatchTiles=8`，SVO 未来 `PatchTiles=MacroCellTiles`）。

## 5. 公共组件架构

```
Source/Voxia/
  Voxel/        ← 权威近场 + 算法 mesher（VHI/SVO/Heightmap mesher 留这里，只是「算法」）
  FarField/     ← 新：远景编排层（规划 / 生命周期 / 上传，全部 visual-only、3D-ready）
  Net/          ← transport（薄化，持有 BuildPipeline 实例）
  Gameplay/     ← WorldActor/Pawn（薄化，持有 PatchUploader 实例）
```

### 5.1 `FVoxiaFarFieldCoveragePlanner` — 纯函数规划器（S1）

纯 C++（无 UObject / 无线程 / 无 IO）。吃「near-window 契约 + coverage 配置」，吐「本轮 build / reuse / remove tile 集合 + coverage-center（含 recenter hysteresis）」。收编 coverage/near-skip 判定 + tile 增量计划。**纯函数 → automation 直接断言、golden fixture 化。**

```cpp
struct FVoxiaFarFieldCoverageConfig {
    FIntVector NearCenterTile;            // 来自 FVoxiaNearVoxelWindow snapshot
    int32 RadiusTiles = 0;               // XZ 覆盖半径
    int32 VerticalRadiusTiles = 0;       // 【3D-ready】Y 覆盖半径，v1=0 表示单 Y band
    int32 NearSkipRadiusTiles = 0;       // 统一命名
    int32 RecenterHysteresisTiles = 0;
    FIntVector PrevCoverageCenterTile;
    int32 StepTiles = 1;                 // SVO=MacroCellTiles
};

struct FVoxiaFarFieldCoveragePlan {
    FIntVector CoverageCenterTile;
    TArray<FIntVector> CoverTiles;       // coverage∖near-skip 全集
    TArray<FIntVector> UpsertTiles;      // 新进入 / 需重建
    TArray<FIntVector> RemoveTiles;      // 离开 coverage
    TArray<FIntVector> ReuseTiles;       // 命中签名可复用
    bool bRecentered = false;
};

namespace FVoxiaFarFieldCoveragePlanner {
    FVoxiaFarFieldCoveragePlan PlanFull(const FVoxiaFarFieldCoverageConfig&);     // SVO/初版
    FVoxiaFarFieldCoveragePlan PlanIncremental(                                   // VHI
        const FVoxiaFarFieldCoverageConfig&,
        const TSet<FIntVector>& AliveTiles,
        TFunctionRef<uint64(FIntVector)> TileSignatureFn,    // 注入①算法相关边界签名
        const TMap<FIntVector,uint64>& PrevSignatures);
}
```

注入差异：VHI 用 `PlanIncremental` + `TileBoundarySignature`；SVO 用 `PlanFull` + `StepTiles=MacroCellTiles`；LOD 不接入。

### 5.2 `FVoxiaFarFieldBuildPipeline<TConfig,TResult>` — 异步生命周期 helper（S4）

模板 struct（值语义，非 UObject），作为 transport 成员（每路线一个实例）。封装 serial guard + pending coalesce/supersede + `Async(ThreadPool)` + GameThread 发布 `++Revision` + observe。**只管生命周期，不管 merge 内容、不管算法。**

```cpp
template<typename TConfig, typename TResult>
struct FVoxiaFarFieldBuildPipeline {
    TResult Result; uint64 Revision = 0;
    bool bInFlight = false; bool bHasPending = false;
    uint64 BuildSerial = 0; uint64 PendingSourceVoxelRevision = 0;
    TConfig PendingConfig;

    struct FHooks {
        TFunctionRef<bool(const TConfig&, const TConfig&)> SameConfig;        // 注入①
        TFunctionRef<void(const TConfig&, TResult&)>       BuildOnThreadPool; // 注入②（后台）
        TFunctionRef<void(TResult& Live, TResult&& Fresh)> MergeOnGameThread; // 注入③
        TFunctionRef<void(const TCHAR*)>                   EmitObserve;       // 注入④
    };
    bool Request(const TConfig&, uint64 SourceVoxelRevision, const FHooks&, /*WeakThis*/...);
};
```

注入差异：VHI `MergeOnGameThread`=tile 集合 merge+sort；SVO=`Move`。LOD 不接入（被动 push 无 serial/pending）。

### 5.3 `FVoxiaFarFieldPatchUploader` — 分帧上传服务（S6）

纯 C++ struct（持上传队列 + section 池），作为 WorldActor 成员。把 VHI 现有「patch 分组 / 距离+朝向排序 / section 池复用 / bulk-hide 阈值 / time+count 双预算分帧」泛化。同时收编 `FVoxiaFarFieldMeshComponentDesc::ApplyTo(UProceduralMeshComponent*)`（10 项 component 属性）。

```cpp
struct FVoxiaFarFieldUploadConfig {
    int32 PatchTiles = 8;                   // SVO 未来=MacroCellTiles
    double BudgetMs = 3.0; int32 MaxPatchesPerFrame = 8;
    int32 BulkHideThresholdPatches = 64;
    FIntVector CenterTile; FVector2D CameraForward;
};
struct FVoxiaFarFieldPatchUploader {
    void Queue(const TArray<FIntVector>& Upsert, const TArray<FIntVector>& Remove,
               const TArray<FIntVector>& Dirty, const FVoxiaFarFieldUploadConfig&, uint64 BuildRevision);
    void ContinueUpload(UProceduralMeshComponent*,
                        TFunctionRef<void(FVoxiaMeshData&, FIntVector Patch)> AppendPatchMesh);
    bool IsBulkHidden() const;
};
```

注入差异：VHI `AppendPatchMesh`=逐 tile 拼 mesh、排序距离+朝向；SVO 接入（S8，延后）需先改 per-macro-cell 输出；LOD 不接入（每 tier 一 section）。

### 5.4 不抽取（保留算法专属）

VHI top+riser 分解 vs SVO octree 遍历；SVO 节点结构 / macro-cell 分块 / seam check；算法层 `MeshEmitter` / `ConfigNormalizer` 模板（过度工程，不抽，仅把 `SameWorldGenConfig` 收成一个 free function）。

## 6. VHI 完善范围

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
| **S1** | 建 `FarField/` + `FVoxiaFarFieldCoveragePlanner`（纯函数，含 Y-aware 字段），**先不接线** + 新 automation `Voxia.Voxel.FarFieldCoverage`（golden fixture：tile 集合 + 增量 diff） | 新测试绿；旧 12 测试不动 | 低 |
| **S2** | VHI 接入 CoveragePlanner（tile 选择改调规划器，注入 `TileBoundarySignature`） | VHI 既有测试绿、snapshot tile 集合不变 | 中 |
| **S3** | SVO 接入 CoveragePlanner（`PlanFull` + `StepTiles=MacroCellTiles`） | SVO 测试绿、seam_check 不退化 | 中 |
| **S4** | 抽 `FVoxiaFarFieldBuildPipeline<>`，VHI 先接（transport 1352-1633 收编），删 VHI 6 个 pending 成员 | VHI until_* / revision bump 行为不变 | 高 |
| **S5** | SVO 接入 BuildPipeline（transport 1648-1859 收编） | SVO revision/pending 行为不变 | 中 |
| **S6** | 抽 `FVoxiaFarFieldPatchUploader` + `MeshComponentDesc`，VHI 先接（WorldActor 568-796 收编），4 component 初始化统一；顺手把 D-2 砍 5 面、D-8 统一命名做掉 | VHI 分帧上传帧预算行为不变；过 Layer-3 像素回归 | 高 |
| S7+ | （下轮）VHI P0 bulk-reveal 分帧揭示 → SVO per-macro-cell（S8）→ VHI P1/P2（S9）→ 清理（S10） | — | — |

> 注：D-2/D-8 这类"砍冗余"的 cleanup 安排在 S6 与上传抽取同 commit 批次完成，避免中途留半截。VHI P0 bulk-reveal（S7）建立在 S6 uploader 之上，故归下轮。本轮交付物 = S1–S6。

## 8. 风险与对抗式批判处置

- **过度工程**：只抽编排（A.2/A.3 逐行重复），算法层不抽模板。`SameWorldGenConfig` 收 free function。
- **LOD 强套**：明确不接入（D-7），只共享 `MeshComponentDesc`。决策稿写死，避免后人"为对称而对称"。
- **SVO/VHI 粒度差异**：uploader 只认 `Patch + AppendPatchMesh`，粒度配置化；SVO per-macro-cell 改造是 S8 前置、非免费午餐，延后。
- **不破坏 12 测试**：行为等价 step 先确认现有测试覆盖（tile 集合 / revision / snapshot）；不足处先补测试再重构；S6 依赖 Layer-3 GPU 像素回归（须 `--test-threads=1`）。
- **bevy/web parity**：无牵连——VHI/SVO/LOD 是 UE 专属远景视觉实验，不触线协议 / 权威态 / WorldGen 取样接口。

## 9. 不在本轮范围

- 切远景数据源到权威 3D voxel store / D-delta（下个里程碑，D-5）。
- SVO per-macro-cell 输出改造 + 接 PatchUploader（S8）。
- VHI P1/P2 完善（S9）、清理（S10）。
- heightmap-LOD 接入统一抽象（永不，D-7）。

## 10. 进度日志

- 2026-06-30：落地决策稿。5-agent workflow 测绘三条远景路线重复面；用户拍板 D-1~D-9（VHI=2.5D baseline / 3D 归 SVO / 抽编排不抽算法 / 公共组件 3D-ready / 3D 源切换作下个里程碑 / 本轮 S1–S6）。下一步 S1：建 `FarField/` + `FVoxiaFarFieldCoveragePlanner` 纯函数 + golden automation。
- 2026-06-30：**S1 完成**。新建 `Source/Voxia/FarField/VoxiaFarFieldCoveragePlanner.{h,cpp}`（纯函数，3D-ready：含 `VerticalRadiusTiles` Y 覆盖维度，v1=0 即单 Y band）：`ShouldCover` 统一复刻 VHI 双中心 `ShouldBuildTerrainTile` 与 SVO 单中心 `ShouldBuildTile`（SVO 为 coverage==near 特例）；`PlanFull`（SVO）/`PlanIncremental`（VHI，含 reuse/upsert/remove + 注入式边界签名）/`ResolveCoverageCenter`（recenter hysteresis）。先不接线。新增 automation `Voxia.Voxel.FarFieldCoverage`（7 组 golden fixture）。验证：`Build.bat VoxiaEditor ... -NoLiveCoding` 退出 0（新文件编译进 Module.Voxia + 链接成功）；`Automation RunTests Voxia.Voxel` 退出 0，**13 个测试全 Success**（原 12 + 新 FarFieldCoverage，含 NearVoxelWindow/SvoPreview/VhiImpostor 不受影响）。
- 2026-06-30：**S2 完成**。VHI 接入 CoveragePlanner：`BuildWorldGen` 全量循环改 `PlanFull`、`BuildWorldGenTileUpdate` 增量循环改 `PlanIncremental`（注入 `TileBoundarySignature` 为 `TileSignatureFn`），删除被 planner 取代的 `CanReuseVhiTile`。关键正确性：**移除集与复用判定解耦**——`AliveTiles=Previous.Tiles`（移除始终基于它，与配置可复用无关），`PrevSignatures` 仅在 `SameReusableVhiConfig` 为真时填充（配置改变则旧 tile 全重建但离开覆盖者仍被移除）。验证：`Build.bat` 退出 0（VhiImpostor.cpp 重编 + 链接）；`Automation RunTests Voxia.Voxel` 退出 0，**13 测试全 Success**，`VhiImpostor`（含增量 reuse/built/removed 断言）行为等价。
- 2026-06-30：**S3 完成**。SVO 接入 CoveragePlanner：`BuildWorldGen` 的 macro-cell 双重循环改 `PlanFull`（`MakeSvoCoverageConfig`：单中心 coverage==near、`StepTiles=MacroCellTiles`），删除被 planner 取代的 `ShouldBuildTile`（SVO 边界 seam 仍用 `IsSuppressedByNearSkip`，保留）。每个 macro-cell 的 SVO 递归构建（TileMacroMin/BuildOccupancySvoNode）不变。验证：`Build.bat` 退出 0；`Automation RunTests Voxia.Voxel` 退出 0，**13 测试全 Success**，`SvoPreview`（含 node/leaf/quad/seam 断言）行为等价。至此 CoveragePlanner 已被 VHI/SVO 共用，三条远景路线的 tile 选择收敛到单一纯函数（LOD 按 D-7 不接入）。
- 2026-06-30：**验证策略升级**（用户拍板）：S4-S6 改 transport 状态机 / 渲染上传，现有 unit automation 覆盖不到 → **build + headless CLI smoke 逐步验证**（`voxia_stdio_cli.js` 起 `-game -nullrhi -VoxiaStdioCli` 跑 `until_vhi`/`until_svo` 读 snapshot 比对 stats；S6 上传需 RHI）。先抓 S3 二进制 VHI 基线：`tile_count=21024 / face_sample_count=336384 / quad_count=932892 / built=21024 / reused=0 / removed=0 / center=[11,0,-51]`（顺带证明 S2/S3 端到端未破坏 VHI）。
- 2026-06-30：**S4 完成**。抽 `FarField/VoxiaFarFieldBuildPipeline.h`（模板 `<TConfig>`，决策枚举式状态机内核：`DecideRequest`/`BeginBuild`/`CompleteBuild`/`Reset`；**纯值语义、不持有 Result**，Async/AsyncTask 管线仍留 transport）。VHI 接入：transport 6 个散落成员（`VhiRevision/bVhiBuildInFlight/bHasPendingVhiBuild/VhiBuildSerial/Pending*`）收敛为单一 `VhiPipeline`；`RequestVhiImpostorsAround` 用 `DecideRequest`、`StartVhiBuildAsync` 用 `BeginBuild`、完成回调用 `CompleteBuild`（pending 差异判定注入 lambda）。新增纯逻辑单测 `Voxia.Voxel.FarFieldBuildPipeline`（coalesce/supersede/serial/apply/reset）。**移除集与复用解耦的同款纪律在状态机层重现**：保留 VHI reset 仅清 Revision 的既有不对称（不动以维持等价）。验证：`Build.bat` 退出 0；`Automation` 退出 0，**14 测试全 Success**（新增 FarFieldBuildPipeline）；**VHI CLI smoke 与基线逐字节相同**（21024/336384/932892/center[11,0,-51]）→ transport 状态机重写行为等价。
- 2026-06-30：**S5 完成**。SVO 接入 `FVoxiaFarFieldBuildPipeline<FVoxiaSvoBuildConfig>`（同 S4 同款映射）：transport 6 个 SVO 散落成员收敛为 `SvoPipeline`，`RequestSvoAround`/`StartSvoBuildAsync`/完成回调改用 `DecideRequest`/`BeginBuild`/`CompleteBuild`，`SvoSnapshot` 的 `build_in_flight`/`has_pending_build` 读 pipeline。覆盖 3 处 SVO reset 点（含 window-reset / enter-scene 的 in-flight 清除 + serial bump，保留 SVO 比 VHI 多清 in-flight 的既有不对称）。验证：`Build.bat` 退出 0；`Automation` 退出 0，**14 测试全 Success**；**SVO CLI smoke 与设计稿 8km 文档值逐项吻合**（macro_cell=21016 / node=189144 / leaf=168128 / quad=155399 / max_depth=1 / range=8064m / seam=pass / revision=1）→ SVO transport 重写行为等价。**至此 BuildPipeline 已被 VHI/SVO 共用，异步构建生命周期收敛到单一模板。**
- 2026-06-30：**S6 完成（范围调整 + GPU 验证）**。第三组件 PatchUploader 按**可复用、可单测、低风险**原则分解落地，而非整块搬迁渲染状态机：
  - `FarField/VoxiaFarFieldMeshComponentDesc.h`（`ApplyTo`）收编 4 个 ProcMesh 组件逐字重复的 8 项属性（Movable/NoCollision/AsyncCooking + 排除 Lumen/光追/反射/距离场）+ 按需关阴影/起始隐藏（A.3#14 极高重复，4 个即时消费者）。
  - `FarField/VoxiaFarFieldPatchGrid.h`（纯函数 `PatchCoord`/`PatchSortTile`/`TileDistanceSq`/`TileForwardDot` + `FloorDiv`）抽出并新增单测 `Voxia.Voxel.FarFieldPatchGrid`；`VoxiaWorldActor` 删本地 4 个等价函数、改用共享版（命名空间别名 `VhiGrid`）。
  - **D-2**：删除 VHI 只写不读的死结构 `EVoxiaVhiFace`/`FVoxiaVhiFaceSample`/`FVoxiaVhiFaceLayer`/`FVoxiaVhiTileArtifact::Faces`（六向 envelope 在 2.5D 源下无数据，3D 归 SVO）。
  - **范围决定（务实调整，已与用户对齐）**：VHI 的 section-pool 分帧上传状态机（`VhiPatchSection`/`FreeVhiSections`/`Pending*` + Queue/Continue，~230 行渲染状态机）**本轮不整块搬进结构体**——它本轮只有 VHI 一个消费者（SVO 上传改造按 D-4 延后），且属渲染状态机（出 bug 表现为视觉损坏、只能 GPU 验证），1-消费者高风险低收益；连同 **D-8**（NearSkip 命名统一，宽 blast、改 snapshot 字段/cmdline/launch 脚本）一并**延后到 S8**（与 SVO per-macro-cell 第二消费者同期落地，届时相对低风险）。本轮已抽出该上传机制的**可复用纯核**（patch 网格数学 + component 描述）。
  - **完整 GPU 验证（用户要求）**：`Build.bat` 退出 0；`Automation` 退出 0，**15 测试全 Success**（新增 FarFieldPatchGrid）；**带 RHI 开窗实跑 VHI 预览**（非 nullrhi），日志 `VHI patch update streamed: uploaded_patches=361 live_sections=361 patch_tiles=8 total_tiles=21024 total_quads=932892` 与文档一致 → ApplyTo + PatchGrid 上传路径正确；`voxia_vhi_tiles_built` 的 `face_sample_count=336384`/`quad_count=932892` 与 D-2 前一致 → 死结构删除未改输出；截图 `Saved/voxia_shot.png` 客户端 183 FPS 正常渲染、无崩溃无损坏。
