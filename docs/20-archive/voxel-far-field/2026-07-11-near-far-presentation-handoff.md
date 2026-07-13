---
status: archived
---

# 决策稿：Voxia 近远景呈现所有权交接

> ✅ **本文已归档**：Phase A-E、XYZ ownership、near retirement lease、快速折返与完整场景性能验收均已完成。其状态机成果已成为扩展里程碑 A 的输入，当前主线见 [`2026-07-12-pure-3d-voxel-shell-migration.md`](../../10-active/voxel-far-field/2026-07-12-pure-3d-voxel-shell-migration.md)。

- **日期**：2026-07-11
- **状态**：Phase A-E 已实施并完成完整场景验收；主观闪烁继续由用户窗口实跑观察
- **范围**：Voxia 近景 mesh 流水线、派生远景 SVO、渲染 patch 与二者之间的呈现所有权
- **非范围**：confirmed voxel truth、服务端 authority、near window 数据订阅、SVO 数据算法、三维滑动窗口本体

## 1. 决策摘要

最终方案复用现有 **3.5m 精度 collar**，不新增 LOD 层，不改变由近及远的粒度划分。需要新增的是一个与 LOD 正交的 **呈现所有权交接层**：

1. 进入近景的 chunk 在 near mesh 完成呈现提交后，逐 chunk 把旧远景裁掉；不再等待整条进入带全部完成后一次性显露近景。
2. 离开近景但仍处于当前远景 hole 的 chunk，不立即回收近景组件；由 near pipeline 签发只读呈现租约，直到新远景 revision 真正可见。
3. 远景不按 chunk 重建 CPU geometry。交接期只对 collar 分区启用一个很小的三维所有权掩码；稳态恢复 Opaque 材质并停止掩码更新。
4. SVO 数据仍可 latest-wins；呈现侧保持 single-flight。候选开始修改 live patch 前可合并或丢弃，首个 patch 提交后必须固定并排空，不能假设现有增量 uploader 支持无代价回滚。
5. 当前二维窗口与未来三维窗口共用同一套 box、chunk XYZ、mask 和状态机契约；本阶段不借机推进三维滑动窗口。

本方案同时修复两个对称问题：

- **进入侧**：远景不能在近景可见前消失。
- **退出侧**：近景不能在新远景可见前回收。

只解决进入侧会把空白从前进方向转移到后退方向，不构成完整交接。

## 2. 当前基线与根因

### 2.1 已完成并保留的修复

当前实现已经完成：

- near pending 只包含当前 active window、当前垂直呈现带内尚未处理的 chunk。
- 历史前缀不再阻止离窗后重新入窗的 chunk 排队。
- presentation-ready 在单 chunk 完成呈现决策时更新。
- 垂直呈现带随玩家 chunk 层自维护，不依赖 voxel revision 偶然刷新。
- far revision 在进入带全部 ready 前被 coarse gate 延迟，避免先挖 hole。

这些改动解决了流水线停滞和大面积空白，必须保留。

### 2.2 coarse gate 的副作用

near mesh 仍然逐 chunk 发布，但旧 far geometry 一直覆盖其上。等进入带全部 ready 后，整个新 SVO 一次性替换旧 SVO，所以视觉上变成“大块地形突然切换”。

问题不在 near 的构建粒度，而在呈现所有权只有“整版旧远景”与“整版新远景”两个状态，缺少 chunk 级交接。

### 2.3 被遗漏的退出侧

设 live far 的近景 hole 为 Hf，当前 near target footprint 为 Hn：

- 进入集合 E = Hn - Hf。这里旧 far 有几何，新 near 需要逐 chunk 接管。
- 退出集合 X = Hf - Hn。这里旧 far 没有几何，旧 near 必须保留到新 far 填回。

如果 near window 更新时直接回收 X 中的组件，即使 E 的裁剪完全正确，玩家身后仍会出现空白。

## 3. 为什么直接复用 3.5m collar

当前 SVO 近景 skip 为中心 3×3 tiles；第一圈为 3.5m 精度 collar，覆盖 Chebyshev 距离 2 至 4，即 9×9 外框减去中心 3×3，共 72 个 macro cells。

相邻移动一个 tile 时：

- E 是新 hole 进入方向的一条 3-tile 边，其相对旧中心的距离为 2，完整落在旧 collar。
- X 是旧 hole 退出方向的一条 3-tile 边，其相对新中心的距离为 2，完整落在新 collar。

因此 collar 天然是双向交接介质：

~~~mermaid
flowchart LR
    A[旧 live far collar] -->|逐 chunk 裁剪 E| B[新 near 接管]
    B --> C[新 far candidate 构建与上传]
    C -->|新 collar 填回 X| D[释放 retained near]
~~~

复用的内容是 collar 的空间覆盖、3.5m 几何精度和现有 patch artifact；新增内容只是呈现所有权。二者必须保持正交：

- **LOD 系统**决定远景用什么精度生成几何。
- **handoff 系统**决定某个 chunk 当前由 near 还是 far 呈现。

handoff 不得反向改变 LOD ring、voxel truth 或 near 调度策略。

## 4. 方案比较

| 方案 | 正确性 | 峰值与稳态成本 | 结论 |
| --- | --- | --- | --- |
| 等全部 near ready 后整版切换 | 无进入空白，但显露粒度过粗；退出侧仍需另解 | 成本低，视觉突变明显 | 仅保留为实施期间 fallback |
| 每个 ready chunk 重建或裁切 CPU far mesh | 能逐块交接 | 高频 patch rebuild、上传与 UObject churn，会重新制造峰值 | 拒绝 |
| 每个 far chunk 一个组件 | 能逐块控制 | draw call 和组件数随覆盖面积增长 | 拒绝 |
| 全远景永久 GPU mask | 逻辑简单 | 8km 远景长期走 Masked 与纹理采样，当前像素瓶颈下风险过高 | 拒绝 |
| stencil / depth priority | 可做遮挡 | 额外 pass；空 chunk 语义不正确；跨材质契约复杂 | 拒绝 |
| **collar 分区 + 瞬态三维 mask + near 退出租约** | 双向无空白、逐 chunk 接管 | 稳态只增加至多 4 个 collar 分区；重成本只存在于交接期 | **采用** |

## 5. 正交职责

### 5.1 NearMeshPipeline

NearMeshPipeline 仍是 near 组件和组件池的唯一所有者，负责：

- active、pending、resolved、submitted epoch。
- 逐 chunk 构建与组件更新。
- 为退出 chunk 签发和回收 **NearRetirementLease**。
- 版本一致时重新收养 retained component；版本不一致时丢弃旧呈现并重建。

租约只冻结最后一次 confirmed snapshot 的视觉组件：

- 不继续占有 active/editable 语义。
- 不参与 truth、intent、raycast、collision 或订阅决策。
- 不允许 coordinator 直接操作组件池内部数组。

### 5.2 FarPresentation

FarPresentation 是 far patch、section、材质和 ownership mask GPU 资源的唯一所有者，负责：

- 维护 live revision 与 candidate revision。
- 按结构化 patch key 聚合和上传。
- 接受 declarative ownership mask snapshot。
- 区分 build complete、upload complete、render submitted、live visible。
- 只有持有 permit 才能开始 candidate presentation。
- 明确 candidate 的 cancellable 与 pinned 边界；pinned 后完成当前 revision，再从 latest desired target 开始下一轮。
- 只有 upload complete、staged removals committed 后才更新 live center；不得在 BeginUpload 时提前改写。
- seamless handoff 中保留旧组件可见，禁止触发全远景 bulk-hide；bulk-hide 只允许 cold start 或显式 Discontinuity。

现有 **FVoxiaFarFieldBuildPipeline** 继续只负责 Transport 侧 source/config build 的 serial、in-flight 与 pending coalesce；它产出不可变 build result。FarPresentation 的 candidate/pinned 只描述该 result 的 patch aggregation、upload 与可见提交。两个状态机以 build revision 关联，但不互相复制队列：

~~~text
FarFieldBuildPipeline: source/config -> immutable build result
HandoffCoordinator:    build result + coverage -> presentation permit
FarPresentation:       permit -> aggregate/upload/live-visible
~~~

### 5.3 NearFarHandoffCoordinator

Coordinator 是纯呈现策略状态机，负责：

- 根据 live far hole 与 target near footprint 计算 E、X。
- 只在 U = live hole ∪ pinned candidate hole ∪ active target 的有界集合上维护 coverage ledger。
- 请求和释放 retirement lease。
- 消费 near resolved/submitted snapshot，而不读取 voxel 内容。
- 决定 mask bit、far candidate permit 和 discontinuity。
- 维护 coverage 不变量并输出结构化观测。

Coordinator 不生成 mesh、不持有组件、不修改 confirmed store，也不推断“空 chunk”。

### 5.4 稳定契约

建议使用以下值类型，命名可在实现时按现有 Voxia 风格调整：

- **FVoxiaNearPresentationSnapshot**：generation、footprint、resolved chunks、submitted epoch、chunk version。
- **FVoxiaNearRetirementLease**：lease id、generation、chunk keys、source versions。
- **FVoxiaFarPresentationSnapshot**：live revision/center/hole、pinned candidate revision/center/hole、candidate status、visible epoch。
- **FVoxiaNearOwnershipMaskSnapshot**：generation、最多三个 region、每个 region 的 anchor/dimensions/owned bits、scope。
- **FVoxiaFarPresentationPermit**：transition generation、candidate revision、expected center、protected holes。

所有快照不可变；跨系统只交换快照、事件和 lease token，不共享可变集合。

coverage ledger 的 owner 是呈现决策而不一定是几何：

- NearSubmitted：有 mesh 的 near 已提交。
- NearResolvedEmpty：near 明确判定为空或完全遮挡，无 mesh 是正确结果。
- RetainedNear：离开 active 后仍持有的最后 confirmed 呈现决策，可有或没有 component。
- LiveFar：当前 live revision 在该 chunk 有远景覆盖。
- Pending：尚未取得合法 owner，不能被误报为 settled。

~~~mermaid
flowchart LR
    T[confirmed store / Transport] -->|只读 chunk 与 window| N[NearMeshPipeline]
    N -->|immutable snapshot| C[NearFarHandoffCoordinator]
    C -->|lease request / release token| N
    C -->|mask snapshot / candidate permit| F[FarPresentation]
    F -->|live-visible snapshot| C
    N -->|near visual components| R[Renderer]
    F -->|far patch components| R
~~~

图中没有 FarPresentation 到 NearMeshPipeline 的写路径，也没有 handoff 到 confirmed store 的写路径。

### 5.5 代码落位

实现时不继续把状态机堆进 AVoxiaWorldActor：

- **Source/Voxia/Presentation/**：handoff types、纯 coverage ledger、coordinator 与目录 README。
- **Source/Voxia/Voxel/**：near presentation registry、retirement lease 和现有 streaming policy。
- **Source/Voxia/FarField/**：保留现有 build pipeline；增加结构化 patch key、mask atlas、材质参数与 uploader presentation lifecycle。
- **AVoxiaWorldActor**：只做 composition root，把快照送入 coordinator，并执行其显式 command。

纯 policy/ledger 不依赖 UObject、World 或 RHI，可用普通 automation test 穷举状态转移；GPU 资源和组件生命周期留在各自 owner 内。

## 6. Patch 与材质设计

### 6.1 结构化 patch identity

现有 compact patch 只以 FIntVector PatchCoord 为 key，8×8 tiles 内可能混合 collar 与外圈。改为：

~~~text
FVoxiaFarFieldPatchKey
  PatchCoord
  PresentationClass = StableFar | NearCollar
~~~

禁止把 class 编码进坐标、section id 或 magic offset。

在 patch aggregation 阶段，根据 artifact tile、SVO center 和 LodRings 推导 PresentationClass；不修改 source artifact 和 cache artifact 的几何格式。

9×9 collar 在 8×8 patch 网格上每轴最多跨两个 patch，因此最多涉及 4 个 PatchCoord。拆分后稳态最多新增 4 个 component/section，而不是 72 个。

### 6.2 三维 ownership mask

CPU 侧用 chunk-key set/bitset 表示，GPU 侧上传 R8 point-sampled Texture2D atlas：

~~~text
region width  = chunk_count_x
region height = chunk_count_y * chunk_count_z
uv            = atlas_offset + flatten(local_chunk_xyz)
value         = 0: far owns, 1: near/retained-near owns
~~~

当前二维窗口只上传实际 footprint 的 XYZ box；未来三维 3×3×3 tile 窗口可直接扩为 21³ texels，仍只有约 9 KB。相邻三维对角移动的 union box 上限约 28³ texels，也只有约 22 KB。

正常相邻交接通常只需 active-target 与 retiring-hole 两个 region。长距离 single-flight 最坏需要同时保护：

1. 当前 live far hole。
2. 已经 pinned 的 candidate hole。
3. 最新 active near target。

因此 atlas 固定最多三个小 region，而不是在相距很远的中心之间分配一个巨大包围盒。region 相交时先合并；不相交时，受影响 patch 的 MID 只绑定与自身相交的 region，避免每像素固定采样三次。

必须只有一个共享的 CPU/HLSL 坐标契约：

- 明确 world origin、chunk size、负坐标 floor division 和 UE axis 映射。
- point sample、clamp、no mip、linear/sRGB off。
- 边界 epsilon 由公共函数定义，不在材质中散落 magic number。

每帧合并 dirty texels 后最多上传一次。为降低复杂度，初版允许上传完整小纹理；是否改 partial update 由实测决定。

### 6.3 瞬态材质

- StableFar 永远保持 Opaque。
- NearCollar 稳态保持 Opaque。
- 只有受影响的 NearCollar 或 fast-move extended patches 在交接期间切到 Masked handoff material。
- settled 后恢复 Opaque，并停止 mask 更新。

现有 M_VoxelFarDither 应抽成通用的 vertex-color transition material/function，继续复用互补 fade，但不把其成本扩散到稳态远景。

材质中必须把两个概念拆开：

- **OwnershipClip**：按 world chunk XYZ 查 atlas，表达 near/far 空间所有权，只取二值。
- **RevisionFade**：表达 old/new far 或 retained-near/new-far 的短时互补渐变，只消费 generation-level alpha。

禁止用 FadeAlpha 兼任 chunk ownership，也禁止让 mask bit 反向驱动 near ready。old/new far fade pair 必须绑定同一份 OwnershipClip snapshot，避免旧组件在 near-owned chunk 内短暂重现。

进入侧使用二值 ownership mask，保持用户原来观察到的逐 chunk 出现；不为每个 near chunk 创建 MID 或启动独立 alpha 动画。

退出侧可在 far visible 后用共享的 generation-level alpha 做 48 至 80 ms 的互补 dither：

- candidate far 在 X 内从 clipped 过渡为 visible。
- retained near 使用互补阈值退出，并保持原有 matte / translucent / emissive section 语义。
- fade 完成并跨过 render submission epoch 后才回收组件。

fade 时长只是视觉参数，正确性只依赖 far-visible 与 epoch，不依赖固定等待。

retained near 不能统一替换成一个 far material。每个现有视觉类别提供对应的 transient transition variant；同一 generation 每个类别共享一个 MID，MID 数量随材质类别而不是 chunk 数增长。若某类别没有 transition variant，必须显式记录 binary-retire mode，在 far visible 后按正确时序切换，禁止静默套用错误材质。

### 6.4 Render backend capability

精细交接首先只承诺生产默认的 PartitionedDynamicMesh：

- backend interface 暴露 FineOwnershipMask / CoarseGate capability。
- PartitionedDynamicMesh 必须实现 FineOwnershipMask。
- ProcMesh、HISM、RuntimeMesh 调试后端在未实现前显式报告 CoarseGate，继续使用当前整带门控。
- 完整场景验收若不是 FineOwnershipMask 立即失败，不能把 debug fallback 的结果当生产结论。

### 6.5 闪烁抑制

现有 screen-space dither 在相机运动和 TSR/TAA 下可能产生爬动。这里不能直接拍板改成 world-space：新旧 LOD 表面的世界位置不同，world-space hash 可能让同一屏幕像素失去严格互补，形成亮缝或空点。

确定的约束是：

- OwnershipClip 使用 world chunk 坐标；RevisionFade 使用同一屏幕像素可复现的共同阈值，二者不得混用。
- old/new 或 near/far 在同一 frame 必须调用同一个阈值函数并严格互补。
- 默认不使用各自独立的逐帧 seed。
- fingerprint 未变化的 patch 不参与 fade。
- 反复跨边界由 generation rebase 合并，不重复创建相反方向的材质动画。
- 把现有 0.35s 长 fade 缩短到经实跑确认的最小可接受窗口，降低 dither 暴露时间。
- 稳态回到 Opaque，彻底消除稳态 dither shimmer。

固定屏幕 pattern、共享 temporal blue-noise sequence 与 UE TAA dither 三种实现要通过同一运动轨迹 A/B；无论选择哪一种，互补性与零稳态成本是硬约束，不能凭静态截图下结论。

## 7. 双向状态机

~~~mermaid
stateDiagram-v2
    [*] --> Idle
    Idle --> Preparing: target footprint 改变
    Preparing --> NearHydrating: 计算 E/X 并取得 X 租约
    NearHydrating --> NearHydrating: near chunk 逐个 resolved/submitted
    NearHydrating --> NearCovered: E 全部取得呈现决策
    NearCovered --> FarUpdating: 签发 candidate permit
    FarUpdating --> FarUpdating: build/upload/render submit
    FarUpdating --> FarUpdating: desired target 改变，仅合并 next target
    FarUpdating --> RetiringExit: matching candidate live visible
    RetiringExit --> RetiringExit: X 互补 fade 与预算化回收
    RetiringExit --> Settled: X 租约清空且 mask disabled
    Settled --> Idle
    Preparing --> Discontinuity: 超出无缝交接预算
    NearHydrating --> Preparing: target rebase
    FarUpdating --> Preparing: 尚未修改 live patch 的 candidate 被合并
    Discontinuity --> Preparing: 新锚点建立
~~~

### 7.1 进入侧时序

1. near component 在 game thread 的 frame N 完成 SetMesh/visibility 提交。
2. NearMeshPipeline 记录 submitted epoch N。
3. Coordinator 最早在 N+1 生成 ownership bit。
4. FarPresentation 先收到 near render command，再更新 mask；宁可一帧重叠，不允许一帧空白。

空 chunk 由 near pipeline 明确给出 resolved-empty；它没有 mesh submit，但仍可在下一个 coordinator epoch 接管并裁掉近似 far geometry。

### 7.2 退出侧时序

1. near window 清理前，请求 X 的 retirement lease；有几何的 component 从 active registry 转入 retained registry。
2. 新 far candidate 在 staging 时绑定 X 的退出 mask，alpha 初始保持 far clipped。
3. candidate 取得 permit 并 live visible 后，开始互补 fade。
4. fade 与 render epoch 完成后，NearMeshPipeline 回收租约和 component。

这样新 far 激活时不会与 retained near 直接 z-fight，也不会先回收 near 形成空洞。

### 7.3 reversal 与 rebase

target 改变时，最新 active ownership 永远相对 **当前 live far hole** 重算，而不是把上一个 target 假装成 live：

- candidate 尚未开始修改 live patch 时可以被 latest target 合并或丢弃。
- candidate 一旦提交首个 patch 就转为 pinned。它必须在受保护 hole 覆盖下完成，随后成为一个合法的中间 live revision；不能把已部分写入的 patch 当作可回滚事务。
- pinned 期间的新 target 只更新 desired target，不追加无界队列；当前 candidate 完成后直接读取最新 target。
- coordinator 同时保护 live hole 与 pinned candidate hole，保证 target 在上传期间继续移动也不会暴露任一 hole。
- retained chunk 重新进入 active footprint 时，若 confirmed chunk version 与 lease source version 相同，直接重新收养。
- 版本不同则保持旧 lease 只承担覆盖，active near 重新构建；新版本提交后再替换。
- mask snapshot 带 generation，迟到更新不得覆盖新状态。

## 8. 长距离移动与 discontinuity

正常连续移动采用 **single-flight candidate + latest desired target**：

- near pipeline 持续处理当前 target，旧 pending 主动裁剪。
- coordinator 相对 live far hole 重算 active E/X，并为 pinned candidate hole 保持独立保护。
- 同一 frame 内多次 target 变化只提交最后一个 mask snapshot。
- 尚未触碰 live patch 的 SVO 工作可取消或丢弃；进入 upload commit boundary 后必须排空。
- 不为移动途中每个 revision 排队；当前 candidate 完成后只消费 Transport 的最新 revision。

这样 retained 覆盖有结构化上限：一个 live hole、一个 pinned candidate hole 和一个 active target，而不是随移动距离累积历史窗口。

无缝模式必须有显式资源上限：

- retained component/quads/bytes 上限。
- ownership mask union box 上限。
- candidate lag 的 tile 距离与时间上限。

真实 teleport、世界切换或超过上限时进入 Discontinuity：

- 输出明确 reason 和被放弃的 coverage。
- 使用已有 loading/scene transition 表现建立新锚点。
- 不静默回收 retained near 后留下空白，也不无限保留组件。

阈值需由完整场景压力测试确定，不能先写死为经验数字。

## 9. 自维护不变量

Coordinator 必须持续维护：

1. 对所有交接 chunk，当前呈现决策至少有一个合法 owner：active near、retained near 或 live far。
2. 有 near geometry 的 chunk，far 只能在 near submitted epoch 之后被裁掉。
3. retained near 只能在 matching far revision live visible 之后退出。
4. stale mask 与 stale lease event 不能改变当前 generation；未 pinned 的 stale candidate 不得开始提交。
5. settled 状态下 masked far components、retained leases、mask dirty texels 均为 0。
6. 交接不修改 confirmed truth、订阅、编辑权限、LOD ring 或源 geometry。
7. 单 chunk ready 不触发 far CPU mesh rebuild、patch reaggregation 或 UObject 创建。
8. seamless handoff 期间 far bulk-hidden 必须为 false；live center 只能在 upload complete + staged removal commit 后更新。

若观测到 uncovered chunk，必须结构化报错并进入可诊断状态，禁止吞错后继续报告 settled。

## 10. 可观测面

near_mesh / near_handoff CLI 快照至少暴露：

- state、generation、scope：collar / extended / discontinuity。
- live far center、candidate center、target near center。
- entering_total、resolved、submitted、masked、pending。
- exiting_total、retained_components、quads、estimated_bytes。
- collar partition cells、patches、masked far components。
- mask dimensions、dirty texels、upload bytes、last/max update_us。
- far live、pinned candidate、latest desired revision/center 与各自 epoch。
- coverage_uncovered_chunks、premature_clip_count。
- rebase、reversal、component adoption、pre-commit candidate drop 计数。
- discontinuity reason 与资源上限。

结构化日志事件：

- near_far_handoff_begin
- near_far_handoff_progress，节流输出
- near_far_chunk_owned
- near_far_candidate_permitted
- near_far_candidate_visible
- near_far_retirement_released
- near_far_handoff_settled
- near_far_handoff_discontinuity
- near_far_handoff_invariant_failed

观察产物写入 .demo/observe/，必须能关联 movement trace、frame timing、SVO revision 和 handoff generation。

## 11. 测试与验收

### 11.1 纯逻辑自动化

| 类别 | 用例 |
| --- | --- |
| collar 几何 | 相邻 ±X/±Z 与对角移动时，E 全在旧 collar、X 全在新 collar；未来 XYZ box 使用同一测试模板 |
| patch split | StableFar + NearCollar 的 cell/triangle 总量守恒；结构化 key 无碰撞；旧分区正确 staged removal |
| mask 坐标 | 原点、负坐标、chunk 边界、axis mapping、flatten/unflatten 往返 |
| 状态机 | near submit 前不得 clip；far visible 前不得 release；stale generation 全部拒绝 |
| 材质契约 | OwnershipClip 与 RevisionFade 正交；old/new 使用同一 mask 与同帧互补阈值 |
| material category | retained near 的 matte / translucent / emissive 语义保持；共享 MID 数量有界 |
| backend | 默认 PartitionedDynamicMesh 必须为 FineOwnershipMask；fallback 必须显式可观测 |
| reversal | 入窗、离窗、立即反向；同版本重新收养，不同版本重建 |
| 空 chunk | resolved-empty 能接管且不等待不存在的 mesh submit |
| fast move | pending 裁剪、target coalesce、pre-commit drop、pinned drain、资源上限与 discontinuity |
| uploader commit | BeginUpload 不改变 live center；完成并提交 staged removals 后才更新；seamless 模式不能 bulk-hide |

### 11.2 完整场景性能

必须使用 near + full SVO + movement + upload 的正式完整场景，同一路径、同相机、同配置做 A/B：

- steady：p50/p95/p99/max frame time，GameThread、RenderThread、GPU。
- transition：mask update、material switch、patch upload、component publish 的 p95/p99/max。
- 统计超过 8.33 ms 与 16.67 ms 的帧数、最长连续超限和峰值归因。
- 冷启动、持续直线、对角、往返抖动、上下层移动和长距离压力轨迹。

初始验收预算：

- settled 时 mask update = 0、masked component = 0、retained lease = 0。
- patch split 稳态 frame time 增量不超过 0.2 ms 且不超过 3%，最终以更严格者为准。
- mask 单次 game-thread 更新目标不超过 0.15 ms。
- uncovered chunks 与 premature clip 必须恒为 0。
- 正常轨迹稳定 120 FPS 以上；不能只报告平均值，必须同时报告 p99/max。

预算不是既定结论。任何一项必须由实跑证据确认。

### 11.3 三入口验收

- 用户入口：完整 Voxia 窗口内实际移动观察逐 chunk 进入、退出和闪烁。
- 自动化入口：固定 movement trace + automation tests。
- CLI / 日志入口：导出 handoff snapshot、frame timing 和 invariant counters。

截图只能补充视觉证据，不能替代结构化状态与 timing 数据。

## 12. 实施切片

### Phase A：契约与观测

- 增加 presentation snapshot、generation、epoch 和 invariant counters。
- 把 coarse gate 改由 coordinator 包装，但行为暂不改变。
- 先拆开 current live center、pinned candidate center 与 latest desired center，修正现有 BeginUpload 即改 center 的隐式假设。
- 建立可复现完整场景 baseline。

### Phase B：collar presentation partition

- 引入结构化 patch key 与 PresentationClass。
- 保持全部 Opaque，不改变视觉行为。
- 先验证 cell/triangle 守恒与稳态 +4 分区预算。

### Phase C：进入侧逐 chunk ownership

- 增加三维 mask 资源、坐标契约和 transient material。
- near submit 下一 epoch 才更新 bit。
- 保留 coarse gate 对 SVO candidate 的延迟，先恢复逐 chunk 显露。

### Phase D：退出侧 retirement lease

- active/retained component registry 分离。
- candidate permit、live-visible ack、版本重收养。
- 增加 X mask 与互补 dither，关闭 trailing blank 与切换闪烁。

### Phase E：长距离与收口

- target coalescing、pre-commit drop、pinned drain、预算与 discontinuity。
- 完整场景 A/B、120 FPS 验收、CLI 自动化和用户窗口实跑。
- 达标后移除旧的独立 coarse gate 分支，仅保留状态机 fallback。

### 12.1 实施结果（2026-07-11）

Phase A-E 已按职责边界落地：

- `Presentation/` 的纯状态层拥有 desired/candidate/live、N+1 epoch、collar/extended/discontinuity 与 XYZ mask；不依赖 UObject/RHI。
- `FarField/` 使用结构化 `FVoxiaFarFieldPatchKey(PatchCoord, PresentationClass)`，稳定远景与 3.5m collar 分区保持 source geometry/LOD 不变。
- `Voxel/` 的 `FVoxiaNearRetirementRegistry` 拥有 lease/version/adopt/release；冻结视觉按完整三维 tile 规划 batch，active near 仍逐 chunk 发布。
- `AVoxiaWorldActor` 只组合快照与执行渲染命令。退休 batch 的 ProcMesh 快照在 GameThread 取得，`FDynamicMesh3` 在 ThreadPool 构建，下一 epoch 提交；原 chunk component 保持注册但隐藏，折返时直接恢复。
- ownership atlas 只上传二维脏矩形；MID 只在纹理对象、mask generation 或受影响 patch 集变化时刷新。相邻常用纹理在初始 SVO live 后预热，把资源首建移出移动窗口。
- 长距离保护集合优先复用仍能容纳新集合的已有 3D 盒，只有越界才按 28/56/112 chunk 容量扩张/重锚；超出 `VoxiaSvoHandoffMaxSpanChunks` 显式进入 discontinuity。
- stdio CLI 固定带 `-DisablePython -NoDDCCleanup`，并同时接受 `--ue-arg VALUE` / `--ue-arg=VALUE`，避免黑窗和验收参数静默丢失。

实际实现没有新增 LOD，也没有把 3.5m collar 复制成另一层。retirement draw batch 只是退出侧的瞬态呈现压缩：它不改变 confirmed truth、active 3×3×3 窗口、进入侧逐 chunk 粒度、编辑/碰撞或远景 ring。

完整 `L_WorldGenSvoPreview`、1600×900、near 3×3×3 tiles、SVO radius 72、rings `3.5@4,7@8,14@24,28@40,56@72`、默认 `PartitionedDynamicMesh`、real RHI 的最终证据：

| 场景 | 结果 |
| --- | --- |
| 相邻一个 tile | 10 秒均值 `136.982 FPS`、最低采样 `132.499 FPS`；20 秒 p50/p95/p99/max=`7.250/8.148/8.644/16.569ms`，`>16.67ms=0` |
| 三次快速移动（250ms 间隔） | 12 秒均值 `136.213 FPS`、最低 `129.108 FPS`；最终 near/SVO revision 自动完成，p99/max=`9.050/20.080ms` |
| 快速折返 | 10 秒均值 `146.548 FPS`、最低 `142.171 FPS`；3 个 batch、266 chunks 全部 adopt/restore，p99/max=`8.247/17.406ms` |
| ownership 更新 | 相邻场景累计上传从优化前约 `4.0MB` 降到 `41.1KB`；正式移动 `max_texture_upload_us=133.6`、`max_update_us=245.5`、material refresh 仅 1 次 |
| 退休 batch | 266 chunks 合并为 3 个三维 tile batch；worker 最大约 `7.3ms`，GameThread submit 最大 `0.519ms` |

最终自动化：`Voxia.Presentation` 3、`Voxia.Voxel.NearRetirementRegistry` 1、`Voxia.Voxel.Far` 12、`Voxia.Gameplay.WorldActor` 1，合计 17 个用例全部 `Success`。证据：

- `.demo/observe/voxia_near_handoff_prewarmed_adjacent_final_20260711.log`
- `.demo/observe/voxia_near_handoff_rapid_three_tile_strict_20260711.log`
- `.demo/observe/voxia_near_handoff_quick_reentry_strict_20260711.log`
- `.demo/observe/near_handoff_final_presentation_20260711.log`
- `.demo/observe/near_handoff_final_retirement_registry_20260711.log`
- `.demo/observe/near_handoff_final_far_voxel_20260711.log`
- `.demo/observe/near_handoff_final_worldactor_20260711.log`

每个 Phase 都必须可独立回滚；不得一次性改写 near pipeline、SVO build 和 uploader。

### 12.2 2026-07-12 用户实跑反馈修正

用户实跑发现两个此前结构化性能验收没有覆盖的视觉回归：近景与远景材质外观不一致，
以及跨 tile 后近景虽然内部逐 chunk 构建，但肉眼仍像整块一次切换。

根因分属两个正交契约：

1. 完整场景启动携带 `-VoxiaLargeTerrainCleanMaterial`。近景 PMC 把 UV0 固定为
   `(0.5,0.5)`，生产 `PartitionedDynamicMesh` 远景仍从 compact quad 重建源 UV0；两侧
   虽绑定同一个 `M_VoxelVertexColor`，材质输入不同，最终纹理外观必然不同。
2. near pipeline 没有被合并成 tile mesh；每个 chunk 仍有独立 PMC，并在构建完成时立即
   `SetVisibility(true)`。但原 streaming 预算只限制总处理量（默认每帧最多 32 chunks /
   0.5ms），简单表面 chunk 可在一帧内连续提交多个，120+ FPS 下肉眼近似一次 reveal。
   `VoxiaNearMeshProgressivePublish*` 只推进 revision/progress ledger，并非组件可见边界。

修正保持职责不变：

- `FVoxiaFarFieldDynamicMeshBuildOptions::PrimaryUvMode` 成为 PMC/DynamicMesh 共享的 UV
  呈现契约；clean 模式在 legacy、compact、RuntimeMesh 与 PartitionedDynamicMesh 一致
  使用 centered UV，且 legacy UV1/UV2 不变。
- 完整 SVO/VHI 入口使用默认 `Source` 模式，让 near/far 共同消费真实 `T_VoxelMosaic`
  纹理链；`ConstantCenter` 只保留为显式诊断档。centered UV 会固定采样单个 texel，不能作为
  正式材质配置。
- 相邻 handoff 只限制**首次产生可见几何**的 chunk，默认
  `VoxiaNearMeshStreamingMaxNewRenderableChunksPerFrame=1`；空、全遮挡和已有组件更新仍按
  原吞吐预算处理，不把视觉节奏反向污染数据加载。
- `near_mesh.material_profile` 暴露 clean UV / far-unlit override；
  `near_mesh.publish_budget` 暴露配置、last processed/new-renderable、max 与 total。Verbose
  日志 `near_chunk_published` 可按 epoch 复核独立提交。
- retirement tile batch 仍只压缩退出侧冻结视觉，不成为 active near 的加载或 reveal 单元。

自动化已通过 `Voxia.Voxel.FarFieldPatchUploader`、`Voxia.Voxel.TileWindow` 和
`Voxia.Gameplay.WorldActor`。1600x900 完整 near+far Real-RHI 场景从 tile 11 移动到 tile 12，
跨界期间共首次发布 `309` 个有几何 chunk，分布在 `309` 个不同 render epoch；单 epoch 最大
`1` 个，`frame_new_renderable > 1` 次数为 `0`。进入侧 ownership 从
`resolved/submitted/masked=113/110/376` 逐步推进到 `1029/1029/1295`，没有一次性 tile reveal；
退出侧仍是 `266 chunks / 3 batches` retirement。

同一场景收敛后 10 秒平均 `125.391 FPS`、最低采样 `121.606 FPS`；16.684 秒 frame profile
p50/p95/p99/max=`7.997/9.598/10.061/14.855ms`，`>16.67ms=0`。本次为核验逐 chunk epoch
而启用了 Verbose 日志，结果包含每次发布日志的额外开销，仍保持 120+。ownership 累计上传
`39.589KB`，最大 texture/total update=`0.037/0.264ms`，material refresh=`1`，premature
clip/precommit drop/discontinuity 均为 `0`。证据：

- `.demo/observe/voxia_near_material_chunk_pacing_full_20260712.log`
- `.demo/observe/voxia_near_material_chunk_pacing_full_ue_20260712.log`
- `.demo/observe/near_handoff_material_uv_parity_20260712.log`
- `.demo/observe/near_handoff_chunk_publish_policy_20260712.log`
- `.demo/observe/near_handoff_worldactor_observability_20260712.log`
- `.demo/observe/near_handoff_regression_presentation_20260712.log`
- `.demo/observe/near_handoff_regression_retirement_20260712.log`

## 13. 残余风险

- Masked collar 在交接期仍有像素成本，必须用完整场景 GPU profile 验证。
- RevisionFade 的最佳屏幕阈值序列取决于 TSR/TAA 与实际移动速度，需要 A/B，但不能牺牲同像素互补。
- ProceduralMesh render submission 没有业务级 visible ack；初版使用 command ordering + epoch，若实测仍出现单帧洞，再增加 render-thread fence 观测，不能用固定 sleep。
- retained snapshot 在离开订阅后可能不是最新 truth，因此租约必须短期、有界且只用于视觉覆盖。
- 当前 uploader 是增量原地提交，不是完整 revision 双缓冲；pinned drain 会在极端快速移动时多完成一个中间中心，但避免了双份全远景内存和不可靠回滚。
- 未来三维滑动窗口会扩大 E/X 的面，但不改变本设计；真正推进三维窗口前仍需单独决策稿与容量验证。

## 14. 最终判定

现有 3.5m collar 足以承担交接，不需要额外 LOD 或额外远景数据层。必须额外设计的是呈现所有权，因为几何精度不能自行表达 ready、visible、retained、generation 和 release 时序。

最小且完整的架构增量是：

**结构化 collar 分区 + 瞬态 XYZ ownership mask + near retirement lease + generation permit 状态机。**

它保留当前粒度体系，避免 per-chunk far rebuild，把额外 GPU 成本限制在交接期，并对进入、退出、反向和长距离移动给出同一套可验证契约。
