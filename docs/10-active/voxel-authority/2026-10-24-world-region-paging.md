# 2026-10-24 世界真值按区域分页（第一阶段：单写者、数据分页）

---
status: approved v4（2026-10-24 用户批准；经 Fable 5.1 high 与 Codex astra xhigh 三轮独立 + 交叉评审；Q6 留第二阶段）
owner: VoxelRegion.World（canonical 体素、实例、附件、属性行、液体、世代）；持久化 owner DataService.Voxel；协议字段 owner mmo_contracts Voxel.Codec
protocol: Hello 41 → 42（仅 N 系列）
supersedes: [2026-10-23-world-memory-compaction.md](2026-10-23-world-memory-compaction.md) 的执行顺序（D1 随 M3；D3 并入 N1；D4 改为按 GC 停顿实测选用；D2 被 P3 取代）
---

## 目标

用户 2026-10-24：

> “以后的超大规模世界也能保持稳定的内存占用。现在的如园只是一个示范，以后近景窗口中全是这样的复杂度。”
>
> “也不用就一味为了极致优化降低太多性能，我们要的就是资源占用尽量平滑，不要有不可控尖峰，同时考虑我们的集群式架构。
> 线上内存实在不够我可以扩，不要以现在的生产服务器内存为最终目标。”

由此定下的优先级：**真值正确与边界清楚 → 资源峰值可解释、可控制、提交尾延迟可接受 → 可按节点扩容 → 最后才压常数**。
允许用内存换更少的解码、I/O 和更稳的尾延迟。3.9 GiB 生产容器不再是设计终点。

可验收的形式：

1. **冷世界斜率**：固定活跃负载，只增加远处冷内容，常驻、单笔成本、启动、检查点、下发都不随之增长。
2. **活跃量模型**：常驻 ≈ 基线 + 斜率 × 活跃窗口（页数与密度），斜率实测写进本稿，作为扩容依据。
3. **无不可控尖峰**：检查点、换窗、装页、启动、跨 Scene 移交等事件的额外占用由在途页、任务、旧版本与队列解释，并受预先声明的预算约束；
   事件后回落到稳定平台；单个 World 回合最长停顿与提交 p99 在写回期间不劣于稳定段的约定倍数；PG 写速率无脉冲。
4. **恢复成本诚实表述**：崩溃恢复 = O(脏页数据 D + 待重做日志后缀 L)，L 由连续写回速率与最老脏页年龄上限界定，不随世界总量增长；
   整体启动另加 G（第一阶段明确保留为全局的表，见 P1 末）与 A（获准恢复的活动过程）。不宣称“严格只与脏页数有关”
   （ARIES 本身就是 O(脏页) + O(RedoLSN 之后的日志)）。

## 整体路线（按实测瓶颈选择的条件分支）

地图将很大、玩家分散各处；服务端的“活跃区域”= 全部玩家窗口（及其模拟半径）的并集，各处同时模拟。
内存可以靠加机器；单个 World 是一个 GenServer，裁决、步进、组装、**以及每笔同步等待 PG 写日志**（`world/edits.ex:331-345` → `world/log.ex:20-21` →
`overlay_log_store.ex:31-34`）都串行在它的回合里。**规模扩大后 World 是单点瓶颈，但先饱和的是 CPU、日志 I/O 等待、GC 还是复制扇出，是待 M0 证实的假设**，
不预先认定。

| 步 | 解决什么 | 不变的东西 | 何时做 |
|---|---|---|---|
| **第一阶段：数据分页**（本稿 P1–P7、N 系列） | 内存随世界总量增长、检查点 / 启动尖峰、每笔全表扫描、下发随世界增长 | 单 World 裁决、单日志、全局 seq、事务原子性 | 现在 |
| 分支 A：**提交与存储调度**（日志追加流水线 / 组提交等） | World 回合主要在等日志 I/O | 同上 | M0 显示日志等待主导时；须先补 committed / pending 可见性、失败与取消、在途预算、恢复合同（pending 状态不得被普通读、碰撞或观察看到），不当作无风险的异步改造塞进 M1 |
| 分支 B：**并行计算、单点提交**（原“第 1.5 步”） | 计算（液体步进、热 / 电路求解、载荷编码、观察组装，含 dirty NIF）占满 World | 同上；World 只做“校验依赖版本 + 应用结果 + 落日志” | M0 显示计算主导时 |
| **第二阶段：按空间拆裁决权** | 校验 + 应用 + 落日志本身成为瓶颈，或单节点资源不够 | 页地址、页格式、读取闭包、按盒下发（第一阶段已按此预留） | 分支 A / B 之后仍饱和时；另立决策稿，大纲见本稿末节 |

分支 A、B 互不依赖，按瓶颈取舍，可以跳过无收益的一支。

第一阶段是分支 A / B 与第二阶段的前提：分片需要可寻址的页、显式的读取闭包、不绑节点的存储和按盒投影的下发流。
第一阶段的页格式、身份编号和读取闭包按第二阶段大纲留接口，避免返工。

## 现状（2026-10-24 调研，源码 b9b305f4）

调研全文与评审在 [`2026-10-24-world-region-paging/`](2026-10-24-world-region-paging/)：`recon-state-persistence.md`、`recon-operations.md`、
`recon-observation.md`、`research-paging-evidence.md`（外部引文原句与 URL）、`review-brief.md`、`review-fable.md`、`review-astra.md`、
`review-fable-cross.md`、`review-astra-cross.md`，第三轮 `review-brief-r3.md`、`review-fable-r3.md`、`review-astra-r3.md`、`review-fable-r3-cross.md`、`review-astra-r3-cross.md`。路径相对 `apps/voxel_region/lib/voxel_region/`。

**常驻**：`restore/1` 的约 90 个键（`world.ex:528-653`）里，全部编辑后真值整表常驻。只有 L0–L3 载荷字节缓存有上限（512 MiB LRU，`world/payloads.ex:348-416`）；
L4+ 载荷常驻不受限（`world/payloads.ex:364-381`）；`GeneratedStore` 的 L0 baseline 字节在磁盘按需读，但 bounds 索引整份进 `source_state`、
ETS 只增（`generated_store.ex:74-94,128-138`），随世界**范围**增长。无淘汰路径的还有 `decoded`、`region_bases`、`snapshots`、`served_headers`、
`liquid_adopted`、`epochs`（只 merge，`world/log.ex:393`）、`food_receipts`、`material_supplies`、`published` 字节（`prefab.ex:25-31`）；
`entries` 常驻一整份检查点事务（`world/log.ex:356-358`，实测 309 MB）；`prefabs` 全目录解码并编译常驻（`prefab.ex:17-22,143-160`，实测 239 MB）。
派生结构还会钉住旧真值：`component_cache` 持 inputs/slots（`world/observation.ex:153-159`）、`thermal_run` 持 damage（`world/thermal.ex:90`）、
原生热域 `seen` 持 damage / liquid_units 旧值（`world/thermal.ex:583-585`）。

**持久化**：PG 只有 `voxel_overlay_log`，唯一索引 `(content_version, seq, ordinal)`，无区域索引；`OverlayLogStore` 只有 `append` / `replace`（删 ≤P 再整插）/
`read_all`。kind1 区域载荷不是该区完整真值：damage、epochs、macro_owners、placed_by、attachment_owners、完整实例表、liquid_active 在一行 region=0 的 kind3 ETF
（`overlay_log.ex:66-69`），且 instances / attachment_owners / thermal 是整值替换语义（`world/log.ex:396,400,411`）。

**每笔写放大**：`Log.attachment_metadata`（`world/log.ex:28-36`）让每笔 `append_log` 写整张 `instances`、`attachment_owners`、`liquid_active`；
几何事务另写整份 `thermal`（`world/edits.ex:307`）。纯液体数量提交走 `liquid_journal` 去掉前两张（`world/log.ex:23-25`、`world/edits.ex:364-375`），
`liquid_active` 仍全量。prefab 几何提交为所涉区写完整后像进日志（`world/prefabs.ex:548-574`）。

**每笔 CPU**：64 处全表扫描（`recon-operations.md` §7）。有订阅者时每笔扫 `macro_owners` / `refined`（`world/observation.ex:223,265`）；每笔几何提交
约 10 处扫 attachments / damage / macro_owners / 热源；每个后像区再扫一组（`world/payloads.ex:178-188`、`canopy.ex:49`）；按身份查找无反向索引
（`world/prefabs.ex:52`、`world/tools.ex:413`、`world/canonical.ex:60,242`）；热重建扫 damage 三遍（`world/thermal.ex:65-73`），电路每段扫全部附件（`circuit.ex:84`）。

**启动**：`read_all` 整表 → 全量回放 → 全部 refined `refresh_structure`（`world.ex:679`）→ 同步全量检查点（`world.ex:680`）→ 全世界 `prepare_component_cache`（`world.ex:682`）。
实测 ready ~72 s、VmHWM 6.5 GB（稳态 2.2 GB，约 3 倍尖峰）。

**检查点（主要尖峰来源）**：每 60 s 冻结整世界 `checkpoint_input` 交 Task（`world/log.ex:269-282`、`world.ex:1611-1617`，非 binary 结构瞬时两份），
重编 `snapshots` 里历史上全部区域（`world/log.ex:298-301`），World 内同步写库（`world/log.ex:333`），随后整堆 full GC（`world.ex:1394`）。
实测 World 堆在 1.26↔2.07 GB 间锯齿，image 14–29 s。

**下发**：属性快照先取全世界表再按盒过滤（`world/observation.ex:184,194` → `property_observation.ex:19`），组装 CPU 随世界增长，窗口字节本身已按盒过滤；
canonical 路径的事务 entries / coarse 不按盒裁剪（`property_observation.ex:14-23`），旧 region 订阅已裁 L0、粗格全局通过（`log_projection.ex:55-58,106-112`）；
换窗整组重发 27 区，`Complete` 即 `Reset`（Voxim `VoxelDamageState.cpp:74-77`、`VoxelM1Client.cpp:400`）；owner 宏格 / 叶子 / 附件都发满血默认行（`VoxelDamageState.cpp:129,151,169-177`）。

**集群拓扑**：World 与 Auth/Gate 在一个节点；Scene 可在 peer 节点，各带只读 `Replica` 按固定盒订阅 World（`apps/world_server/lib/world_server/topology.ex:30-49,104-163`、
`replica.ex:3-5,38-73`）；流送玩家的 `CollisionStream` 仍直接向 authority 节点的 World 取快照（`collision_stream.ex:84-85`）。DataService 拥有 PG，
每个 peer 有自己的连接池（`config/runtime.exs:223-229`）。增加 Scene peer 不扩 World 写吞吐。

## 依据

| 结论 | 原文出处（均已打开核实，存档页注明） | 用在 |
|---|---|---|
| 页为恢复单位；WAL 先于页落盘；检查点只记脏页表、不强制刷页；重做从 min(RecLSN) 起扫日志、只看脏页；pageLSN 判定是否重做 | ARIES，Mohan et al., ACM TODS 17(1) 1992，pp.97, 103, 121–125（https://people.eecs.berkeley.edu/~brewer/cs262/Aries.pdf） | P2、P3、P4 |
| 刷脏分小批进行；把检查点 I/O 摊到整个间隔，代价是更长的恢复后缀 | InnoDB innodb-checkpoints（dev.mysql.com）；PostgreSQL wal-configuration（checkpoint_completion_target） | P3 连续限速写回 |
| 多对象写入在同一 PG 事务内原子可见；upsert 可带冲突条件 | PostgreSQL tutorial-transactions、sql-insert（ON CONFLICT … WHERE） | P3 拒旧写回 |
| 多份日志须两阶段提交 | ARIES p.96 | 第二阶段边界（本阶段保持单日志） |
| 三维块为持久单位、KV 表（坐标 → BLOB）、玩家周围活跃半径、闲置超时卸载、定期保存；模拟范围与发送范围是两个参数；forceload 有数量上限 | Luanti `builtin/settingtypes.txt`、`doc/world_format.md`、`src/database/database-postgresql.cpp`（引擎源码，一手）；Vintage Story VCDBS（SQLite，一行 32³） | P1、P5、P6 |
| 只加载玩家周围区块，未加载区块不处理；ticket 与 simulation-distance | Minecraft Wiki（社区维护，**仅作佐证**，不单独支撑 Q1） | P6 |
| 进程 GC 与堆上活数据成正比；>64 B binary 离堆引用计数；跨节点消息要编码复制；ETS 读写复制；persistent_term 更新触发全局 GC；DETS 2 GB；Mnesia disc_copies 全表常驻 | erlang.org：ERTS garbagecollection、binaryhandling、eff_guide_processes、stdlib ets／dets、persistent_term、FAQ mnesia | P5、D4 取舍、Q2 |
| 分区 authority 的代价是逻辑只知道部分世界，交接可能丢更新 | SpatialOS 文档（Wayback 存档） | 本阶段不拆 authority |
| 只发相关状态的变化；静止对象不进复制候选 | Valve Source Multiplayer Networking（存档）；UE Actor Relevancy／Dormancy；Boulanger et al., NetGames 2006 | N 系列 |
| 延迟、流量、错误、饱和度与尾部观测 | Google SRE Book, Monitoring Distributed Systems | 验收指标 |
| 乐观并发控制；快照执行 + 单日志 + 提交时验证 | Kung & Robinson, ACM TODS 6(2) 1981；Hyder, Bernstein et al., CIDR 2011 | 分支 B |
| 区域分解 + ghost 层到交互截断距离；整体速度受最慢分区限制 | LAMMPS Developer_par_part | 第二阶段候选 1 |
| 动态成区、相邻必合并、区内不跨区访问 | PaperMC Folia reference overview / region-logic | 第二阶段候选 2 |

未核实、不作依据：EVE “星系不可跨节点”、Dual Universe 一手资料、Minecraft “卸载前必写盘”、Valve baseline。Riak／leveled 不用 RocksDB。

**项目适配与原创**（外部来源不直接证明，需用户判断）：P1 的 home 规则与外来 owner 引用；粗层页的树冠段；按页重做的事务粒度；
连续写回的安全前缀协议；装页令牌；发送／驻留／模拟三集合（Q1）；N1 世代进载荷与 N3 缺行默认语义；N5 增量窗口生命周期；D3 盒内等值格换世代。

## 设计

### 不变量（先于各项设计）

- **I1 唯一真值**：任一时刻每个页、身份、角色行只有一个可写表示（World 中的常驻页，或 PG 中的持久页）；缓存、索引、目录、Replica 都是可丢弃派生物。
- **I2 只落已提交状态**：只有在合法提交边界（含热提交：沿用 `thermal_run == nil` 冻结，`world.ex:1611`）冻结的版本才能写回；
  `Thermal.flush` 写进 damage 的中间值不是已提交状态（`world/thermal.ex:564-580`）。
- **I3 版本不回退**：写回、装页、淘汰都按页版本判定；旧版本不能覆盖或复活新版本。
- **I4 缺失不冒充**：“未装入”“读取失败”“PG 确认无此页（= 从未编辑，读 baseline）”是三种不同状态，World 内不以 map 缺项代替存储结论。
  应用从不物理删除页行（恢复为 baseline 也写一行），因此“PG 无行”是唯一的“从未编辑”证据；不为防人为删库另造存在性清单。
- **I5 读取闭包在裁决前装齐**：一笔裁决读到的全部页在同一 World 回合内已常驻；回合内缺页是程序错误（显式失败，不当空气），不做阻塞 I/O。

### P1 页的定义

**L0 页**（64³ 宏格 core；ring 只是投影，延续 `world/log.ex:98-123` 的 “core 拥有、ring 投影”）持有该 core 的：
地形基底 + L0 overlay、refined 槽、liquid_units、liquid_active、epochs（含裁剪到本页的 D3 盒戳）、macro_owners、placed_by、thermal.sources（按格）、
anchor 在本页的附件槽、damage g=0/1/4（按微格所在页）、**home 在本页的身份记录**及其 g=2 / g=3 行与 attachment_owners。
页内索引（派生，不持久）：owner → cells、parent → children、aid → slots、macro → slots，以及本页格引用的外来 owner 及其 home 页键。

**home 规则**：实例 home = 实例 anchor 所在 L0 页；附件 aid 的 home = 创建时首个槽 anchor 所在页，写入 aid 的身份记录后不再迁移（非 home 槽只存 aid）。
整件 HP（g=2 / g=3）只在 home 页；树的覆盖页集合存在根实例记录里，aid 的槽所在页集合与整件 max_hp 汇总存在 aid / 部件的 home 记录里，
均由改动它的事务增量维护——使 M2 在协议 41 下输出整件默认量时不必装入全部覆盖页，可变 HP 仍以 home 页的行为准。
页**不是**自足的：读一个页的完整语义需要其**读取闭包** = 本页 + 26 邻页（ring、后像）+ 外来 owner 的 home 页 + 祖链所在页。闭包由操作决定，不硬编码成固定上界。

**身份定位表**（PG，`instance / aid → home 页键`，与页同一提交写入）：因 `remove_prefab`、GM 移动、工具从 owner 身份出发等多个入口只带 id
（`world.ex:374-388`、`world/gm.ex:208-218`、`world/tools.ex:425-450`），保留定位能力；查询走 P4 的准备流程，不在回合内同步 SQL。
（Fable 建议用协议带 anchor 删掉这张表；Codex 指出 id-only 入口不止玩家请求一处，采纳保留。）

**粗层页 L1–L5** = 该级区域的 coarse overlay + structure + **树冠段**（锚点 / 去叶残余），后者现由 `Canopy.project` 每次从 L0 现算（`world/canopy.ex:9-25,61-89`），
改为随 `Canopy.affected_keys` 同笔增量维护并持久。物化粗层页不再读 L0 页；否则 L5 页（32³ 个 L0 区）会拉起数万冷页。
`refresh_structure` 对冷子页缺项不得当“无细节”（`world/payloads.ex:278-283`）。区分两件事：直接物化一个粗层页只读该页的持久段；
重算受影响的父格需要该父格的**完整**子输入——闭包装入相关子页，不以部分子页推出父格。

**仍为全局、第一阶段不分页**（列明增长轴，不阻塞首个闭环）：protection 区域与 256 m 桶、beacons、cid=0 安装回执、prefab 目录与 published 字节、
GeneratedStore bounds 索引、L4+ 载荷、角色账（balances / energy / phase_inventory / food_receipts / material_supplies 角色部分）、semblances 与在飞投射物。
它们按目录、角色数、世界范围或安装历史增长，不按近景内容密度增长；但“不制造尖峰”未经测量，M0 记录各自保留量与增长轴，
L4+ 载荷并入 P5 的统一字节预算。阶段报告不把这些轴算作已满足目标。角色账按 cid 只常驻在线角色、food_receipts 的持久消费游标与退休合同
放在 M3 之后单独定（Codex 坚持最终不能保留全部历史角色状态，采纳为后续项）。

**页的存储格式与线格式分开**：页 envelope 有自己的存储版本，网络 VXR 载荷由唯一 owner 从页派生；P 系列不改协议 41 输出。

### P2 日志：每笔只写本笔改了什么

`voxel_overlay_log` 仍是唯一应用 WAL：一笔事务的全部行在一个 DB 事务写入，落盘后才确认 / 广播（原子性不变）。改动：

- kind3 按**目标**拆行：页目标用已有 `level / region_x/y/z` 列；身份、角色、全局目标用新的目标类型列。每行写变化键的**新绝对值或显式删除**
  （沿用 `world/production.ex:58-63` 先结算再写后像的做法；这是本项目的简化选择，不是幂等的唯一解）。
- 删掉 `attachment_metadata` 的整表合并与几何事务的整份 `thermal`；`liquid_active` 改增量。
- **重做粒度**：同一 `seq` 对同一页的全部行（多 ordinal）整体应用后才推进该页 `page_seq`；重做不重新执行扣料、广播或任何裁决。
- 已有世界做**一次性迁移**（旧整表语义 → 新目标行），校验后切换；不长期双读。存量玩家状态按数据保留合同验收，不能用从空重装代替。
- kind1 整区后像是否改为页内增量，按 M0 实测的“每笔 WAL 字节”再定，不预先删 `select_transaction` 等旧概念。

### P3 连续限速写回与安全前缀

取代 60 s 整世界检查点：

- World 在合法提交边界选定切点 C，把截至 C 的脏记录（页、身份、角色、全局水位）**逐页**交给后台写回进程；单页拷贝有界，不冻结整世界。
- 写回进程按配置的速率（页数与字节两个上限）编码并写库；每批是一个 PG 事务：`upsert … WHERE stored.page_seq < new.page_seq` + 安全前缀水位。
- 全部覆盖 C 的记录持久后才发布安全前缀 C（未完整覆盖不发布；水位单调、持久在同一 PG 事务里），并渐进删除 ≤C 的日志。
  完成回调只把“仍等于所写版本”的页标干净，C 之后再变的页保持脏。逐页冻结取的是该页在 C 时的版本；为等待写回而保留的旧版本计入在途预算。
- **积压边界**：脏字节与最老脏页年龄有上限，超限时提高写回速率；仍追不上时对新提交施加明确的接纳限流（显式等待），不靠无界 mailbox 吸收。
- 不再整堆 full GC；`entries` 不再常驻检查点事务。旧游标订阅：在安全前缀之后的从日志补；早于前缀的显式要求重新取当前快照（新切点），
  不把页版本当历史切点；Replica 退休通知改发安全前缀 seq。

这是评审 4.1 方案（两位评审一致选它；4.2“每笔同库 upsert 页”把编码与 I/O 压回提交路径，形成按事务率的写脉冲，不采纳）。

### P4 装页与启动

- **装页令牌**：World 对每个缺失页最多发出一个装页请求（页键 + 令牌），由调用方进程 / 装页 Task 读 PG（或确认无行后读 baseline）并解码；
  World 只接纳令牌匹配、且该页仍未常驻的结果。页淘汰前必已写回（I2），之后的新装页必读到不旧于淘汰时的版本——这是 I3 对可变页的保证
  （现有 `prepare` 依赖“来源按 cv 不可变”，`world.ex:147,750-753`，不能直接套用）。
- **意图准备**：玩家意图、工具、prefab、GM 与身份定位先在 World 外求读取闭包、装齐，再进 World 一个回合接纳并裁决。闭包求解是**迭代**的
  （例如 home 页要先读页内的外来 owner 表才知道）。跨回合等待期间闭包页被 pin，失败或调用方退出时释放。
  **pin 只保证页不被淘汰，不保证闭包仍新鲜**：等待期间树、槽集或定位可能已被其他提交改变（`world/prefabs.ex:50-72`、`world/attachment_ops.ex:203-209`），
  World 接纳时按依赖版本复核，变了就回到准备或显式并发拒绝，不沿旧闭包提交。I5 的“回合内缺页 = 程序错误”只针对复核通过之后。
- **定时模拟**中**有模拟资格但未驻留**的页（P6）：该步暂停、请求装页、装齐后在 World 重新裁决，期间不提交任何部分通量或账目。
  无模拟资格的页按 Q1 的边界规则处理，不走这条。
- **只读依赖**：无模拟资格的页仍可因操作闭包被只读装入（热损伤更新跨页整件 HP 池、电路发现判连通、ring / 后像、保护判定、身份定位），
  装入不授予模拟资格，准备阶段受在途预算约束。
- **启动** = 读全局行 + 安全前缀之后的日志后缀；后缀涉及的页经装页令牌装入后按 P2 粒度重做；**活动索引**（有进行中过程的页键，随页提交持久）
  决定启动后需要恢复模拟的页。不全量回放、不全量 `refresh_structure`、不启动检查点、不全世界 `prepare_component_cache`。

### P5 驻留与缓存

- **驻留集** = 订阅盒覆盖页及其读取闭包 ∪ 在途准备的 pin 页 ∪ 模拟集（P6）。驻留页在 World 状态中以解码可改形式存在（热路径性能优先）。
- **冷缓存**：离开驻留集的干净页保留已持久的编码字节（refc 离堆、不重新编码），进带字节上限的 LRU；L0–L3 载荷缓存并入同一预算。缓存上限可配、可观测，按内存档位放大以换更少的 I/O 与解码。
- 淘汰页时同时释放其派生引用：`decoded`、`region_bases`、`snapshots`、`served_headers`、`liquid_adopted`、页内索引、`component_cache` 条目、热域节点与 `seen` 旧值。
- prefab 定义按 id 加载并进有界缓存（D1）。
- **D4**（活跃 refined 槽改二进制）不预做：M0 记录 GC 停顿分布与最长回合，只有 map 表示的停顿超出验收线、且二进制方案不劣化提交 p99 时才做。

### P6 发送、驻留、模拟三个集合（Q1 待定）

- **发送集**：客户端订阅盒（近景窗口、远景 LOD 带）。
- **驻留集**：P5。为射线、远景、身份定位而装入的页**不**获得模拟资格。
- **模拟集**：**全部**玩家各自模拟半径的并集（与发送范围分开的参数，依据 Luanti active_block_range）∪ 进行中过程的 ticket。
  相邻或重叠的玩家区域合成一块连续模拟区，内部完全联合求解，没有边界；“边界”只存在于模拟集与任何玩家都不在附近的冷区之间。
- 模拟资格由模拟 owner 判定，与是否驻留无关；资格变化（玩家走近 / 离开、ticket 发放 / 释放）时唤醒边界两侧的过程（复用 `world/claims.ex:96-101` 的唤醒动作）。
- 冷区的过程**不补算**离开期间流逝的时间；预算冻结的过程在重启后不因重启而复活，只有重新获得资格才继续。
- 液体、燃烧、相变、电路、热传导只在模拟集上推进。模拟集与非模拟页的边界语义、ticket 资格与上限、重启后的活动恢复，见 Q1。

### P7 去掉每笔全表扫描

64 处按 `recon-operations.md` §7 改为页内索引或身份定位；维护入口（粗层重建、属性目录发布、parcel 导出 / 安装）允许 O(范围) 总工作量，但要流式分批并明确原子发布边界，
不再持有全世界前后像（`world/coarse_rebuild.ex:20-34,64-85`）。认领与权限判定不得因冷页缺数据而当成野外或无主（`world/claims.ex:89-101`、`protection.ex:35-44`）——
闭包须装入判定所需的页。`in_refined_order` 的整表遍历次序（`world/canonical.ex:54-60`）改为按 (页, 格) 的确定次序，会改变既有部件 max_hp 的浮点求和结果（Q5）。
热域与电路图从模拟集上的种子增量构建，不再扫全部 damage / attachments。

### N 系列：下发只随窗口（协议 42，与 P 系列联合设计、分开交付）

1. **N1 世代进区域载荷**（稀疏世代段 + 裁剪到区域的 D3 盒戳），删 PropertyBatch `epochs`。必须调整提交数据流：现在后像先构造（`world/edits.ex:288`）、
   世代后算（`:295-307`），照搬会发旧世代、破坏 ABA 拒旧。客户端 `VoxelDamageState.cpp:18,34,155` 与 `replica.ex:62,186` 用同一取值函数。
   同页反复安装的盒戳需有合并规则（被新戳完全覆盖的旧戳删除），否则随安装历史增长。
2. **N2 宏格 owner 进载荷**，删 owner 宏格默认行（`world/observation.ex:189,204-214`）。
3. **N3 只发非默认行**：缺行 = 满血 + 环境温度；整件 max_hp（g=2 与 g=3）进载荷；可变 HP 仍以 home 页的行为准。
4. **N4 批内行瘦身**：去掉每行 request_id / seq / digest（按实测收益排期）。
5. **N5 换窗只发新进入区域**：定义退出清除、retained 与 entered 间 g=2/g=3 去重、恢复默认的显式删除、property / geometry / fence 顺序；
   替换客户端“完整 XYZ 盒 + 同 seq”的解码前提（`VoxelGateCodec.cpp:646-664`），载荷头仍盖观察切点 seq（`world/payloads.ex:419-421`），不用 page_seq。
6. **N6 事务 entries 与 coarse 按订阅盒和 LOD 带投影**，远景订阅不丢更新。

### 第一阶段为分支 A / B 与第二阶段保留（只留不变量，不预建机制）

- 页地址是 `(cv, level, rx, ry, rz)`，不绑 PID、节点名或 Scene 分区；页存在 DataService 的 PG，不放 World 节点本地文件。
- 一页的重做只依赖该页键的日志行与页本身（P2 按目标拆行的第二个理由）。
- 读取闭包显式求出（P4）——分支 B 的并行计算输入、第二阶段跨片取数 / 交接都以它为单位。
- 定时模拟的一步以“只读输入页集 → 结果”的形式组织（P4 已要求“装齐后重新裁决”），分支 B 才能把它搬到 World 外；热核 NIF 的可变常驻态不是纯输入，这一点留给分支 B 稿处理。
- 每条下发流只含订阅盒内容（N6）。
- 已知第二阶段必须拆的全局水位：附件 id = `max(serial, seq) + 1`（`world/attachment_ops.ex:192`）、实例 id = `{birth seq, occ}`、全局 `seq`；新格式不再把全局 seq 当跨区唯一键。
- 不预做：分片路由、2PC、authority 交接、每页进程、跨分片目录、无人使用的 lease / fencing 字段。

## 对功能设计目标的影响

- 驻留范围内玩家可见行为不变；单写者裁决、事务原子性、全局 seq、incarnation 拒旧不变。
- **改变（Q1）**：模拟集以外的过程不推进、不补算。现在全世界液体与热都在全局推进。近边界的可见行为有变（例如远景里贴着边界的液面），用近边界与跨远端网络的小场景验收。
- **改变（Q5）**：部件 max_hp 的浮点求和次序变为确定序，存量部件 HP 上限可能有末位差异。
- Parcel 安装盒内等值格换世代（原 D3 语义点）。
- 协议 41 → 42，客户端同步发布。

## 决策点（需用户定）

| # | 问题 | 两位评审与我的建议 |
|---|---|---|
| Q1 | 远处过程的模拟语义 | 两位评审都支持“无人区域冻结、回来时不补算流逝时间”，都认为这是产品取舍须你定。建议：① 模拟半径为玩家周围 N 个 L0 页（与发送范围分开）；② 稳态过程（有源电路、恒温热源）在模拟集外冻结；③ 有限终点过程（液体趋静、燃料燃尽、相变完成、投射物落地）可持 ticket，设页数与字节上限，超限的按最早者冻结并记日志；④ 跨模拟边界，按交换类型分别定：液体以非模拟页为墙（不流入也不取出）；热传导以非模拟页为绝热面（绝热 ≠ 环境温度，冷页不等于“无记录”）；
辐射视线遇非模拟页按**遮挡**处理，不按露天（`world/thermal.ex:914-943`）；投射物飞入非模拟页时停在边界并持 ticket 直到落地或预算冻结；身体与世界的热交换只在模拟页上。
模拟半径取近景窗口外再加一圈页，减轻但不消除边界可见性——远景里可能看到贴着边界的液面，这是产品语义变化，用近边界小场景验收；
⑤ 电路：只要有一部分在模拟集内，以**有界、可暂停的迭代发现**找出整个连通分量（导通随开关和温度变化，不预建持久连通目录），分量所在页获得**整页**模拟资格
（电路与焦耳热 / 热电结算耦合，不能只推进电路而冻结它的热结算），计入 ticket 上限；
**单个分量超出上限时的可见行为需你定**：(a) 整个分量暂停并向玩家显示原因；(b) 在冷边界处开路后重新求解（新物理语义）；(c) 在接线时拒绝会使分量超限的连接（限制合法规模）；
⑥ 重启后只按活动索引恢复有资格的过程；不采用“整条网络一起暂停”（会让玩家身边的部分也停） |
| Q2 | 页存哪里 | 一致：PG 新表（DataService 共享，页不绑节点）；页写回、身份 / 角色 / 全局行与安全前缀同一 DB 事务；不用 Mnesia / DETS，暂不引入 RocksDB |
| Q3 | 协议 42 | 一致：与 P 系列联合设计接口、分开交付；页存储格式与线格式分开版本 |
| Q4 | 验收数值 | 一致：先批准测量定义（见“验收”），数值在 M0 之后定；不做“噪声大就自动放宽阈值” |
| Q5 | `in_refined_order` 改确定序导致存量部件 max_hp 末位变化 | 建议接受，在迁移时一次性重算并记录差异；迁移的“逐项相等”验收把这一项列为唯一批准的例外。M1 的确定序子项在 Q5 定之前不动 |
| Q6 | 第二阶段体素分片是否与 Scene 分片对齐 | 不在第一阶段决定；第二阶段稿按“独立映射、可同址部署”与“严格对齐”两案比较（见大纲） |

## 交付顺序（每步在真实 World 正常入口闭环）

1. **M0 规模与尖峰基准**（Test-only，隔离库，经既有 parcel 作者入口一次安装并记账）。分别控制并记录：冷内容份数（开发机 1/2/4，有大内存机器则 1/4/16）、
   活跃窗口数与密度（互不重叠 / 重叠）、脏集合、日志后缀长度、远处事务率、重复安装与进食历史；先装好并完成基准前缀，再只改局部做测量。
   记录：各节点进程与 binary / ETS / NIF 总占用的时间序列与高水位、GC 停顿分布、最长 World 回合、提交 p50/p95/p99、窗口 Ready、每笔 WAL 字节、PG 写速率与连接池等待。
   **单 World 饱和点**：同样的如园密度与活动量（液体、燃烧、电路、挖放），逐步增加互不重叠的活跃窗口数，测 World 调度器利用率、mailbox 长度、提交延迟，
   World 回合耗时拆为：计算（步进 / 求解 / 编码 / 组装，含 dirty NIF）、接纳 / 应用、日志 I/O 等待（复用现有 `log_us`）、GC、复制与扇出、PG 连接池等待。
   日志等待主导 → 分支 A；计算主导 → 分支 B；接纳 / 应用 / 落日志本身饱和 → 第二阶段。另记玩家分布的聚集度（第二阶段静态分片与动态合并的选型依据）。
   M1 之后、M3 之后各复测一次（全表扫描去掉后饱和点会移动）。
   冷内容轴之外再加：固定内容扩大世界范围、增加不同定义数、同页反复安装（G 与 D3 历史的增长轴）。
2. **M1 每笔与世界无关**：P2（kind3 按目标拆行 + 一次性迁移）+ P7 中每笔提交 / 每次观察路径的全表扫描 + 检查点去掉 World 内同步写库与整堆 GC。不改页存储。
   保持现单 World 裁决、提交可见性、全驻留与现模拟语义。子项各自的前置：P2 须先写定目标类型、set / delete、存储版本、一次性迁移与回放语义，不能只写出新数据、以后再补恢复；
   检查点后台化只退休已持久的前缀，不提前截日志；`in_refined_order` 确定序等 Q5。不夹带：日志流水线（分支 A）、键级版本、按过程拆模拟资格、多写者。
3. **M2 页存储闭环**：页表、身份定位表、装页令牌、读取闭包准备、粗层树冠段、P3 连续写回与安全前缀、P4 启动。此时允许页常驻不淘汰，但启动已按需装页。
4. **M3 驻留预算与模拟集**：P5 淘汰与统一缓存预算、P6（按 Q1）、D1；之后再排角色账按 cid 与回执退休。
5. **M4 下发**：N 系列，协议 42，客户端同步，真实双客户端验收。

**开工门槛**：M0 测现行实现，不依赖 Q1–Q6，可先做；M1 按上面的子项前置推进；M2 开工前闭合 P1 home 汇总、P4 接纳复核与粗层父格输入；
M3 开工前 Q1 定案；M4 开工前协议 42 与客户端接口冻结。工期在 M0 之后给出。

## 测试矩阵

| 项 | 证伪方式 | 期望依据 |
|---|---|---|
| 冷世界斜率 | M0：固定活跃负载，冷内容 1/2/4 份，常驻、单笔、启动、检查点、组装 CPU 不随份数增长 | 目标 1 |
| 活跃量与尖峰 | 多个独立稠密窗口、持续换窗、跨 Scene 移交、写回期间：事件额外占用 ≤ 声明预算并回落，尾延迟不劣于稳定段约定倍数 | 目标 2、3 |
| 页往返 | 多轮淘汰再装入后，该区下发字节与属性行逐字节等于淘汰前；派生引用全部释放 | I1、I3 |
| 写回并发 | 冻结后同页再改；两个版本写回乱序完成；写回成功但回调未达；截断前后崩溃——不丢更晚更新，不回退 | I2、I3 |
| 跨页原子恢复 | 多页 + 角色扣料 + 身份 + 全局水位同笔；只写回部分页后崩溃，恢复为完整一次效果；纯角色事务（进食）无空间页也正确恢复 | 现事务语义 |
| 重做粒度 | 同 seq 同页多行 + kind3、删至 baseline，重复恢复只生效一次 | P2 |
| 装页拒旧 | 装页 I/O 期间该页被装入、改写、写回、淘汰，迟到的旧结果被拒 | I3 |
| 热提交边界 | 热提交未完成时请求写回 / 淘汰，未提交热值不落页 | I2 |
| 缺失语义 | 冷页不被当 baseline；PG 无行才读 baseline | I4 |
| ring / 粗层 | 正负 XYZ 面 / 棱 / 角 ring；L1–L5 兄弟页编辑后卸载；冷页树冠；冷子页不删父级结构 | P1 |
| 跨页身份 | home 在窗口外的 g=2；跨页 g=3 从非 home 槽命中、拆除、重启；跨 4 页拼装件只按 id 拆除 | P1 home 规则 |
| 模拟边界 | 跨模拟边界导热、有限燃料 / 相变、电路跨冷热页、液体跨界、投射物轨迹；无玩家重启后活动恢复；守恒账前后相等 | Q1 合同 |
| 闭包新鲜度 | 准备等待期间依赖（树、槽集、定位）被另一提交改变：接纳时被复核拒绝或重新准备，不沿旧闭包提交 | P4 |
| 预算冻结与重启 | ticket 超额冻结后重启，资格不因重启重置；重新获得资格后才继续 | P6 |
| 边界唤醒 | 液体在墙前趋静 → 玩家走近使边界打开 → 两侧过程被唤醒继续 | P6 |
| 冷页视线 | 跨冷页的辐射视线按遮挡处理，不按露天 | Q1 |
| 权限 | 跨冷页的保护区与认领不被判成野外 / 无主 | P7 |
| 旧游标 | 安全前缀之前的游标显式重取快照；Replica 退休与 Scene 移交切点 | P3 |
| 迁移 | 用演练副本的现存世界迁移，迁移前后下发字节、属性行、余额逐项相等（Q5 批准的 max_hp 末位差异为唯一例外，逐项列出） | P2 |
| 维护入口 | 粗层重建、目录发布、parcel 导出 / 安装在分页后仍可运行，内存按范围有界 | P7 |
| 协议 42 | 服务端 golden 与 Voxim `VoxelM1CodecTests` / `VoxelDamageTests` 同一字节样本；进入 / 保留 / 退出 / 重进、默认化删除、同材质新世代、仅属性变化 | N 系列 |
| 双客户端 | 真实双客户端在不同区域往返、挖同一跨页拼装件，逐笔核对事务与属性行 | Voxim Testing.md §4 |

每处被替换的全表扫描按自然事务入口计“触及页数 / 字节”，不为 64 处逐一配计时测试，也不在生产路径加“没有全表扫描”自检。

## 验收（测量定义待批，数值 M0 后定）

- **每节点资源包络**：测前为每个节点声明 活跃集合占用 + 缓存预算 + 在途写回 / 装页 / 旧版本预算 + 运行时余量，测得峰值不超过包络，包络留在部署容量安全余量内；同主机多 peer 合计计算。
- **事件额外占用**：检查点、多窗口进入、跨 Scene 移交、Replica 初装、合法大事务、启动恢复——峰值减事件前平台、持续时间、在途字节；扩大冷世界不放大同一局部事件的峰值。
- **回落与积压**：突发结束后在声明窗口内，脏字节、最老脏页年龄、日志后缀、队列回到稳定区间；重复事件无逐轮抬升。
- **性能**：成功事务吞吐、拒绝 / 超时数；提交 p50/p95/p99（样本足够时 p99.9）、最长 World 回合、Scene tick、窗口 Ready、移交时限；写回期间对比同负载稳定段。
- **共享服务**：PG 连接数与池等待、日志 / 页写入率、磁盘余量。
- **冷世界斜率**：以上指标随冷内容份数的增量；10% 作为固定实验的候选回归线。
- 记录版本、硬件、预热、采样时长与样本数；样本不足判“未判定”，不判通过。

## 分支 A / B 与第二阶段大纲（不在本稿实施；各自另立决策稿时必须回答）

**分支 A：提交与存储调度。** 若日志等待主导，评估日志追加流水线、组提交等。PostgreSQL 文档说明并发提交可以摊销 flush，
但 “potentially at the expense of transaction latency”（wal-configuration），且不说明应用层 pending 状态如何安全暴露。另立稿必须先定：
committed / pending 的可见性（pending 不得被普通读、碰撞、观察看到）、后续事务对 pending 的依赖与失败撤销、取消、在途预算、恢复；
一笔失败不得拖垮同批无关操作。

**分支 B：并行计算、单点提交。** World 仍是唯一提交者与日志写者。计算在 World 外的工作进程上，以某版本的只读页集为输入算出结果；
World 校验依赖版本后应用并落日志，变了就丢弃重算。形态即乐观并发控制（Kung & Robinson, ACM TODS 6(2) 1981：
“they rely mainly on transaction backup as a control mechanism, ‘hoping’ that conflicts between transactions will not occur”，
https://www.cs.purdue.edu/homes/bb/cs542-20Spr/readings/cc/OMCC-Kung-81.pdf ）；最接近的系统先例是 Hyder（Bernstein, Reid, Das, CIDR 2011：
“Each transaction executes on a snapshot, logs its updates in one record … using optimistic concurrency control to determine whether each transaction commits”，
https://www.microsoft.com/en-us/research/publication/hyder-a-transactional-record-manager-for-shared-flash/ ）。另立稿必须回答：
- 提交成本 = 读集校验 + 应用结果，不是 O(差量)；读集随算随记（热的视线伙伴会动态扩张），校验粒度（页版本 / 键级版本）按实测冲突率选，
  热点页（液体 0.1 s、热步进与挖放共页）的重算率与活性必测；
- 热核 NIF 持有可变常驻态（`Mutex<Resident>`），不能当纯输入；worker 需独立的工作态或显式的副作用边界；
- 只读投影（载荷编码、观察组装）按观察切点计算，不落写日志，与写计算分开；
- 跨节点传页要编码复制（erlang.org eff_guide_processes：“When a message is sent to a process on another Erlang node, it is first encoded to the Erlang External Format”），
  先用同节点空闲核，跨节点只在实测有收益时采用；净收益（含重算）必测。

**第二阶段：按空间拆裁决权。** 两条候选路线，按 M0 记录的玩家聚集度与跨区事务比例比较：

- **候选 1 静态分片 + 边界交换**：每个分片拥有一组连续的页，各自串行裁决、各自日志；页到分片的映射由控制面持有（沿 `WorldServer.Movement.route/1` 的显式路由），
  重新分配时以 owner 版本拒旧（仓内 `DataService.BodyStore` claim/save 的 owner_epoch 是相近实践）。
  区域分解的一手依据：LAMMPS 开发者文档 “the simulation box is spatially decomposed (partitioned) into non-overlapping subdomains”、
  “subdomains are extended with ‘ghost’ atoms up to the communication cutoff distance”、“the overall simulation rate is limited by the slowest processor”
  （https://docs.lammps.org/Developer_par_part.html ）。
- **候选 2 动态合并（Folia 模式）**：按玩家附近的已加载区域动态成区，相邻即合并，区内单线程，从不跨区访问：
  “Adjacent regions must eventually merge to form a single region.”、“Code that is running in one region under no circumstance can be accessing or modifying data that is in another region.”
  （https://docs.papermc.io/folia/reference/overview/ ）。它按构造消除跨片物理与跨片电路，代价是热点合并后回到单写者、区身份随时间变化；
  Folia 自述最适合玩家天然分散的服务器。

无论哪条，第二阶段稿必须回答：
1. **邻接交换**：halo 宽度 = 各子算法的最大依赖距离（液体读两层 `world/liquids.ex:328-330`、热视线按 view_range 行进 `world/thermal.ex:898`、投射物飞行段 `world/projectiles.ex:54-62`），
   不是“一层”；锁步还是异步的时间协调范围。跨片流量：唯一消息号只保证不重复，不等于容量裁决与原子守恒——目标片的容量判定、在途状态的持久与恢复要明确。
2. **整体求解（电路）**：协调片汇总子图是候选之一；还要覆盖其他非局部耦合（热视线、身体交换、粗层派生页）。
3. **跨片原子事务**（拼装件跨界、片边界上的建造 / 挖掘 + 角色余额、施法取能）：候选为两阶段提交（ARIES p.96：多日志须 2PC）、
   单一排序点串行、或各片共用 PG 的同一数据库事务；**单一排序只给出顺序，不自动给出原子性**，每个候选都要写明原子决定与恢复。
4. **观察与订阅**：全局 seq 拆为各片序号后，客户端窗口跨多片时的观察切点与 fence（现客户端要求整窗同一 seq，`VoxelGateCodec.cpp:659-664`）；
   Replica 与 CollisionStream 现在只订阅单个 authority，需多片订阅合并；Scene 移交现以 `world_ref` 相等判定（`apps/world_server/lib/world_server/movement.ex:39-53`）。
5. **身份与共享事实**：分片内 id 命名空间（取代基于全局 seq 的 id）；protection holder、beacons、身份定位表、L5 等跨多片的共享派生页的 owner。
6. **迁移与交接**：热点片的负载迁移，交接期间拒旧、不丢更新（SpatialOS 文档警示交接丢更新）。
7. **Q6**：体素分片与 Scene 分片是否对齐。对齐只是让两者的边界一致，现拓扑下 Scene 与 World 本就不在同一进程，**对齐不等于同进程**；
   取舍是交互跨进程的次数 vs 两者切分粒度绑定。
8. **共享 PG 容量**：各片连接池与写入速率的合计。

## 进度日志

- 2026-10-24：四路只读调研完成，写成 v1。
- 2026-10-24：用户补充目标（平滑、无尖峰、考虑集群、内存可扩、不以 3.9 GiB 为终点）。Fable 5.1 high 与 Codex astra xhigh 各做独立评审与交叉评审，
  结论一致为“方向正确、v1 合同未闭合”。v2 补齐：不变量 I1–I5、home 规则与身份定位表、粗层树冠段、装页令牌、热提交边界、kind3 按目标拆行与迁移、
  连续限速写回与安全前缀、发送 / 驻留 / 模拟三集合、O(D+L) 的诚实表述、M2 提前包含装页、M0 变量分离、尖峰类验收。
  分歧裁定：保留身份定位表（Codex）而非协议带 anchor 删表（Fable）；角色账最终要按 cid（Codex），但排在 M3 之后（Fable）；
  删页检测不另造存在性清单（Codex）。待用户审批 Q1–Q5 后从 M0 开工。
- 2026-10-24：用户指出活跃区域是全部玩家窗口的并集、单 World 求解在大地图下压力过大、Scene 已按片多实例。补“整体路线”（第一阶段分页 → 1.5 步并行计算单点提交 →
  第二阶段按空间拆裁决权，后两步由 M0 饱和点触发）、M0 单 World 饱和点测量、Q1 边界改为“液体 / 热以冷页为墙，电路整分量装入”（取消“整条网络一起暂停”）、
  Q6 与第 1.5 步 / 第二阶段大纲。送两位评审第三轮。
- 2026-10-24：第三轮（两位评审独立 + 交叉）结论：前两轮严重项均已正确吸收；三步方向成立；v3 需定向修订。v4 修订：
  “World 先饱和的是 CPU”改为待 M0 证实的假设，回合耗时按计算 / 接纳应用 / 日志等待 / GC / 扇出 / 池等待拆分，路线改为按瓶颈选择的分支 A（提交与存储调度）/ B（并行计算）；
  启动成本加 G 与 A；全局保留项不再断言“无尖峰”；P1 home 记录带 aid 槽页集与整件 max_hp 汇总；粗层父格重算需完整子输入；
  P4 接纳按依赖版本复核（pin ≠ 新鲜）、闭包迭代求解、“有资格未驻留”与“无资格”分开、允许无资格页只读装入；P6 资格变化唤醒两侧、不补算、预算冻结不因重启复活；
  Q1 按交换类型分别定边界（辐射视线遇冷页按遮挡），电路改为有界迭代发现 + 整页资格，单分量超限行为加第三选项（接线时限制规模）；
  分支 B 补 OCC / Hyder 依据与 NIF 可变态、读投影分离；第二阶段补 LAMMPS 与 Folia 两条候选、halo 按依赖距离、“唯一消息号 ≠ 原子守恒”“单一排序 ≠ 原子”、
  多片订阅、共享事实 owner、Q6 “对齐 ≠ 同进程”；M0 不再等 Q1–Q6，M1 按子项前置推进。
  分歧裁定：日志流水线作条件分支而非强制步骤（Codex）；不预建持久电路连通目录（Codex）；电路页给整页资格而非仅电路资格（Codex：电热耦合不可割）；
  无资格页允许只读装入（Codex）；采纳 Folia 候选与键级校验作为待测选项（Fable）。
- 2026-10-24：用户批准 v4（“可以没问题”）。Q1 按建议定案，单个电路分量超限取 **(c) 接线时拒绝使分量超限的连接**；Q5 接受确定序与迁移时一次性重算并记录差异；
  Q2–Q4 按稿；Q6 留第二阶段。开工交给新会话，起点 M0，执行说明见 [`2026-10-24-world-region-paging/kickoff.md`](2026-10-24-world-region-paging/kickoff.md)。
- 2026-10-24 M0（进行中，1 份如园已测完，冷内容份数轴受开发机内存阻塞）：
  - **装置**（只测试，`apps/voxel_region/bench/paging_m0/`，见其 README）：Windows 原生 prod 构建（OTP 29 / Elixir 1.20，16 调度器；不起 gate_server——quicer 只在 Linux 构建），
    隔离 PG `voxim-pg-paging1024`，数据只从 `D:/hemifuture/Backups/ruyuan-20261024/` 的 dump 还原；探针每秒采节点内存 / World 堆与 mailbox / 调度器利用率，
    `:sys.install` 计 World 每条消息的回合时长，system_monitor 记 long_gc（≥20 ms）/ long_schedule，Repo telemetry 记池等待；负载 = N 个互不重叠窗口，
    各一个 `canonical_snapshot_and_subscribe` 订阅者 + 一个经作者入口 `apply_edits` 每秒交替放 / 挖一格的编辑者（只覆盖几何提交尾部，不覆盖玩家工具会话与扣料）。
  - **命令**：`python run_m0.py <deploy> <out> --dump /tmp/backup.dump --steps 1,2,4,8 --step-seconds 180 --idle-seconds 120`；
    证据 Voxim `Saved/Playtest/paging-20261024/runs/r10-1x-steps/`（源码 4cd0bab2 + 未提交的 bench 目录）。
  - **启动 / 空闲**：就绪 61 s，OS 峰值工作集 2.92 GB；空闲节点 2.0 GB、World 堆 1274 MB（字段与 10-23 基线一致）。
  - **逐级加压**（窗口 1 在如园中央，其余在 256 m 网格的普通地形上）：

    | N | 实得提交/s | 提交 p50 / p99 / max | World 回合忙碌 | 每笔 WAL | 每条增量 |
    |---|---|---|---|---|---|
    | 1 | 0.97 | 384 / 2892 / 3183 ms | 56% | 1395 KB | 1099 KB |
    | 2 | 1.92 | 408 / 2271 / 3813 ms | 81% | 843 KB | 298 KB |
    | 4 | 3.13 | 598 / 3955 / 4660 ms | 95%（饱和） | 744 KB | 94 KB |
    | 8 | 2.98 | 2504 / 4930 / 5471 ms | ≈100% | 745 KB | 33 KB |

    单格编辑的 World 内阶段（日志 `voxel_macro_stages`）：如园区 `l0_cache` ≈ 210 ms、普通地形 ≈ 40 ms；`log_us`（同步写库）p50 ≈ 10 ms；fanout ≈ 26 ms。
    PG 池等待 p99 ≤ 128 µs。**World 进程 long_gc 472 次、中位 434 ms、最长 709 ms；8 窗口时每 30 s 约 14 s 在 GC**；World 堆在 1.8↔4.2 GB 间锯齿，
    节点总量最高 7.8 GB，OS 峰值工作集 6.33 GB；运行结束存活堆 1.81 GB（`refined_encoded` 39→276 MB，无淘汰）。
    检查点每次冻结 World 455–520 ms，image 5.5–5.9 s。如园中央窗口快照 262 MB、8–13 s；普通地形窗口 7 MB、1.6–10 s（随并发准备排队）。
  - **初判（待 2 / 4 份与活动负载复核）**：饱和点约 3 笔/s；日志等待只占回合约 3%，不支持分支 A；回合主要是大堆 GC 与按区域 / 全世界的计算，
    分页（缩小常驻）与 P2 / P7 直接对准这两项。GC 停顿已远超任何合理回合上限，D4 的触发条件需在 M1 后复测时一并看。
  - **发现并修复的缺陷**：`Parcel.target_trees` 对全世界附件取主人（`world/parcel.ex:188`），世界里有无主人的独立附件（玩家所挂，如园有 11 个）时
    `parcel_install` 崩溃——10-23 装在空白野地上未触发，第二份如园必现。改为先按目标盒筛、无主人附件按越界拒绝；
    回归 `parcel_world_test.exs`“a player attachment outside the target box does not block the install”（改前红、改后绿，套件 6/6）。未提交。
  - **核对事实**：如园 15 批里只有 14 批有回执，garden-g4（约 48 万格纯地形）10-23 安装时 OOM 未装上；每份冷内容沿用这 14 批。
  - **阻塞**：第 2 份装到 Δ(-6352,-200,-6624) 时节点 RSS 7.9 GB、峰值 9.4 GB，系统可用内存降到 3.1 GB，会话内存护栏停掉了驱动；已停隔离节点，
    库停在 seq 14629（7/14 批，无半份）。用户同意停演练副本服务端容器 `voxim-qinglan-ruyuan-20261023`（只停未删，PG 容器未动）后续装：
    其余 6 批成功，最后的 garden-g2（206 万格、1717 实例、3.8 万格水）单笔安装时节点 RSS 10.05 GB、峰值 10.95 GB 仍在上涨，系统可用降到 2.3 GB，
    装置护栏（可用 < 2.5 GB）停掉隔离节点，g2 未写入。g2 内实例树与水互相咬合，沿 X 无切面、沿 Z 只有一处（切下 8064 格），不能再分批。
    **同一局部维护事件（装一批）的峰值约 11 GB，本身即 M0 的尖峰证据。** 当前隔离库 = 第 1 份完整 + 第 2 份缺 g2 的 13 批（seq 14641，dump
    `Saved/Playtest/paging-20261024/source/paging_2x_no_g2.dump`）。**用户决定暂停 M0，等加内存后继续**（冷内容 2 / 4 份、活动负载 `--activity`、电路、重叠窗口、跨 Scene 移交均未测）。
- 2026-10-25 M0（续，开发机加到 95.8 GiB 后；源码 4cd0bab2 + 未提交的 bench 目录与 `world/parcel.ex` 修复，prod 构建同此）：
  - **冷内容份数轴**：第 2 份补装 garden-g2（142 s，峰值工作集 10.5 GB），第 3、4 份装到 Δ(-7632,-200,800)、Δ(48,-200,-6112)，全部 14 批成功（seq 14698）；
    dump `Saved/Playtest/paging-20261024/source/paging_2x.dump`、`paging_4x.dump`。三轮负载与 10-24 的 1 份完全相同
    （`run_m0.py ... --steps 1,2,4,8 --step-seconds 180 --idle-seconds 120`，runs `r10-1x-steps` / `r20-2x-steps` / `r30-4x-steps`，对比 `bench/paging_m0/compare.py`）：

    | 份数 | 就绪 / 启动峰值 | 空闲 World 字段（entries / refined / epochs / component_cache，flat MB） | 每笔 fanout / reduce / regions / log p50 | 单格每笔 WAL | 饱和吞吐 | 8 窗口提交 p50 / p99 | World long_gc 中位 / 最长 | OS rss 最高 | 检查点冻结 / image |
    |---|---|---|---|---|---|---|---|---|---|
    | 1 | 61 s / 3.1 GB | 309 / 310 / 276 / 560 | 26 / 10.5 / 12 / 10 ms | ≈0.75 MB | ≈3.1 笔/s | 2.5 / 4.9 s | 449 / 563 ms | 6.2 GB | 0.46–0.52 s / 5–6 s |
    | 2 | 200 s / 7.5 GB | 871 / 582 / 704 / 1047 | 57 / 21 / 26 / 17 ms | ≈1.9 MB | ≈1.8 笔/s | 4.8 / 12.3 s | 919 / 1177 ms | 12.3 GB | 0.86–0.90 s / 13–16 s |
    | 4 | 330 s / 10.7 GB | 1419 / 1126 / 1187 / 2019 | 118 / 43 / 56 / 29–38 ms | ≈5–7 MB | ≈1.2 笔/s | 4.6 / 19.4 s | 509 / 2084 ms | 20.5 GB | 1.47–1.56 s / 41–67 s |

    常驻状态、启动、检查点与每笔提交里与本笔无关的阶段都**随冷内容份数近似线性增长**（prefabs 239 MB 不变）；冷世界斜率（目标 1）现状不合格。
    口径更正：`total_heap_mb` 含未回收垃圾、随 GC 时机跳动（2 份 4183 MB > 4 份 3775 MB），跨轮只比字段 flat 量；long_gc 统一按 events.jsonl 里
    World 进程重算（1 份最长 563 ms，10-24 条目的 709 ms 是另一口径）。回合直方图的统计窗口从 reset 起含快照 / 夹具安装期，长于提交 span，
    “忙碌 > 100%”是分母差，只比占比。
  - **同一局部事件（装 g2 一批）**：峰值减装前平台 第 2 / 3 / 4 份 ≈ 6.9 / 8.8 / 8.1 GB（不随份数明显放大），但平台随常驻抬高（安装期间节点未重启，
    绝对峰值 9.6 → 16.0 → 27.1 GB）。
  - **活动负载**（1 份，`--activity --circuit`，run `r40-1x-activity`）：每窗口 18 格水（液体实验入口）+ 20 kW 有限热源 + circuit_test“手算例 1”的
    热电石 8 格环（作者入口 `apply_edits`）+ 200 kW 热源；8 窗口时电路 64 节点、8 盏灯亮，热电做功累计 4.95 万 J，能量账闭合。

    | N | 实得 | 提交 p50 / p99 | 回合前三（s） |
    |---|---|---|---|
    | 1 | 0.20 笔/s | 4.3 / 9.7 s | 液体 98、热 81、挖放 18 |
    | 2 | 0.54 笔/s | 3.4 / 7.5 s | 热 161、液体 59、挖放 28 |
    | 4 | 0.54 笔/s | 7.3 / 9.5 s | 热 172、液体 56、挖放 46 |
    | 8 | 1.48 笔/s | 5.0 / 9.7 s | 热 224、液体 90、挖放 61 |

    编辑者串行，1 窗口的低吞吐是单笔排在 2–3 s 的热 / 液体回合之后；水区内单格编辑 `regions` 阶段 p50 580 ms（无水 12 ms）。
    热步进成本对夹具位置敏感（同为 1 窗口，另一组位置热 31 s），绝对值只对本组位置成立。**有活动时回合由计算（热、液体）主导**。
    夹具三次修正记录在失败目录：`r40-failed-spot-search`（坡地找不到平地）、`r43-failed-start-timeout`（逐格探测在液体回合后排队超时）、
    `r44-failed-circuit-totals-timeout`（`:sys.replace_state` 5 s 默认超时）；第一次失败（水落在微格上 `{:error, :refined_cell}`）的目录已删，
    原始错误在 `server/logs/20261025-035856.log:31250`。另：水离编辑格 2 m 时会流到编辑格上，作者入口拒绝改写液体格（`:use_liquid_tool`），已挪到 12 m。
  - **重叠窗口**（1 份，`--spacing 64`，run `r50-1x-overlap64`，窗口都落在如园稠密区）：N=2/4/8 实得 1.40 / 1.52 / 1.43 笔/s，提交 p50 1.1 / 2.7 / 5.7 s，
    8 窗口 p99 8.2 s；每窗口快照 125–262 MB（不重叠普通地形 7 MB），8 窗口增量下发 1764 MB（不重叠 177 MB）。饱和点约减半；本组同时改变了重叠与密度。
  - **同页反复安装**（1 份，`reinstall.py --rounds 2 --skip ruyuan-garden-v1-g2`，run `r61-reinstall-13`）：原位 Δ(+3952,−200,+96) 每遍 13 批，
    overlay 行 16640 不变、World 各字段不变、每遍安装峰值约 5.4 GB 无抬升、就绪 60 / 84 / 67 s（噪声）。**该增长轴现状无增长。**
    发现：garden-g2 **不能原位重装**——`{:target_attachment_crosses_boundary, 25143}`，目标盒里有第一遍装入的玩家独立附件，既有规则是盒内不随树清除的附件
    整批拒绝（10-24 的修复未改变这条语义）。分页后“维护入口”一项须决定盒内独立附件是随安装替换还是拒绝。证据 `r60-failed-g2-refused`。
  - **分支判定**：日志同步写在 1 份时约占回合 3%，随份数增长的是整笔与世界相关的工作（P2 / P7 的对象），不支持分支 A；只有挖放时回合主体是大堆 GC 与全表扫描，
    有液体 / 热 / 电路活动时主体是计算——M1 后复测若仍如此，指向分支 B。
  - **未测**：跨 Scene 移交（Windows 原生无 Gate，需 Linux 构建 + 真实客户端）；玩家聚集度（开发期无真实玩家分布数据）；“固定内容扩大世界范围”与
    “增加不同定义数”（冷内容份数轴已部分覆盖前者）。这些不阻塞 M1。
- 2026-10-25 M1（进行中，未提交；改动见工作区 `apps/voxel_region`）：用户定“目标是定位根因并修复”。先剖析再改：
  - **定位方法**：`bench/paging_m0/profile.ex` 只对 World 进程开 `call_time` / `call_memory` 计数（`:erlang.trace_pattern`，不带 `:local`——
    首次误带 `:local` 让每次调用都发追踪消息、吃光开发机内存，会话内存护栏杀掉了节点，已改并在独立 erl 里验证 0 条消息），
    4 份如园上 6 笔单格编辑排序；证据 Voxim `Saved/Playtest/paging-20261024/runs/p01..p04-*`。
  - **根因 1（CPU 与分配的大头）**：`AttachmentOps.affected_attachments/2` 每笔多次遍历全世界附件槽、逐槽展开宏格与支撑邻格再去重
    （4 份 ≈4 万槽；6 笔里 `Attachments.map` 840 万次、分配 4.8 亿字）。修复：`attachment_regions` 派生索引（L0 区域 => 锚点在该区的槽，
    只由 `Canonical.put_attachments/drop_attachments/index_attachments` 写，不持久化），`affected_attachments`、`l1_faces`、区域载荷 `extract`
    只取相关区域候选再按原判定筛；`prune_attachments` 的整表键差改为按索引区域求差。结果按槽排序（小表与原整表次序相同）。
  - **根因 2**：`Observation.property_transaction` 每笔拼接并去重提交前后的全部 refined 键与全部 `macro_owners` 键再逐格比较。修复：
    `refined_regions` 改存区域 refined 子表（写入即换新），`changed_refined_cells/2` 只在子表不同的区域里比较；归属 / 世代改动只看
    `txn.macro_owners` / `txn.epochs`（两者本就是日志回放与 Replica 唯一依据的完整增量，`ownership_metadata` 覆盖全部写入路径）。
  - **根因 3**：`Canopy.affected_keys/project`、区域载荷、`live_instance_ids` 每笔整表扫 `macro_owners`（4 份 ≈27 万格）。修复：
    `macro_owner_regions`（区域 => 子表）与 `macro_owner_cells`（归属 => 格）派生索引，只由 `put_macro_owner/3` 写；第 5 级祖格（32 宏格）
    落在一个 L0 区域内，所以树冠受影响键只需改动格所在区域的绑定格。区域载荷的 `liquid_units` 同样改为 `liquid_regions`（`put_liquid/2`）。
  - **根因 4（每笔 WAL）**：kind 3 元数据每笔整表写 `prefab_instances`（4 份 7501 个）与 `attachment_owners`（5.4 万项），压缩后 741 / 760 KB。
    修复：`Log.append_log(before, state, txn)` 在两表与提交前相同时不写；回放缺省沿用前值（`replay_damage/2` 既有语义，纯液体提交早已如此），
    不改格式、不需迁移。真正改了实例 / 附件的提交仍写整表——按键增量（完整 P2）留待定格式版本与迁移后再做。
  - **根因 5（检查点）**：World 回合内同步写库（4 份 `persist_us` 7.6–14 s）与检查点后的整堆 `:erlang.garbage_collect`（4 份 ≈1 s）。
    修复：落盘移入检查点任务（`Log.persist_checkpoint/2`；Db 后端 `replace` 本就只删 ≤ P、保留并发追加的 seq > P 行；文件后端改为检查点写
    `overlay.log.checkpoint`、回放 = 检查点 + 更晚帧，与 Db 同一契约，可与 World 追加并发），去掉整堆 GC（常规分代 GC 回收已退休历史）。
    剩余：`freeze_us` 仍随世界增长（1 份 0.6 s、4 份 2.1 s）——`Task.async` 把整份检查点输入复制进任务进程堆，BEAM 进程不共享堆，
    留给 M2 按页连续写回解决。
  - 另：`apply_batch` 的 `carried` 只在有随笔搬运值时扫 damage；`edits`/`prefabs`/`gm` 的按身份删附件只在确有身份要删时才扫附件表。
  - **验证**：新增 `world_attachment_index_test.exs`（手算区域 + 固定种子 5 组 400 槽跨正负坐标与 ±512 微格边界，`affected_attachments`、
    `l1_faces`、`extract`、`dropped_attachments` 与整表定义逐项相同）、`world_refined_index_test.exs` 增 refined 改动格 / macro_owners / liquid 索引用例，
    `prefab_macro_world_test.exs` 增“未改实例与归属的提交不写两表、重启后实例 / 归属 / 附件拆除退料不变”（改前红、改后绿）。
    夹具补派生索引字段：`canopy_projection_test`、`payload_candidate_test`；检查点完成信号由 `voxel_checkpoint_gc` 改为 `voxel_checkpoint seq=`
    （`phase_world_test`、`thermal_fire_benchmark_test` 解析器与其三条单测按新阶段：后台 = select+image+persist，World = freeze+rebase）。
    全量 `MIX_ENV=test mix test --no-start`（voxel_region）五轮：每轮失败 = 开工说明列出的 14 项既有失败；另有两类非改动引入：
    `world_interactions_test` 真实库用例在多文件同跑时失败（改动前的代码同组合同样失败，单独跑 4/4 通过——测试间共享真实库），
    `thermal_switch_test` / `furnace_generator_world_test` 各一次在全量高负载下偶发（单独连跑 3 次全过，依赖真实时钟热节拍的时机）。
  - **实测**（同 M0 装置与负载，`run_m0.py ... --steps 1,2,4,8 --step-seconds 180`；runs `r70/r71`（前两项）、`r80/r81`（全部））：

    | 份数 | 版本 | 8 窗口实得 | 8 窗口提交 p50 / p99 | 4 窗口 p50 / p99 | log p50 | 8 窗口每笔 WAL | World GC 最长 | 检查点 World 内（freeze + persist） |
    |---|---|---|---|---|---|---|---|---|
    | 1 | M0 | 2.98 笔/s | 2.5 / 4.9 s | 598 / 3954 ms | 10 ms | 745 KB | 563 ms | 0.5 + 1–2 s |
    | 1 | 现 | 7.87 笔/s（不饱和） | 0.40 / 1.36 s | 83 / 815 ms | 4 ms | 154 KB | 606 ms | 0.65 s + 后台 |
    | 4 | M0 | 1.24 笔/s | 4.6 / 19.4 s | 2.5 / 16.4 s | 29 ms | 5.06 MB | 2084 ms | 1.5 + 7.9–14 s |
    | 4 | 现 | 6.15 笔/s | 0.51 / 3.1 s | 363 / 1771 ms | 4.9 ms | 0.50 MB | 2111 ms | 2.1 s + 后台 |

    每笔阶段 fanout 118 → 0.1 ms、structure 33 → 0、reduce 43 → 3.9、log 29 → 4.9（4 份）。仍随份数增长：`regions`（1 份 9 ms / 4 份 40 ms）、
    检查点 freeze、最长 GC（停顿 ∝ 存活堆，M2/M3 缩小常驻才能根治）。`l0_cache`（如园窗口 ≈190–200 ms）与 `collision`（≈50 ms）随内容密度、
    不随份数。冷世界斜率仍未达 10% 候选线，M1 继续。
  - **根因 6（每笔扫全部 damage）**：`Tools.damage_geometry` 的移除筛选、`attachment_damage` 的逐槽 / 整件行、`apply_batch` 的 `carried`
    每笔遍历全部属性行（4 份 23.5 万行；p04 剖析里 `Damage.macro` 172 万次、`Integer.floor_div` 670 万次，计时落在 `regions` 阶段）。
    用户选定“按提交前目标反查”（不建 damage 派生索引）：`Canonical.damage_rows_in/3` 由提交前改动格上的实占目标算出键直接取行
    （未细分格的宏格行、refined 格逐槽热节点行与部件行），读格值借用本笔已解码的源基线、不在 World 里重读；`attachment_damage`
    只取提交前后被删 / 新增 / 改值的槽（`changed_attachments/2`；附件索引改为区域 => %{槽 => 值} 子表，未写区域与提交前同值）。
    前提是“damage 无过期行”（行键 = 其坐标上实占目标的键；整件行最大 HP = 现存槽折算）：`test/support/damage_invariant.exs` 定义，
    4 份如园真实数据核对 235 480 行（0/1/2/4 粒度 156 563 / 78 692 / 1 / 224）过期 0 行（`runs/s01-4x-stale`）；全量测试期间临时让每次调用
    同时跑旧整表扫描并在候选集不同时抛错，全程 0 次（该对拍代码未保留）；`damage_world_test` 三个真实场景（宿主被挖附件失撑、热节点烧毁、
    附件部分失撑 + 重启 + Prefab 放拆）断言无过期行，把整件行重算改成恒保留后断言即报 `%{3 => [{3, 7}]}`（反例验证后已还原）。
    全量第 6 轮：14 项既有失败，另 `thermal_radiation_world_test` 逐位摘要一项在全量高负载下偏差（同组 `enclosed` 温度在全量与单独跑
    不同，依赖真实时钟热节拍；单独连跑 4 次全过），非本次引入。
  - **实测**（runs `r90-1x-m1c`、`r91-4x-m1c`，同上负载）：`regions` p50 1 份 9.3 → 3.0 ms、4 份 40 → 12.6 ms（仍随份数，待剖析）；
    1 份 8 窗口 p99 1.36 → 0.86 s、最长 2.1 → 1.1 s；4 份 8 窗口 6.15 → 6.69 笔/s、p50 513 → 473 ms，p99 3.1 → 3.2 s 不变。
    4 份 p99 由 World 主回收主导：每次把 5–6 GB 存活堆整份复制，停顿 1.6–2.5 s；≥1 s 的次数各轮 167 / 102 / 48 / 128（M0 / m1a / m1b / m1c）
    随堆尺寸档位起伏，不随本次改动。根治要缩小存活堆（M2/M3）；另发现空闲时 `entries` 里唯一一条（检查点）按 `flat_size` 计 4 份 1.4 GB /
    1 份 0.3 GB，随世界增长，待核实是否与 World 状态共享结构。
  - **根因 7（常驻第二份世界）**：上条已核实。线上检查点正文（全部世代、全部属性行、账本）在任务里构建，经任务结果消息复制回 World——
    BEAM 消息复制拆掉全部共享——再整条留在保留历史 `entries` 里：每次检查点往 World 堆里瞬时复制 ≈1.3 GB，之后常驻到下一次检查点。
    内存里保留事务的读者只有订阅补发与分区增量投影（读 `seq` / `entries` / `coarse` / `liquid_units`；线格式只编码前三项与落体 / 操作），
    `entries_after`（只供测试与诊断）对只剩投影的事务从持久日志读正文。修复：`Log.persist_checkpoint/2` 落盘后只把投影带回 World；
    `retain_entry` 对检查点（唯一带 `interaction_history` 的事务，`Interactions.apply/2` 同一判据）与纯属性事务一样只留投影，启动回放的检查点
    与线上检查点同一规则。曾试过让 `entries_after` 一律读日志——日志里单格编辑与区域整图的形态和内存不同，3 个用例依赖内存形态——已撤回。
    `damage_world_test` 增“完成的检查点在内存只留投影、正文从日志读”（改前红、改后绿）。全量第 9 轮：14 项既有 + `world_interactions_test`
    真实库多文件同跑偶发（同组单独跑通过）。
  - **实测**（runs `r92-1x-m1d`、`r93-4x-m1d`，同上负载）：

    | 份数 | 版本 | 8 窗口实得 | 8 窗口 p50 / p99 / 最长 | World 主回收：≥20 ms 总停顿 / ≥1 s 次数 / 最长 | 结束时 World 堆 | `entries` |
    |---|---|---|---|---|---|---|
    | 4 | m1c | 6.69 笔/s | 473 / 3234 / 4622 ms | 215 s / 128 / 2514 ms | 6.5 GB | 1318 MB |
    | 4 | m1d | 7.83 笔/s（不饱和） | 198 / 723 / 2725 ms | 17 s / 13 / 1149 ms | 4.7 GB | 15 MB |
    | 1 | m1c | 7.93 笔/s | 347 / 861 / 1080 ms | 42 s / 0 / 780 ms | 2.5 GB | 309 MB |
    | 1 | m1d | 7.91 笔/s | 397 / 859 / 1551 ms | 113 s / 0 / 478 ms | 1.3 GB | 4 MB |

    4 份的长停顿基本消失（瞬时 1.3 GB 复制本身就会触发主回收）。1 份 p99 持平，≥20 ms 停顿次数随堆尺寸档位起伏（110 → 332 次，最长反降）。
    剩余随世界增长：`regions` 1 份 3 ms / 4 份 12.5 ms；检查点 freeze（整份输入复制进任务）；存活堆本身（`component_cache` 2.0 GB、`refined` 1.1 GB、
    `epochs` 1.2 GB @4 份）——M2 / M3。
  - **根因 8（热提交与附件归属每次扫全部附件 / 属性行）**：剖析 `p05-4x-profile-m1d`（6 笔单格编辑）里 `Tools.attachment_damage` 每笔对全部附件槽
    （4 份 ≈5.4 万）建存活 ID 集再 `Map.take` 归属表——这就是 `regions` 阶段剩下的 12.5 ms。另从基准日志 `voxel_thermal_prepare` 发现：每笔编辑后的
    热 / 电路提交即使候选域为空，4 份也要 48 ms（1 份 10 ms，整轮 1157 次合计 60 s World 时间）：热域休眠时 `thermal_work` 重置、附件足迹缓存随之清空，
    下一次 `ThermalWork.refresh` 对全部附件重算足迹并逐槽比对候选域（36 ms）；结算后判活跃又逐行扫全部属性行找燃烧标记（≈10 ms）。修复：
    归属表只对本笔丢槽的附件判存活（同一附件的槽都在锚点一宏格内，查所在区及相邻区，`Canonical.attachments_around_region/2`）；
    `refresh` 改收候选域附近区域的槽（新 `Canonical.attachments_touching/2`），删去附件足迹缓存（它在热域活跃期间也不随附件改动失效）；
    判活跃只查计划时的燃烧行、本步改写的行与上次写回后在原生侧熄灭的行（`ThermalWork` 新字段 `extinguished`，写回时清空）。
    `thermal_work_test` 去掉直接预置足迹缓存的一行（`refresh` 已直接用传入的附件）。验证：归属与判活跃各加临时对拍（新旧结果每次比较、不一致即抛错），
    附件 / 预制件 / 地块 8 个文件 145 项全过、对拍触发真实删除（id 2、7）；全量第 11 轮 0 次不一致，只剩 14 项既有 + `world_interactions_test` 真实库偶发，
    既有失败里的热摘要与第 9 轮逐位相同（如 `thermal_edit` 的 `7ca7a94…`）；临时对拍已删。
  - **实测**（runs `r94-4x-m1e`、`r95-1x-m1e`，同上负载）：

    | 份数 | 版本 | `regions` p50 | 空域热提交 p50（整轮合计） | 8 窗口 p50 / p99 / 最长 | World 主回收：≥20 ms 总停顿 / ≥1 s 次数 / 最长 |
    |---|---|---|---|---|---|
    | 4 | m1d | 12.5 ms | 48 ms（60 s） | 198 / 723 / 2725 ms | 17 s / 13 / 1149 ms |
    | 4 | m1e | 0.1 ms | 0.1 ms（2.3 s） | 78 / 609 / 2526 ms | 18 s / 14 / 1171 ms |
    | 1 | m1d | 3.0 ms | 10 ms（31 s） | 397 / 859 / 1551 ms | 113 s / 0 / 478 ms |
    | 1 | m1e | 0.1 ms | — | 308 / 766 / 1376 ms | 91 s / 0 / 391 ms |

    每笔 World 内阶段除 `reduce`（1 份 1.1 / 4 份 3.9 ms）外不再随份数增长。剩余长尾是主回收：停顿时长随存活堆（4 份 ≈4.6 GB、1 份 ≈1.3 GB），
    1 份堆小、主回收更频繁（268 次 × ≈340 ms），所以 1 份 p50 反比 4 份高。根治要缩小存活堆（M2 / M3 分页）；检查点 freeze 同前。
  - **提交后真实节点核对**（`acb401e7`，1 份隔离库，runs `v01-1x-restart`）：3 处地表放石、1 处挖空 → 等线上检查点（新投影路径，seq 14617）→
    检查点后再放一格 → 停机重启：8 个格的材料逐格相同，重启 seq 14619 = 停机前最后提交（快照后自动的一笔热提交）。同库再测每笔日志行：
    单格编辑 ≈0.9 KB（kind0 24 B + kind2 300 B + kind3 ≈0.57 KB）、空域热提交 ≈0.5 KB，已与世界大小无关；PG 写入量现由 60 s 整世界检查点主导
    （1 份每次 kind3 35 MB + 区域整图 11.8 MB），连同 World 内冻结（1 份 0.5 s、4 份 ≈2 s，整份输入复制进任务）与 4 份每次 ≈58 s 的后台编码，
    以及主回收停顿，都要 M2（页存储 + P3 连续写回）才能去掉。
- 2026-10-26：用户同意 M2 先做“页表 + 连续写回”、设计先评审。M2 拆为 M2a（页表、脏页判定、逐页冻结写回、多版本页 + 安全前缀、启动读页 + 后缀、一次性迁移）
  与 M2b（按需装页、身份定位表、读取闭包、启动按需）；M2 交付门槛不变。设计稿 [`m2a-page-store.md`](2026-10-24-world-region-paging/m2a-page-store.md) v1，
  简报 `review-brief-m2a.md`，送 Fable 5.1 high 与 Codex astra xhigh 独立评审。
- 2026-10-26：M2a 两轮评审完成。首轮独立（两位一致：方向正确、v1 不能开工，严重项为身份归属、判脏出口、切点一致、闭包、崩溃脏集、旧游标）→ v2
  （页存本页原始真值、`remember_entry` 判脏、冻结引用、信用窗口）。交叉评审（两位都给“改完六项即可开工”）→ v3：在线事务缺整表字段改按引用比较（R1）、
  装页恢复 `snapshots`（R2）、切点由 seq 前进驱动且启动规范化改真实维护提交（R3）、液体活动集变化也提交（R4）、写回尝试状态机（R5）、旧游标显式拒绝（R6）；
  另把有主 aid 的 home 定为 owner 实例 home（对 P1 的显式修订）、负坐标 floor_div、段级行与最短写回间隔控制写放大。两位都表示其余【中】【轻】随实现落实，不需再开一轮设计。
