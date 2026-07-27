# Voxia 统一层间补墙与安全交接实施计划

> **For Codex:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task.

**目标：** 让 Near/Far 以及任意相邻 Far LOD 的真实分界面都由同一套机制补齐，并保证玩家移动时先形成新区域的完整可见覆盖，再撤掉旧区域，任何 XYZ 方向都不能短暂露洞。

**架构：** Far Patch 只负责分批存储、构建和预算，不再决定哪里需要补墙。系统先从完整 XYZ 所有权图中独立计算“哪些相邻区域属于不同层”，再把这些真实分界面作为正式渲染产物提交。目标请求和正式切换分开；新目标清单未准备好时，当前可见目标与旧覆盖保持不变。审计端从目标清单推导应有分界面，不能再从现有渲染结果反推预期。

**技术栈：** Unreal Engine 5.8、C++20、UE Automation Framework、DynamicMesh、Voxia stdio CLI / JSON observe、PowerShell。

**正式实现位置：**

- Voxia 代码：`.worktrees/voxia-phase2-macro-interaction`
- 跨仓设计与进度：当前外层仓库 `docs/`
- 唯一生产入口：`AVoxiaUnifiedVoxelWorldActor`

---

## Task 1：把边界账本改成统一数据结构

**主要文件：**

- `Source/Voxia/Presentation/VoxiaBoundaryGeometryArtifact.h`
- `Source/Voxia/Presentation/VoxiaBoundaryGeometryArtifact.cpp`
- `Source/Voxia/Presentation/VoxiaPresentationCommitLedger.h`
- `Source/Voxia/Presentation/VoxiaPresentationCommitLedger.cpp`
- 对应 Automation Test

**步骤：**

1. 先写失败测试：同一账本能同时保存 Patch 外壳面和真实层间面；移除某个层间面不会误删同批次其他边界。
2. 给边界编号增加“层间面”，编号由轴向和负方向一侧的 Tile 坐标唯一决定。
3. 将 Far 提交中的固定 face/edge/corner 三套字段收敛为统一边界 after-image 列表和统一 live map。
4. 保留现有 face/edge/corner 统计口径，避免已有 CLI 和正确功能回退。
5. 运行账本、提交计划器和渲染覆盖的定向测试。

---

## Task 2：建立与 Patch 无关的真实层间面构建器

**主要文件：**

- 新增 `Source/Voxia/Presentation/VoxiaVoxelLayerInterface.h`
- 新增 `Source/Voxia/Presentation/VoxiaVoxelLayerInterface.cpp`
- 新增 `Source/Voxia/Presentation/VoxiaVoxelLayerInterfaceAutomationTest.cpp`
- 复用 `VoxiaNearFarBoundarySeam.*`

**步骤：**

1. 先写失败测试，覆盖：
   - Near 空气、Far 实体时，生成朝 Near 内侧可见的墙；
   - Far 的两个不同 LOD 相邻时生成接缝；
   - 六个 XYZ 方向、负坐标、同一 Far Patch 内的分界；
   - 两边都为空气时合法地不生成几何；
   - 相同输入得到稳定编号和指纹。
2. 构建器只接收两侧的方块采样与所有者信息，不读取 Patch 边界。
3. 复用现有采样/缝合算法；由所有权或 LOD 切割形成的人造截面允许使用已确认占用方块的材质。
4. 运行新模块测试，确认旧 Near/Far seam 测试继续通过。

---

## Task 3：从完整 XYZ 所有权图生成应有分界清单

**主要文件：**

- `Source/Voxia/Gameplay/VoxiaCanonicalVoxelShellSceneBuilder.h`
- `Source/Voxia/Gameplay/VoxiaCanonicalVoxelShellSceneBuilder.cpp`
- `Source/Voxia/FarField/VoxiaFarTargetManifest.h`
- `Source/Voxia/FarField/VoxiaFarTargetManifest.cpp`
- `Source/Voxia/Gameplay/VoxiaFarPatchBuildStream.*`
- 对应 Automation Test

**步骤：**

1. 先写失败测试：同一 Patch 内的 Near/Far 和 Far LOD 分界必须出现在目标清单中；Patch 边界上的既有外壳不得重复。
2. 根据目标 Near 体积和 Far 规划器的实际 owner/LOD，枚举每一对 XYZ 相邻 Tile。
3. owner 或 LOD 不同时建立层间面；相同时不建立。
4. 将层间面收据及其指纹写入 Far 目标清单和对应 Far Patch stage。
5. 构建流严格校验 stage 与清单一致，不一致显式失败。

---

## Task 4：把层间面接入唯一正式提交路径

**主要文件：**

- `Source/Voxia/Gameplay/VoxiaPure3DVoxelStreamingSubsystem.*`
- `Source/Voxia/Presentation/VoxiaVoxelPresentationSceneHost.*`
- `Source/Voxia/Presentation/VoxiaPatchCommitPlanner.*`
- `Source/Voxia/FarField/VoxiaFarPatchBoundaryShell.*`
- 对应 Automation Test

**步骤：**

1. 先写失败测试：发布 Far Patch 时，既有 Patch 外壳和新增层间面必须在同一次原子提交中出现。
2. 将固定 Patch 外壳转换成统一边界 after-image，并合并层间面 after-image。
3. 每个 Far Patch 记录上一版已发布的层间面；新版缺少的编号生成明确移除项。
4. Far Patch 退场时同时移除其拥有的层间面。
5. 继续使用现有隐藏构建、render fence、一次可见切换和 fence 后回收流程，不新增第二条生产路径。

---

## Task 5：让审计从目标推导预期，而不是相信现状

**主要文件：**

- `Source/Voxia/Presentation/VoxiaRendererCoverage.h`
- `Source/Voxia/Presentation/VoxiaRendererCoverage.cpp`
- `Source/Voxia/Presentation/VoxiaVoxelPresentationSceneHost.*`
- 对应 Automation Test

**步骤：**

1. 先写失败测试：目标清单要求层间面而账本没有时，审计必须报告缺失；账本存在但清单不要求时，必须报告孤儿。
2. SceneHost 从当前精确 Far manifest 汇总“应有层间面”。
3. 审计分别比较目标、账本和 renderer binding，三者不得互相充当真值源。
4. 原有 Patch 外壳审计和 Near/Far 覆盖审计保持不变。

---

## Task 6：修正三维保护范围与目标发布时序

**主要文件：**

- `Source/Voxia/FarField/VoxiaFarTargetManifest.*`
- `Source/Voxia/Gameplay/VoxiaPure3DVoxelWorldActor.*`
- `Source/Voxia/Gameplay/VoxiaUnifiedVoxelWorldActor.*`
- 对应 Automation Test

**步骤：**

1. 先写失败测试，复现旧目标一侧恰好缺少
   `3 × NearWindowChunks² = 3 × 21 × 21 = 1323` chunks 的保护薄片。
2. 保护范围按“目标 Near + 交接期仍可见 Near”的精确 XYZ 并集计算，再在六个方向各扩 3 chunks。
3. 3 chunks 仅是玩家允许越出最后完整 Near 的移动余量，不能代替退出 Tile 的完整 Far 接管。
4. Root 只登记候选目标；Far manifest 完整产生并安装后，SceneHost 才正式切换目标。
5. 候选目标尚未就绪时是正常等待，不得把当前目标提前改掉，也不得删除旧覆盖。
6. 覆盖单轴、对角线、竖直移动、负坐标和高空全空气 Near。

---

## Task 7：补齐可观测面、文档与完整验证

**主要文件：**

- `Source/Voxia/Diagnostics/*` 或现有 world diagnostics 文件
- `clients/Voxia/README.md`
- 最近的 Voxia 子系统 `README.md`
- `docs/00-current-truth/*`
- `docs/10-active/voxel-far-field/2026-07-12-pure-3d-voxel-shell-migration.md`

**必须可观察字段：**

- 当前目标与候选目标；
- 应有、账本已有、renderer 已绑定的层间面数量；
- 首个缺失/孤儿层间面的轴向与 Tile 坐标；
- 当前三维保护范围和缺失 chunks 数；
- 旧覆盖是否仍因候选目标未就绪而保留。

**验证顺序：**

1. 每个 Task 的 RED → GREEN 定向 Automation Test。
2. `VoxiaEditor Win64 Development` 完整编译。
3. 相关 Presentation / FarField / Pure3D / World 自动化组。
4. 完整 `Automation RunTests Voxia`。
5. stdio CLI 的水平、竖直、高空全空气再下降路线，产物写入 `.demo/observe/`。
6. 真实运行画面检查 Near/Far 与每级 Far LOD 的六向分界；视觉结果只作为结构化证据之外的补充。

**完成标准：**

- 真实层间面覆盖不依赖 Far Patch 对齐；
- 所有 Near/Far 与 Far/Far LOD 分界均由同一套规则产生；
- 新目标未准备完整时旧画面不会先消失；
- 审计能独立发现缺墙，不再出现“根本没登记所以检查通过”；
- 高空全空气不走任何专用分支；
- 既有正确的流送、编辑、材质、预算、取消和 render fence 行为不回退。

---

## 2026-07-27 实施进度

- [x] canonical `LayerFace` 支持 Near/Far 与任意 Far/Far LOD 分界，六向统一。
- [x] 层间面按实际所有权枚举，不依赖 `8³` Far Patch 外框对齐。
- [x] 跨 `8³` Far Patch 的层间面不再被跳过；Near/Far 由实际 Far 一侧发布，
  Far/Far LOD 由负方向一侧稳定发布。
- [x] 退场旧 Near 只参与精确覆盖保护，不再进入新目标 owner/LOD 图或移动新目标接缝。
- [x] 层间面收据、几何、构建流、提交账本和 renderer 批次使用同一身份。
- [x] renderer auditor 从 manifest 独立推导应有层间面，可发现缺失与孤儿。
- [x] 精确保护区按新旧 Near 包围盒六向外扩 3 chunks，并只排除新 Near；即将退出的
  旧 Near 会作为新 Far 必需覆盖。
- [x] 请求目标与 live 目标分离；完整候选 manifest 到达前 SceneHost 和 Near 均保持旧目标。
- [x] 层间内容身份不再混入后台调度 generation；generation 只负责拒绝陈旧提交。
- [x] 连续目标不会再轮换掉仍可见 Far 的 coverage/层间墙依据；每个 live Far Patch 自带
  immutable manifest entry，并与 Patch/墙同事务替换或移除。
- [x] CLI/observe 公开 live/候选目标、候选发布阶段、保护区边界/数量，以及 live
  层间面总数、真实几何数、跨 Patch 数、Near/Far 数和 Far/Far LOD 数。
- [x] Development build；完整 `Automation RunTests Voxia` 为 `165/165`；Node 为 `98/98`。
- [x] 最新 Null-RHI `--movement-guard-only`
  `.demo/observe/voxia_phase1_2026-07-27T09-42-41-034Z_null_rhi_1280x720/`
  通过：目标连续推进 `11→12→13`，47 个主要交接采样、101 个全部路线采样和最多
  `45082` 个受保护帧中，gap/overlap/orphan 及对应受保护失败计数均为 `0`；前三格放行、
  第四格阻止、沿边和返回放行，最终 `acceptance_complete.passed=true`。
- [ ] Real-RHI 唯一生产场景与用户可见竖墙验收通过；2026-07-27 已执行一次并失败，
  表现为不该补处有墙、该补处缺墙，完成根因重查前不把视觉问题写成关闭。
