# VoxelRegion.World 操作数据访问路径调研（只读）

- 仓库：`D:\hemifuture\ex_mmo_cluster`，源码版本 = 当前工作树（`main`，e3d35494 之后未改 voxel_region）。
- 范围：`apps/voxel_region/lib/voxel_region/world.ex`、`world/*.ex` 以及被调用的领域模块（`attachments.ex`、`thermal_work.ex`、`circuit.ex`、`protection.ex`、`log_projection.ex`、`property_observation.ex`、`overlay_log.ex`）。
- 方法：逐个读 handle_call/handle_info/handle_continue（**World 没有 handle_cast**），沿调用链找对整张 map/MapSet 的 `Enum.*`/`for`/`Map.filter|reject|keys|values`/`==` 比较/`term_to_binary`。未做运行测量；频率来自代码中的定时器与调用点。“推断”均已标注。
- 路径简写：`W`=`world.ex`，`w/xxx`=`world/xxx.ex`，其余为 `lib/voxel_region/` 下文件。

---

## 0. 结论摘要

1. **每笔提交都有世界规模的固定成本**，不只是已知热点：`Log.append_log` 把**整张** `instances`、`attachment_owners`、`liquid_active`（以及多数事务里的整个 `thermal`，含全部 sources/semblances）`term_to_binary(compressed)` 写进该事务的元数据行（`w/log.ex:28-36` → `overlay_log.ex:66-69`）。纯液体日志只去掉前两者（`w/log.ex:24-25`）。这是 O(实例数+附件归属+活跃液体格) 的序列化 + zlib + DB 写，**每笔**发生，包括 50 ms 一次的投射物提交与 0.1 s 一次的液体提交。
2. **有订阅者时每笔提交**在 `Observation.property_transaction` 里全扫 `macro_owners`（`w/observation.ex:265`，两遍 keys），有格条目时再全扫 `refined` 键（`w/observation.ex:223`）；变动部件非空时 `component_geometry` 再整表编 `refined` 次序并遍历全部 `refined_owners`（`w/observation.ex:146-149`，调两次：:235/:241）。
3. **每笔几何提交**（`Edits.apply_batch`／`Prefabs.prefab_reply`／`AttachmentOps.commit_attachment`，含液体每步、热致相变/死亡、转化）另有约 10 处整表扫描：`attachments`（edits.ex:100、attachments.ex:48 ×2、attachment_ops.ex:262 ×3-5、:230、tools.ex:74）、`damage`（edits.ex:292、tools.ex:485、tools.ex:77）、`macro_owners`（canopy.ex:49 ×2、payloads.ex:210）、`refined_owners`（payloads.ex:210）、`thermal.sources`（tools.ex:518/:528），外加每个重编后像区域的 `with_refined` 全扫（payloads.ex:178/180/185、attachments.ex:37、canopy.ex:10）。**液体纯数量提交也走完整几何路径**（edits.ex:191 的短路条件要求 `liquid_changes` 为空）。
4. 以“部件/实例身份”为键的查找没有反向索引：`subtree_ids` 每次 `group_by` 全部 instances（prefabs.ex:52），`leaf_component?` 每次工具命中微格构件都全扫 instances（tools.ex:413），`subtree_cells` 全扫 macro_owners（prefabs.ex:71），`attachment_slots` 全扫 attachments（canonical.ex:242），`in_refined_order` 每次全扫 refined 宏格层（canonical.ex:60，被 `micro_owner_cells`/`component_max_hp`/`target_cells` 等调用）。
5. 热/电路是**世界唯一工作集**：一次热提交覆盖全世界所有热行（一笔事务），`rebuild_work` 全扫 damage（thermal.ex:66-71），之后下一次提交 `ThermalWork` 的 nil 增量集合再全扫 damage/attachments（thermal_work.ex:62/69/129/183）；电路每段 `Circuit.prepare` 全扫 attachments（circuit.ex:84）并全局求解。
6. 检查点每 60 s（有新事务时）在 World 内同步写全量检查点（`w/log.ex:333`），之后 `handle_continue` 对 World 整堆 full GC（`W:1391-1397`）——两者都是 O(常驻世界) 的阻塞停顿。（全量构建本身在 Task 中，`W:1611-1618`。）
7. 原子性：一笔事务 = World 一个回合内的纯函数状态替换 + 一次 DB `repo.transaction` 插入全部行；失败返回 `before` 丢弃新状态；若干路径用 `:ok =`/`{:ok, s} =` 断言，失败即崩溃，由日志重放恢复。**大量提交天然跨多个 L0 区域与多个层级**（ring、L1–L5 父格、液体全局活跃集、热全局工作集、实例树、附件足迹、角色余额），全局单调 `seq` 也是跨区域的。

---

## 1. World 状态字段（W:529-653）与空间性

| 字段 | 键 → 值 | 性质 | 空间性 |
|---|---|---|---|
| `overlay` | `{level, cell}` → `{material, skins}` | 真值（稀疏编辑） | 按格，可分区 |
| `overlay_regions` | `{level, region}` → MapSet cell（含 ring 归属） | 派生索引 | 按区，但一格登记进 ±1 的 1–8 个区 |
| `region_bases` | `{level, region}` → 解码 Payload | 真值表示（检查点换基底后） | 按区；**一旦换基底永久常驻** |
| `decoded` | `{level, region}` → 解码 Payload | 缓存 | 按区；除换基底外不删（`serve_item` 会还原，其他路径不还原，W:1292） |
| `snapshots` | MapSet `{level, region}` | 派生（需整区后像的区） | 按区 |
| `payloads`/`lru*` | `{level, region}` → bytes | 缓存，L0–L3 LRU，L4+ 常驻 | 按区 |
| `served_headers`, `liquid_adopted` | region → seq/hash、bytes | 缓存/备忘 | 按区，不淘汰 |
| `refined` | macro cell → `%{slot => {material, owner}}` | 真值 | 按格 |
| `refined_owners` | owner `{birth, occ}` → MapSet cell | 派生索引（canonical.ex:38-48 维护） | **全局按身份** |
| `refined_regions` | L0 region → MapSet cell | 派生索引 | 按区 |
| `refined_encoded`, `component_cache` | cell → 编码槽；owner → 几何汇总 | 缓存 | 按格 / 全局按身份 |
| `instances` | `{birth, occ}` → `%{definition_id, anchor, orientation, parent_id, component_slot, placed_by}` | 真值 | **全局按身份**；无 parent→children 索引 |
| `macro_owners` | cell → owner | 真值 | 按格；**无 owner→cells 反向索引** |
| `attachments` | slot `{kind, axis, anchor_micro}` → `{aid, material}` | 真值 | 按 anchor（`Attachments.region/1`），**无 aid→slots、macro→slots 索引** |
| `attachment_owners` | aid → `{instance owner, slot}` | 真值 | **全局按身份**，无 owner→aids |
| `attachment_serial` | 整数 | 真值（ID 水位） | 全局 |
| `damage` | `Damage.key/1`：g0/1/4 = `{g, micro, inc, owner, mat}`；g2 = `{2, owner}`；g3 = `{3, aid}`（damage.ex:340-342） | 真值（HP/温度/燃料/储能/开关…） | g0/1/4 按微格；**g2/g3 按身份** |
| `epochs` | macro cell → seq | 真值 | 按格 |
| `placed_by` | macro cell → cid | 真值 | 按格 |
| `liquid_units` | macro cell → units | 真值 | 按格 |
| `liquid_active` | MapSet cell | 真值（持久化） | 按格；但全量写进每条日志 |
| `liquid_falls` | material → transfers | 只广播 | 按格 |
| `structure` | `{level, cell}` → grid | 派生真值（持久化为条目） | 按格（L1–L5） |
| `thermal` | `%{config, sources: cell→src, semblances: id→s, 各能量账…}` | 真值 | sources 按格；semblances 移动；账为**全局标量** |
| `thermal_work`（含原生 domain） | 派生工作集 | 派生 | 全局唯一热域 |
| `material_balances` | `{cid, material}` → units | 真值 | 按角色 |
| `phase_inventory` | `{cid, material}` → `{E, I}` | 真值 | 按角色 |
| `caster_energy` | cid → J | 真值 | 按角色 |
| `material_supplies` | `{cid, key}` / `{0, {:gm|:parcel|:beacon, key}}` → 回执 | 真值（防重） | 全局，单调增长 |
| `craft_ledger`/`food_ledger` | material → 累计 | 真值 | 全局标量 |
| `food_receipts` | cid → seq → 收据 | 真值 | 按角色，**无裁剪，单调增长**（production.ex:21-22,163） |
| `protection` | `regions: id → rect`, `index: 256m 桶 → ids`（protection.ex:12-16） | 真值 | xz 矩形、y 无限；已有空间桶索引 |
| `beacons` / `beacon_attunements` | id → 记录；cid → ids | 真值 | 全局小表 |
| `prefabs` / `published` | 定义目录 / 发布列表 | 目录 | 全局 |
| `entries` / `entry_regions` | seq → 事务；region → gb_tree seq | 检查点后缀 | 按区索引，随检查点清空 |
| `interaction_history` | 最近 512 条 | 真值 | 有界 |
| 会话：`tool_sessions`/`spell_sessions`/`claim_corners`（按 player pid）、`build_sessions`（按 gate pid）、`pending_casts`/`bodies`/`caster_coherence`（按 cid） | | 在线派生 | 在线规模 |
| 订阅：`subs`（pid→{box,min_level}）、`canonical_subs`/`replica_subs`（pid→box）、`canonical_feeds` | | 在线 | 每笔提交线性遍历 |

---

## 2. 公共成本块（下表引用）

### T_commit：每笔已提交事务的尾部（所有写操作都经过）

| 步骤 | 位置 | 访问 | 规模 |
|---|---|---|---|
| `Log.append_log` → `attachment_metadata` 合并整张 `attachment_owners`、`instances`、`Enum.to_list(liquid_active)` | w/log.ex:17, 28-36 | 全表 | O(实例+附件归属+活跃液体) |
| 元数据行 `term_to_binary(…, compressed)`（含 `thermal`、`property_states` 等） | overlay_log.ex:66-69 | 全表序列化 | 同上 + O(热源+拟态) |
| DB `repo.transaction(insert_rows)` 同步 | data_service/…/overlay_log_store.ex:31-33 | — | 行数 = 条目数+1 |
| `remember_entry` → Interactions、`LogProjection.index`、`Thermal.touch` | w/log.ex:39-55 | 局部 | O(条目) |
| `Observation.fanout` 遍历全部 `subs` 并逐个投影 | w/observation.ex:36-38 | O(订阅者×条目) | 在线规模 |
| `fanout_canonical` → `property_transaction`（有 canonical/replica 订阅才执行，:368-375） | w/observation.ex:390-391 | | |
| ├ 有格条目时 `Map.keys(before.refined) ++ Map.keys(state.refined)` 逐格比较 | w/observation.ex:223-228 | **全表 refined** | O(refined 宏格) |
| ├ 变动部件非空时 `component_observations` ×2 → `component_geometry` 编整表次序、遍历全部 `refined_owners` | w/observation.ex:146-149（调用 :235, :241） | **全表 refined + refined_owners** | |
| ├ `before.attachments == state.attachments`；不等时 `attachment_observations(state, nil)` group_by 全部附件 | w/observation.ex:258-261, 471-472 | **全表 attachments**（附件变化时） | |
| ├ `Map.keys(before.macro_owners) ++ Map.keys(state.macro_owners)` 无条件 | w/observation.ex:265-267 | **全表 macro_owners ×2** | O(实例宏格) |
| ├ `id_slots` 遍历全部 attachments（行里有 g3 时） | w/observation.ex:327-336 | **全表 attachments** | |
| ├ `owner_cells` → `owner_refined` → `in_refined_order` | w/observation.ex:309-324 → canonical.ex:59-60 | **全表 refined 宏格层** | |
| └ 每个 canonical/replica 订阅者 `PropertyObservation.project`；replica 需要的区域字节 | w/observation.ex:393-460 | O(订阅者×行) | |
| `Log.schedule_checkpoint` 60 s 定时器 | w/log.ex:58-63 | — | |

### T_geom：几何提交（`Edits.apply_batch` w/edits.ex:81-359；`Prefabs.prefab_reply` w/prefabs.ex:490-594；`AttachmentOps.commit_attachment/attachment_geometry` w/attachment_ops.ex:85-134）

| 步骤 | 位置 | 访问 |
|---|---|---|
| 被移除附件槽：`for {slot,{id,_}} <- state.attachments`（即使 `removed_attachments` 为空也执行） | w/edits.ex:99-100 | **全表 attachments** |
| 移除部件时 `micro_owner_cells` + `clear_subtree` + `live_instance_ids` | w/edits.ex:104-114 | 全表 refined（canonical.ex:60）+ 见 prefabs |
| 花草失支撑、掉落、逐格写 overlay | w/edits.ex:117-185 | 局部（按 edits） |
| `instances: Map.take(…, live_instance_ids(state))` | w/edits.ex:207；w/prefabs.ex:498 | **全表 refined_owners 键 + macro_owners 值**（payloads.ex:208-210）+ 祖先链 + Map.take |
| `AttachmentOps.attachment_dirty` → `affected_attachments` | w/edits.ex:219；w/prefabs.ex:539；attachment_ops.ex:259-265 | **全表 attachments**（每次调用） |
| `reduce_batch` L1：`Attachments.l1_faces(state.attachments, parents)` | w/edits.ex:418 → attachments.ex:46-48 | **全表 attachments** |
| L1–L5 逐级父格归约 `child_values`/`cell_value` | w/edits.ex:416-501 | 局部，但跨层级/跨区（见 §5） |
| `prune_attachments`：`affected_attachments` + `Map.keys(before.attachments) -- Map.keys(state.attachments)` | attachment_ops.ex:225-231 | **全表 attachments ×2** |
| `Canopy.affected_keys`：`candidates(before) ++ candidates(state)`；bound 非空再 `attachment_dirty` ×2 | canopy.ex:30-45, 48-54 | **全表 macro_owners ×2**（每项 `Map.fetch!` instances/prefabs） |
| `refresh_macro_payloads`（非后像区） | w/edits.ex:390-409 | 局部 |
| `Payloads.refresh_structure`：`attachment_dirty` + `l1_faces` | payloads.ex:263-265 | **全表 attachments ×2** |
| `Log.select_transaction` | w/log.ex:207-259 | 局部（变动格所在区） |
| `region_afterimages` → 每区 `with_refined`（见 T_payload） | payloads.ex:221-260 | 每区一次全表扫描组 |
| `carried = for … <- before.damage` | w/edits.ex:292-293 | **全表 damage** |
| `Tools.damage_geometry`：`before.damage |> Map.values |> Enum.filter` | tools.ex:484-498 | **全表 damage** |
| ├ `Map.reject(state.thermal.sources)` + `Enum.reduce(state.thermal.sources)` | tools.ex:517-530 | **全表热源** |
| ├ `attachment_damage`：`MapSet.new(state.attachments…)` + `Enum.reduce(before.damage…)` | tools.ex:73-77 | **全表 attachments + 全表 damage** |
| └ 附件变化时 `Thermal.rebuild_work` | tools.ex:553-554 | 见 §3.4 |
| `Thermal.drop_geometry` → `ThermalWork.drop` 遍历 `work.sights` | thermal_work.ex:252-264 | 热域视线缓存规模 |
| `append_journal` 判定：`state.instances == before.instances`、`attachment_owners ==`、`refined ==` | w/edits.ex:365-366 | map 等值比较；未变时指针相等快，变了最坏 O(n) |
| `Observation.canonical_changes`（碰撞 chunk 前后采样） | w/observation.ex:343-366 | 局部（变动格 ∩ 订阅盒） |
| prefab_reply 额外：`Map.keys(before.attachments) -- Map.keys(state.attachments)` | w/prefabs.ex:492 | **全表 attachments** |
| prefab 玩家结算 `prefab_payment`：`Enum.reduce(state.attachments)`、`Map.filter(before.attachments)` | w/prefabs.ex:196, 204-207 | **全表 attachments ×2**（仅玩家路径） |
| `prefab_operation`：`for … <- source.attachments` | w/prefabs.ex:268 | **全表 attachments**（仅玩家路径） |
| commit_attachment：`attachment_damage` + `Thermal.rebuild_work` | attachment_ops.ex:87, 90-93 | 全表 attachments + damage；rebuild 见 §3.4 |
| 之后 T_commit | | |

### T_payload：一个 L0 区域载荷物化（缓存 miss 或整区后像）

`payload_bytes` miss（payloads.ex:73-121）或 `region_afterimages`（payloads.ex:228-229）→ `with_refined`（payloads.ex:152-157）：

| 步骤 | 位置 | 访问 |
|---|---|---|
| 27 区 refined（区域索引） | payloads.ex:160-176 | 局部（好） |
| `Map.filter(state.macro_owners, …in_span?)` | payloads.ex:178 | **全表 macro_owners** |
| `for {owner, cells} <- state.refined_owners, not MapSet.disjoint?(…)` | payloads.ex:180 | **全表 refined_owners**（每项一次集合求交） |
| `Refined.ancestors(state.instances, …)` + `Map.take` | payloads.ex:181, 191 | 局部（按涉及身份） |
| `for {cell, units} <- state.liquid_units, in_span?` | payloads.ex:185-187 | **全表 liquid_units** |
| `Attachments.extract(state.attachments, region)` | payloads.ex:188 → attachments.ex:37-44 | **全表 attachments** |
| `Canopy.project` → `candidates(state)` | payloads.ex:154 → canopy.ex:10, 48-54 | **全表 macro_owners**（+ instances/prefabs 查表） |
| L1+ 载荷：`for {{^level, cell}, grid} <- state.structure` | payloads.ex:196-205 | **全表 structure** |

触发：`serve_item` 缓存 miss、每笔几何提交的每个后像区、replica 订阅区不在后像中时（w/observation.ex:441）、`select_transaction` 带上限物化（w/log.ex:238）、液体接纳（w/liquids.ex:61）、检查点构建（Task 内，w/log.ex:298-301）、离线粗层重建。

---

## 3. 逐操作访问路径

列说明：**局部** = 只按给定坐标/区域/身份读写；**全表** 列给出 file:line；频率：每笔提交 / 每 tick / 每次观察 / 仅启动 / 仅维护 / 只测试。

### 3.1 handle_call（W:703-1388）

前置：热提交进行中（`thermal_work.domain.pending`）时，除 `@unflushed`（`:serve_item, :tool_definition, :content_version, :seq, :body_coherence, :body_contact, :interactions_since`）外每条调用先 `Thermal.flush`（W:701-705；thermal.ex:564-581，热域规模）。

| 消息（行） | 读/写字段 | 局部/全表 | 全表扫描 file:line | 频率 |
|---|---|---|---|---|
| `:content_version` `:seq` `:liquid_activity` `:source` `:magic_range` `:magic_digest` `{:tool_range}` `{:tool_definition}` `:prefab_catalog` `:material_catalog`（W:707-713, 961-962, 985-988, 1139, 1143） | 读标量/目录 | 局部 | — | 每请求 |
| `{:interactions_since}`（W:709） | 读 interaction_history | 有界 512 | w/interactions.ex:81 | 诊断/NPC |
| `{:prepare, keys}`（W:715-731） | 读 region_bases/decoded/payloads；`adopt_liquid_regions` 写 liquid_units/active/adopted、可能提交液体 | 局部（按 keys）；接纳若提交 → T_geom+T_commit | 接纳路径见 w/liquids.ex:50-89（区域内二进制扫描） | 每次窗口/编辑预备 |
| `{:adopt_liquid}`（W:733） | 同上 | 同上 | — | 冷区预备后 |
| `{:prepare_intent}` / `{:prepared_intent}`（W:737-754） | 读 needs_source；写 decoded（**不还原**）、液体接纳；然后转发到实际意图 | 局部 | — | 每个工具/生产意图 |
| `{:publish_properties}`（W:756-802） | 读全部 phase_inventory、damage；写 properties、damage（**全部行重写**）、attachments、thermal | 全表 | W:761, W:766；catalogs.ex:92-93（全部 damage 行进一笔事务）、:98（`wake_liquid(Map.keys(liquid_units))`）、`rebuild_work`（thermal.ex:66-71）；T_commit | 仅维护 |
| `{:publish_parameters}`（W:804-820） | ParameterEvolution 读全部 damage/thermal/attachments；同上发布 | 全表 | 同上（ParameterEvolution 内部未逐行核，推断亦为全表） | 仅维护 |
| `{:thermal_experiment}`（W:827-858） | 写 thermal.sources/config；`rebuild_work`；`thermal_commit` | 全表 | thermal.ex:66-71；T_commit | 只测试 |
| `{:sight_snapshot}`（W:861-874） | 射线 `target_at`、`property_state` | 局部；但 g2 无行时 `component_max_hp` → canonical.ex:60 **全表 refined** | canonical.ex:233 → :60 | NPC 感知，每次观察 |
| `{:material_snapshot}`（W:877-906） | 读给定 cells 的 overlay/refined/instances/placed_by；`balance_projection` | cells 局部；余额全表 | w/observation.ex:71（`Enum.sort(全部 material_balances)`） | 诊断/验收 CLI |
| `{:simulation_snapshot}`（W:908-920） | `prepare_component_cache(box)`、`property_snapshot(box)`、液体、相态库存、热账 | 全表 | W:915（hot list），W:916；observation.ex:146-149、184、207、471、87、95-98；observation.ex:71 | 诊断/验收 CLI |
| `{:liquid_experiment}`（W:923-939） | apply_batch | T_geom+T_commit | — | 只测试 |
| `{:author_regions}`（W:941-959） | protection；`commit_protection` | 全表 | claims.ex:100（全部 liquid_units）、:101 rebuild_work（thermal.ex:66-71）；T_commit | 仅维护 |
| `{:caster_state}` `{:send_caster_state}`（W:964-976） | caster_energy[cid]、caster_coherence[cid] | 局部 | — | 登录 |
| `{:spell_intent}`（W:978-983）→ `Casting.prepare_spell` | 报价：只读目录；施放：射线、`foot_target`、protection、spell_sessions；`commit_casts` 写 seq + 广播 pending_casts | 局部 + T_commit（空事务也写全量元数据） | casting.ex:199（全部 semblances 计数，小）；T_commit | 每次施法 |
| `{:body_tool}`（W:990-1010） | 射线、tool_sessions | 局部 | — | 每次打人 |
| `{:material_balances}`（W:1012） | balances[{cid,m}] | 局部 | — | 每登录/每次 |
| `{:material_supply}`（W:1015-1032）→ `supply_materials` | material_supplies、balances、phase_inventory、thermal | 局部 + T_commit | — | 作者入口 |
| `{:gm}`（W:1034）→ `Gm.run` | 见 §3.5 | 全表若干 | gm.ex:161, 233, 271-276 | 只测试 |
| `{:parcel_export}` `{:parcel_install}`（W:1036-1042） | 见 §3.5 | 全表若干 | parcel.ex 多处 | 仅维护 |
| `{:beacon_install}` `{:beacon_directory}`（W:1044-1048） | beacons、material_supplies；目录读全部 beacons | 全局小表 | beacons.ex:73-77 | 维护 / 登录 |
| `{:liquid_fill}`（W:1050-1059） | 洪泛 ≤ max_cells；commit_liquid → apply_batch | 局部洪泛 + T_geom+T_commit | — | 只测试 |
| `{:production_intent}`（W:1061-1068）→ `build_target`（production.ex:104-141） | build_sessions；action 1 建造：balances、phase_inventory、cell、可能排液 → apply_batch；2/3 舀/倒：`transfer_liquid` → commit_liquid → apply_batch；4 合成、5 进食：balances、ledgers、food_receipts（纯账事务） | 建造/舀倒：T_geom+T_commit；合成/进食：T_commit | T_geom/T_commit 各项 | 每次玩家建造/舀倒/合成/进食 |
| `{:attachment_intent}`（W:1070-1077）→ `attachment_target` | build_sessions、attachments、attachment_serial、balances、damage | 放置：局部判定 + commit_attachment；拆除：`for … <- state.attachments` 找同 id 槽 | attachment_ops.ex:204；claims.ex:27-30（拆除时 `attachment_slots` → canonical.ex:242）；commit_attachment 见 T_geom（tools.ex:73-77、rebuild_work）| 每次挂/拆附件 |
| `{:tool_intent}`（W:1079-1133） | 见 §3.2 | | | 每次工具命中（最高频玩家写） |
| `{:publish_prefabs}` `{:publish_prefab}` `:published_prefabs`（W:1135-1155, 1141） | prefabs、published；`persist_prefab` 读 `published` 列表 | 目录规模 | w/prefabs.ex:600-601 | 发布时 |
| `{:prefab_cells}`（W:1157） | 定义展开 | 局部 | — | 放置前置 |
| `{:instance_cells}`（W:1165）→ `owner_cells` → `subtree_ids` + `subtree_cells` | instances、macro_owners、refined | 全表 | prefabs.ex:52-55（group_by 全部 instances）、:71（全部 macro_owners）、canonical.ex:60（全部 refined） | 每次 prefab 拆除前置 |
| `{:replacement_cells}`（W:1170） | 同上 + 定义 | 全表 | 同上 | 每次替换前置 |
| `{:place_prefab}`（W:1181）/`place_tree`（prefabs.ex:374-488） | 读写 overlay、refined、macro_owners、placed_by、instances、attachments、attachment_owners | 足迹局部；`next.attachments` 键检查局部 | 之后 prefab_reply（T_geom） | 作者 |
| `{:prefab_intent}`（W:1185-1215） | build_sessions、protection；`prefab_intent_cells`（拆/换时 `owner_cells`）；`player_prefab` | 全表 | prefabs.ex:647 → :52, :71, canonical.ex:60；player_prefab 再 `subtree_ids`/`subtree_cells`（prefabs.ex:117-119）；`clear_subtree` prefabs.ex:89-101（live_instance_ids、`Map.filter(attachment_owners)` :92、`Map.reject(attachments)` :100）；prefab_reply（T_geom，含 :196/:205/:268 玩家路径） | 每次玩家放/拆/换 prefab（一次拆除对 instances 至少 group_by 3 次：前置 call、:647、:117） |
| `{:remove_prefab}` `{:replace_prefab}`（W:1217-1247） | 同上，作者 | 全表 | 同上 | 作者/夹具 |
| `:stats`（W:1249-1276） | `:erlang.external_size(state.attachments)`、`(state.damage)` | **全表序列化** | W:1266, W:1269 | CLI/诊断 |
| `{:serve_item}`（W:1278-1294）→ `serve_item`（payloads.ex:20-63） | payloads/lru、served_headers、entries/entry_regions；miss 时 T_payload；完毕还原 decoded | 命中局部；miss → T_payload 全表组 | payloads.ex:178/180/185/188, canopy.ex:10（L0）；payloads.ex:198（L1+） | 每个 HTTP 区域请求 |
| `{:apply_edit}` `{:apply_edits}`（W:1296-1310, 1374-1384） | `raw_liquid_edit` 读 cells；apply_batch | T_geom+T_commit | 见 T_geom | 作者/夹具/旧入口 |
| `{:subscribe}`（W:1312-1322） | 遍历 `state.entries`（检查点后缀） | 后缀规模 | W:1316-1319 | 每次订阅 |
| `{:entries_after}`（W:1325-1334） | 后缀；纯属性事务时 `backend.replay(handle)` **读整份日志** | 全日志 | W:1326, W:1330 | 测试/诊断 |
| `{:canonical_snapshot}`（W:1337-1360）/`{:replica_snapshot}`（W:1362-1372）→ `capture_canonical_snapshot` | box 内区域字节（局部/可能 T_payload）、`prepare_component_cache(box)`、`property_snapshot(box)`、`food_receipts` 整表 | 区域局部；属性部分全表 | observation.ex:146-149（×2：prepare_component_cache 与 component_observations）、:184（全部 damage）、:207（全部 macro_owners 键）、:471（全部 attachments group_by）、:194 整张 `epochs` 再在 property_observation.ex:19 逐项过滤、:58 整张 `food_receipts`（不过滤） | 每次窗口快照（登录、移交、replica 启动） |
| `:compact`（W:1386）→ `request_checkpoint` | 见 §3.4 | 全量 | w/log.ex:269-327, 330-369 | 维护 |

### 3.2 `{:tool_intent}` 内部分支（W:1079-1133 → tools.ex）

公共前段：`current_actor`（跨进程回调 Player）；`tool_target` 射线（tools.ex:40-53，局部，经 `target_at`）；g3 命中时 `attachment_reach`（局部射线）；`property_state`（canonical.ex:176-229）——**无属性行时**：g2 → `component_max_hp` → canonical.ex:233 → :60 **全表 refined**；g3 → `attachment_max_hp` → canonical.ex:242 **全表 attachments**；`Protection.permitted?(…, target_cells)`：g2 → claims.ex:20 → canonical.ex:60 **全表 refined**，g3 → claims.ex:18-19 → canonical.ex:242 **全表 attachments**（protection.ex:47-48，本身按 256 m 桶局部）；`attack_target` 写 `tool_sessions`。

| 分支（tools.ex） | 写字段 | 额外全表 | 尾 |
|---|---|---|---|
| g2 叶子检查 `leaf_component?`（:178, :412-413，**每次命中微格构件**） | — | **全部 instances** tools.ex:413 | — |
| 未毁伤（:213-243） | seq、damage[key] | — | T_commit（property_transaction 只走 :265 macro_owners 与附件等值比较） |
| 宏格毁坏（:193-211）→ `destroy_target` → apply_batch | overlay、damage、balances、epochs、liquid… | T_geom | T_commit |
| 拆卸构件（:425-455）→ `micro_owner_cells`（canonical.ex:60）+ `clear_subtree` + `prefab_reply` | refined、instances、attachments… | canonical.ex:60；prefabs.ex:89-101；T_geom | T_commit |
| 附件毁/拆（attachment_ops.ex:59-83）→ `attachment_slots`（canonical.ex:242）+ commit_attachment | attachments、damage、balances、thermal | canonical.ex:242；tools.ex:73-77；`rebuild_work` thermal.ex:66-71 | T_commit |
| `protection.claim`（claims.ex:40-80）→ 第二角 `region_occupied?` | protection、claim_corners | **全部 placed_by、macro_owners、refined（含逐槽）** claims.ex:89-93；`Protection.held` 全部区域 protection.ex:63；`commit_protection` claims.ex:100（全部 liquid_units）+ :101 rebuild_work | T_commit |
| `circuit.toggle`（tools.ex:251-279） | damage 一行 | — | T_commit |
| `beacon.use`（beacons.ex:45-67）→ `nearest` | beacon_attunements | 全部 beacons（小） beacons.ex:130-139 | T_commit |
| `combustion.*`（tools.ex:283-410）→ `commit_combustion` | damage、thermal、balances | **`Thermal.rebuild_work`** tools.ex:385 → thermal.ex:66-71（全部 damage ×3） | T_commit |
| `phase.cool/heat`（phases.ex:126-151）→ commit_liquid | liquid_units、damage、thermal、balances | T_geom（液体路径） | T_commit |
| 相态固体毁伤（phases.ex:155-187）→ commit_liquid | 同上 | T_geom | T_commit |

### 3.3 handle_info / handle_continue / 定时 tick（W:1390-1581）

| 消息（行） | 读/写 | 局部/全表 | 全表 file:line | 频率 |
|---|---|---|---|---|
| `{:timeout, ref, :checkpoint}`（W:1406） → `request_checkpoint` → `start_checkpoint`（W:1599-1620） | `checkpoint_input` 冻结（结构共享，W 内便宜）；Task 内 `build_checkpoint` | Task 内全量 | w/log.ex:289-292（全部 overlay）、:298-301（全部 snapshots 区物化，T_payload 每区）、:307（全部 damage）、:308-321（全部各表） | 有新事务时每 60 s（w/log.ex:60-61） |
| 检查点 Task 结果（W:1411-1419）→ `finish_checkpoint` | **在 World 内**：`backend.checkpoint(handle, txn)` 写整份前缀；逐条后像 `Payload.decode` 换基底；后缀重建索引；通知 replicas | 全量（阻塞 World） | w/log.ex:333（全量 DB 写）、:340-353（每区解码）、:356（entries 后缀） | 每次检查点 |
| `handle_continue({:checkpoint_gc})`（W:1391-1397） | `:erlang.garbage_collect(self())` | **整堆 GC，O(常驻世界)** | W:1394 | 每次检查点后 |
| `:projectile_tick`（W:1421-1424）→ `drain_thermal` + `Projectiles.poll` | semblances（带 projectile_source） | 拟态规模 | projectiles.ex:16 | 有飞行物时每 50 ms（projectiles.ex:8-13） |
| 投射物 Task 结果（W:1426-1430）→ `Projectiles.accept` → 每个结果一笔 `HeatCommit.thermal_commit` | thermal.semblances、ledgers；射线段 `Semblance.segment`（局部） | 局部 + **每结果 T_commit** | T_commit（含整份 thermal + instances + attachment_owners + liquid_active 序列化） | 每 50 ms × 飞行物 |
| `:liquid_commit`（W:1432-1437）→ `advance_liquid`（liquids.ex:326-366） | 读 active 邻域 cell_value、liquid_units；每种流动材料一笔 `commit_liquid` → `apply_batch` | 活跃集局部；**每材料一次 T_geom+T_commit**（纯数量变化也走全路径，edits.ex:191 不短路） | liquids.ex:332（liquid_falls，小）；T_geom 全部项；T_commit | 有活跃液体时每 `step_seconds`（夹具 0.1 s） |
| `{:body_contact}`（W:1441-1457） | `Thermal.body_contacts`：脚下/身体列 `target_at`、semblances；写 bodies；`wake` | 局部 | thermal.ex:785-788（全部 semblances，小） | 每在线身体每秒 |
| `{:body_detach}`（W:1463-1470） | bodies | 局部 | — | 移交/退出 |
| `{:body_coherence}`（W:1474-1484） | caster_coherence | 局部 | — | 每秒 |
| `{:body_death}`（W:1487-1491）→ `death_drop` | balances、cells、protection | **全部 material_balances**（所有角色）production.ex:232-244；落点 commit → apply_batch 或 commit_liquid | production.ex:233；T_geom+T_commit | 每次死亡 |
| `{:quote_cast}` `{:prepare_cast}` `{:authorize_cast}` `{:cancel_cast}`（W:1494-1525） | pending_casts、caster_energy、thermal、damage（取能石） | 局部；`cancel_pending_cast` Enum.find 全部 pending（在线规模）casting.ex:128 | 结算 settle_spell → T_commit；`commit_casts` → T_commit | 每次施法 2–3 笔事务 |
| `{:prepare_beacon}` `{:commit_beacon}`（W:1528-1538） | beacons、attunements、核心格 `target_at`（`ensure_sources` 可能同步生成冷区） | 局部 | — | 每次传送 |
| `:thermal_tick`（W:1542-1548）→ `Thermal.fired/begin` | bodies 超时清理；`circuit_seeds`（候选集合） | 在线/候选规模 | thermal.ex:83-85（全部 bodies，在线） | 热活动时每 500 ms（thermal.ex:22-27） |
| `{:thermal_step}`（W:1550）→ `Thermal.tick` → `advance_run`/`thermal_step`/`circuit_segment` | 热域、damage、thermal、attachments、protection | 热域局部为主；见下 | 见下 | 每拍若干步 |
| ├ `circuit_segment` → `Circuit.prepare(state.attachments, state.damage, …)` | 遍历**全部附件槽**算导线边；`DCNetwork.solve` 全图 | **全表 attachments** | thermal.ex:234 → circuit.ex:84 | 每个电路段（有种子且非 quiet） |
| ├ `ThermalWork.plan`：`work.burning || for … <- damage` | | nil 时**全表 damage** | thermal_work.ex:128-130 | rebuild_work 后首步 |
| ├ `ThermalWork.refresh`：`work.attachment_cells || Enum.map(attachments…)` | | nil 时**全表 attachments** | thermal_work.ex:182-184 | rebuild_work 后首步 |
| ├ `refresh_native`：`damage == state.damage` 比较；不同则遍历 `domain.table` | | 热域规模 | thermal.ex:588-605 | 每步 |
| ├ 步末 `active = … or Enum.any?(damage, burning)`（短路：有热源/热格时不扫） | | 静默时**全表 damage** | thermal.ex:511-513 | 每步 |
| ├ `settle_run`：`settle_keys(nil, …)` → `Map.keys(damage)` | | nil 时**全表 damage** | thermal_work.ex:62（调用 thermal.ex:173） | rebuild_work 后首次结算 |
| └ `commit_thermal`（heat_commit.ex:17-55）：无死亡/相变 → `thermal_commit`（T_commit）；有相变/死亡 → `commit_liquid` → apply_batch（T_geom）；`transform_heated_materials`：`transform_keys(…, nil, …)` → `Map.keys(damage)`；有产物 → `prefab_reply`（T_geom） | | | heat_commit.ex:95 → thermal_work.ex:69；T_geom/T_commit | 每次热提交（≤ 2 次/秒） |
| `:thermal_commit`（W:1554-1557） | 同上，同步走完 | 同上 | 同上 | 测试/直接投递 |
| `{:DOWN}`（W:1559-1579） | 遍历 pending_casts、bodies；删各会话表 | 在线规模 | W:1560, W:1563 | 每次断线 |

### 3.4 启动 / 维护 / 离线

| 入口 | 访问 | 全表 file:line | 频率 |
|---|---|---|---|
| `restore` → `replay_log`（w/log.ex:65-70）：逐事务 `replay_entry`（每个后像 `Payload.decode`、`refined_in_regions` 清本区 refined、`Map.reject(state.attachments, region)`、`Map.reject(state.liquid_units, region)`、`live_instance_ids`） | **每个整区条目全表 attachments/liquid_units + live_instance_ids** | w/log.ex:111, 113-118, 124-126 | 仅启动 |
| `replay_damage`：txn 缺 `liquid_active` 时 `Liquid.neighborhood(Map.keys(liquid_units))` | 全表 liquid_units | w/log.ex:399 | 仅启动（旧日志） |
| `init`（W:663-695）：`validate_damage_catalog`、`migrate_component_damage`、`refresh_structure(state, Map.keys(state.refined))`、structure 非空则**同步** `compact_log`、`rebuild_work`、`prepare_component_cache(state, nil)` | 全表 damage/refined/attachments、同步全量检查点 | catalogs.ex:122；heat_commit.ex:233-249；W:679；W:680 → w/log.ex:263-266；W:681 → thermal.ex:66-71；W:682 → observation.ex:146-149 | 仅启动 |
| `Thermal.rebuild_work`（thermal.ex:62-74）：`hot_rows(damage)`、`Enum.any?(damage, exhausted?)`、`electric(Map.keys(damage), …)`；重置 `ThermalWork.new()`（burning/pending/attachment_cells/electric = nil → 下一轮再全扫） | **全表 damage ×3**；连带下一次热提交的全表扫描 | thermal.ex:66, 70, 71；thermal_work.ex:90 | 调用点：attachment_ops.ex:92（每次附件提交）、tools.ex:385（每次点火/熄火）、tools.ex:554（几何提交改了附件）、claims.ex:101（每次认领/释放）、catalogs.ex:88/95、W:681、W:856 |
| `rebuild_coarse` → `CoarseRebuild.run`（离线，独占日志库） | 全部 overlay/refined/macro_owners/attachments 键、全部 L0 base 每格 | coarse_rebuild.ex:24, 29-30, 40-44, 66, 93 | 仅维护（离线） |
| 检查点（见 §3.3） | 全量 | | 每 60 s |

### 3.5 GM（只测试）/ 地块（维护）

| 操作 | 访问 | 全表 file:line |
|---|---|---|
| `:clear` | 盒内 ≤4096 宏格局部；`prune_instances` | gm.ex:271（live_instance_ids）、:272（全部 instances 键）、:273（全部 attachment_owners）、:275（全部 attachments）；prefab_reply（T_geom） |
| `:fill` | 盒内局部 → apply_batch | T_geom |
| `:recolor` | `state.attachments |> Map.keys |> Attachments.macros` | gm.ex:161（全部 attachments）；apply_batch |
| `:liquid_fill` | 洪泛局部 → commit_liquid | T_geom |
| `:drain` | `for {cell, units} <- state.liquid_units` | gm.ex:233（全部 liquid_units）；commit_liquid |
| `:move_instance` | `subtree_ids`/`subtree_cells`/`clear_subtree`/`place_tree` | prefabs.ex:52, 71, 89-101；T_geom |
| `parcel_export`（parcel.ex:24-66） | 盒内格局部；其余全表 | parcel.ex:33（macro_owners）、:36（attachment_owners）、:38（attachments）、:40（attachments）、:41（attachments）、:53（`Map.values(damage)`）、:58（liquid_units）；`trees` → prefabs.ex:52/71 每根树一次（parcel.ex:174-175，**树数 × 全表**） |
| `parcel_install`（parcel.ex:78-165） | 目标盒局部写入；`target_trees` | parcel.ex:186（macro_owners）、:188（attachments）、`units` ×2 parcel.ex:278（attachments）；`clear_subtree`；prefab_reply（T_geom，一笔数十万格） |

---

## 4. 跨区域依赖（一笔操作同时触及多个 L0 区域或跨层级）

| 依赖 | 机制（file:line） | 跨区范围 | 原子要求 |
|---|---|---|---|
| **ring（1 格边带）** | 一格登记进 `region_keys` ±1 的全部区（log_projection.ex:6-12；edits.ex:65-77）；载荷 ring 从 26 邻区基底投影（payloads.ex:128-150）；`with_refined` 读 27 区 refined（payloads.ex:160） | 边界格编辑 → 最多 8 个 L0 区载荷失效/后像 | 同一笔事务的 entries 同时含多区 |
| **L1–L5 粗层归约** | `edit_keys` 每格 6 级（edits.ex:40-45）；`reduce_batch` 逐级父格（edits.ex:416-484）；结构网格 L1–L5（payloads.ex:263-346） | L 级区域边长 64·2^L m；L5 区 = 32³ 个 L0 区 | 粗层条目与 L0 同笔 |
| **液体** | 活跃集与邻域（liquids.ex:326-340）；`Liquid.step_transfers` 跨格；每材料**一笔事务覆盖全世界活跃液体**（liquids.ex:362）；排液 `Liquid.displace`（production.ex:387-401）；洪泛（liquids.ex:240-251）；`liquid_bounds` 是全局盒 | 无上界（随活跃范围） | 全世界活跃液体一笔原子提交 |
| **热传导/辐射** | 单一原生热域 `ThermalDomain`；种子六邻域 + 视线伙伴扩域（thermal_work.ex:117-176）；视线沿轴 `view_range_cells`（thermal.ex:894-945）；分区只按 protection 持有者 × 气候区（thermal.ex:1039-1050），不按区域 | 无上界 | 一次热提交 = 全世界变化行一笔；死亡/相变/转化随后几何事务 |
| **热账/守恒** | `thermal` 里全局累计账（observation.ex:78-86）；`thermal_accounting` 是“整个世界累计结算账”（W:273） | 全局 | 每笔改热的事务都写整份 `thermal` |
| **电路** | `Circuit.prepare` 从全部附件槽建导线图（circuit.ex:81-）；`circuit_contacts` 沿实体导体 BFS 扩张（thermal.ex:327-346）；`DCNetwork.solve` 全图（dc_network.ex） | 导线/导体连通即无上界 | 电源观察行、发光、储能与热段同一热提交 |
| **Prefab 实例树** | `parent_id` 树（refined.ex:129-145）；`place_tree` 足迹任意大；拆除 = 整棵子树（prefabs.ex:50-103）；载荷需实例祖先（payloads.ex:181） | 建筑可跨任意多区（如园整园迁入一笔数十万格） | 整树一笔 |
| **附件** | 槽按 anchor 归区（attachments.ex:34-35），但 `macros` 含支撑邻格（attachments.ex:121-122）、载荷 extract 含 ring（attachments.ex:37-44）、L1 面投影跨父格（attachments.ex:46-55）；`attachment_owners` 绑实例 | 足迹跨 2 个宏格可能跨区；归属随实例跨区 | 附件与实例/支撑格同笔 |
| **部件/附件属性行** | damage `{2, owner}`、`{3, aid}` 不含坐标（damage.ex:340-341） | 随实例/附件跨区 | 与几何同笔 |
| **结构/支撑** | 地面花草失支撑（edits.ex:117-130）读上方格；附件支撑重判（attachment_ops.ex:225-257）；`refresh_structure` 跨父格 | 相邻格可在邻区 | 同笔 |
| **树冠呈现** | `Canopy.affected_keys` 0..5 级祖格 + ring（canopy.ex:30-46） | 多级多区 | 同笔 |
| **射线/投射物** | 工具射程 `tool_regions(eye, range)` 预备所有 L0 区（tools.ex:599-604）；NPC sight、拟态弹道 trace、投射物飞行段（projectiles.ex:55-62）、液体视线、附件可达 | 射程内多区（只读） | 只读判定，写入目标格 |
| **受保护区域** | xz 矩形 y 无限（protection.ex:5-8），256 m 桶索引；物理边界影响液体侧流/热/电路/还原剂（protection.ex:2-4） | 一个区域竖向贯穿所有 y 区；可横跨多区 | 认领一笔；边界改变 → 全热工作集重建 + 区内液体唤醒 |
| **角色账本** | balances/phase_inventory/caster_energy/food_receipts 按 cid（与空间无关） | 角色 × 区域 | 每次建造/挖取/舀倒/施法：格变化与余额同笔 |
| **信标** | 两核心任意距离（beacons.ex:84-103） | 远距两区（只读） | 只读校验 |
| **拟态/投射物热交付** | 拟态移动；交付到 Scene 身体（projectiles.ex:42-52） | 跨区 + 跨进程 | 交付前先持久冻结（projectiles.ex:85-86） |
| **全局 seq** | 每笔事务 `seq + 1`（各提交点）；客户端 have_seq 按区域投影但 seq 全局（payloads.ex:44） | 全局 | 全局全序 |

---

## 5. 全局索引（按身份/owner/网络 id）与区域化可行性

| 索引 | 键 → 值 | 现在的反向查找 | 区域化方案（推断） | 难点 |
|---|---|---|---|---|
| `instances` | `{birth, occ}` → 实例记录 | 子节点：`group_by` 全表（prefabs.ex:52）、`leaf_component?` 全表（tools.ex:413） | 实例记录放其 anchor 所在 L0 区；区内维护 `parent → children`；**跨区目录**只收“树跨多区”的根：root id → 区集合 | 协议里 prefab 拆/换只带 `instance_id`（W:375-378），需 id → home region 目录（O(实例) 而非 O(跨区树)），或协议带坐标 |
| `refined_owners` | owner → MapSet cell | — | 改为 region → owner → cells；加 owner → regions 小目录 | `in_refined_order` 依赖**全表遍历次序**以保浮点求和/代表格一致（canonical.ex:54-60、observation.ex:145-146），分区后次序语义要重定义（或改为确定排序） |
| `macro_owners` | cell → owner | owner→cells 全扫（prefabs.ex:71）、值全扫（payloads.ex:210）、canopy 全扫（canopy.ex:49） | 天然按格分区；加区内 owner → cells；canopy 候选按区内“有呈现绑定的 owner”索引 | — |
| `attachments` | slot → {aid, mat} | aid→slots 全扫（canonical.ex:242、attachment_ops.ex:204）；macro→slots 全扫（attachment_ops.ex:262、attachments.ex:46）；按区 extract 全扫（attachments.ex:37） | 按 anchor 区分区；区内 aid → slots、macro → slots；足迹跨区时在邻区登记“外来足迹”引用 | 支撑邻格在邻区：剪枝需读邻区 |
| `attachment_owners` | aid → {owner, slot} | owner→aids 全扫（prefabs.ex:92、gm.ex:273、parcel.ex:36） | 跟随附件所在区；加 owner → aids（并入实例目录） | 每笔整表写日志（w/log.ex:32） |
| `damage` g2/g3 | `{2, owner}` / `{3, aid}` → 行 | `Damage.macro` 取代表微格 | 部件行放实例 home 区；附件行放附件 anchor 区；目录同上 | 观察格（observation_cells）跨区 |
| 热工作集 | 全局单一 domain，热行 key → 足迹 | — | 推断：可按“热连通分量”分片，但分量可跨任意多区；守恒账是全局和 | 需全局账或分账再汇总 |
| 电路网络 | 无 network id；每段从全部附件建图 | 全扫 circuit.ex:84 | 推断：维护“导线连通分量 id → 槽/区集合”目录（增量于附件提交），电路段只取有种子的分量 | 导体经实体格接触扩张（thermal.ex:327-346），分量边界随格编辑变化 |
| 液体活跃集 | MapSet cell | — | 天然按格；但事务目前一材料一笔覆盖全世界 | 跨区流动需两区同时提交 |
| 角色账本 | `{cid, m}` 等 | `balance_projection`、`death_drop` 全扫（observation.ex:71、production.ex:233） | 推断：按 cid 一张子表 `cid → %{m => units}`，与空间分离 | 与格编辑原子同笔（§6） |
| `protection` | id → 矩形；256 m 桶 → ids | 已有空间索引；`held` 全扫（protection.ex:63，小） | 保持全局小目录即可 | y 无限，按 L0 区分会在每个 y 区重复 |
| `beacons`/`semblances`/`pending_casts` | id/cid | 全扫（小） | 全局小目录 | — |
| 订阅 `subs`/`canonical_subs`/`replica_subs` | pid → box | 每笔遍历全部（observation.ex:37, 393, 413, 446） | 推断：region → 订阅者索引 | 在线规模，不随世界增长 |

---

## 6. 事务原子性与回滚（事实）

1. **单写者 + 纯函数状态**：每笔提交在一个 GenServer 回合内由 `before` 构造 `next`；任何 `{:error, _}` 都回复并保留 `before`（如 w/edits.ex:187-189、w/prefabs.ex:588-592、tools.ex:241-242、attachment_ops.ex:44、production.ex:125-128）。内存回滚 = 丢弃 `next`，无撤销日志。
2. **先落盘再确认/广播**：`Log.append_log` 同步成功后才 `remember_entry`、`fanout`、回复（例：w/edits.ex:331-354、w/heat_commit.ex:73-79）。DB 端一笔事务一次 `repo.transaction(insert_rows)`（overlay_log_store.ex:31-33），条目行（每区后像 kind 1、逐格 kind 0、粗格 kind 2、结构 kind 4）与元数据行（kind 3）同一 DB 事务（overlay_log.ex:48-71）。所以**多区域、多层级、角色账、实例、热账在一笔里全有或全无**。
3. **断言即崩溃的路径**：`thermal_commit` 的 `:ok = Log.append_log`（heat_commit.ex:73）、`commit_thermal` 的 `{:ok, state} = Liquids.commit_liquid`（heat_commit.ex:23, 37）、`finish_checkpoint` 的 `:ok = backend.checkpoint`（w/log.ex:333）、`ensure` 的 `:ok = source.ensure`（edits.ex:385、liquids.ex:105, 286, 334）。失败时 World 崩溃，重启经 `replay_log` 恢复到最后一笔已落盘事务（内存派生全部重建）。液体 tick 的 `commit_liquid` 失败只记日志并保留旧状态（liquids.ex:362-365）。
4. **预备阶段不在事务内**：冷区生成/解码在调用方进程（W:111-159），之后第二次 call 才提交（W:137-145, 750-754）；两次之间可插入其他提交。源载荷按内容版本不可变，World 在提交回合内重新判定 `needs_source?`，缺失即显式失败（`:missing_region`），不当空气。
5. **分步热提交**：一次热提交分多条 `:thermal_step` 消息推进（W:1540-1551），步间可插入其他事务；其他调用先 `flush` 写回原生热域（W:701-705）；整段仍作为**一笔**热事务提交（thermal.ex:104-127, 157-224）。步间事务使本次电路不能判 quiet（thermal.ex:112-116）。
6. **必须跨多区原子的提交**（事实，按 §4）：任何 ring 内编辑、全部粗层归约、每次液体步、每次热提交（全世界热行 + 死亡几何 + 转化产物各自一笔）、prefab 放/拆/换、附件足迹跨区、地块安装、GM 盒操作、建造/挖取（格 + 角色余额）、施法取能（施法者能量 + 蓄能石 stored_j + 热源，casting.ex:298-397）、认领（protection + 热工作集重建 + 液体唤醒）、目录发布（全部 damage 行 + 附件迁移）。
7. **检查点**：Task 冻结前缀（W:1611-1618），World 内一次写入替换前缀（w/log.ex:330-369），期间提交的后缀保留；`seq == txn.seq` 时才把后像换基底（w/log.ex:337）。

---

## 7. 全表扫描清单（按字段汇总）

频率记号：**C** = 每笔提交（有订阅者时）；**G** = 每笔几何提交（含液体每步、热致相变/死亡、转化、建造、挖毁、prefab、附件）；**P** = 每次 L0/L1+ 载荷物化（serve miss、每个后像区、检查点每区）；**T** = 热/电路 tick；**O** = 每次窗口/模拟快照；**I** = 特定玩家意图每次；**S** = 仅启动；**M** = 仅维护/作者；**X** = 只测试。

| # | 字段 | file:line | 代码形态 | 频率 |
|---|---|---|---|---|
| 1 | instances + attachment_owners + liquid_active（+ thermal 整份） | w/log.ex:28-36 → overlay_log.ex:66-69 | 整表 term_to_binary 进每条日志元数据 | **每笔事务（无订阅者也有）** |
| 2 | macro_owners | w/observation.ex:265-267 | keys(before)++keys(after) 逐格比较 | C |
| 3 | refined | w/observation.ex:223-228 | keys(before)++keys(after) 逐格比较 | C（有条目时） |
| 4 | refined + refined_owners | w/observation.ex:146-149 | 整表 with_index 次序 + 遍历全部 owner | C（变动部件）×2；O ×2；S |
| 5 | attachments | w/observation.ex:258-261, 471-472 | 等值比较；不等时 group_by 全表 | C（附件变化）；O |
| 6 | attachments | w/observation.ex:331-336 | id_slots 遍历全表 | C（行含 g3） |
| 7 | refined（宏格层） | canonical.ex:60（经 :14/:17/:233、observation.ex:314、claims.ex:20、edits.ex:105、prefabs.ex:72、tools.ex:431） | `for {cell, slots} <- state.refined, member?` | C；I（每次命中无行构件、构件许可判定、拆卸）；G |
| 8 | attachments | edits.ex:99-100 | for 全表（removed 为空也跑） | G |
| 9 | refined_owners 键 + macro_owners 值 | payloads.ex:208-210（经 edits.ex:113, 207；prefabs.ex:89, 498；log.ex:111；gm.ex:271） | live_instance_ids | G；S（每个整区回放条目） |
| 10 | attachments | attachment_ops.ex:259-265（经 edits.ex:219、prefabs.ex:539、attachment_ops.ex:226、payloads.ex:264、canopy.ex:37-38） | affected_attachments filter 全部键 | G（每笔 3–5 次） |
| 11 | attachments | attachments.ex:46-48（经 edits.ex:418、payloads.ex:265、canopy.ex:66） | l1_faces reduce 全表 | G（×2）；P（canopy L>0） |
| 12 | attachments | attachment_ops.ex:230；prefabs.ex:492 | `Map.keys(before) -- Map.keys(after)` | G |
| 13 | macro_owners（+instances/prefabs 查表） | canopy.ex:48-54（经 :10、:31） | candidates for 全表 | G ×2；P |
| 14 | damage | edits.ex:292-293 | `for … <- before.damage` | G |
| 15 | damage | tools.ex:484-498 | Map.values |> filter | G |
| 16 | thermal.sources | tools.ex:517-530 | Map.reject + reduce 全部热源 | G |
| 17 | attachments + damage | tools.ex:73-77 | MapSet.new(attachments) + reduce(before.damage) | G（经 damage_geometry）；I（每次附件提交） |
| 18 | attachments | prefabs.ex:196, 204-207, 268 | reduce/filter/for 全表 | I（玩家 prefab 每次） |
| 19 | instances | prefabs.ex:51-56 | group_by 全表 | I（prefab 拆/换每次 ≥3 次；GM move；parcel 每棵树） |
| 20 | macro_owners | prefabs.ex:71 | for 全表 | I（同上） |
| 21 | attachment_owners + attachments | prefabs.ex:92, 100 | Map.filter / Map.reject 全表 | I（clear_subtree） |
| 22 | instances | tools.ex:412-413 | `Enum.any?(state.instances, parent == owner)` | **I：每次工具命中微格构件** |
| 23 | attachments | canonical.ex:242（经 :248、claims.ex:19, 30、attachment_ops.ex:60） | for 全表找 aid | I（命中/拆附件） |
| 24 | attachments | attachment_ops.ex:204 | for 全表找 aid | I（拆附件） |
| 25 | macro_owners | payloads.ex:178 | Map.filter 全表 | P（hot list） |
| 26 | refined_owners | payloads.ex:180 | for 全表 + disjoint? | P（hot list） |
| 27 | liquid_units | payloads.ex:185-187 | for 全表 | P |
| 28 | attachments | attachments.ex:37-44（payloads.ex:188） | extract for 全表 | P |
| 29 | structure | payloads.ex:198-202 | for 全表（L1+） | P（L1+） |
| 30 | damage | observation.ex:184-187 | for 全表 | O（hot list） |
| 31 | macro_owners | observation.ex:207 | Map.keys 全表 | O |
| 32 | epochs | observation.ex:194 → property_observation.ex:19 | 整表放入再 Map.filter | O |
| 33 | food_receipts | observation.ex:58 | 整表放入快照（不过滤、不裁剪） | O |
| 34 | liquid_units / phase_inventory | W:915, W:916 | Map.filter 全表 | O（simulation_snapshot，hot list） |
| 35 | thermal.sources / semblances | observation.ex:87-88, 95-98 | for 全表 | O（simulation_snapshot） |
| 36 | material_balances | observation.ex:70-73 | Enum.sort 全表 | O（material/simulation snapshot） |
| 37 | damage ×3 | thermal.ex:66, 70, 71 | hot_rows / any? / electric(keys) | rebuild_work：I（每次附件提交、点火、认领）、M、S |
| 38 | damage | thermal_work.ex:128-130 | burning nil 时 for 全表 | T（rebuild 后首步） |
| 39 | attachments | thermal_work.ex:182-184 | attachment_cells nil 时 map 全表 | T（rebuild 后首步） |
| 40 | damage | thermal_work.ex:62；:69（heat_commit.ex:95） | `Map.keys(damage)` | T（rebuild 后首次结算/转化） |
| 41 | damage | thermal.ex:511-513 | `Enum.any?(damage, burning)`（短路） | T（每步，静默时） |
| 42 | attachments（+damage 查行） | circuit.ex:84（thermal.ex:234） | reduce 全部槽建导线图 | T（每个电路段） |
| 43 | placed_by + macro_owners + refined（逐槽） | claims.ex:89-93 | Enum.any? ×3 全表 | I（每次认领第二角） |
| 44 | liquid_units | claims.ex:100 | for 全表 | I（每次认领/释放）；M（author_regions） |
| 45 | material_balances | production.ex:232-244 | flat_map 全表（所有角色） | 每次死亡 |
| 46 | beacons | beacons.ex:73-77, 130-139 | 全表（小） | 登录 / 每次调谐 |
| 47 | phase_inventory + damage | W:761, W:766 | Enum.all? 全表 | M |
| 48 | damage（全部行重写入一笔事务） | catalogs.ex:92-93 | for 全表 | M |
| 49 | liquid_units | catalogs.ex:98 | wake_liquid(Map.keys) | M |
| 50 | damage | catalogs.ex:122；heat_commit.ex:234-238 | 校验/迁移 | S |
| 51 | refined | W:679 | refresh_structure(Map.keys(refined)) | S |
| 52 | 全世界 | W:680 → w/log.ex:263-266 | 同步全量检查点 | S（structure 非空） |
| 53 | attachments / liquid_units | w/log.ex:113-118, 124-126 | 每个整区回放条目 Map.reject 全表 | S |
| 54 | liquid_units | w/log.ex:399 | neighborhood(keys) | S（旧日志） |
| 55 | overlay / snapshots / damage / 各表 | w/log.ex:289-292, 298-301, 307-321 | 检查点构建（Task 内） | 每 60 s |
| 56 | 全量 DB 写 + 每区解码 | w/log.ex:333, 340-353 | finish_checkpoint（World 内） | 每 60 s |
| 57 | World 整堆 | W:1394 | full GC | 每次检查点 |
| 58 | attachments + damage | W:1266, W:1269 | external_size 全表序列化 | stats 调用 |
| 59 | entries 后缀 / 整份日志 | W:1316, W:1326, W:1330 | 遍历 / backend.replay | 订阅 / 诊断 |
| 60 | attachments | gm.ex:161 | Map.keys 全表 | X |
| 61 | liquid_units | gm.ex:233 | for 全表 | X |
| 62 | instances / attachment_owners / attachments | gm.ex:271-276 | prune_instances | X |
| 63 | macro_owners / attachment_owners / attachments / damage / liquid_units | parcel.ex:33, 36, 38, 40, 41, 53, 58, 186, 188, 278 | export/install | M |
| 64 | 订阅表 | observation.ex:37, 393, 413, 446 | 每笔遍历全部订阅者 | C（在线规模，不随世界增长） |

未计入：只按目录（材料表）规模的遍历（phases.ex:17, 23；beacons.ex:105；catalogs.ex:120）、在线规模（W:1560, 1563；thermal.ex:83, 382, 455；casting.ex:128）、有界 512（interactions.ex:81）、测试专用整表重建 `index_refined`（canonical.ex:28-35）。

---

## 8. 跨区域依赖清单（汇总）

| # | 依赖 | 读/写 | 跨度 | 现有分区边界 | 一笔是否必须多区原子 |
|---|---|---|---|---|---|
| 1 | ring 投影/失效 | 写多区载荷与条目 | ±1 格，最多 8 个 L0 区 | 无（按格扩张） | 是 |
| 2 | L1–L5 粗层与结构 | 写多层父格 | L5 区 = 32³ 个 L0 区 | 层级区域 | 是 |
| 3 | 液体活跃集流动 | 写全部活跃格 | 全世界活跃范围（每材料一笔） | `liquid_bounds` 全局盒、protection 持有者 | 是 |
| 4 | 排液/洪泛 | 写邻格 | 邻域 / ≤ max_cells | 同上 | 是 |
| 5 | 热传导/辐射/拟态/身体接触 | 写全部热行 | 全世界热域，视距 `view_range_cells` | protection 持有者 × 气候区 | 是（一次热提交） |
| 6 | 热账守恒 | 全局累计 | 全局 | 无 | 每笔改热事务写整份 |
| 7 | 电路网络 | 读全部附件 + 导体 BFS；写观察行/储能 | 连通即无上界 | protection 持有者（端点/接触） | 是（随热提交） |
| 8 | prefab 实例树 | 写树内全部格/实例/附件 | 任意（建筑、整园迁入） | 无 | 是 |
| 9 | 部件属性行 `{2, owner}` | 写一行，观察格跨区 | 随部件 | 无 | 与几何同笔 |
| 10 | 附件足迹/支撑/L1 面 | 写槽、读邻格 | 跨 2 宏格 → 可能跨区 | anchor 所在区 | 是 |
| 11 | 附件归属 `attachment_owners` | 随实例 | 随实例树 | 无 | 是 |
| 12 | 花草/附件失支撑 | 读上/邻格，写删除 | 相邻格 | 无 | 是 |
| 13 | 树冠呈现 | 读写多级祖格 + ring | 多级多区 | 无 | 是 |
| 14 | 工具/NPC/拟态/投射物射线 | 读射程内格 | 射程（工具 `range_macro`、魔法 `range_m`、投射物寿命×速度） | 无 | 只读；写目标 |
| 15 | 受保护区域 | 读 holder；写区域 | xz 矩形、y 无限 | 256 m 桶 | 认领事务 + 热重建 + 液体唤醒 |
| 16 | 角色账本 × 格编辑 | 写余额与格 | 角色 × 任意区 | 无（按 cid） | 是 |
| 17 | 施法取能 | 写施法者能量 + 蓄能石行 + 热源 | 射程内 | 无 | 是 |
| 18 | 信标传送 | 读两核心 | 任意距离 | 无 | 只读 |
| 19 | 全局 seq / 日志全序 | 每笔 +1 | 全局 | 无 | 是 |
| 20 | 订阅广播 | 每笔遍历全部订阅者再按盒过滤 | 全部在线 | 订阅盒 | — |

---

## 9. 推断与未核实

- `VoxelRegion.ParameterEvolution`（W:813-818）内部未逐行读，推断对 damage/attachments 为全表（它重标全部行，catalogs.ex:92 也重写全部行）。
- `Payload.encode`/`replace_*`、`CollisionSource`、`Structure`、`Liquid.step_transfers`、`ThermalDomain`（NIF）按输入规模工作，未发现读 World 全表；未逐行核。
- map 等值比较（edits.ex:365-366、observation.ex:258、tools.ex:554、thermal.ex:594）：BEAM 对同一 term 指针相等时快速返回（推断），表变动时最坏 O(n)。
- `decoded`、`region_bases`、`served_headers`、`liquid_adopted`、`food_receipts`、`material_supplies` 无淘汰/裁剪：常驻随“曾触及区域/历史”增长（事实：代码中没有删除路径，除换基底删 decoded）。这是常驻问题，不是单笔成本问题。
- 各全表扫描的实际耗时未测；10-15 事故（140 万细化槽、42 块叠石移除 ~9 s → 0.55–0.9 s）与“剩余线性项”的记载见 `docs/00-current-truth/design/server/voxim-runtime.md:11-12`。本报告 #1（每笔日志写整张 instances/attachment_owners）与 #56/#57（检查点在 World 内全量写 + 整堆 GC）未在该文档热点列表中出现。
