# 独立评审：世界真值按区域分页决策稿（2026-10-24）

评审人：Fable（只读）。对象：`2026-10-24-world-region-paging.md`（status: draft）及同目录四份调研；源码版本 b9b305f4（HEAD，与稿内一致）。
路径相对 `apps/voxel_region/lib/voxel_region/`，OLS = `apps/data_service/lib/data_service/voxel/overlay_log_store.ex`。
标“推断”的是由源码推出、未实测的结论。

---

## 1. 能否达成目标：三条斜率与残余项

总体：按 P1–P7 做完，**常驻／每笔／检查点三条主斜率可以变平**，方向正确；但下面这些项在稿内没有归位，做完 M0–M4 仍随世界总量（或世界范围）增长。

| 级别 | 残余项 | 证据 | 说明 |
|---|---|---|---|
| 【中】 | `prefabs` 目录常驻 O(定义数) | `prefab.ex:17-22`：启动 `Prefab.load` 读全部 `.vxpd` 并 `publish` 编译；heap-probe：767 个定义，`nodes` 二进制 58.6 MB 堆外 | D1 只去掉 `definition.cells/macro_cells` 解码列表（236 MB），`nodes`、summary、compiled 仍随定义数常驻。定义数随世界内容增长（如园一处 767 个）。要达目标需按定义 id 懒加载整个 compiled 条目，不只是懒解码 |
| 【中】 | `thermal.sources` 在“全局标量行” | `world/catalogs.ex:79`：`thermal = %{config, sources: %{}, …}`；`world/tools.ex:518-535` 每笔几何事务重算 sources | 稿把 `thermal` 整个归为“全局标量”（P1）。`sources`（macro → 热源）随世界热源数增长，属于按格数据，应进区域页；账目（`supplied_j` 等）才是标量 |
| 【中】 | 启动需要知道哪些页有进行中过程 | `world.ex:681,688-690`：`rebuild_work` 扫全部 damage、`schedule_liquid`、`Projectiles.wake` 读 `thermal.semblances` | P4 只读“全局元数据 + 日志后缀”。P6 的 ticket 页若不持久化，重启后无法得知哪些页有活跃液体／燃烧而不打开全部页。需在全局元数据持久化“活跃页集”（Minecraft forced ticket 持久化即此；稿引了却未用） |
| 【轻】 | `protection`、`beacons`、`material_supplies` 全局行 | `protection.ex:12-16`（id → rect，256 m 桶）；`parcel.ex:12` 回执 `material_supplies[{0,{:parcel,key}}]` | 随认领数／信标数／安装次数增长，与世界内容相关但系数小。16 km 世界上千认领仍可接受；写明即可。注意 parcel/beacon 回执是全局防重键，不属于稿内“角色账的角色部分” |
| 【轻】 | L4+ 载荷缓存常驻不计上限 | `world/payloads.ex:355,368-381` `@resident_level`；`world.ex:38` | 随世界**范围**（非内容）增长：16 km 立方 L4 区 4096 个。P5 未提及；应随页一起受上限约束 |
| 【轻】 | 粗格条目（coarse）全局广播 | `property_observation.ex:14-23` 不过滤 `coarse`；稿 N6 明说只投影 entries | 远景 LOD 一致性要求如此，属设计行为；但 L1–L5 条目数随全世界编辑活动增长，应在 N6 写明按 LOD 带过滤的边界 |

每笔成本一项补充：

- 【中】**“本笔涉及的页”比稿内 `edit_keys` 大得多**。一次 L0 几何编辑的后像区最多 8 个（ring，`log_projection.ex:6-12`），每个后像区物化要读 27 个区的 refined（`world/payloads.ex:160`）和 26 个邻区基底（`world/payloads.ex:128-135`）。所以单笔工作集是编辑格周围约 4×4×4 = 64 个 L0 页，而 `edit_keys`（`world/edits.ex:40-45`）只给 6 个键（每级一个）。P5 的常驻集定义须按“region_keys(±1) 的 27 邻域”写，否则回合内必缺页。
- 【中】**kind1 整区后像仍随每笔几何事务进 WAL**。`world/log.ex:207-259` `select_transaction` 对改实例／附件／液体／树冠的区域一律写完整后像；稿 P2 保留。如园密度下一页约 1.8 MB（416 万槽 / 38 区 × 16 B，推断），一镐击落一个细化槽 = 最多 8 × 1.8 MB 写 PG。斜率是平的，但系数与 10-15 事故同源。见 §4 建议。

---

## 2. 正确性风险

### 2.1 【严重】kind3 元数据没有页键，按页 page_seq 幂等重做无法按稿实现

- 现状：kind3 一笔一行，`level=0, region={0,0,0}` 固定（`overlay_log.ex:67`）；回放是整笔 `Map.merge` 后整表覆盖／合并（`world/log.ex:384-416`）。
- 稿 P2 说“回放某页时只应用 `seq > page_seq` 的条目”，P4 说“后缀涉及的页按需装入再重做”。但一笔事务的 damage 行、epochs、macro_owners、实例增量跨多个页，要知道“这条增量属于哪页”：
  - g=0/1/4 行可由 `micro` 算区（`damage.ex:342`）；
  - **g=2 行键是 `{2, owner}`，g=3 是 `{3, aid}`（`damage.ex:340-341`），不含坐标**。按 P1 home 规则，归属区 = 实例 anchor 所在区／附件 anchor 所在区，恢复时要查“全局小目录”。目录按稿只在检查点写（“脏的目录行”），崩溃点在检查点之前时目录落后于 WAL，重做会把行放错页或找不到 home。
- ARIES 的前提是**每条日志记录带 PageID**（论文 §3 日志记录结构）；稿引了 pageLSN 却没有给日志记录 PageID。
- 建议：kind3 拆成**每页一行**，用现成的 `level/region_x/y/z` 列（迁移 `20260907000001` 已有列，`:15-27`）；每行只含该页的增量；全局标量另一行。这样后缀按区域可查（加 `(cv, level, region)` 索引），单页重做自足，目录不再是恢复依赖。

### 2.2 【严重】回合内的模拟（液体／热／投射物）访问冷页没有机制

- 液体步在 World 回合内直接 `cell_value` 读邻格，缺源时**同步** `source.ensure`（`world/liquids.ex:333-335`）；热域读 `view_range_cells` 视线伙伴（`world/thermal.ex:898`）；投射物飞行段跨区（`world/projectiles.ex:55-62`）。
- 稿 P5：“回合内仍缺页则显式失败”。对玩家意图可以（调用方重试），对**定时器驱动的模拟**“失败”= 本步跳过，下一步再撞缺页——事实上是重试循环，或者液体停在页边界、热传导把冷页当环境温度（第二真值）。稿 P6 的测试“ticket 先装入目标页再推进”假设了一个未设计的装页步骤。
- 建议：把“步进前求出本步触及页集 → 缺页交 Task 装入 → 装齐后再步”写成明确两段式（与 `prepared_intent`，`world.ex:138-145` 同形），并写明装页期间该过程暂停、守恒账不变。热传导跨冷页边界的语义（暂停 vs 以边界页为绝热）必须在 Q1 里定，不能靠实现时默认。

### 2.3 【中】预备到提交之间没有 pin，内存压力下意图会偶发失败

- 现在 `prepare` → `GenServer.call` 两段之间可插入其他提交（`world.ex:111-145`；recon-operations §6-4），缺源靠 `needs_source?` 重判显式失败。源是不可变文件，“缺”极少发生；分页后页会被淘汰，缺页会**常态化**。
- 建议：ARIES fix/unfix——调用方 `prepared_intent` 把页接纳进常驻集后，直到该意图的提交回合结束才可降级；淘汰只作用于冷缓存。

### 2.4 【中】脏页淘汰与降级的成本都在 World 回合内

- 稿 P5：“脏页先写回再淘汰（steal）”。写回是 I/O，不能在回合内同步做，因此脏页实际上**不可淘汰**，只能等检查点或后台写回；冷缓存的字节上限对脏页无效，内存上界变成“脏页产生速率 × 写回延迟”。应给脏页单独上限并触发提前检查点（InnoDB `innodb_max_dirty_pages_pct` 即此；稿引了 InnoDB 却未用这条）。
- 降级（常驻页 → 冷字节）要编码。现检查点 145 区 image 15–29 s（旧稿实测），约 100–200 ms/区（推断）；玩家换窗降级 9–27 页若在 World 回合内编码，是秒级停顿。应写明降级编码在 Task 内，或保留解码态直到写回完成。

### 2.5 【中】页行缺失会被当成“未编辑”——缺失冒充成功

- 分页后 `Canonical.decoded`（`world/canonical.ex:83-107`）的语义变成：页表没有行 → 读 baseline。这与“从未编辑”不可区分。任何写回路径的 bug（或人为误删行）都会把该区**静默还原成原始地形**，没有探测点。现在 `snapshots`／kind1 的存在性起着“这区有过编辑”的作用，分页后这份信息要有去处。
- 建议最小做法：页行一旦写入永不删除（空页也保留，内容可为“与 baseline 相同”标记），全局元数据不记页清单；加一条测试：删一行页后启动，缺页区域访问须显式失败而非返回 baseline。若接受“PG ACID 足够”，至少把这个失败模型写进稿。

### 2.6 【中】增量语义必须是幂等的“绝对值 upsert”

- 现回放全部是绝对值合并（`world/log.ex:393,401-414`），所以重放两次结果相同。稿 P2 把 kind3 改成“增量”但未说明是“变化的键的新值”还是“加减量”。`thermal` 账、`material_balances` 若写成加减量，截断点之后的条目在重启时会被重复应用（页已含、全局行未含的边界尤其危险）。应把“增量 = 变化键的绝对值；删除显式标记（现 `flags==1`，`world/log.ex:387`）”写成不变量。

### 2.7 【中】全局目录是热路径上的 DB 读，与“回合内不做阻塞 I/O”冲突

- `voxel_prefab_remove_v1/replace_v1` 只带 `instance_id`（`world.ex:374-378`）；稿让 World“按需查”PG 目录。应在调用方进程查（与 prepare 同段），或见 §4 的更简做法（协议带 anchor，不需目录）。

### 2.8 【中】跨区 g=2 部件 HP 池：命中时 home 页不可预知

- 工具命中微格构件时无行则算 `component_max_hp`（`world/canonical.ex:232-239` → `micro_owner_cells` → `in_refined_order` 全表），`tool_regions` 只按射程预备几何页（`world/tools.ex:599-604`），不包含“被命中 owner 的 home 页”和“该 owner 伸出射程的其它页”。P1 的“外来 owner 列表”能回答 home 在哪，但 prepare 必须两段（先装几何页读外来表，再装 home 页）。稿未写。N3 把整件 max_hp 写进载荷实例段可以绕开第二段，但那是派生值，目录重发布（`world/catalogs.ex:88-93` 全部行重写）时须同步重算，须写明。

### 2.9 【中】检查点冻结后又被改的页：RecLSN 与 page_seq 的记账

- 现 `finish_checkpoint` 用 `state.seq == txn.seq` 整体判定是否换基底（`world/log.ex:337`）。按页后，Task 写回的冻结副本 page_seq = S，期间该页又被 S+k 改过：页须保持脏、首次变脏 seq 变为 S+1、截断点不得超过 S。稿只说“完成时记账”，测试矩阵没有这项。

### 2.10 【轻】其它

- `in_refined_order` 改确定排序（P7）会改变浮点求和次序，已存在的 g=2 行 `max_hp` 可能与新算法不等（`world/observation.ex:145-146` 注释明言不能换序）。要么重算现有行一次，要么把差值接受写进稿。
- 旧游标订阅（`world.ex:1312-1321`）与 `serve_item` 的 `:entries` 回复（`world/payloads.ex:43-54`）依赖 `entries` 里保留的检查点事务作“完整补丁”；P3 去掉后，`LogProjection.since` 返回 `:region` 的分支已能回退到整区字节，方向对；但 Replica 退休通知（`world/log.ex:360`）要改成发截断点 seq，稿未提。
- `food_receipts` 按 cid 嵌套、无裁剪（`production.ex:21-22`）：角色表只常驻在线角色后不再是常驻问题，但单角色行仍单调增长，属角色数据生命周期问题，另记。

**真值丢失／重复／第二真值小结**：2.1（行放错页）、2.2（热把冷页当环境）、2.5（缺页当 baseline）三处有造成真值错误的现实路径；2.6 若实现成加减量会重复应用。其余为可用性与性能。

---

## 3. 核对事实（抽查 20 处）

| 稿内断言 | 核对结果 |
|---|---|
| `restore/1` 约 90 个键 `world.ex:528-653` | ✓ 状态 map 在 529–653 |
| L0–L3 载荷字节缓存 512 MiB LRU `world/payloads.ex:348-416` | ✓ `cache_fetch…cache_evict` 348–413；`@default_cache_bytes` `world.ex:39` |
| `epochs` 只 merge 不删 `world/log.ex:393` | ✓ |
| `entries` 常驻整份检查点事务 `world/log.ex:356-358` | ✓ |
| `Log.attachment_metadata` 每笔写整表 `world/log.ex:28-36` | ✓ |
| **几何事务另写整份 `thermal` `world/edits.ex:298`** | **✗ 行号错**：298 是 `Phases.put_phase_values`；写 thermal 在 `world/edits.ex:307` 与 `world/tools.ex:546-547`（recon-state 同错） |
| 每笔扫 `macro_owners`／`refined` `world/observation.ex:223,265` | ✓ |
| `world/payloads.ex:178-188`、`canopy.ex:49` 全表 | ✓（178 macro_owners、180 refined_owners、185 liquid_units、188 attachments；canopy 49） |
| `world/prefabs.ex:52` group_by；`world/tools.ex:413`；`world/canonical.ex:60,242` | ✓ |
| `rebuild_work` 扫 damage 三遍 `world/thermal.ex:66-71` | ✓（66、70、71） |
| 电路每段扫全部附件 `circuit.ex:84` | ✓ |
| 启动 `world.ex:679,680,682` | ✓ |
| 检查点写库在 World 内同步 `world/log.ex:333`；整堆 GC `world.ex:1394` | ✓ |
| 属性快照全世界再过滤 `world/observation.ex:184,194` → `property_observation.ex:19` | ✓ |
| Voxim `VoxelM1Client.cpp:400` `Reset()` | ✓ |
| Voxim `VoxelDamageState.cpp:18,34,155` `Epochs.FindRef` 三处；`:129,151` | ✓ |
| **`prepare` 骨架 `world.ex:122-175`** | **✗ 不准**：`prepare` 111–125，`ensure_source` 127–135，`prepared_intent` 138–145，`decode_sources` 148–159；175 是 `publish_parameters`。recon 写的 W:122-150／163-175 也偏 |
| `rebase_region` 单区装回 `world/log.ex:90-205`；core 拥有／ring 投影 `:102,115-123` | ✓ |
| `edit_keys` `world/edits.ex:40-45` | ✓ |
| `voxel_prefab_remove_v1/replace_v1` 只带 `instance_id` `world.ex:375-378` | ✓ |
| PG 唯一索引、无区域索引；OLS 三操作 | ✓ 迁移 `:27`；OLS `:31-35, 38-60, 63-75` |
| `replica.ex:62,186` epochs | ✓ |
| “L5 区域覆盖 32³ 个 L0 区” | ✓（2⁵） |

结论：20 处中 2 处行号错／不准，其余一致；稿内未发现与源码相反的事实陈述。另有一处**措辞不准**：“M1 不改存储”（见 §6）。

---

## 4. 更简单的方案与过度设计

| 级别 | 项 | 建议 |
|---|---|---|
| 【中】 | **全局小目录（实例 id → home）可以不要** | 协议 42 已在做。`voxel_prefab_remove_v1/replace_v1` 加带实例 anchor（客户端从载荷实例段本就持有 anchor），home = `region_of(anchor)`；树覆盖区域集存在 home 页的实例记录里、由同一笔事务维护。附件拆除同理：拆除意图经射线命中（`attachment_ops.ex:59-83`），槽 anchor 已知。少一张 PG 表、少一次热路径 DB 读、少一条恢复依赖（§2.1）。§2.2-6“信任边界校验一次”：anchor 由 World 校验与 id 匹配即可 |
| 【中】 | **角色账分页（“只常驻在线角色”）第一阶段可不做** | 角色数是与世界内容无关的另一条轴，每角色几 KB。目标只要求常驻与世界内容无关；先保留全表常驻，M0 测出角色账占比后再决定。减少 M3 范围 |
| 【中】 | **WAL 只记增量，页是唯一全量形式**（可选，权衡） | 现在 kind1 整区后像既进每笔 WAL 又（按稿）进页表，两份全量表示（DRY）。若 WAL 对 refined 改成槽级增量（新 kind，16 B/槽记录已有格式 `Refined.slot_records`），`select_transaction`、`rebase_region`、`snapshots`、`region_bases` 四个概念都可删除——页即“基底 + overlay + 细节”的单一形式。代价：新增一种重做条目格式。建议在 M2 设计时用 M0 的“每笔 WAL 字节”数据决定；不要默认保留两份 |
| 【轻】 | ticket 不必是独立状态机 | “有 ticket 的页”= “liquid_active／燃烧行／semblances 非空的页”这个谓词本身，常驻集 = 订阅盒页 ∪ 意图页 ∪ 该谓词为真的页；只需持久化这个页集（§1）。不要另设发／释放的生命周期 |
| 【轻】 | P1 页内“地形基底 + L0 overlay”双表示 | 页内保留 baseline + 稀疏 overlay 是对的（64³×2 B 全网格 = 0.5 MB/页，轻编辑区浪费），但应写明理由，并让 M0 统计“编辑格数 / 页”分布来确认 |
| 【轻】 | 粗层页持久化 structure | structure 是 refined/附件的派生物（`world/payloads.ex:263-346`）。持久化派生物是对的（重算 L5 要 32768 个 L0 页），但须写明“同一笔事务更新，不允许滞后”，否则违反 SSOT |

违背 §2.2 的地方不多；主要问题是**该写清的不变量没写**（§2 各项），而非多余抽象。

---

## 5. 依据

- 【轻】ARIES／InnoDB／PG 对 WAL、脏页、fuzzy checkpoint、RedoLSN 的支撑充分；但稿**只用了一半**：没有用“日志记录带 PageID”（§2.1）、没有用“脏页上限触发刷页”（§2.4）、没有用 fix/unfix（§2.3）。这三条都在已引文献里。
- 【轻】Luanti／Minecraft 对“块为持久化单位、只模拟玩家周围、ticket”的支撑充分。Q1 引 Minecraft “Unloaded chunks are unprocessed” 正确；但要注意 Minecraft **在加载区内**照常模拟稳态（红石、熔炉），所以“稳态冻结”只对无人页成立，稿的措辞一致。玩家会造“区块加载器”（推断，社区常识），Q1 应预告这一需求。
- 【轻】SpatialOS 是停产产品的存档文档，作“第一阶段不拆 authority”的论据够用，但是反面教训而非正面先例；EVE 单星系单节点更贴，稿已标未核实，处理恰当。
- 【中】**原创但未标出的决策**：
  1. 页的物化依赖 26 个邻页（ring）——Luanti/MC 的块自足，这是本项目特有，决定了工作集与淘汰策略（§1）；
  2. L1–L5 粗层页（层级页作为真值派生物持久化）；
  3. 页内“外来 owner 列表”；
  4. kind3 增量改页键（若采纳 §2.1）；
  5. 单日志、页表与 WAL 同库的组合（PG 作页存储有 Luanti 先例，但“WAL 表 + 页表同一 PG”是本项目组合）。
  已标出的两项（home 规则、ticket 范围）标注恰当。
- 【轻】缺少的依据：PG 大 bytea 行（1–2 MB/页）upsert 与 TOAST 的性能特性；Luanti PG 后端 schema（`blocks(posX,posY,posZ, data)`）可直接作 Q2 的表设计依据。

---

## 6. 交付顺序与验收

- 【中】**M0 的 16 份现状基线跑不起来**。现状 1 份 VmHWM 6.5 GB、堆 1.27 GB（旧稿实测）；16 份按线性是 ~20 GB 堆、VmHWM 远超开发机。建议现状基线用 1／2／4 份（足以证线性），16 份留给 M2/M3 之后复测；或用如园四分之一盒做单位。
- 【中】**“M1 不改存储”不成立**。P2 把 kind3 从整表覆盖改为增量，回放 `instances: Map.get(txn,:prefab_instances,state.instances)`（`world/log.ex:411`）等整表覆盖语义必须改为合并+删除；现有世界（青岚、beacon 测试服）的日志是旧语义。AGENTS 不许兼容层，就要写明一次性转换路径：旧格式读一次 → 新格式检查点 → 旧行删除；或从空世界重装。两者都要在 M1 决定。
- 【中】M0 只放一个玩家在第 1 份，测不出 O(活跃区域) 的**系数**。3.9 GiB 容器的真实问题是“N 个玩家各在一处如园密度”：补一组 N = 1／4／8 窗口分别落在不同份上的测量，并给出“每常驻稠密页字节”这个绝对预算。常驻页若仍是现 map 表示（310 MB / 30 822 宏格 ≈ 10 KB/宏格），27 页如园密度 ≈ 220 MB/玩家（推断）；D4 槽记录二进制约 1/5。稿 P1 说 D4 即页内格式、P5 又说“常驻页解码可改”，应钉死常驻表示就是槽记录二进制（D4），否则系数不达标。
- 【中】测试矩阵缺项：
  1. 检查点 Task 期间再改冻结页（§2.9）；
  2. 删一行页后启动 → 显式失败（§2.5）；
  3. 同一条目重放两次 **跨页与全局行边界**（§2.6）；
  4. 内存压力下淘汰—再装—再淘汰（页往返只测了一次）；
  5. N 个客户端各在一处稠密区（上条）；
  6. 热传导／电路在常驻—冷页边界的行为（Q1 定义后）；
  7. 受保护区域横跨冷页时认领与液体侧流判定；
  8. `subs` 旧游标早于截断点；Replica 收到截断 seq 后的退休；
  9. 维护入口在分页下的可运行性：`publish_properties`（全部行重写，`world/catalogs.ex:88-93`）、`parcel_export`、`rebuild_coarse` 须能流式分页，不要求全常驻；
  10. 协议 42 N5：保留区 (seq, hash) 失配时客户端显式失败而非静默重取。
- 【轻】M1 估“数天”对 64 处全表改写偏乐观；P7 每处都要带回归断言（矩阵“全表回归”），工作量以此计。
- 【轻】顺序本身合理（先去全表 → 页持久化 → 淘汰 → 下发），每级有可独立验收的 M0 复测，符合“可运行闭环优先”。

---

## 7. Q1–Q4 建议

- **Q1（稳态过程）——同意冻结，但要把“瞬时／稳态”改成机械规则**：ticket 只给有**有限终点**的过程（液体趋静、燃料燃尽、相变完成、投射物落地、热传导收敛到既有 `thermal_quiet_seq` 判据）；电路有源、恒温热源永不收敛，无人页上直接冻结，不做回归时的“补算流逝时间”（Minecraft 同）。冻结时账目不变 → 守恒自然成立。还要在 Q1 里定热传导跨冷页边界 = 暂停该行（而非绝热或环境温度）。预告玩家“区块加载器”诉求，列为将来功能而非本稿兜底。
- **Q2（页存哪里）——同意 PG 新表**。额外理由：页写回与日志截断能放在同一 DB 事务，没有撕裂页问题（PG 行级原子；文件方案要 tmp+rename）。表设计直接照 Luanti PG 后端 + 本仓已有 `(cv, level, region_x/y/z)` 列。同一张表也应承载 §2.1 的按页 kind3 行索引。不用 Mnesia／DETS 的理由充分。
- **Q3（协议 42 分开交付）——同意，附一条**：M2 的页容器**不能等于线格式载荷**。若页编码直接“复用区域载荷容器”并加世代／owner 段，M2 就改了 VXR 版本，等于把 N1/N2 提前进 P 系列。写明：页 = 当前 v13 载荷字节 + 独立 sidecar 段；N1/N2 落地时再合并。
- **Q4（验收数值）**：
  - 斜率 ≤10% 可接受，但要规定样本：单笔 p50 与 p99 各 ≥1000 次同类型同位置操作；1 份基线跑两次给出噪声底，阈值 = max(10%, 2×噪声)。
  - 加绝对预算：每常驻稠密页字节上限（M0 实测后定，目标按 D4 估 ≈ 2 MB）；N=8 窗口分落 8 份时 World 常驻 ≤ 2.5 GiB（给 Scene 留量，沿旧稿 3.0 GiB 思路）。
  - “首次进入属性下发 ≤ 1 MB”未经分项计数：全世界 58 948 条 damage（heap-probe），窗口内比例未知，N4 瘦身后 ~65 B/行；若窗口内 >1.5 万行就超。先做 recon-observation §5.3 提的分项计数再定。
  - 保留“已实现／已实跑／已验收”三态；M0 的任何一项缺样不得判通过。

---

## 总评

方向正确：L0 页 + 单 WAL + 脏页检查点 + 淘汰，是把 ARIES 的 redo 半边套到现有 `rebase_region`／`GeneratedStore` 骨架上，改动面比拆 authority 小得多，三条主斜率可以变平。
最需要在开工前补的是**恢复路径的两条缺口**：kind3 元数据没有页键，按页幂等重做与“只装后缀涉及的页”无法实现，g=2/g=3 行的归属还得靠可能落后的目录（§2.1）；回合内定时模拟触及冷页没有装页机制，“显式失败”对液体／热意味着停滞或第二真值（§2.2）。
其次是把已引文献里现成的三条用上：日志记录带 PageID、脏页上限、fix/unfix；以及把“本笔涉及页 = 27 邻域”“常驻表示 = 槽记录二进制”“增量 = 绝对值 upsert”写成不变量。
可以删的：全局实例目录（协议带 anchor）、角色账分页（第一阶段不做）、ticket 状态机（改成谓词）。
事实核对 20 处 2 处行号错（`edits.ex:298`→307、`world.ex:122-175`），无反向事实。
M0 要改成 1/2/4 份现状基线并加入多窗口系数测量，否则跑不起来也测不出容器上限。
建议：补齐 §2.1、§2.2、§2.6 的不变量与 §6 的矩阵缺项后再批准开工；Q1–Q4 按 §7 定。
