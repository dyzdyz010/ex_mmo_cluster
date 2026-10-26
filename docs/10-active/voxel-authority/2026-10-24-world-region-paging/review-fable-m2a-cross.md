# M2a 交叉评审（Fable）：设计稿 v2 + astra 首轮意见

只读评审。源码 master `acb401e7`；路径缩写同首轮：W `world.ex`、Log `world/log.ex`、Ed `world/edits.ex`、Pl `world/payloads.ex`、Can `world/canonical.ex`、
OL `overlay_log.ex`、OLS `data_service/.../overlay_log_store.ex`、Att `attachments.ex`、Pf `prefab.ex`、Rep `replica.ex`、P `mmo_contracts/.../voxel/payload.ex`，
其余 `world/` 下按文件名。"事实"来自源码；"推断"标注。

---

## 1. 对 astra 首轮（review-astra-m2a.md）的异议与严重度校正

| astra 条目 | 我的判断 | 依据 |
|---|---|---|
| A2.2【严重】`before` 不是上一已提交状态（热源、`liquid_active`） | **同意，且我首轮漏了 `liquid_active` 这一处**。`:liquid_commit` 先清空再步进（W:1430-1433），无变化不提交（Ed:192-205） | v2 §4.2 用 committed 副本是对的；语义与现行日志恢复一致（Log:426 从最后一笔 kind3 取全量列表），不是新语义，见 §3 Q3 |
| A1.3【严重】VXR 实例投影会覆盖 home 记录丢 `placed_by` | 同意，比我首轮 F1.2 更准确（`refined.ex` 不编 `placed_by`，`prefabs.ex:453` 写入） | v2 §3 页存完整记录已解决 |
| A3.4【严重】"先只计量再限流"取消资源上界 | 严重度应为【中】：v1 的"先计量"符合 AGENTS.md"只处理当前问题"，且父稿 P3 的上限承诺可在实测后接。v2 已实现在途窗口，不再有争议；但 v2 的接纳行为需分级（见 Q4） | — |
| A5.2【严重】"表空才迁移"不能覆盖半途崩溃 | 严重度应为【中】：迁移一次性、只在隔离库、可重跑；v2 §7 已改为按已发布前缀判定 | — |
| A2.3 `changed_refined_cells` "并非 O(实际脏页)" | 【轻】：它是 O(区域数) 的指针比较（145–580 项/笔，µs 级），不影响结论 | Can:38-48 子表换新 |
| A6.3 缓存命中保留旧 header seq、canonical 另行盖序号 | 同意（Pl:69、Pl:420-424）；v2 不再存 VXR，此项转为 §8 的"规范化真值"比较 ✓ | — |
| A4.3 REPEATABLE READ 一致读、cv 约束、渐进删除 | 同意【中】；v2 §6.2 已吸收 | OLS:42-47、118-121 |

对自己首轮的更正：F3.3 已被 v2 采纳为"epochs/placed_by 嵌套、damage 索引"✓；F1.1 的"无主附件最小槽"被采纳，但需补两条依据（见 Q2）：槽换算必须 floor_div，"同一附件的槽都在锚点一宏格内"要落到 `Attachments.footprint`（Att:13-20，size ≤ micro_resolution）。

---

## 2. 按 v2 §9 六问逐条

### Q1 v2 是否正确吸收；有无吸收错或新引入的问题

**1.1【严重】新引入：装页不维护 `snapshots`，重启后"无 base、无 overlay、但有细节"的区域会被按 baseline 原始字节服务，几何消失。**
事实：`payload_bytes`（Pl:74-82）在 `overlay_regions[key]` 为空、`key ∉ snapshots`、26 邻区无 `region_bases` 时直接返回 `source.read` 字节，不走 `with_refined`，
refined / attachments / liquid 细节全部不进载荷。`snapshots` 今天只由四处填充：后像（Pl:225）、液体回放（Log:103）、结构条目（Log:161、Pl:337）、rebase（Log:218）。
v2 §6.2 装页走 `put_overlay / put_refined / put_attachments / put_liquid / put_macro_owner`，没有任何一步加 `snapshots`。
反例（推断）：prefab 放在从未编辑的地形区 → 该区 `base` 缺省、overlay 空、refined 非空 → 切点发布 → 重启 → `serve_item` / `canonical_snapshot` 回 baseline 字节；
碰撞 `canonical_chunks` 直接读 refined（Pl:441-453）仍正确，所以客户端会看到"能撞到但看不见"的建筑，直到该区再被编辑。
现在不会发生，因为每个出过后像的区重启时都经 kind1 回放 → rebase → `snapshots`（Log:149、218），而 v2 页方案在线不再 rebase（我首轮 F4.8）。
修正：装页时"页行存在 ⇒ `snapshots.put(key)`"（页存在本身就是 I4 的"曾编辑"证据），并在 §3 写明 `snapshots` 与页的关系；
§8 判定器的比较集合"每个有 base 或 overlay 的区域"同样漏掉这类区域，应改为"页存在的区域"。`coarse_rebuild.ex:24, 99` 仍读 `snapshots`，一并核对。

**1.2【中】§3 home 换算 `div(anchor, micro)` 对负坐标错。** `div` 向零截断；项目既有换算都用 `Integer.floor_div`（`Prefab.macro_slot` Pf:416-420、`Attachments.region` Att:35、
`Canonical.region_of` Can:288）。应写成 `Prefab.macro_slot(anchor) |> elem(0) |> region_of()`。Voxim Testing.md 把负坐标列为关键不变量，§8 装页次序用例应含负坐标 home。

**1.3【中】§4.1 "prefab_instances（整表，变了才写）"在线拿不到。** 在线 `remember_entry` 收到的是调用方的内存事务（Ed:335、prefabs.ex:574 的 `txn`）；
`prefab_instances` / `attachment_owners` / `liquid_active` 是 `append_log` 内部由 `attachment_metadata` 加进**日志副本**的（Log:22-26、38-46），内存事务没有这些键。
回放形态才有。应改为与 `committed_instances` / `committed_attachment_owners` 引用做指针比较（同 §4.1 对 sources 的做法），不同时才 diff id → 新旧 home 页。
同理 `committed_sources` 应取 `txn.thermal.sources`（事务里的已提交值），不要取 `state.thermal`——提交后 `state.thermal` 可能已被下一拍热步进推进（thermal.ex:526-538 在 tick 内改写）。

**1.4【中】§3 base 段直接存 `%Payload{}` 结构体的 ETF，把 Elixir 结构体字段集变成持久格式。** `Payload` 有 16 个字段（P:19-41），任何字段增删都要 bump `format` 并迁移。
建议 base 段用 `Payload.encode(去细节 payload, %{}, C, cv)` 的 VXR 字节：已有 v4–v13 版本化与 `Payload.decode`（Log:110 装入同一路径），cells 二进制同样 refc，
编码仍只读本页、不违反 §3 原则。不阻塞开工。

**1.5【轻】§0 对 F3.2 / A3.1 的处理正确但口径要写清。** 页不存 VXR 后，写回不再需要 27 页闭包 ✓；但服务路径 `payload_bytes` 的闭包与整表扫描
（Pl:181 `refined_owners`、Pl:198-203 `structure`、canopy 34³ `canopy.ex:52-55`）仍在 World 内每次后像 / 服务时发生，属父稿 P7，应在 §2 "不做"里点名，避免读成"已消除"。

**1.6【轻】§4.3 CoarseRebuild 的空维护事务有先例**（`commit_casts` casting.ex:156-160，空 entries / coarse 的事务）✓；但其现有断言围绕 `finish_checkpoint`
（coarse_rebuild.ex:61-65、71-73 `=== metadata`、字节相等）要改写为"切点发布后字节相等"。

### Q2 页存原始真值（§3）是否完整；与 M2b 衔接；无主附件 home

**2.1【中】完整性：对照 `checkpoint_input`（Log:299-312）与 kind3 白名单（OL:67），页段 + 全局行覆盖了全部真值。** 派生物 structure / canopy / 各索引 / 缓存不进页 ✓；
`properties` / prefabs / `published` 为资产 ✓；`protection` 只写 regions、`Protection.apply` 重建桶（Log:434）✓；`liquid_active` / `sources` 用 committed 副本 ✓。
唯一要补的是 1.1 的 `snapshots`（它是"区域曾编辑"的真值性标记，不是可丢弃派生物——丢了会改变服务结果）。

**2.2【中】与 M2b 衔接：可以。** 页段都是 M1 子表或 home 归属，按需装页 = 取一页 + 各 `put_*`，次序无关 ✓；身份定位表可由 `instance_pages` / `aid_pages` 索引导出 ✓。
注意服务闭包仍是 27 页（`neighboring_bases` Pl:128-135 读邻页 base 做 ring），这是 M2b "读取闭包准备"的对象，与页闭包无关，v2 口径一致。

**2.3【中】无主附件 home 规则可靠，前提可由源码证明。** `Attachments.footprint`（Att:13-20）从 anchor 展开、size ≤ micro_resolution，所以同一附件的槽都在 anchor 起一宏格内；
M1 据此用 `attachments_around_region(state, Attachments.region(slot))` 找整件（tools.ex:78-81）。从 g=3 行的 `micro`（某槽 anchor）查本区 + 邻区即可找全现存槽、取最小槽 ✓。
部分失撑使最小槽变化 → 新页由 state 算、旧页由 `damage_pages[key]` ✓（v2 已写）。有主附件整件消失时 `attachment_owners` 同笔 drop（tools.ex:84），行为墓碑，旧页走索引 ✓。
g=4 逐槽行按 `Damage.macro(row)`（micro = 槽 anchor，不变）✓。建议把上述两条依据写进 §3，不留"推断"。

**2.4【轻】实例记录含 `placed_by`（prefabs.ex:453），页存完整记录即可；父子链跨页只是 id 引用 ✓。**

### Q3 `remember_entry` 判脏 + 页索引（§4）是否覆盖全部路径；`committed_liquid_active` 是否可接受

**3.1 覆盖：成立。** 所有 17 处 `append_log` / `append_journal` 成功后都紧随 `remember_entry`
（attachment_ops.ex:103、beacons.ex:154、casting.ex:161/382、claims.ex:106、catalogs.ex:105、Ed:199/335、heat_commit.ex:76、prefabs.ex:574、production.ex:96/169/208、
tools.ex:244/276/410），回放经 Log:87 ✓；`acknowledge_noop` 不产生事务 ✓。`remember_entry` 返回 state，解决了 astra A2.1 指出的"`append_log` 回 `:ok` 无法改 state"。

**3.2【中】两种形态的推导要按 1.3 修正。** 内存形态的纯液体事务含后像但不含 `liquid_units` 键（Ed:374-375 才加进 journal）→ 页集靠后像头 ✓；
`liquid_active` 的变化靠 `state.liquid_active` 与 `committed_liquid_active` 比较，不依赖 txn ✓；但 instances / attachment_owners 不能靠 txn 键（1.3）。

**3.3【中】`committed_liquid_active` 语义：可接受，不必改为无几何事务。** 现行从日志恢复本来就取最后一笔 kind3 的全量列表（Log:426），W:1430-1433 清空再步进、无变化不提交的情形今天也不进日志；
只有"检查点恰好冻结了在线值"这一偶然路径不同。保留 `Liquid.neighborhood` 兜底（Log:426）。恢复后少几个待步进格的后果是水在下一次相邻改动时才继续流，与父稿 Q1"不补算"方向一致。

**3.4【轻】epochs / placed_by 嵌套：`observation.ex:194` 整表 `state.epochs` 给属性快照，改为展开嵌套表后每次窗口快照 O(世界)——与现状相同，N1 处理 ✓。**

### Q4 `frozen` 冻结、在途窗口与接纳边界（§5）

**4.1 一致性：成立。** `frozen = state` 同进程零拷贝，全部批次只从 `frozen` 抽 ✓；全局行最后一批从 `frozen` ✓；开切点条件 `thermal_run == nil and domain.pending == false`
（flush 的触发条件正是 `pending: true`，thermal.ex:570、W:1399-1401）✓。

**4.2【中】`frozen` 会钉住整份 state，含 `payloads` / `decoded` 缓存与各索引。** 在途期间缓存被替换的旧字节仍被 `frozen` 引用，最坏双份缓存上限（512 MiB）。
建议 `frozen = Map.take(state, 页段所需键)`（与 `checkpoint_input` Log:299-312 同法，但不送出进程所以不复制），只钉住真值。

**4.3【中】写回进程崩溃后"重开切点"会主键冲突。** §5.3：DOWN 时 D_C 并回 `dirty_pages`、重开切点；若其间无新事务，新切点 C' = C，而 C 的已写页行（`cut_seq = C`）仍在表中
（孤儿清理只在启动 §6.2）→ INSERT 冲突 → 写回进程再崩 → 循环。修正：DOWN 处理里先删 `cut_seq > P` 的行（与启动同一清理），或 INSERT 用 `ON CONFLICT (…) DO UPDATE`（同一 C 的页内容相同，幂等）。

**4.4【中】`{:error, :persist_backlog}` 作为最后一级合适，但要分级并核实到客户端的通道。** 建议顺序：窗口满 → 停抽取（已写）；软上限 → 暂停热 / 液体步进（内部，不可见）；
硬上限 → 拒玩家 / GM / parcel 意图。两点需核实：(a) Gate 对意图拒绝原子的编码——我在 `mmo_contracts` 没找到 reason 枚举表（grep `tool_cooldown` / `out_of_reach` 只在
voxel_region 与 npc_server），推断按原子透传；若是枚举式则新增原子是协议改动（Hello 41）；(b) `publish_property_catalog` 在线执行会一次让全部有 damage 的页变脏（catalogs.ex:90-103），
必然触顶硬上限并拒绝玩家数十秒——§4.3 应写明这是预期，或让维护提交只在无玩家窗口执行（parcel 已如此，parcel.ex:15）。

**4.5【轻】每回合一批 + 5 ms 预算：dense 如园页（refined 子表数百格、epochs 子表数万条、damage 千余行）构造页段并发往写回进程会复制非 refc 部分，单页数百 KB ETF 量级，ms 级；
按 `batch_bytes` 而非页数限批是对的（v2 已有）。**

### Q5 发布、孤儿清理、渐进删除、订阅 / Replica（§6）是否闭合 I1–I3

**5.1 闭合判断：I1 ✓（页只从已提交的 `frozen` 写，唯一在线写者 World）；I2 ✓（4.1 的切点条件）；I3 ✓（版本只新增、`safe_prefix` UPDATE 带 `WHERE seq < C`、C 严格大于已发布前缀、启动清孤儿）。**
REPEATABLE READ 单事务读 ✓；渐进删除保留每页最新可见版本、cv 约束 ✓。例外是 4.3 的写回崩溃路径。

**5.2【中】旧游标的合成"完整快照"不能在 World 回合内生成并发送。** `subscribe` 线格式只编码 seq / entries / coarse（Log:57-60 `@projection`），属性行不走这条通道，所以合成事务只需
盒内区域载荷 + coarse ✓；但按盒 `payload_bytes` 是 O(盒)，如园窗口实测 262 MB / 8–13 s（父稿 M0），在 World 回合内做会卡住所有提交。应像 `canonical_snapshot`（W:1344-1362）那样
World 只取字节、交 CanonicalFeed / 调用方进程编码发送。

**5.3【中】`serve_item` 的判断点要落在 `LogProjection.since` 之前。** 今天旧游标靠 `since` 遇到区域替换返回 `:region`（LP:47-48）兜底；`entries` 按安全前缀退休后保留窗口只有秒级，
`:region` 几乎不再出现，`have_seq < floor → payload` 必须在 Pl:44 之前显式判断（v2 写了"同理"，实现点要点名）。

**5.4【轻】Replica 按"发布时间 ≥ 60 s 的最新前缀"发退休通知 ✓，保持 Rep:201-214 的窗口量级；`canonical_deltas_after` 显式失败（Rep:108）✓。`compact/1` waiters 改按发布的 C 回复
（现按 `checkpoint.transaction.seq`，W:1411）✓。`schedule_checkpoint` 的 `map_size(entries) > 1` 条件（Log:79）替换为脏页 / 定时，要写明。**

### Q6 §8 是否足以证伪；能否按 v2 开工

**6.1 矩阵覆盖了两份首轮的反例 ✓**（纯液体 journal、热源删除、活动集变空、跨页整件行、无主附件、双重启、并发切点、装页次序、读者 P−1/P/P+1、新 VM、对拍、迁移等价、真实隔离 PG）。

**6.2【中】缺 1.1 的反例。** "prefab 放在未编辑地形区 → 不再编辑 → 切点发布 → 重启 → `serve_item` / `canonical_snapshot` 字节与停机前相同"。§8 判定器的比较集合必须是"页存在的区域"，
否则这个用例在判定器层面就被漏掉。

**6.3【中】缺两个崩溃面：** 写回进程崩溃且无新事务 → 重开切点（4.3 主键冲突）；`publish_property_catalog` 在线触发 O(世界) 切点 + 接纳边界（可与"受控慢写回"合并）。

**6.4【中】写放大没有接受线。** §8 只写"写库字节与改动量成正比"。页粒度 = 整区全部段，2 s 节拍下持续编辑同一密集页每 2 s 重写一次（1 份如园 145 区按现 kind3 35 MB + kind1 11.8 MB 估，
平均每区 ≈320 KB 压缩后；推断），8 窗口负载每分钟写库可能高于今天的常量 47 MB/min。建议：开工前在 1 份隔离库量一个密集页的 ETF 字节；§8 记"每分钟写库字节 vs 47 MB/min"；
给切点加"脏页最小年龄"合并旋钮（父稿 P3 允许更长恢复后缀换更少 I/O）。ring 过标（后像键 `region_keys` 在区边界格最多 8 区，LP:7-13）只在边界格发生，约 2/64 概率/轴，不是主因。

**6.5【轻】"重启后先比较、再允许热 / 液体继续演化"需要启动时不自动 `Thermal.wake` / `schedule_liquid` / `Projectiles.wake`（W:695-697）→ Test-only opt。**
**6.6【轻】真实 PG 用例不用全表 `reset` ✓；DataService 需新增 PageStore 与迁移文件（现只有 `20260907000001_create_voxel_overlay_log.exs`）。**

---

## 3. 开工前必须改的最少条目（6 条）

1. **【严重】§3 / §6.2 / §8**：装页时"页行存在 ⇒ `snapshots.put(key)`"；判定器比较集合改为"页存在的区域"；加 6.2 反例。（证据 Pl:74-82；现填充点 Pl:225、Log:103/161/218）
2. **【中】§3**：home 换算用 `Prefab.macro_slot/1`（floor_div），装页次序用例含负坐标。（Pf:416-420）
3. **【中】§4.1**：instances / attachment_owners 改为与 `committed_*` 引用指针比较后 diff；`committed_sources` 取 `txn.thermal.sources`。（Log:22-26、38-46；thermal.ex:526-538）
4. **【中】§5.3**：写回进程 DOWN 后先清 `cut_seq > P` 再重开切点，或 INSERT `ON CONFLICT DO UPDATE`。
5. **【中】§6.3**：合成完整快照由 Feed / 调用方进程发送，World 只取字节；`have_seq < floor` 的判断点写在 `serve_item` 的 `since` 之前。（W:1344-1362；Pl:44）
6. **【中】§8**：开工前量 1 份如园一个密集页的 ETF 字节，基准记"每分钟写库字节 vs 现状 47 MB/min"，切点加脏页最小年龄旋钮。

实现中带着做（不阻塞）：【中】base 段改 VXR 字节（1.4）、`frozen` 只 take 页段键（4.2）、接纳分级与 reason 通道核实（4.4）、CoarseRebuild 断言改写（1.6）；
【轻】§2 点名服务路径闭包仍在（1.5）、N1 的 epochs 展开（3.4）、启动不自动唤醒的 Test-only opt（6.5）、PageStore 迁移文件（6.6）。

---

## 总评

v2 正确吸收了两份首轮的全部【严重】项：归属改 home、判脏改 `remember_entry` 并在回放重建、`frozen` 零拷贝、在途窗口、孤儿清理、旧游标显式快照、嵌套 epochs，
与 astra 的分歧只在 A3.4 / A5.2 的严重度（应为【中】），均已被 v2 覆盖。
v2 新引入一个【严重】缺口：页存原始真值后装页不再经 rebase，`snapshots` 无人填充，`payload_bytes`（Pl:74-82）会把"有细节、无 base、无 overlay"的区域按 baseline 服务——重启后建筑看不见但撞得到。
另有 5 处【中】要在开工前写定：负坐标 home 换算、在线事务无 `prefab_instances` 键、写回进程崩溃后同 C 主键冲突、合成快照不能占 World 回合、写放大接受线。
`committed_liquid_active` 的语义差异可接受（与现行日志恢复相同，Log:426）；`{:error, :persist_backlog}` 可作最后一级，前两级应是停抽取与停步进。
**结论：先改上述 6 条即可按 v2 开工**；其余【中】【轻】可在实现中带着做。本评审未运行任何测试或服务，不构成运行验收。
