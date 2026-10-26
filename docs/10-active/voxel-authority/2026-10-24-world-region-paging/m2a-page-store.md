---
status: v3 已批准开工（2026-10-26）；§5.2 按实测改为 16³ 子块行
parent: ../2026-10-24-world-region-paging.md（approved v4，本稿细化其 M2 的第一个增量；§3 对 P1 的 aid home 规则做一处显式修订）
code: ex_mmo_cluster master acb401e7
reviews: review-fable-m2a.md、review-astra-m2a.md（v1 独立）；review-fable-m2a-cross.md、review-astra-m2a-cross.md（v2 交叉）
---

# M2a：页表与连续写回（取代 60 s 整世界检查点）

## 0. 评审吸收记录

### v1 → v2（首轮独立评审，两位一致：方向正确、v1 不能开工）

| 评审意见 | 处理 |
|---|---|
| `attachment_owners` 的 `slot` 是定义内组编号（F1.1 / A1.1）；g=2/3 行的 `micro` 随命中改变、`tools.ex:461` 改写 `before`（F1.1 / F2.2 / A1.2） | 身份按 home 归页（§3），旧页由页索引给出（§4.1），不用 `before` |
| 复用 `replay_entry` 的实例 merge 会让 VXR 投影覆盖 home 记录（丢 `placed_by`）（F1.2 / A1.3） | 页存本页原始真值，装页不走 `replay_entry` 的实例合并与 live 过滤（§3、§6.2） |
| `payload_bytes` 闭包远超 27 页（粗层 34³ 个 L0 区）（F3.2 / A3.1） | 页编码只读本页原始值，不调 `payload_bytes`（§3） |
| 纯液体走 `append_journal` 直写，不经 `append_log`（F2.1 / A2.1） | 判脏放在所有成功提交与回放共同经过的 `remember_entry`（§4.1） |
| 分批跨回合抽取混合切点（F3.1 / A3.2） | 切点绑定冻结引用，批次只从它抽取（§5.1） |
| 资源上界不能“先计量后限流”（A3.4） | 信用窗口 + 显式接纳边界（§5.3） |
| 崩溃后脏集不重建（F4.1 / A4.1）；旧游标静默缺事务（F4.3 / A4.2）；迁移判定（A5.2）；structure 不持久（F1.3） | 回放经 `remember_entry` 重建脏集；§6、§7、§3 |
| epochs 用嵌套存储（F3.3 / A3.3） | 采纳（§5.4） |

### v2 → v3（交叉评审，开工前必改六项 + 中项）

| 评审意见 | 处理 |
|---|---|
| **R1** 在线 `remember_entry` 收到的事务没有 `append_log` 内部补入的 `prefab_instances` / `attachment_owners` / `liquid_active`（A3.1 / F 交叉 4） | 这三项与 `thermal.sources` 改为与“上次已记住的值”按引用比较，在线与回放同一规则；其余字段事务本身就带（§4.1） |
| **R2** 装页只填 `region_bases`，`snapshots` 无人填，`payload_bytes` 快路径会按 baseline 服务（重启后建筑撞得到看不见）（A2.1 / F 交叉 2） | 唯一装页入口按页段恢复 `snapshots` 等派生标记；判定器加正式读取等价（§6.2、§8） |
| **R3** 只写全局账的提交开不了切点；启动规范化与 C>P 冲突；首次启动（A3.3） | 切点由“seq 前进”驱动，D_C 可空；启动规范化改为真实维护提交；首次启动发布 P=0；CoarseRebuild 定为独占维护（§4.3、§5.1、§7） |
| **R4** 不接受只存已提交活动集带来的恢复差异（A3.2 / X3） | 液体 owner 把无数量变化的活动集转换也提交成事务（§4.2） |
| **R5** C>P 不能去重；DOWN 不能证明未发布（A5.1 / X5 / F 交叉 5） | 写回尝试的状态机：以持久水位判定结果、重试前清理未发布版本（§6.1） |
| **R6** “合成完整快照事务”不具快照语义（A5.2 / F 交叉 6） | 旧游标显式拒绝，调用方走已有快照入口；`serve_item` 返回整区载荷（§6.3） |
| 有主 aid 归 owner home 与父稿“首槽页”不同（X1） | 明确为对 P1 的修订（§3） |
| `div(anchor, micro)` 对负坐标错（A2.2 / F 交叉 3） | 用 `Prefab.macro_slot/1`（floor_div） |
| 不应再加 `domain.pending` 门禁（X4） | 删去，切点只用现有合法提交边界 |
| 冻结引用会钉住无关字段（A4.1） | 冻结只取持久字段的引用（§5.1） |
| 写放大无接受线（F 交叉 7） | 每页最短写回间隔 + 段级行 + 开工前先量密集页（§5.2、§8） |
| 接纳要在扣账前、覆盖全部提交入口、恢复时唤醒调度（A4.3） | §5.3 |
| Replica 退休通知单调、Scene 无 stream 分支未处理过期（A5.3） | §6.3 |

### 实现与本稿的偏差（第 1–5 步，2026-10-26）

| 本稿 | 实现 | 理由 / 代价 |
|---|---|---|
| §6.1 同一时刻一个写回进程，旧进程 `DOWN` 后由新进程以持久前缀收口 | 写回进程与 World **链接**：写回异常退出时 World 一起重启，启动按持久前缀装页 + 重放后缀；尝试“开始”仍读前缀（≥ C 即已发布，否则清残留） | 单写者与“以持久水位判定结果”同一保证，少一条在线重启分支；代价是写回异常 = World 整体重启（启动时长仍随世界大小，M2b 再降） |
| §5.1 `cut_interval` 默认 10 s；§5.2 另设 `min_segment_interval` 30 s；每批按段数 / 字节 / 5 ms 预算 | 切点间隔 30 s；不单设 `min_segment_interval`（每行每个切点至多写一次，切点间隔即最短写回间隔）；每批 64 个单元 | 实测常规切点 ≈26 单元、30 ms（`r97-4x-m2a4`），按单元计数已足够；字节预算未做 |
| §5.3 积压量含冻结存活时长、在途字节、脏段数、最老脏段年龄、日志后缀行数 | 全部进 `World.stats`；**定级只看**日志后缀事务数（`seq − P`）与攒下的脏单元数，默认 {软, 中, 硬} = {2 000, 10 000, 50 000} 笔、{2 万, 10 万, 40 万} 单元，启动选项 `persist_backlog` 可改 | 两者只随提交增长、只因发布回落，在提交与发布时重算即可，不需定时器；资源增长（后缀、保留历史、冻结与当前状态的分叉）都由提交驱动。迁移切点期间尚无前缀，不计积压 |
| §5.3 软上限停非必要后台 | 软上限：立即排切点（200 ms）、停发布后的按区压实（当前唯一的在线整世界类维护） | — |
| §5.3 中上限暂停热 / 液体步进 | 另暂停投射物轮询 | 投射物经热提交落账，不停会继续产生提交 |
| §5.3 硬上限覆盖施法 / 投射物 / 身体后果等全部提交入口 | 在 World 调用入口（编辑、工具 / 生产 / 附件 / 预制件意图、施法、供料、注液、GM、地块、信标安装、作者与目录发布）与新施法前摇、新信标读条处拒绝；工具 / 施法的 action 0（只查询）照常；已接纳的施法结算、已开始的信标读条、进行中的热步进收尾走完；**死亡掉落豁免**，硬上限下照常提交 | 进行中的动作在接纳时积压尚未到硬上限；死亡掉落是已确认死亡的后果、不是新的玩家意图、频率有限，被拒即物品永久丢失（没有重试通道），2026-10-26 统筹定为豁免（`persist_backlog_test` 覆盖） |
| §6.1 第 3 步“推进影响 0 行时重读 P” | 发布事务先 `SELECT … FOR UPDATE` 读前缀，已 ≥ C 即什么都不写、回滚报 `{:prefix, P}`；写回进程把 `P == C` 当作已发布、其余当失败 | 同切点重发若先插段会撞主键；先读前缀后两种情形都不写 |
| §6.3 Replica 退休 | 只通知确认已满 `replica_retain_s`（默认 60）的最新前缀、单调，定时器收尾；到期通知先于 `compact` 回复发出 | 同节点调用方收到 `compact` 回复时 Replica 邮箱里已排着通知 |
| §6.3 Scene 无 stream 移交遇过期“重新准备” | 目标 Scene 拒绝本次准备（回 `{:error, reason}`、不建 Player）；源侧沿既有失败路径关连接，客户端重连走快照入口 | 不在 Scene 内自动重试 |
| §8 判定器 a“按 core 物化的格材料与 skins” | 原始字段逐键比较；地形的 base + 稀疏格在发布 / 回放会换基底（同一真值两种表示），表示可能不同的场合只比正式读取（整区载荷去头部 seq） | 迁移等价两侧表示相同，原始 overlay / region_bases 也逐键比较 |

## 1. 为什么先做这一步（M1 收尾实测）

M1 之后，每笔提交在 World 内的各阶段已与世界大小无关，每笔日志行 ≈0.5–0.9 KB。剩下随世界增长的，全部来自整世界检查点与存活堆：

| 随世界增长的量 | 1 份如园 | 4 份如园 |
|---|---|---|
| 检查点 World 内冻结（`checkpoint_input` 复制进 Task） | 0.52 s | 2.1 s / 次（4 份提交最长 2.5 s 即此） |
| 后台检查点 select / image / persist | ≈1.4 / 7.5 / 2.2 s | ≈5 / 44 / 8 s（每 ≈2 min 一次） |
| 每次检查点写库 | kind3 35 MB + kind1 11.8 MB | ≈4× |
| 主回收单次停顿 | ≈340 ms | 最长 1.17 s |

主回收停顿属 M3，本步不承诺改善。M2a 只改变写回路径；启动与常驻仍随全世界增长。

## 2. 范围

**做**：页表、页索引与脏页判定、切点冻结与后台写回、信用窗口与接纳边界、多版本页 + 安全前缀与写回尝试状态机、日志 / 旧版本渐进删除、
旧游标与 Replica 退休语义、启动从页表 + 日志后缀恢复、启动规范化 / CoarseRebuild 接入、一次性迁移、真实 PG 上的恢复与崩溃验收。

**不做（M2b / M3）**：按需装页、身份定位表、读取闭包、粗层 structure / 树冠段持久化、启动去掉全量 `refresh_structure` / `prepare_component_cache`、淘汰、P2。
M2b 会**新增**页段（structure、树冠、身份覆盖汇总）与定位能力，本步的段与归属沿用，不承诺格式不再扩充（A2.3）。M2 交付门槛不变。

## 3. 页的内容：本页原始真值

页键 `(cv, level, rx, ry, rz)`。页只存本页拥有的原始真值，编码只读本页的值，不调 `Payloads.payload_bytes`；网络载荷仍由唯一 owner 在服务时派生。

**L0 页段**：

| 段 | 内容 |
|---|---|
| `base` | `region_bases[{0, region}]`，或显式“无”（= baseline；I4：缺省是页内字段，不是缺行）；66³ 中的 ring 是派生冗余，只有 core 是真值 |
| `overlay` | core 内 L0 稀疏格（`region_of(cell) == region`） |
| `refined` / `attachments` / `liquid_units` / `macro_owners` | M1 已有的区域子表 |
| `liquid_active` | `liquid_active` 中本 core 的格（§4.2：其变化都是已提交的） |
| `epochs` / `placed_by` | 区域嵌套存储的本区子表（§5.4） |
| `sources` | `thermal.sources` 中本 core 的格 |
| `damage` | 归属本页的属性行：g=0/1/4 按 `Damage.macro(row)`；g=2/3 按身份 home |
| `instances` / `attachment_owners` | home 在本页的完整记录（实例含 `placed_by`） |

**home 规则**（对父稿 P1 的显式修订，X1）：实例 → `Prefab.macro_slot(anchor)` 的宏格所在 L0 页（anchor 是微格坐标，floor_div，负坐标正确）。
anchor 只在创建时写；GM 搬移、替换、parcel 都是旧身份删除 + 新身份创建，不存在原地迁移。g=2 行 `{2, owner}` → owner 的 home。
**有主 aid**（在 `attachment_owners`）及其 g=3 行 → owner 实例的 home。父稿写的是“aid 创建时首槽页”，但现有数据没有记录首槽，`attachment_owners` 的第二项是定义内组编号；
owner home 是可由记录算出、不迁移的规则，本稿据此修订 P1。**无主 aid**（玩家直挂）的 g=3 行 → 现存槽中最小槽的 `Attachments.region`：正常来源只允许 size 1 / 8、
size 8 宏格对齐、足迹沿正向 ≤ 8 微格，同一 aid 的槽都在同一宏格（`codec.ex:130`、`attachment_ops.ex:178`、`attachments.ex:13`；parcel 按宏格整数倍平移），
所以最小槽变了页也不变。迁移时校验存量无主 aid 满足此不变量（违反即迁移失败并报出 aid，不静默归页）；全部槽删除时按页索引的旧页删除行。

**L1–L5 页段**：`base` + 本级 core 的 coarse overlay 格。structure / 树冠为派生，启动重算（M2b 加段）。

**全局行**：seq、material_balances、caster_energy、material_supplies、craft_ledger、food_ledger、food_receipts、protection.regions、beacons、beacon_attunements、
phase_inventory、thermal（除 `sources` 外整值，含拟态等动态键）、attachment_serial、material_units_per_micro、interaction_history / floor。
`thermal.config` 每次启动由资产覆盖（`catalogs.ex:34`），存档值不参与比较。`properties`、prefab 定义、`published` 是文件资产，不进页。

存储：逐格段按 16³ 宏格子块（`Spatial.chunk_size`，每页 64 块）一行，`base` 每页一行；envelope `%{format: 1, key, segment, chunk, cut_seq, value}` 经 `term_to_binary(compressed: 6)`。
页仍是归属、装入与切点的单位，子块只是存储行粒度（§5.2 实测）。

## 4. 页索引与脏页判定

### 4.1 判脏点与页索引（R1）

判脏在 `Log.remember_entry/2`：所有成功提交（含纯液体 `append_journal` 分支）与启动回放都以“提交后的 state + 本笔事务”调用它（19 处调用点，实现时逐一核对都在成功之后）。
World 新增派生字段（不持久）：

- `dirty`：自上次切点以来变脏的 `{页键, 段}` 集合，另加 `globals_dirty`；
- 页索引：`damage_pages`（键 ⇒ 页）/ `page_damage`（页 ⇒ 键集合）、`instance_pages` / `page_instances`、`aid_pages` / `page_aids`；
- `remembered`：上次 `remember_entry` 时的 `instances`、`attachment_owners`、`liquid_active`、`thermal.sources`、全局各键的值（引用，不复制）。

规则分两类，在线与回放相同：

1. **事务自带的字段**：kind0 / kind2 格、kind1 区域后像、`liquid_units`、property_states、epochs、macro_owners、placed_by 的键 → 所在页与段；
   property_states 的旧页取 `damage_pages[key]`（删除时先读旧页、再退休索引）。纯液体两种形态（内存的整区后像、日志的 kind0 格 + `liquid_units`）都覆盖实际改动格所在页。
2. **整表字段**（`append_log` 只在日志副本里补入，在线事务里没有）：`instances`、`attachment_owners`、`liquid_active`、`thermal.sources` 与全局各键，
   和 `remembered` 按引用比较（`==` 对同一项先比指针）；不同才求差异键，差异 id / 格的新旧 home 页变脏，随后更新 `remembered` 与页索引。差异计算只在该表真被改动的提交里发生。

### 4.2 液体活动集（R4）

`liquid_active` 决定液体是否继续排程（`liquids.ex:17`），现检查点持久的是在线值。液体回调先清空再重建它，数量不变时 `apply_batch` 不产生事务（`world.ex:1430`、`liquids.ex:355`、`edits.ex:192`）。
本步改为：液体 owner 在一次步进后若 `liquid_active` 与步进前不同而没有其他变化，提交一笔无几何事务（只带 `liquid_active`）。于是活动集的每次变化都是已提交的，页与恢复语义和现在一致。
频率上限：只在活动集真变化的“无数量变化步”发生（趋静与唤醒），基准里单独计数。

### 4.3 绕开在线提交的入口（R3）

- **启动规范化**：`migrate_component_damage`（`heat_commit.ex:234`）有改动时，作为一笔真实维护事务（新 seq、经 `append_log`）提交，可重放、可持久；无改动时不提交。
  `environment_tolerance` 只把资产配置覆盖到 `thermal.config`，每次启动重做，不是需要持久的改动。
- **CoarseRebuild**（离线入口，`world.ex:484`，`coarse_rebuild.ex`）：定为**独占维护**：重派生粗层后，提交一笔维护事务推进 seq、把全部 L1–L5 页与改动的 L0 页标脏，
  开切点并以“该切点发布”为成功边界；发布前失败则重跑整个维护（它本就是离线、可重跑的全量作业）。
- **目录发布** `publish_property_catalog`：一笔事务含全部行 → 全部有 damage 的页变脏，由信用窗口限速吸收；`migration.attachments` 整表替换由 `attachment_regions` 子表比较补标。

## 5. 切点、冻结与写回

### 5.1 切点（R3）

- 条件：在现有合法提交边界（`thermal_run == nil`，与现检查点同一 owner 边界，X4）、无进行中的切点、`state.seq > 已发布前缀 P`。D_C 可以为空（只写全局行）。
- 节拍：距上次切点 ≥ `cut_interval`（默认 10 s），或积压量超软上限，或 `compact` 请求。
- 开切点：`frozen = Map.take(state, 持久字段 ∪ 页索引 ∪ remembered)`（引用，零拷贝；不钉 entries、订阅与任务，A4.1），`C = state.seq`，取出 D_C。

### 5.2 抽取、编码与写放大

- World 每个回合最多抽取一批（段数 ≤ `batch_segments`、估计字节 ≤ `batch_bytes`、耗时 ≤ 5 ms，可配），只从 `frozen` 抽取；单段 O(该段内容)。
  base 段里的大二进制是 refc，发给写回进程不复制。全局行在最后一批；它是按角色 / 历史增长的单元，单独计入字节窗口并在基准里单列，诚实标为本步的残余上界（A4.2）。
- **写放大**（F 交叉 7）：只重写脏的（段, 子块）行；同一行最短写回间隔 `min_segment_interval`（默认 30 s，紧急 compact 例外），间隔内的重复改动合并。
  **实测**（1 份如园，runs `m2a-01-segments`，`:erlang.external_size` 与 `term_to_binary(compressed: 6)`）：按整页段，最密 L0 页 29 MB（refined 23 MB、epochs 3.7 MB、damage 1.8 MB），
  单格编辑要重写 ≈5.5 MB、改细化格再加 23 MB，写放大高于现检查点；按 16³ 子块并压缩后，epochs p90 / 最大 11.9 / 13.7 KB，damage g0/1/4 2.2 / 40 KB，
  refined 203 / 755 KB，其余段 ≤ 15 KB；base 压缩后 ≈561 KB（只在 rebase 时变）；g=2/3 行 1 条。单格编辑每次 ≈15 KB，细化编辑几十到 200 KB。验收看“每分钟写库字节”与现状对比（§8）。
- base 只在 rebase 时变。M2a 不再有检查点触发的 rebase，L0 稀疏 overlay 会随编辑累积；本步在探针里记 overlay 格数，按需在后续加“按区压实”（单区 rebase 并标 base 脏），不预做。

### 5.3 在途窗口与接纳边界

- **信用窗口**：写回进程每确认一批（已写入 PG）给 World 一个信用；World 最多领先 `window_batches` 批，窗口满就停抽取，不往 mailbox 堆。
- **积压量**：`frozen` 存活时长、在途字节、脏段数、最老脏段年龄、日志后缀行数，全部进探针。
- **接纳边界**（三级）：软上限 → 停抽取以外的非必要后台（不开新切点以外的整世界维护）；中上限 → 暂停开始新的热 / 液体步进（进行中的步进走到合法提交边界）；
  硬上限 → 会产生新提交的入口在**扣账、创建身份、消费意图状态之前**显式回复 `{:error, :persist_backlog}`（经现有 `ResultFrame.error` 通道），覆盖玩家、GM、parcel、作者、施法 / 投射物 / 身体后果等全部提交入口（A4.3）。
  回落后由写回确认处理恢复既有调度（热 / 液体定时器），不依赖新的玩家操作唤醒。上限默认值按 M0 负载与受控慢写回实测再定。

### 5.4 epochs 与 placed_by 改为区域嵌套存储

`16³ 子块 => %{cell => value}`（子块键 = `CollisionSource.chunk_coord(cell)`，与存储行同粒度，按子块抽取 O(子块)）作为唯一表示：epochs 访问点 10 处、placed_by 13 处，经访问函数读写；对外观察契约不变（`observation.ex:194` 由嵌套表展开，整表输出本身属 N1）。
damage 保留平铺表，只加页索引。实现时实测内存与展开成本。

## 6. PG 表、写回尝试与读者

### 6.1 表与写回尝试状态机（R5）

```
voxel_page_segment(content_version, level, rx, ry, rz, segment, chunk, cut_seq, format, payload,
                   PRIMARY KEY (content_version, level, rx, ry, rz, segment, chunk, cut_seq))
voxel_world_globals(content_version, cut_seq, format, payload, PRIMARY KEY (content_version, cut_seq))
voxel_safe_prefix(content_version PRIMARY KEY, seq)
```

所有 SQL 带 `content_version`（u64 按补码，沿用 `overlay_log_store.ex:118`）。同一时刻只有一个写回进程（World 在旧进程 `DOWN` 之后才启动新进程）。写回切点 C 的一次**尝试**：

1. **开始**：读持久 `P`。若 `P >= C`，该切点已发布（上次确认丢失）→ 直接进入“确认”。否则删除 `cut_seq > P` 的页段与全局行（上次未发布尝试的残留），再写。
2. **写批**：以 `cut_seq = C` 插入页段（不覆盖旧版本）。
3. **发布**：最后一批 + 全局行 + `UPDATE voxel_safe_prefix SET seq = C WHERE content_version = $cv AND seq < C` 在同一 PG 事务；影响 0 行时重读 `P`：`P == C` 视为已发布，否则报错（不当作成功）。
4. **确认**：World 收到“C 已发布”后才退休 D_C 的在途记录、`entries` 前缀与等待者。

写回进程中途死亡：World 不判断结果，按“开始”一步由新进程以持久 `P` 判定——已发布则确认，未发布则清残留重写同一 C；无新事务也能收口，不依赖下一笔提交改变 C。
迟到的旧结果（属于已被取代的尝试）按尝试编号丢弃。

### 6.2 恢复与渐进删除

- **启动**：一个只读 REPEATABLE READ 事务读 `P`、每页段 `max(cut_seq) <= P` 的版本、`cut_seq = P` 的全局行、日志 `seq > P` 的行。随后（读事务之外、开任何切点之前）删除 `cut_seq > P` 的残留。
- **唯一装页入口**（R2）：base 进 `region_bases`；overlay 格经 `put_overlay`；refined / attachments / liquid / macro_owners 经各自 put 函数（维护区域子表）；epochs / placed_by 进嵌套表；
  实例 / aid 记录进 home 并建页索引；**凡有 base 或任一细节段的页，按旧 `rebase_region` / 回放的同一规则把 `{level, region}` 加入 `snapshots`**，并恢复它依赖的其他派生标记。
  `snapshots` 是派生物，不持久。不走 `replay_entry` 的实例合并与 live 过滤。装页次序不影响结果。然后按 seq 重放后缀（经 `remember_entry` 重建 `dirty`）。
  之后同现在：`refresh_structure` 全量、`rebuild_work`、`prepare_component_cache`；去掉启动同步整世界检查点。
- **渐进删除**：安全前缀是删除授权，删除分批（每批行数上限）：日志 `seq <= P`；每页段低于其最新可见版本的旧版本；`cut_seq < P` 的全局行。读者只认可见版本与 `seq > P`。

### 6.3 订阅、诊断与 Replica（R6）

- `entries` 保留最近一次已确认安全前缀之后的后缀；确认后退休更早的事务与 `entry_regions`。
- `subscribe(have_seq)`：`have_seq >= 保留下限` → 照旧补发；`have_seq < 保留下限` → 显式回复 `{:error, :cursor_expired}`，调用方走已有的 `canonical_snapshot_and_subscribe`（同一 owner 屏障取快照 K、其后有序增量）。
  现有生产代码没有调用 `subscribe/5`（只测试），影响面限于测试与诊断。
- `serve_item`：`have_seq < 保留下限` 的判断放在 `LogProjection.since` 之前，直接返回整区载荷。
- `entries_after(seq)`：`seq < 保留下限` 时显式报错。
- **Replica**：退休通知只发**单调推进**的安全前缀，且只发“确认时间距今 ≥ `replica_retain_s`（默认 60 s）的最新前缀”；无新切点时由定时器收尾。验收按 `replica.ex:204` 的实际裁剪算法测窗口。
  Scene 无 stream 移交分支（`scene_server/.../movement/scene.ex:369,381`）对过期错误元组直接 `length(tail)`：本步补显式处理（重新准备），并加短场景。
- `compact/1`：若调用时 seq 已被已发布前缀覆盖且无待发布维护 → 立即成功；否则开切点并在其确认后回复。

## 7. 首次启动与一次性迁移

- **判定**：`voxel_safe_prefix` 有该 cv 的行 = 已迁移 / 已初始化。
- **全新世界**（无日志、无前缀）：发布 `P = 0` 与空全局行。
- **未迁移**（有旧日志、无前缀）：删除该 cv 的全部页段与全局行 → 按现路径全量回放 → `migrate_component_damage` 作为维护事务提交（§4.3）→ 状态 S →
  全部页的全部非空段 + 全局行标脏 → 开切点 C = S.seq，经正常写回与发布。旧日志（含旧检查点行）随 `seq <= C` 渐进删除。
  页集 = 所有真值字段归属页的并集（含纯元数据页、地形已回到 baseline 但仍有世代的页）；空页也写显式版本（I4）。迁移中途失败 → 无前缀 → 下次启动从头重做。
- 迁移只在隔离库运行；如园源库、备份与发布目录只读。

## 8. 测试与基准

**判定器**：在合法提交边界取同一 seq，比较停机前与重启后：(a) 原始真值逐键精确相等（每个有 base 或 overlay 的区域按 core 物化的格材料与 skins、refined、attachments、liquid_units、
liquid_active、epochs、placed_by、macro_owners、damage 不加容差、instances 完整记录、attachment_owners、全局各键、seq）；(b) **正式读取等价**：每个页存在的区域，`serve` 与
canonical 快照给出的载荷在同一 seq 下相等（R2；派生 structure / cache 的私有布局不比较，但其正式读取结果比较）。重启后先比较，再允许热 / 液体演化。

**最小反例矩阵**（正常入口产生真值；故障只注入写回 / 持久边界；页存储用例用真实隔离 PG，固定 cv 并断言另一 cv 不受删除影响，不用全表 reset）：

1. **判脏**：纯液体跨区流动；热源消耗至删除；活动液体非空 → 无数量变化步 → 清空 → 无其他事务（R4）；跨页部件两页各命中再敲死叶部件（`tools.ex:440-467`）；
   无主多槽附件部分失撑；正常入口创建远处 home 的 prefab / 附件（R1）；GM 搬移、parcel 安装；只有供料 / 进食的全局账提交（R3）。每项在发布、删日志前缀后重启，后缀不顺带修补；
   Test-only 故障注入“漏标某字段”时对应用例失败。
2. **切点并发**：部分批已抽取时提交跨页 prefab、全局账变化并启动热步进；C 的页段全部等于 `frozen` 的值，恢复 = C + 后缀。
3. **装页**：跨页实例带 `placed_by`、祖链跨 home；颠倒装入次序；仅元数据页；删除后空页；有旧 rebase base、无 overlay、无同层邻 base 的页的正式读取（R2）；负微格 anchor 的 home。
4. **写回尝试**（R5）：第一批后只杀写回进程、无新事务 → 新进程收口同一 C；发布已提交而确认丢失；影响 0 行的旧发布；节点在第 k 批后被杀 → 重启 → 提交无关页 → 再发布 → **再重启**；首次迁移半写后被杀。
5. **读者**（R6）：`have_seq` 为 P−1 / P / P+1 时 subscribe 与 `serve_item` 的实际接收结果；Replica 在两次退休之间读后缀；Scene 无 stream 移交遇过期错误不崩溃。
6. **启动**：首次全新世界（P=0）；P 之后无新事务的启动规范化；已覆盖时的 `compact`。
7. **接纳**：受控慢写回触发三级上限，硬上限下各提交入口在扣账前拒绝；写回恢复后无新输入也恢复热 / 液体调度。
8. **新 VM 解码**（复用 `overlay_log_fresh_vm_test.exs` 的意图）；**测试期对拍**（每笔提交后独立求真实脏段，断言 ⊆ §4.1 结果，不与 §4.1 共用字段枚举）。
9. **迁移等价**：隔离库上，迁移前按旧路径恢复 = 迁移后按页恢复（判定器 a + b；1 份与 4 份如园）。

**基准**（同 M1 负载，4 份 / 1 份，8 窗口，对照 r94 / r95）：单次 World 回合（开切点、每批抽取）与整个切点总耗时；`frozen` 存活时长与双份字节；在途字节与 mailbox；
每分钟写库 / 删除字节（与现状 1 份 47 MB / 次检查点对比）；全局行字节；无几何活动集提交次数；提交 p50/p99/最长；启动时长与峰值；受控慢写回下的接纳行为。
通过条件：开切点与每批抽取的单回合 p99 不随份数增长；写库字节与改动量成正比且不高于现状；主回收停顿不在本步验收。

## 9. 实施顺序（每步可运行）

1. 测密集页各段字节，定 `min_segment_interval` 默认值。
2. epochs / placed_by 嵌套存储（独立可测：现有全量测试 + 基准不退化）。
3. 页索引与 `remember_entry` 判脏 + 测试期对拍（不写库，只在测试里核对脏段 ⊆）。
4. PG 表、写回进程与尝试状态机、装页入口、启动读页；旧检查点并存期间先用测试 cv 验证恢复等价与崩溃矩阵。
5. 去掉整世界检查点；订阅 / Replica / compact / CoarseRebuild / 启动规范化接线；液体活动集提交。
6. 迁移与迁移等价（隔离库 1 份、4 份）；基准；进度日志。
