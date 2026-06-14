# 2026-06-14 架构分诊与对齐主线(triage & alignment）

> 基线规范:[`docs/HEMIFUTURE-MMO-架构设计规范-v2.0.1-冻结稿.md`](../HEMIFUTURE-MMO-架构设计规范-v2.0.1-冻结稿.md)（任务里称 `architecture-v2.0.1.md`，是其简称）。
> 本文件是"现有实现 → 规范对齐"长期迁移工作的**固化结论与主线索引**。证据来自 8 路并行源码审计（2026-06-14）。
> 工作纪律沿用本目录约定：决策稿先行 → 逐 step commit（`mix format` / 测试）→ 进度日志 → 不 push → 全新系统不留兼容。

---

## 0. 四项已拍板的定位决策（不可静默推翻；如需变更走附录 C 流程）

| # | 议题 | 决策 | 对迁移的含义 |
|---|---|---|---|
| D-1 | 规范 v2.0.1 与现有 voxel-authority 代码的收敛关系 | **双向反哺**：规范为准，但凡现实证明更优处（region 路由、chunk-CAS 当全序、Elixir 侧 stage 调度）优先走变更流程改规范，代码尽量改造保留。 | 判定整体偏"改造保留"；【建议的规范变更】要落地为正式修订（见 §4）。 |
| D-2 | region（连续 chunk 3D AABB，Y 参与所有权）vs 规范 cell_id=(level,morton) XZ-column | **有意保留 region + 垂直分片，走变更流程修订 CELL-2/CELL-3**。 | region 模型留用；规范放宽 morton 强制、允许 3D 归属（含 Y）。 |
| D-3 | entity_handoff 缺失 + MapLedger 单进程 + SceneNodeRegistry no-failover（违 CELL-23 线性化） | **属必须尽快补的高优地基**。 | 第 1 梯队最高优先；epoch 单调/防双主是正确性根基。 |
| D-4 | prefab/事务 commit「入队即确认 + 异步落库」（单方块已 durable-before-ack，prefab 不是） | **是缺陷**：prefab 也应落库后（或 durable-pending 后）才确认。 | 列入第 1 梯队正确性返工；不采纳"用 AUTH-14 speculative ack 合法化异步"的反哺。 |

---

## 1. 三句话总览

1. **离规范不远、整体能救**：架构方向与规范高度同构（团队"铁律"≈ PRIN/AUTH/PERS）；服务端权威体素链路、事务+fence+崩溃恢复、确定性移动核、AOI 分档、物理建模选型（图/stencil 而非 PDE）均已长成且值得留用——约 **60–70% 数据面资产可留用或改造保留**，真正舍弃的只有遗留 Mnesia/agent 空壳与 `coordinate_system` crate。
2. **裂缝集中在三类承重契约**：(A) 分布式正确性地基（CELL-23 线性化、owner_epoch 持久化/单调时钟、entity_handoff）；(B) NIF 故障与数据归属（无 catch_unwind、无节点级 SimRuntime、场数据留 Elixir 违 BND-1）；(C) 涌现/提交契约（无 system_actor 桥、无 flux ledger、无 visibility_watermark、无 PERS-5 四分类、无模型卡）。
3. **最大成本是词汇错位而非架构错位**：`region`↔`Cell`、`ChunkProcess`↔`CellServer`、`FieldRegion`↔`CellSim`、`TransactionCoordinator`↔`AUTH/outbox`；多数"违背"其实是"用另一套名字做了同一件事，但少了规范要求的信封字段或持久化保证"。

---

## 2. 词汇映射（认知锚点）

| 规范概念 | 代码对应物 | 关键差异 |
|---|---|---|
| **Cell**（16×16 chunk，`(level,morton)` XZ-column） | **region**（`RegionAssignment`：连续 chunk 3D AABB + owner_epoch + lease） | 无 morton/level；Y 参与所有权（D-2：改规范保留） |
| **CellServer** | **ChunkProcess**（每 chunk 一个 GenServer，持 truth+lease） | 权威粒度落 chunk |
| **CellSim**（Rust ResourceArc） | `FieldRegion`/`FieldLayer`（数据留 Elixir）+ `field_kernel`（无状态数学 NIF） | 违 BND-1/PRIN-2 |
| **AUTH 提交 + outbox + 恢复** | `TransactionCoordinator` + 持久化 `pending_fence` + `TransactionRecoveryWatcher` | 成色高，事实上的 2PC/saga 雏形 |
| **owner_epoch fencing + DB 条件写** | `MapLedger.validate_write_identity` + `WriteTokenStore` CAS + `ChunkSnapshotStore` advisory_lock+FOR UPDATE+chunk_version CAS | 绑 region/chunk；无 cell_seq 全序；WriteTokenStore 非持久化 |
| **Replicator（per-observer 预算）** | `aoi/priority.ex` + `ChunkProcess` 平铺扇出 | 有打分降频，无出口预算/聚合/可靠性分类 |
| **derived→authoritative 经 system_actor** | "铁律 4"：FieldKernel 产 FieldEffect → ChunkProcess 写回 | 形似神缺：直写 storage，无 system_actor/candidate_effect 信封 |
| 代码里的 **"Cell"**（`RefinedCellData`/`CellRefined`） | **体素级 cell**（chunk 内子格） | 与规范 Cell 完全是两回事 |

---

## 3. 组件分诊清单（留用 / 改造 / 舍弃 / 缺失）

> 判定已纳入 §0 四项拍板。证据 `file:line` 见 2026-06-14 审计；本表为固化索引。

### 3.A Umbrella 拓扑与分层
| 路径/组件 | 现在做什么 | 判定 | 理由(条款) | 迁移动作 |
|---|---|---|---|---|
| world_server | Cell/区域目录控制面（MapLedger/TransactionCoordinator/SceneNodeRegistry）；worker/world.ex 空 stub | 改造 | MOD-1、CELL-6/10/18/23 | 保留 world 层；MapLedger 线性化（梯队1）；删空 stub |
| scene_server | Cell owner 热执行 + Rust NIF | 留用 | MOD-1、CELL-6、PRIN-3 | 内部按梯队2/3 改造 |
| gate_server | 连接层 packet:4 TCP/WS/UDP，按 cell 路由，连接不迁移 | 留用 | MOD-1、CELL-8 | 补可靠性分类与背压（梯队3） |
| data_service | PostgreSQL 持久化（账户/角色 + voxel ledger/transaction/snapshot/write_token） | 留用 | MOD-1、CELL-23、AUTH-2 | WriteTokenStore 落库（梯队1） |
| beacon_server | libcluster + Horde 发现 | 留用 | MOD-1、CELL-6 | 作 region→node routing hint |
| auth_server | Phoenix 鉴权 | 留用 | §4、SEC-2 | 保留 |
| visualize_server | LiveView 运维观测 | 留用 | §24、EMG-9 | 保留；确认读状态不绕 REPL/AUTH |
| replicator（独立层） | 不存在；打分寄居 aoi.priority | 缺失 | MOD-1、REPL-2、LOAD-5 | 抽统一 Replicator（逻辑层即可，见 §4 变更①） |
| agent_server / agent_manager | 传统 MMO 空壳，无人引用 | 舍弃 | ANTI-5 | 从 umbrella+release 移除 |
| data_store / data_contact | 旧 Mnesia，已被 release 排除 | 舍弃 | §16、ANTI-8 | 删除 |
| data_init | 旧 Mnesia 表定义，供 migrate_to_pg | 改造 | §16 | 降为一次性迁移脚本 |

### 3.B Cell 模型 / 所有权 / 时间
| 路径/组件 | 现在做什么 | 判定 | 理由 | 迁移动作 |
|---|---|---|---|---|
| map_ledger.ex | region 目录单写者；issue_lease 递增 owner_epoch；validate_write_identity 条件校验；整库单行 blob | 改造(高优) | CELL-6/18/23、ANTI-32 | epoch 分配迁线性化基础（Horde+持久化条件写/DB 事务锁） |
| region_assignment.ex | region 几何/所有权（3D AABB + owner_epoch） | 留用(待规范变更) | CELL-1/2/3/4 | 保留；规范改 CELL-2/3（D-2）；补 region_id↔morton 等价说明 |
| scene_lease.ex | 热执行写租约（owner_epoch + expires_at_ms 墙钟） | 改造(高优) | CELL-18/20/24 | 过期改单调时钟 + 保守 TTL |
| write_token_store.ex | owner_epoch/lease fencing，token_version CAS——进程内非持久化 | 改造(高优) | CELL-19/21 | 落 Postgres |
| chunk_snapshot_store.ex | advisory_lock + FOR UPDATE + chunk_version CAS 每 chunk 线性化条件写 | 留用 | CELL-19、DET-1 | 走变更承认 chunk_version 作 cell_seq 聚合等价（§4 变更②） |
| migration_plan.ex | region ownership 迁移状态机，递增 owner_epoch | 改造 | CELL-10、TIME-6 | 方向=cell_migration；补 migration_tick/commit_watermark + 术语正名 |
| region_runtime.ex | scene 端 lease 缓存 + boundary event 双 epoch 校验 | 改造 | CELL-9、XBOUND-3、TIME-3 | 保留双 epoch；补 source_cell_tick/source_seq |
| chunk_process.ex | 每 chunk GenServer，truth+lease+事务+fence | 改造 | CELL-6/20、NIF-7、ANTI-1 | 保留为 chunk owner；tick 改挂 SimRuntime（梯队2） |
| simulation_tick.ex | 每 chunk tick，tick_seq 进程内自增 + output_hash | 改造 | TIME-1/2、DET-2 | tick_seq 改不随进程/迁移重置的 cell_tick；引入 sim_time |
| entity_handoff | **完全缺失** | 缺失(高优) | CELL-9/12~15、FROZEN-5、TIME-6 | 新建幂等 transfer 协议，不递增 owner_epoch |
| cell_tick/sim_time/snapshot_tick | 不存在 | 缺失 | TIME-1~6、FROZEN-5 | 引入统一 Cell 时间字段（骨架前置） |

### 3.C NIF 边界 / Rust crates
| 路径/组件 | 现在做什么 | 判定 | 理由 | 迁移动作 |
|---|---|---|---|---|
| 节点级 SimRuntime | 不存在；场 tick 每 region 一个 FieldTickWorker 各自 10Hz | 缺失(高优) | NIF-1/5、ANTI-15 | 新建 SimRuntime 统一 CPU 预算/线程池 |
| field_kernel crate | 无状态数学 NIF，0 ResourceArc，数据每 tick 序列化进出 | 改造(高优) | BND-1、PRIN-2、ANTI-3、NIF-3/8 | 数据迁入 ResourceArc<CellSim> + 命令队列/事件回传 |
| field_tick_worker.ex | per-region GenServer，Process.send_after 自调度 + 同步调 NIF | 舍弃(调度部分) | NIF-1/5、ANTI-15 | 调度交 SimRuntime；编排逻辑保留 |
| 6 crate panic 策略 | 无 catch_unwind、无 [profile]；movement.rs 用 SystemTime::now().unwrap() | 改造(高优) | NIF-6/11/15、ANTI-13 | FFI 边界统一 catch_unwind；移除 panic 源 |
| movement_core crate | 纯 f64 确定性积分核，100k-tick 位级可复现测试 | 留用 | DET-1/2/3 | 直接留用；登记为反作弊 replay 基准 |
| movement_engine crate | NIF 薄壳，delegate movement_core | 留用 | NIF-1、DET-1 | 保留 |
| octree crate | 空间索引 ResourceArc，只回 id 列表 | 留用 | BND-1/BND-5 | 留用；扩 query_*_batch |
| scene_ops crate | rapier3d 角色碰撞，2 ResourceArc | 改造 | NIF-7、SIM-4、NIF-1 | 绑 cell_id/owner_epoch；rapier parallel 线程池交 SimRuntime |
| coordinate_system crate | 旧坐标系，get_*_raw 整结构 clone 出边界；unsafe 无 Miri | 舍弃 | BND-1、NIF-12、ANTI-3 | 确认无调用方后删除 |
| cargo workspace + 单 facade | 6 独立 cdylib、5 init | 改造 | MOD-3 | 收敛 workspace + 单 facade |

### 3.D 权威命令 / 持久化提交 / 状态分类
| 路径/组件 | 现在做什么 | 判定 | 理由 | 迁移动作 |
|---|---|---|---|---|
| 单方块 VoxelEditIntent 提交 | 同步 persist_snapshot 成功后才 ack | 留用 | AUTH-2、PERS-6 | durable-before-ack 范本 |
| prefab/事务 commit ack | enqueue_snapshot_persist 异步 → :queued 入队即 ack | 改造(缺陷) | AUTH-2、ANTI-10 | **D-4**：改 durable-before-ack/durable-pending |
| transaction_coordinator.ex | 跨区两阶段 + (txid,decision_version) 幂等 + 整库 snapshot | 留用 | AUTH-7/10/12 | 补 commit_watermark |
| transaction_recovery_watcher.ex | 启动 sweep，:prepared 自恢复 | 留用 | AUTH-7/10 | 崩溃恢复闭环核心 |
| build_transaction_applier.ex | Scene 侧 prepare/commit/abort + fence | 留用 | AUTH-12 | commit 落库改同步（随 D-4） |
| command_id 幂等 | 无；只到事务级 + chunk_version CAS | 缺失(高优) | AUTH-4、SEC-4 | 新建 replay-protection 表 |
| outbox / visibility_watermark / commit_watermark | 0 命中 | 缺失 | AUTH-8/9/10、FROZEN-5 | outbox 表 + watermark 闸门 |
| state_class 四分类 | 无显式标记 | 缺失 | PERS-5、ANTI-8 | 显式归类；未分类禁入生产 |
| FROZEN-5 信封 | wire 缺 command_id/owner_epoch/target_tick/payload_version 统一形态；system/candidate 全缺 | 缺失 | FROZEN-5 | 骨架前置（梯队0） |

### 3.E 复制层 / 网络下行
| 路径/组件 | 现在做什么 | 判定 | 理由 | 迁移动作 |
|---|---|---|---|---|
| aoi/priority.ex + aoi_item.ex | per-observer 分档降频 + 打分上 wire；chat/skill 全量扇出 | 改造 | LOAD-5、REPL-2 | 打分留用；补出口预算+聚合；低频事件可豁免（§4 变更⑤） |
| chunk_process.ex 下行 | snapshot+delta（base/new_chunk_version）平铺扇出，可恢复 | 改造 | REPL-5/NET-2(✓)、REPL-2/6 | delta_base 留用；纳入 per-observer 预算 |
| 可靠性四分类 / 大流隔离 | 单裸 WS 承载所有消息 | 改造 | REPL-4/6、NET-1/3/4/5 | bulk-chunk-stream 独立队列；背压回传 |
| fast_lane_registry.ex | UDP 旁路票据/绑定，WS 路径未启用 | 留用 | NET-5 | 保留为未来 unreliable 实时流 |
| visibility_watermark 闸门 | 直发当前权威态，无 speculative/committed 区分 | 缺失 | AUTH-8、ANTI-31 | 复制前加闸门 |
| Cell PubSub 直连客户端 | 不存在（:pg 仅 CLI 读） | 留用 | CELL-7、ANTI-11(未触犯) | 引入 Cell 时保持隔离 |

### 3.F 物理场 / 局部规则层 / 涌现
| 路径/组件 | 现在做什么 | 判定 | 理由 | 迁移动作 |
|---|---|---|---|---|
| temperature_diffusion.rs / temperature_field.ex | 读旧写新 stencil，活跃集+halo；逐格弛豫无 flux 守恒 | 改造 | RULE-3(✓)、SIM-1(✓)、RULE-4(✗)、ANTI-30 | 补 flux ledger / 源格预算结算 |
| electric_potential / conduction_path / discharge_path .rs | macro-cell 图 Dijkstra，max_frontier 熔断 | 留用 | SIM-4(✓)、RULE-13(部分) | 留用；补阈值滞回锁存 |
| circuit_current_kernel.ex | 闭环电流重建，纯派生，不写权威 | 留用 | RULE-3/12 | 留用 |
| electric_discharge_kernel.ex + chunk_process apply_field_effect | {:write_voxel_attribute} 直写 storage 改温度 truth | 改造 | RULE-11、AUTH-11、RULE-15/16、ANTI-26/34 | 经 system_actor 桥 + candidate_effect 锁存 |
| field/kernel.ex + kernel_context.ex | Kernel behaviour + 只读上下文（仅 5 字段） | 改造 | RULE-1/9/10、EMG-10、DET-2 | effect 补 candidate/system 信封；context 补 world_seed/rule_version/owner_epoch/seed |
| 模型卡 / fidelity_class / 安全阀 | 四系统全无（0 命中） | 缺失 | EMG-1/3/7、ROADMAP-3 | 每系统补模型卡 + fidelity_class + 安全阀 |
| stage 顺序 / merge operator / 版本化 | 列表串行有序，无版本号/无声明式 merge | 改造 | RULE-5/10 | 补 stage/merge/rebuild 版本（同字段多写才需 merge，§4 变更④） |
| 解析快进(SIM-2/6/7) | 未实现 | 缺失 | SIM-2/6/7 | 休眠中观/事件层离线推进 + T_eq 分段积分 |

### 3.G 移动 / 战斗 / runtime_authoritative
| 路径/组件 | 现在做什么 | 判定 | 理由 | 迁移动作 |
|---|---|---|---|---|
| player_character.ex 移动 | 固定 tick 服务端积分，输入只 latch | 改造 | AUTH-15、PRIN-8(✓) | 逻辑留用；补 runtime_authoritative 恢复声明 |
| 断线重连恢复 | 重连即新建进程，last_input_seq 归零 | 改造 | PERS-12、AUTH-15 | 显式声明恢复策略（§4 变更⑥） |
| combat/executor.ex + state.ex | 服务端 resolve cast，同步直改 HP；HP 纯内存无信封无持久化 | 改造 | AUTH-1/4/11、PERS-5、PRIN-8(✓) | HP 归类 runtime_authoritative；cast 带 command_id；PVP 最终结算转 durable AUTH |
| voxel_damage_router.ex + object_registry.ex | 破坏落 put_object，裸提交无 system_actor/幂等 | 改造 | AUTH-11/4/10、PERS-9 | 走 system_actor + 幂等键 |
| combat/{cast_request,effect_event,...}.ex | 意图归一化，不信客户端 outcome | 留用 | PRIN-8、SEC-1、AUTH-6 | 留用 |
| 标签语义施法系统 | 仅设计稿，无运行时代码 | 缺失 | DET-2、AUTH-11、RULE-11 | 落地走 RULE-7 注入旁路 + AUTH-11 |

---

## 4. 已拍板的规范反哺修订（已应用到规范 v2.0.2，附录 C 留痕）

> D-1=双向反哺。以下 7 条已按附录 C 变更流程应用到规范本体（见规范 §附录 C v2.0.2 条目 + 各条款内联 `[v2.0.2]` 标记）。

1. **MOD-1 放宽为逻辑层职责清单**（不强制独立 app 数量；仅强制 LOAD-5 per-observer 出口预算接口第一天存在）。
2. **CELL-19/AUTH-3 承认 chunk 聚合等价**（`chunk_id` 作 `cell_id` 聚合等价、`chunk_version` 作 `cell_seq` 聚合等价的 DB 条件写为合规全序路径）。
3. **CELL-2/CELL-3 纳入 region + 垂直分片**（morton 改为可选编码之一；允许 region 3D AABB、Y 参与所有权；补 region_id↔morton 迁移条款）。
4. **RULE-5 区分同字段多写 vs 分字段单写**（仅前者需 merge operator）。
5. **REPL-2 分级**（高频连续流必须进出口预算；低频离散事件可全量/affected-chunk 扇出 + AOI 裁剪）。
6. **DET/反作弊纳入纯函数积分核**（movement_core 的 DET-3 可复现核登记为 replay 基准；并允许 runtime 高频态最小恢复声明形态）。
7. **MOD-4 允许 stage 调度在 Elixir、Rust 仅提供计算单元**作为合规变体。

> 注:agent 曾提出"用 AUTH-14 speculative ack 把 prefab 异步 ack 合法化"——**D-4 已否决**，prefab 走 durable-before-ack，故不纳入规范变更，改为代码修复项。

---

## 5. 承重契约符合度小结（迁移起点基线）

| 承重契约 | 起点现状 | 目标 |
|---|---|---|
| Elixir/Rust 切分 + 数据留 Rust（BND-*、NIF-1、PRIN-2） | 违背（场数据在 Elixir、无 SimRuntime） | 符合（梯队2） |
| 按 cell 路由（CELL-6） | 部分（region≠cell，D-2 改规范保留） | 符合 |
| AOI 与所有权分离 / PubSub 不下行（CELL-7） | 部分（方向符合，缺统一 Replicator） | 符合（梯队3） |
| 连接不迁移只迁权威（CELL-8） | 符合（方向） | 符合 |
| Fencing（CELL-18~24） | 部分→违背（CELL-23 线性化、CELL-24 墙钟、WriteToken 非持久化） | 符合（梯队1） |
| entity_handoff vs cell_migration（CELL-9~15） | 违背/缺失 | 符合（梯队1） |
| AUTH 提交 + 只发意图（AUTH-2、PRIN-7/8） | 部分（单块✓、prefab 缺陷、只发意图✓） | 符合（梯队1，D-4） |
| 状态四分类（PERS-5） | 违背 | 符合（梯队0） |
| 规则层（RULE-3/4/5/9、DET-*） | 部分（RULE-3✓/DET 移动✓；RULE-4 违背） | 符合（梯队3） |
| 三分辨率 + 解析快进（SIM-2/6） | 部分（选型✓、快进未实现） | 符合（梯队4） |
| NIF 故障模型（NIF-11~15） | 违背 | 符合（梯队2） |
| 复制层独立 + watermark/outbox（REPL-*、AUTH-8/9） | 违背 | 符合（梯队3） |
| derived→authoritative system_actor（RULE-11、AUTH-11） | 违背 | 符合（梯队3） |

---

## 6. 改造顺序（梯队）

**梯队 0 · 契约骨架前置**：FROZEN-5 最小信封 + owner_epoch/commit_watermark/visibility_watermark/state_class 字段骨架（ROADMAP-1）；PERS-5 四分类显式标记。

**梯队 1 · 分布式正确性地基（D-3 高优）**：
1. MapLedger epoch 分配迁线性化基础（消除 ANTI-32）；WriteTokenStore 落 Postgres。
2. lease/时间改单调时钟 + 保守 TTL（CELL-24）；引入 cell_tick/sim_time（TIME-1）。
3. prefab ack 改 durable-before-ack（修 AUTH-2 缺陷 D-4）+ command_id 幂等（AUTH-4）。
4. entity_handoff 幂等协议（CELL-9~15）+ cell_migration 正名 + migration_tick/commit_watermark。

**梯队 2 · NIF 故障与数据归属**：
5. FFI 边界 catch_unwind + 移除 NIF panic 源（NIF-6/11/15）。
6. 节点级 SimRuntime（NIF-1）。
7. 场/体素本体迁入 ResourceArc<CellSim> + 命令队列/事件回传/水位背压（BND-1、NIF-2/3/8）。

**梯队 3 · 提交/复制/涌现契约**：
8. derived→authoritative system_actor 桥 + candidate_effect 锁存（RULE-11/15/16、AUTH-11）。
9. durable outbox + visibility_watermark 闸门（AUTH-8/9/10）。
10. 统一 Replicator（出口预算/聚合/可靠性分类/背压回传）（REPL-2/4/6、NET-3/4/5）。
11. flux ledger 守恒（RULE-4）；涌现系统补模型卡 + fidelity_class + 安全阀（EMG-1/3/7）。

**梯队 4 · 收尾清理**：
12. 删除 agent_server/agent_manager/data_store/data_contact/coordinate_system；data_init 降迁移脚本。
13. 解析快进（SIM-2/6/7）；cargo workspace + 单 NIF facade（MOD-3）。

---

## 7. 进度日志（时间倒序）

- **2026-06-14**：固化分诊结论；四项定位拍板 D-1~D-4 落定；规范反哺修订 7 条应用为 v2.0.2（附录 C 留痕）。迁移梯队 0→4 任务建立。下一步进入梯队 0 决策稿。
