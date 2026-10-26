# M2a 独立评审（Fable）：页表与连续写回（m2a-page-store.md draft v1）

只读评审。源码 = master `acb401e7`（工作树仅多了本目录两份未提交的 .md），路径缩写同 `recon-state-persistence.md`：
W `world.ex`、Log `world/log.ex`、Ed `world/edits.ex`、Pl `world/payloads.ex`、Can `world/canonical.ex`、OL `overlay_log.ex`、
OLS `apps/data_service/.../overlay_log_store.ex`、LP `log_projection.ex`、Rep `replica.ex`、Att `attachments.ex`、Dmg `damage.ex`、
Pf `prefab.ex`；`world/` 下其余按文件名（`prefabs.ex`、`tools.ex`、`gm.ex`、`parcel.ex`、`liquids.ex`、`heat_commit.ex`、`thermal.ex`、
`canopy.ex`、`catalogs.ex`、`coarse_rebuild.ex`、`attachment_ops.ex`、`casting.ex`、`projectiles.ex`）。
"事实"直接来自源码；标"推断"的是由源码推出、未经实测的结论。按设计稿 §9 六个问题分节。

---

## Q1 页内容与归属规则（§3）

**1.1【严重】g=2 / g=3 行的 `micro` 在行生命期内会变；`attachment_owners` 的 `slot` 不是世界槽坐标。§3 表里这两条归属规则不成立。**

- `Canonical.property_state/3`（Can:357-364）对已存在的行做 `Map.merge(t, target)`——命中目标的 `micro` **覆盖**存储行的 `micro`。
  所有改 g=2 行的入口都用命中目标构造行：`tools.ex:227-231`（`Map.put(state.damage, Damage.key(target), target)`，target 即本次射线命中的微格）、
  `tools.ex:264-272`（toggle_switch）、`prefabs.ex:293-296`、`prefabs.ex:358-361`（`property_state(before, %{target | granularity: 2})`，
  target 来自 `changed_phase_micro`，prefabs.ex:337-341，取的是本笔变化的任一槽）。因此 `{2, owner}` 行的 `micro` = **最近一次命中/变更的槽**，
  跨页部件的整件行会随命中位置在页间迁移。g=3 同理：`Attachments.identity(slot, value)`（Att:6-7）的 `micro` 是**该槽**的 anchor，多槽附件按被命中/丢失的槽
  （`tools.ex:86`）。设计稿 §3 的"推断：g=2/3 行的 micro 在行生命期内不变"被源码否定。
- 更糟的一处：`tools.ex:461` `damaged = %{before | damage: Map.put(before.damage, Damage.key(target), target)}` 把 **`before`** 里的整件行换成命中目标再交给
  `prefab_reply(damaged, …)` → `Log.append_log(before = damaged, …)`（prefabs.ex:572）。§4 用 `before.damage[key]` 求"前页"时读到的是命中微格的页，
  不是原行真正所在的页 → 原页不被标脏，其持久元数据段里留下已拆部件的僵尸整件行（推断，需 §8 用例证伪）。
- `attachment_owners aid => {owner, slot}`：写入点 `prefabs.ex:470` `{g.owner, g.slot}`，`g` 来自 `Prefab.attachments/4`（Pf:339-342），`slot: g.slot`
  是**定义内附件组编号**（Pf:118-120 解码 `slot::32-little`），不是 `{kind, axis, anchor}`；parcel 搬运的也是这个编号（parcel.ex:128-130）。
  "`slot` 所在 L0 页"无法由记录算出。
- 建议：g=2 行与 `attachment_owners` 记录都归 **owner 实例 anchor 所在 L0 页**（`instances[owner].anchor`）。anchor 在实例生命期内不变：只在创建时写
  （Pf:303、Pf:355、parcel.ex:126），GM 搬移是清旧树 + 新 id 放置（gm.ex:212-218），无原地改 anchor 的写点（grep `anchor:` 全部写点核实）。
  g=3 行归 `attachment_owners[aid]` 的 owner anchor 页；**无主附件**（玩家直接挂的，parcel.ex:38、189-191 证明存在）归其现存槽集合中最小槽的
  `Attachments.region`（Att:35），槽集变化（部分失撑 `attachment_ops.ex:225` 起）时前后两页同标。这与父稿 P1 home 规则一致，M2b 不返工。
  注意同一笔删除实例时 `state.instances` 已无该 id，归属要用 `before.instances`（`append_log/3` 有 `before`）。

**1.2【中】L0 页"地形段复用 `Log.replay_entry(%{payload})` 装入"会让实例出现两个表示，且装入路径含全世界过滤。**

- `replay_entry`（Log:129-130, 144）`Map.merge(state.instances, p.instances)` 后 `Map.take(instances, live_instance_ids(state))`；
  `live_instance_ids` 扫全部 `refined_owners` + `macro_owner_cells`（Pl:209-211）。M2a 全量装入下只是 O(页数 × 世界) 的启动开销；
  对 M2b 按需装页是**正确性错误**——格尚未装入的页所持有的实例会被判死删除。
- 载荷里的 `instances` 只是"跨度内被引用的 id 及祖先"（Pl:178-182, 192），与元数据段"按 anchor 页的实例记录"并存 → 两个表示（I1）。
- 建议 §3 明确：元数据段的实例记录是唯一真值；装页只解 core 的 refined / attachments / liquid（Log:116-127, 134-143 那几段），不走实例合并与 live 过滤。

**1.3【中】粗层页（L1–L5）"coarse overlay + structure"：structure 不会被持久。** 现回放 L1+ kind1 只 `rebase_region`（Log:145-149），rebase 清空 `structure`
（Log:208），结构靠启动 `refresh_structure` 全量重算（W:686）。M2a 保留这一步（§2），所以粗层页实际只持久 coarse overlay；§3 表应改写为
"structure 为派生、不是页真值"，§7 验收字段清单也不应列 structure（列了会把派生物当真值比）。

**1.4【轻】边缘字段核对。**
- `prefabs` / `published` 在文件系统（`persist_prefab` prefabs.ex:596-608；parcel 的 `publish_definitions` 在提交**前**写 .vxpd，parcel.ex:231-242），
  不在页也不在全局行——§3 应写明"目录不进页存储，迁移等价不比较"。
- `liquid_active` 可在无提交时改变：`advance_liquid`（liquids.ex:355）先并入 `liquid_active` 再 `commit_liquid`，而 `apply_batch` 在
  `changes == %{}` 时不产生事务（Ed:192-205）。页元数据段按 state 写、方案 A 按 txn 判，此处二者不一致；下一笔 kind3 全量列表（Log:45）自愈，无害，记为已知偏差。
- `interaction_history/floor` 由 `Interactions.apply` 从 txn 派生（Log:50）✓ 全局行；`material_units_per_micro` seq=0 初值（W:677-680）✓；
  `thermal.config` 启动被资产覆盖（W:673、catalogs.ex:34-37），全局行里只是存档值，语义正确。
- 改 `thermal` 的全部路径都把整值放进 txn（Ed:309、prefabs.ex:563、attachment_ops.ex:96、casting.ex:368/375、heat_commit.ex:70、production.ex:93）✓。

---

## Q2 脏页判定方案 A（§4）

**2.1【严重】"所有真值改动都经唯一出口 `Log.append_log/3`"不成立。** 纯液体数量提交走 `Log.append_journal/2` 直写（Ed:366-375 → Log:30-31），
不经 `append_log`；这是液体流动的主路径（`advance_liquid` liquids.ex:362 → `commit_liquid` liquids.ex:283-302 → `apply_batch` → `append_journal`）。
钩在 `append_log` 会漏掉全部流动改动（liquid_units、liquid_active、格材料与所涉区域）。钩点必须是 `append_journal`（真正唯一的 WAL 出口），
或 `remember_entry`（所有成功提交与回放都经过，Log:49-55、Log:87）。注意日志表示与内存事务表示不同（journal 形态是 kind0 格 + `liquid_units` 增量，
内存形态是整区后像）：脏页函数要对两种形态产出同一页集，并在回放时也执行（见 Q4.1）。

**2.2【严重】方案 A 对 `property_states` 的"前页"依赖 `before` 真实。** `tools.ex:461` 传入的 `before` 已被改写（Q1.1）。按 Q1.1 改为 owner anchor 归属后，
行的页由键里的 owner 决定、与 `micro` 无关，此问题随之消失；否则 A 在这条路径上必漏。

**2.3【中】逐项核实不经 `append_log` 改真值的路径。**
- GM：六个操作全部复用 `Edits.apply_batch` / `Prefabs.prefab_reply` / `Prefabs.place_tree` / `Liquids.commit_liquid`（gm.ex:8-10；120、149、179、186、201、217），
  回执经 settlement 进 `txn.material_supplies` ✓。
- Parcel：`prefab_reply` → `append_log` ✓（parcel.ex:158、prefabs.ex:572）；`publish_definitions` 写 .vxpd 是文件系统（parcel.ex:237-239），非页。
- **CoarseRebuild**：直接调用 `Log.checkpoint_input / build_checkpoint / persist_checkpoint / finish_checkpoint`（coarse_rebuild.ex:68-70）整世界替换前缀。
  设计稿删掉整世界检查点（§1、§7 "去掉 W:680"）却没写 CoarseRebuild 怎么改——M2a 后它写出的 kind1/kind3 没有读者。须改为"重派生后把全部 L1+ 页
  （及 `dirty` 触及的 L0 页）标脏，开一个切点"，或明确停用并记录。
- 目录发布 `publish_property_catalog`：`append_log(state, next, txn)` ✓（catalogs.ex:103），`property_states` 含全部行 → 一次把所有有 damage 的页标脏，
  是 O(世界) 的合法维护切点，应在 §5 积压边界里点名由限速吸收。`attachments: migration.attachments` 整表替换（catalogs.ex:94）只有 `migration.slots`
  的后像进 txn（catalogs.ex:99-101）；若迁移改了 slots 之外的槽则 A 漏标（推断，取决于 ParameterEvolution 契约，建议在 §8 用例覆盖）。
- 热 flush：`Thermal.flush` 直接写 `state.damage`（thermal.ex:572-586），W:1399-1401 在热提交进行中处理任何其他消息前触发。切点限定 `thermal_run == nil`
  （W:1609）能排除它，但应同时断言 `thermal_work.domain.pending == false`（flush 在 `:done` 路径 thermal.ex:543 已调），否则页元数据段会带未提交行（I2）。
- 启动迁移：`migrate_component_damage`（heat_commit.ex:234-251）与 `environment_tolerance`（W:673）在回放后直接改 damage / thermal、不写日志。
  页存储下它们只随页变脏才落盘，必须幂等：migrate 只处理 `granularity == 1 and no temperature_kelvin` 的行，已迁移行为 no-op（推断幂等）。
- Projectiles / Casting / Beacons / Claims / Production：都以 `thermal_commit` / `append_log` 收尾（projectiles.ex:48、73、86、98、101；casting.ex:160、379；
  beacons.ex:152；claims.ex:104；production.ex:94、167、206、312、356、360）✓。`publish_prefabs` / `publish_prefab`（W:1142-1158）只改目录与文件 ✓。
- 结论：除 2.1 的 `append_journal` 分支外，没有绕开 WAL 的在线真值改动；离线/启动路径有 CoarseRebuild 与两处启动迁移。

**2.4【中】A / B 取舍。** 同意 A 做产品路径，但补两点：
- B 的"区域子表指针比较"对 refined / attachments / macro_owners / liquid 四类在 M1 已免费（Can:38-48、60-72、91-104、126-138；
  `changed_refined_cells/2` 的做法），每笔只比较 O(区域数) 个指针。若 Q3 按建议把 epochs / placed_by 改嵌套，B 对它们也免费；此时只剩 damage 靠索引。
  那样"页脏判定全用 B、A 只做全局行"比"A + 17+1 处事务字段完整性"更简单、更难漏。请作者在 Q3 定了存储形态后重新比较。
- 不论选哪个，TEMP-VERIFY 对拍与 §8 恢复等价都保留；不把 B 做成产品内运行时断言（AGENTS.md 禁止无当前失败的运行时防御）。

---

## Q3 逐页冻结（§5）

**3.1【严重】切点一致性未定义。** §5 "分批（每批页数与字节上限）发给写回进程"没说页输入从**哪个状态**抽取。若分批跨多个 World 回合从当前 `state` 抽，
不同页反映不同 seq，切点不是一致快照，§6 "不依赖日志重放幂等"的前提崩塌（跨页 prefab、owner 记录与槽分页、全局行与页的账目对应）。
BEAM 持久化数据结构下，在同进程保留切点时的 `state` 引用是零拷贝（Log:299-312 的 `checkpoint_input` 之所以贵，是 `Task.async` 把闭包复制到任务堆，
W:1613）。须写明：切点时绑定 `frozen = state`，所有批次从 `frozen` 抽取；`frozen` 保留到 D_C 抽完，切点后被改写的那部分结构才是双份（在途预算）。
或者在切点回合一次抽完 D_C 全部页输入（2 s 节拍下脏页通常个位数到几十，4 份 8 窗口 ≈8 笔/s 也只触及十几页）。

**3.2【中】页输入闭包比 §5 列的多，且粗层页不是"本页 + 26 邻页"有界。** `payload_bytes`（Pl:66-123）→ `with_refined`（Pl:152-195）→ `Canopy.project`
（canopy.ex:9-27）实际读取：
- `overlay_regions[key]` 及这些格的 `overlay`（含邻区 ring 格）；`region_bases` **本页 + 26 邻页**（`neighboring_bases` Pl:128-135，用于 `ring_overrides`，
  邻页基底是完整 66³ Payload，只需 ring 面）；`decoded[key]` / `source.read`；`snapshots` 成员判断（Pl:77）；
- 27 区 refined 子表 + `refined_encoded` 备忘（Pl:160-176）；27 区 macro_owners（Pl:178-179）；**`refined_owners` 整表扫描**（Pl:181，O(全部部件)，
  应改为由跨度内槽的 owner 直接得出，结果相同）；`Refined.ancestors(state.instances, …)`（Pl:182）——祖链可在任意页；27 区 liquid（Pl:186）；
  `attachments_around_region`（Pl:189）；
- Canopy：`candidates` 读 `span_regions(level, region)` 的 macro_owners（canopy.ex:52-64）——L0 是 27 区，**L5 覆盖 ≈34³ 个 L0 区**；还读 `instances`、
  `prefabs[…].definition.presentation_bindings`（全局目录）、锚点格 `cell_value`、L1 的 `attachments_near_parents`、`structure`；
- L1+：`state.structure` **整表过滤**（Pl:198-203），O(全部结构格)；
- 头部 `state.seq` / `state.cv`（Pl:102-103）：写回进程编码必须传切点 C，不是编码时的当前 seq。

结论：L0 页"本页 + 26 邻页"大致成立，需补 region_bases ring、实例祖链、`refined_owners` 改法、bindings 目录；L4/L5 页输入 = 该粗区下全部 macro_owners / 实例 / 结构，
不是有界的 27 页（父稿把树冠段持久化放到 M2b 正是为此）。缓解：L4+ 载荷常驻缓存（`@resident_level 4` Pl:16、366-383），"缓存字节直接带上"覆盖大多数；
L1–L3 可能被 LRU 淘汰。建议 M2a：粗层页只用 World 内缓存字节，缓存缺失时在 World 内物化（现状 O(范围)），不要求写回进程复算；给 `structure` 加区域索引
（同 M1 四个索引的形状），去掉整表过滤。

**3.3【中】epochs：选嵌套存储，不选索引。** 理由：(a) 索引 +1 GB@4 份是把 469 万 × 4 个 cell 键复制一遍，嵌套 `%{region => %{cell => seq}}` 不增内存、
小 map 更省；(b) M3 淘汰必须按页卸载 epochs / damage / placed_by，嵌套是最终形态，索引是一次性弃物；(c) 嵌套让 B 对 epochs 免费（Q2.4）。
访问点：grep `.epochs` 共 10 处，真值读写只有 Can:322、tools.ex:495-503、tools.ex:565、parcel.ex:213、Log:420、W:569，其余是观察/Replica 只读。
`damage` 不同：键 `{2, owner}` / `{3, aid}` 不含坐标（Dmg:340-342），嵌套后按键查找要先解 owner → anchor，91 处访问点改造面大 → damage 用索引
（23.5 万键）合理。`placed_by` 键是 cell、13 处，建议与 epochs 同形嵌套。

---

## Q4 多版本页 + 安全前缀（§6）

**4.1【严重】崩溃后脏页表没有重建。** `dirty_pages` 在内存。崩溃在 C 写一半 → 恢复 = 上一前缀 + 日志后缀（含 C_prev..C 的全部事务），但 §7 回放后缀没有
"把后缀触及的页重新标脏"。若不标：这些页永不重写，下一切点 C2 发布并 `DELETE … seq <= C2` → 改动**永久丢失**（ARIES 重做阶段重建 dirty page table 就是为此）。
修正：脏页函数在回放每笔时同样执行（放进 `remember_entry` Log:49-55 或 `replay_log` Log:84-89）；M2a 全量装入下代价只是 O(后缀)。
§8 必须加"崩溃 → 重启 → 切点 → 截日志 → 再重启"双重启用例；单次重启永远通过，测不出。

**4.2【中】孤儿版本未处理。** C 写一半留下的 `cut_seq = C` 行：(a) 恢复后 seq 从日志末尾继续，若下一切点又落在 C（无新事务）或后台删除未完成，
主键 `(cv, level, rx, ry, rz, cut_seq)` 冲突；(b) 这些行内容其实是"seq = C 时的正确状态"，safe_prefix 越过 C 后按 max 规则可见——只有在 4.1 修正、
该页此后真的被重写时才被覆盖，否则恰好正确，但这是巧合不是设计。建议：启动时删除 `cut_seq > safe_prefix` 的行（或写回用 `ON CONFLICT DO UPDATE`），写进 §6。

**4.3【严重】旧游标的"完整补丁"随整世界检查点一起消失，§6 没有替代。** 现在 `entries` 常驻一条检查点事务投影（含全部 snapshot 区域后像，Log:69-73、384-385），
`subscribe`（W:1319-1328，只过滤 `seq > have_seq`）对任意旧 `have_seq` 都能靠它补齐；`serve_item` → `LogProjection.since`（Pl:44；LP:36-52）
遇到区域替换返回 `:region` → 整载荷。页方案没有这条事务：若 `entries` 按安全前缀退休（父稿 P3），`have_seq` 早于保留下限的订阅者会**静默**只收到保留窗口内的事务，
`since` 也返回不完整列表而不是 `:region`。须加显式规则：`have_seq < retained_floor` → subscribe 按 box 发整载荷（或拒绝、要求重取快照），
serve_item 直接回 payload；父稿 P3 末已有此语义，m2a 漏了落地点。另 `schedule_checkpoint` 的触发条件 `map_size(entries) > 1`（Log:77-82）要换成脏页 / 定时。

**4.4【中】Replica 与 `entries` 的保留窗口不应绑定切点节拍。** `Rep:201-214` 保留"上一检查点之后"的 deltas（滞后一个检查点），60 s 节拍下窗口 60–120 s；
改发安全前缀后窗口缩到 2–4 s，Scene 移交切点早于 4 s 即被拒。退休通知与 `entries` 退休都应取 max(安全前缀之后, 最近 N 秒/字节下限)，Replica 侧下限独立可配。

**4.5【中】写回进程崩溃 ≠ 节点崩溃。** §6 只讲节点崩溃。写回进程死亡时 World 的"在途"页收不到确认；要 monitor 并把在途页放回脏集，重开切点。
不要用 link 让 World 一起死（等于整节点重启）。

**4.6【轻】I3 与表结构。** "切点串行 + 只新增版本 + 完整发布后才可见"下 I3 成立；"后台删 `cut_seq < C`"只针对 C 写过的页 ✓；
`DELETE voxel_overlay_log WHERE content_version = $1 AND seq <= C` 走唯一索引 `(content_version, seq, ordinal)`（Mig:26；OLS:42-47 已有同形谓词）✓。
全局行每 2 s 整行写：`material_supplies`（含全部 parcel / gm / beacon 回执）、`food_receipts` 随历史增长（recon §1.3），建议"本切点内有全局键变化才写"，
并在 §8 记每分钟全局行字节。

**4.7【轻】`entries_after`（W:1332-1341）对只剩投影的事务从 `backend.replay` 补正文；前缀删除后 `seq <= safe_prefix` 的正文不存在。只影响测试与诊断，
依赖它的用例要只取 `seq > safe_prefix`。

**4.8【轻】World 内不再 rebase。** 现 `finish_checkpoint` 只在无并发后缀时换基底（Log:364）；页方案写回后若不换基底，World 内 `overlay` 的稀疏编辑直到重启才被吸收进
`region_bases`。M2a 可接受（M3 淘汰 / 重装解决），记为已知。

---

## Q5 拆成 M2a / M2b（§2）

**5.1【中】拆分合理，但按 §3 现稿 M2b 会返工两处。** (a) g=2 / g=3 / `attachment_owners` 的归属页（Q1.1）——改成 owner anchor 后与父稿 home 规则一致，不返工；
(b) 装页复用 `replay_entry` 的实例合并 + live 过滤（Q1.2）——M2b 按需装页必须换掉；若 M2a 一开始就"元数据段实例为真值、装页不做 live 过滤"，不返工。
身份定位表（id → home 页）可由元数据段一次导出，实例记录已含 anchor（Pf:303），不需额外格式。

**5.2【轻】格式本身。** `format: 1` 独立版本号、页键 `(cv, level, rx, ry, rz)` 与父稿一致 ✓。元数据段按键存"本页子表"即可（已是），不要再做 ETF `compressed`
以外的自定义编码，M2b 读取闭包只需按键取段。

**5.3【轻】门槛归属。** M2a 保留 `refresh_structure` 全量（W:686）、`prepare_component_cache` 全量（W:689），"启动已按需装页"由 M2b 兑现——应同步写进父稿进度日志，
不只在 m2a 内部说明；父稿"M2 开工前闭合 P1 home 汇总、P4 接纳复核与粗层父格输入"三项在 m2a 里应标注哪些推到 M2b。

---

## Q6 测试与验收（§8）

**6.1【严重】缺双重启用例。** "崩溃在第 k 批 → 重启 → 再提交并等一个切点发布（截日志）→ 再重启 → 逐字段相等"。证伪 Q4.1；单次重启 = 上一前缀 + 后缀，永远绿。

**6.2【中】缺"切点后并发提交"用例。** 切点 C 后立刻连续提交（含跨两页的 prefab 放置 / 拆除），分批写回期间持续提交，再崩溃或正常停机重启；
期望 = C 状态 + 后缀。证伪 Q3.1。

**6.3【中】缺跨页整件行迁移用例。** 同一跨页部件在两页各命中一次、再在另一页敲死叶部件（`tools.ex:440-467` 路径）→ 重启后只有一行 / 一枚墓碑、HP 正确；
多槽附件跨页同理。证伪 Q1.1。

**6.4【中】缺纯液体流动用例。** 放水让其跨区流动（走 `append_journal` 分支）→ 切点 → 停机 → `liquid_units` / `liquid_active` / 格材料相等。证伪 Q2.1。
§8 现列的"液体"是通过放挖类入口描述的，未必走到 Ed:366-375 分支，要点名。

**6.5【中】缺旧游标用例。** 订阅者 `have_seq` 早于保留下限 → 必须收到整载荷或显式拒绝，不得静默缺事务；`serve_item` 同理。证伪 Q4.3。
现有 `subscribe`/`serve_item` 测试都在 60 s 窗口内，不会触发。

**6.6【中】"恢复等价"的比较对象。** 去掉派生物（structure、各索引、缓存、`refined_encoded`），加 `attachment_serial`、`interaction_history/floor`、`thermal` 整值、
`protection`（含 index 的重建相等）、`seq`；并比较**按区域物化字节**（`Payloads.canonical_region_bytes`，CoarseRebuild 已有先例 coarse_rebuild.ex:103-108、34、64-65、72-73），
覆盖 ring / canopy / 载荷头一致性。迁移验收同一清单。

**6.7【轻】方案 A 对拍的成本。** 若 Q3 选嵌套，B 的全量比较是 O(区域数) 指针比较，每笔都做可行；若 epochs 保持平铺，4 份下每笔 O(世界) 比较会拖慢全量测试，
建议只在小世界夹具做，大世界用抽样。

**6.8【轻】基准与崩溃面。** §8 基准加"最老脏页年龄分布""每分钟全局行字节""`voxel_page` 行数与孤儿行数"；崩溃用例加写回进程单独崩溃（Q4.5）。
一次性迁移本身是 O(世界) 页写入（4 份 ≈580 L0 页 + 粗层页），应限速并记录峰值与时长；如园源库只读、隔离库跑 ✓。

---

## 总评

不能按稿直接开工：方向正确（逐页、只写脏页、多版本 + 安全前缀、不依赖幂等），但有 4 个会丢真值或破坏一致性的缺口，最少改 5 处：
1. §3：g=2 / g=3 行与 `attachment_owners` 改归 owner 实例 anchor 页（无主附件按最小槽页）；删去"slot 所在页"与"micro 不变"两条；装页不复用实例合并 / live 过滤。
2. §4：脏页钩点放到 `append_journal`（或 `remember_entry`），回放后缀时同样执行以重建脏页表。
3. §5：写明页输入从切点时绑定的 `frozen` 状态抽取（零拷贝）；闭包补 region_bases ring、实例祖链、bindings；`structure` 加区域索引；粗层页用缓存字节、缺失在 World 内物化。
4. §6/§7：孤儿版本清理；`have_seq < 保留下限` 的显式整载荷 / 拒绝；Replica 与 `entries` 保留下限与切点节拍解耦；写回进程崩溃的在途回收；CoarseRebuild 的替代路径。
5. §8：加双重启、切点后并发提交、跨页整件行、纯液体路径、旧游标五个改前红的反例。
epochs / placed_by 选嵌套存储，damage 用索引；若嵌套落地，重新比较"B 做页脏判定、A 只做全局行"。M2a / M2b 拆分、PG 表形、I3 论证可按稿。
