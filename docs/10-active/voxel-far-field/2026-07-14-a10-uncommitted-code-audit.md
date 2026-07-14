---
status: active
---

# A10 未提交代码审计 + 会话现场（2026-07-14）

- **日期**：2026-07-14
- **性质**：对当时嵌套 Voxia 仓库整批未提交代码（A10 S1a→S5 / S2L / S4 + 本会话 S1b-1）做「代码是否与计划对齐」的对抗式审计，并记录本会话现场以便换机继续。
- **计划真值**：[`2026-07-12-a10-cancellable-incremental-voxel-shell-streaming.md`](2026-07-12-a10-cancellable-incremental-voxel-shell-streaming.md)（§5 契约、§8 切片退出门槛、§9 测试矩阵、§10 退出门槛、「禁止越界」）。
- **审计方法**：7 个并行子代理，每个盯一个切片对照决策稿契约做 file:line 级对抗核对，重点找「文档声称做了但代码没做」的过度声称、偏离计划、禁止越界。

## 一句话判断

**这批代码在功能行为上忠实于计划，未踩任何架构铁律/禁止越界，无任何「冒充统一/冒充完成」的谎报。** 所有偏差集中在**退出门槛 / 契约形式化 / 测试证明力未收口**，大部分是文档自己已标注的 PARTIAL。作为底座可放心继续开发；正式宣布各切片「完成」前需补下述 A/B/C 类。

## 逐切片判定

| 切片 | 判定 | 要害 |
| --- | --- | --- |
| ① 组合根 + 生命周期 + S1b-1 | 基本对齐 | 结构全对齐、诚实标注未统一；缺 S1b-1 automation |
| ② S2 planner + provider + residency | 基本对齐 | 核心对齐；§5.2 不变量半程序式、planner 测试只一维 |
| ③ S2L H-gated 本地 provider | **ALIGNED** | 完全对齐，无瑕（H gate 实算 SHA-256、错误 H 硬失败无 fallback）|
| ④ S4 依赖感知 artifact DAG | PARTIAL（诚实）| 无过度声称、两条 §5.5 禁止都没踩；两处字面偏离 |
| ⑤ S5 稳定 XYZ far-patch | PARTIAL | 核心全对齐 + 诚实；两处退出门槛未落地 |
| ⑥ S3 合作取消 | PARTIAL | 核心真实；粒度硬编码 + 死枚举 |
| ⑦ 禁止越界 / near / CLI | **全通过** | 零 VIOLATION |

## 按严重度分类的「代码与计划差距」

### A. 明确契约偏离（代码违背写死的要求，应优先修）

1. **S3 取消粒度硬编码**：§5.3 明写「必须配置可观察（`max_pages_per_quantum` 等）…不靠硬编码猜测」，代码却是一 page=一 work unit、resolved surface 页内 `& 4095` 硬编码掩码。正是 §5.3 反对的做法。（`FarField/VoxiaVoxelShellResolvedSurfaceStager.cpp:679` 等）
2. **S3 `ProviderInvalidated` 死枚举**：§5.3 要求「provider 失效也走同一取消路径」，该 reason 定义了但全仓无 `RequestCancel(ProviderInvalidated)` 调用点。（`FarField/VoxiaVoxelShellBuildCancellation.h:17`）
3. **S5 per-patch 预算完全缺失**：§5.6 把「`MaxLivePatchComponents` + 单 patch quad/byte 硬预算 + 超预算 hidden staging 前显式失败」列为进入 S5 前必做，全仓零命中，只有全局总量预算 `MaxTotalSurfaceQuads`。（`Gameplay/VoxiaCanonicalVoxelShellSceneBuilder.cpp:28-30`）

### B. 退出门槛「声称达成」但实际未强制（结构基础在，度量没落地）

4. **S5「提交帧 gap/overlap=0」**：只有 CLI 单 chunk 探针 `voxel_coverage_ownership_probe`，提交路径无帧级计数/断言。唯一 owner + 覆盖对账结构上排除了，但不能说「已强制统计每帧=0」。
5. **S2「provider_requested == enter + dirty」**：运行期涌现相等、非断言不变量（A→B→A 折返复用时反而更少）。

### C. 测试 / 证明力缺口（行为对，护栏缺）

6. **S1b-1 无 automation**（本会话新写，只做了编译 + 实跑验证 `provider_kind:worldgen` 生效，欠 worldgen/local_disk 两路 automation + 错误 H 一致 `source_authorized=false` 断言）。
7. **S2 planner 测试只一维 X 轴**（缺 same / ±Y±Z / 对角 / 负坐标 / anchor 跳变 / profile）；residency 的 LRU 淘汰 / 跨 identity 拒绝无测试；§5.2 六条不变量只 2 条进了可复用 `Validate()`（`required_old` 没存、无法事后校验）。
8. **S3 `post_cancel_work_units ≤ 1`** 无 automation 断言，只有运行时日志（`.demo/observe/voxia_a10_s3_default_cancel.log` 约 2ms ack）。

### D. 字面偏离（当前可证等价，是维护隐患非错误）

9. **S4 material mip 复用键**未把「mip algorithm version」显式入键，靠 source-bound cache + 重编译丢弃间接保证换算法失效。（`FarField/VoxiaVoxelShellArtifactStager.cpp:126-143`）
10. **S4 surface 依赖指纹**用独立的固定 `[-1..Span]³` 邻域镜像枚举，而非 §5.5 所写「sampler 记录实际读取」；两条独立代码路径（依赖指纹 vs 真实 build sampler）将来任一改动需同步，否则复用正确性 / full-oracle 等价会静默漂移。（`FarField/VoxiaVoxelShellResolvedSurfaceStager.cpp:250-356` vs `:661-732`）

### E. 诚实的未收口（文档已承认，不算过度声称）

- S4 反向依赖索引 + 增量/full-oracle 一致性测试；S5 near/far 统一 fence；S2L「已有 live 后下一代缺页/损坏保旧 live」的用户级证据（归 S6）。文档均如实标 PARTIAL/待收口。

## 关键正面结论

- **零禁止越界**：不碰 `apps/*`/wire/HTTP/launcher、不复活 raymarch（默认关、flag 门控、`voxia_stdio_cli.js:218` 的 `svoRaymarchHasHit` 是死残留非复活）、不把 WorldGen 当 confirmed truth、不绕 H gate（`Voxel/VoxiaCanonicalVoxelPages.cpp:1074-1076` 实算 SHA-256 比对）、无 Y=0/XZ near-skip hack（`VoxiaCoords.h` 全 `FIntVector`+`FloorDiv`、`VoxiaPawn.cpp:703-707` 三轴 3D 遍历）、无服务器 provider。
- **零谎报统一**：每切片如实标注迁移期/首轮状态——根 snapshot `source_consumption:{far:"root_source_identity", near:"independent_worldgen_pending_migration"}`（`Gameplay/VoxiaUnifiedVoxelWorldActor.cpp:190`）、`roles`、注释「绝不冒充统一」。成熟 near 被 unified root 拥有时关掉自己的 far（`VoxiaWorldActor.cpp:1123`），各自维护 generation。

## 收口建议（优先级 A→B→C）

1. 先修 **A 类三项**（S3 可配置 quantum + 接线 `ProviderInvalidated`、S5 per-patch 预算硬失败）——它们是代码违背了明确契约。
2. 再补 **B 类退出门槛度量**（S5 提交帧 gap/overlap 计数、S2 provider==enter+dirty 断言化）。
3. 补 **C 类测试矩阵**（S1b-1 两路 automation、S2 planner 多轴 + residency 淘汰/越界、S3 post-cancel 断言）。
4. **D 类**记入 backlog（S4 mip algo version 入键、surface 依赖指纹与 sampler 同源化）。

## 本会话现场（换机继续用）

### 提交账本（截至 2026-07-14）

| 仓库 | 远程 | 分支 | 本会话提交 |
| --- | --- | --- | --- |
| 外层 `ex_mmo_cluster` | `github.com/dyzdyz010/ex_mmo_cluster` | `agent/voxia-a10-s1b-near-far-unify` | `60bdfe6` 合并 master(保留 12.3/12.4 回归记录)、`aad1c0b` S1b 子分片决策稿、`2acff32` capture-window-shot skill、本审计文档 |
| 嵌套 `Voxia`（`clients/Voxia`，被外层 `.gitignore` 忽略）| `github.com/dyzdyz010/Voxia` | `master` | `67e25c9` 可跑脚本、本次「A10 整树快照」提交（S1a→S5/S2L/S4 + S1b-1）|

> master（外层）此前已快进到 `60bdfe6` 并 push；PR #9 已 MERGED。

### 本会话做了什么

- 合并外层 docs 分叉、把工作合入 master、删旧分支、新开 `agent/voxia-a10-s1b-near-far-unify`。
- 写完 **S1b-1**（根拥有唯一 `FVoxiaVoxelWorldSourceIdentity` + resolver，far 从根消费停止自解析，根诚实汇报）：编译通过 + 实跑 observe 确认生效。**注意**：S1b-1 automation 未补（见 C.6）。
- **233s 冷启动破案**：根因是启动方式（Python/MCP + UDS Niagara + DDC + 首次 shader 冷编译），非流送代码。快标志 `-DisablePython -NoDDCCleanup -VoxiaNoSky` → 首跑 ~55s / 热跑 ~20.6s。
- 新增 **可跑脚本** `clients/Voxia/Scripts/run_voxia_3d_world.bat/.ps1`（双击即跑带窗口 3D 世界、WorldGen 无需服务器、`-Measure` 分段计时）。
- 新增 **截图 skill** `.claude/skills/capture-window-shot`（record-window-gif 姊妹）。
- 本审计（7 子代理）。

### 换机注意

- 客户端代码在**独立的 `dyzdyz010/Voxia` 仓库**，与外层 docs 仓库分开推。另一台机器需分别 `git pull` 两个仓库（`clients/Voxia` 目录本身被外层忽略）。
- 另一台机器 UE 路径可能是 `D:\Epic Games\UE_5.8`（本机是 `D:\UE\UE_5.8`）；`run_voxia_3d_world.ps1` 会自动探测，或用 `-Editor` 指定。
- PS 5.1 脚本含中文必须存 UTF-8 BOM，否则解析乱码。

### 下一步（换机后可直接接）

按上「收口建议」推进 A 类三项；或继续 S1b-2（根级 lifecycle+HUD）→ S1b-3（near 消费同一 provider，核心）。S1b 子分片见决策稿 §8「S1b 子分片分解」。
