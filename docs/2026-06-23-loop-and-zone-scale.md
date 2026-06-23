# 玩法 loop + zone 规模(决策稿)

- 日期:2026-06-23
- 状态:**执行中**(决策稿先行;用户已拍板两轨范围)
- 关联:`docs/2026-04-07-增量迁移计划.md` §4(Stage 4 场景分区,7 步设计)、`docs/2026-04-17-场景空间索引架构设计.md`(AOI 瓶颈=N² 交互、SHG+交互管理)、`docs/voxel-server-authority/2026-06-14-architecture-triage-and-alignment.md`(梯队1 分布式正确性前置)、`docs/HEMIFUTURE-MMO-架构设计规范-v2.0.1-冻结稿.md`(FROZEN-5 + EMG 契约)、[[gameplay-roadmap-and-construction-scope]]。
- 触发:用户玩法目标序列第 3 项「loop+zone 规模」。终点是**基于方块/prefab 的建设系统(建城市)**。

## 0. 用户拍板范围(2026-06-23)

- **玩法 loop = 建造/创造 + 涌现**:循环 = 探索/采集 → 用方块+prefab 建造 → 建成物经电/光/热/力学/化学**涌现真工作**(通电的灯、会塌的桥、会烧的木屋、光门)→ 涌现城市。直通建设系统目标。
- **zone 规模 = 完整多 zone**:单 zone → 多 zone + 跨 scene_node 玩家 handoff(边界监控 / 状态快照迁移 / 连接重定向)。承认触发梯队1 前置。

## 1. recon 结论(现状,带出处)

### zone(多 zone 大半地基已就位)
- 体素/区域层**已 zone-keyed**:`MapLedger.route_chunk(logical_scene_id, …)`(map_ledger.ex:1104)、`ChunkDirectory`({zone,coord} 键)、`RegionRuntime` 租约带 logical_scene_id、region `owner_epoch` fencing —— **无需改**。
- 缺口:① 玩家 spawn 硬编 `logical_scene_id:1`(player_character.ex:133,注释自承 TODO);② **AOI 单一全局 octree**(aoi_manager.ex:190),非 zone 分区;③ 无玩家跨 zone handoff;④ `SceneNodeRegistry`(round-robin 分配)**未接 Beacon**,gate 仍 `lookup(:scene_server)` 单节点。
- **AOI O(N²) 不是索引问题**:`2026-04-17` 文档结论「密集区瓶颈在 N² 交互数不在索引结构」。每 actor 每 tick 向半径内所有 ~N 订阅者广播 move(aoi_item.ex:546)。修法 = **交互管理**(SHG 网格 + Top-K 邻居 + LOD tick 降频),非换 octree。octree 另有 3 个已知正确性 bug(merge 丢孙节点 / max_depth 未校验 / check-then-act 竞态),决定 benchmark SHG 后再定。
- **梯队1 前置(多 zone 阻塞项)**:`HandoffPlan` 幂等状态机(prepare/accept/commit/abort/timeout + epoch fencing)**已存在但无人触发**;边界监控、PlayerCharacter snapshot/apply、跨节点搬迁、连接重定向「推迟到多 scene_node tier」。WriteToken 需从进程内移 PostgreSQL;command_id 重放(voxel 侧 `GateServer.VoxelCommandId`+CommandLog 已有,需复核覆盖)。

### 玩法(底子厚、loop 空白)
- **已有**:认证/连接(三态机)、服务端权威移动(movement_engine NIF)、战斗(4 技能/HP/死亡/3s 重生)、聊天、**体素 edit/prefab place/build-reservation intent**、5 个涌现物理系统、NPC AI。
- **缺(loop)**:无目标/任务、无背包/物品/资源/经济/合成、无进阶/XP、无领地归属(build-reservation 是 stub 只回 accepted 不锁)。
- **致命基础缺口**:**啥都不持久化** —— 玩家 position 登录读、登出**从不写**(player_character.ex terminate 不落库);HP/deaths 仅 runtime。会话间零连续性。
- 架构论点(PRIN-10):玩法由物理组合涌现,**玩家向的目的层是 future work**。

## 2. 设计:两轨 + 共享地基

### Track A — 建造/创造 + 涌现 loop
最小可玩建造循环(对齐建设系统终点):
- **持久化**(地基):玩家 position/朝向/stats 登出落库、登录恢复(现 Character schema 有 position 字段,只是没写);**建成的世界本就 chunk durable**(PERS-5,ChunkSnapshotStore),确认重启存活。
- **资源/采集 → 建造成本**:挖方块产出材料(背包/资源账本最小版),放方块/prefab 消耗材料。把现"免费写体素"变成"有成本建造"——建造**有意义**的第一步。
- **建造目的 = 涌现**:建成物经现成涌现系统真工作(电路通灯、力学塌桥、热/化学/光门)。loop 的"目的"就是**让你建的东西活起来**;无需硬任务系统(留后续)。
- (进阶/经济/任务 = 后续增量,本轮先立"采集→建造→涌现"闭环。)

### Track B — 完整多 zone
按迁移计划 §4 + 梯队1 前置,分段:
- **梯队1 前置**:WriteToken 落 PostgreSQL;复核 command_id 重放覆盖;`HandoffPlan` 接真实触发。
- **交互管理(AOI O(N²))**:SHG 网格 + Top-K 邻居 + LOD tick 降频(单 zone 内即收益,且多 zone 必需)。
- **zone 分区**:`zone_config`(边界)→ region-aware 玩家分配(替 spawn 硬编 1)→ `SceneNodeRegistry` 接 Beacon(per-region/zone 发现)。
- **边界 + handoff**:`EntityBoundaryMonitor`(监玩家越界)→ 触发 `HandoffPlan`(prepare/accept/commit)→ `PlayerCharacter.snapshot/restore` → 跨 scene_node 搬迁 → gate 连接重定向(连接不迁、权威迁:client 对目标节点重握手)→ AOI 跨 zone 摘要。

## 3. 排序(共享地基先行,价值早交付)

- **Phase 0 · 玩家持久化**(共享:loop 连续性 **且** handoff 的 snapshot/restore 基元)。**先做**——小、高价值、零风险、两轨复用。
- **Phase 1 · AOI 交互管理**(O(N²) 修;单 zone 即收益、多 zone 必需)。
- **Phase 2 · 建造 loop MVP**(资源/采集 → 有成本建造 → 涌现工作)。对齐建设系统终点的核心价值。
- **Phase 3 · 多 zone 分区**(梯队1 前置 + zone_config + region-aware 分配 + SceneNodeRegistry→Beacon)。
- **Phase 4 · 跨 zone handoff**(边界监控 + snapshot/restore + 连接重定向 + AOI 跨 zone)。最重、风险最高、放最后。

每 phase 内逐 step commit(co-author `Claude Opus 4.8 (1M context)`),决策稿先行,每 step 测试。多 zone 重活先 recon + 复核现状再动(梯队1 前置状态须实测确认)。

## 4. 效率 / MMO / 正确性

- 持久化:登出一次写、登录一次读(非热路径)。
- 交互管理:把 O(N²) → O(N·k)(k=邻居上限);LOD 远处降 tick。
- 多 zone:体素层已 zone-keyed;玩家 handoff 走现成幂等 `HandoffPlan`(epoch fencing 防 ghost);连接不迁只迁权威(降复杂度)。
- 测试:每 step 单测 + 关键路径 e2e;客户端侧改动补 Layer-3/像素证(用户无法自跑)。

## 5. v1 局限(记档,后续放宽)

资源/背包最小版(无装备/合成/经济);loop 无硬任务/进阶(留后续);多 zone 先 2×2 + 静态边界;跨 zone AOI 只同步位置摘要;octree 3 bug 视 SHG 决策处理。

## 6. 逐 step 计划(Phase 0 先列,后续 phase 各自细化)

- **step1**:决策稿(本文件)。
- **Phase 0**:玩家持久化——登出落 position/朝向/(可选 stats),登录恢复;复活点/默认 spawn 兼容;单测 + e2e(连续性)。
- 后续 phase 各起细化 step(资源、交互管理、zone 分区、handoff)。

## 7. 注

这是玩法目标序列里**最大**的一项(分布式 + greenfield 玩法并行),多周量级;按 phase 增量、每 step 可交付、随时可被用户重定向。建设系统(下一目标)将建在本项的建造 loop + 多 zone 之上。
