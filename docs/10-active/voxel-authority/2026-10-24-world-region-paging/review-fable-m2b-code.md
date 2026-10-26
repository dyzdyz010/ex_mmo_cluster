# M2b（按需装页）代码评审 — Fable

评审对象：ex_mmo_cluster 工作树相对 HEAD `2931f09f` 的未提交改动（`apps/` diff + 未跟踪 `closure.ex` / `page_load.ex` / `page_on_demand_test.exs` / 定位表迁移 / `migrate.py`）；只读，未运行 mix / 测试。
行号为当前工作树文件行号。标 “推断” 的项未在代码路径上逐行跟到底，只按已读的契约推出。

## 1. 正确性

### 1.1 【严重】只按 L0 种子装页的提交入口写粗层页：非驻留 `(L, R)` 的 `coarse_overlay` 被部分内容整页覆盖，且归约旧值读的是 baseline

所有几何提交都经 `Edits.apply_batch` → `reduce_batch`（`edits.ex:421-489`）逐级归约，归约写 `put_overlay(s, level, parent, new)`（`edits.ex:455`）→ `Pages.mark({:page, :coarse_overlay, {L, R}})`（`pages.ex:53`、`edits.ex:68`）；切点抽取该单元时整页重写：`extract(..., {:page, :coarse_overlay, {L, R}})` 只取内存里 `overlay_regions[{L, R}]` 的格（`pages.ex:403-405`），`PageCut` 不按驻留过滤脏单元（`page_cut.ex:43`、`page_cut.ex:189`）。

而以下入口的闭包只给 L0 键，`Pages.expand` 只扩同级 26 邻页（`pages.ex:81-83`），L1–L5 页从不进驻留集：

- 液体步进：`world.ex:1641`（`{0, region_of(cell)}`）→ `advance_liquid` → `commit_liquid` → `apply_batch`（`liquids.ex:306`）。
- 热提交：`Thermal.seed_keys/1` 只产 `{0, region}`（`thermal.ex:51-61`）；`commit_thermal` 的相变走 `Liquids.commit_liquid`（`heat_commit.ex:23/37`），转化走 `Edits.put_overlay` + `Prefabs.prefab_reply`（`heat_commit.ex:142-164`），都是几何提交。
- `body_death`：`closure.ex:109` 只给脚位 L0 页 → `death_place` / `move_flowing` → `apply_batch`（`production.ex:312-314`）。
- 投射物结果：`closure.ex:112-121` 只给飞行段 L0 页（本步只写属性行，暂不触发；推断）。
- `{:adopt_liquid, regions}`：不在 `Closure.seeds`（兜底 `:none`，`closure.ex:123`）→ `adopt_liquid_sources` → `commit_liquid`（`liquids.ex:76`）。`prepare` 之后由调用方单独发起（`world.ex:122-124`）。
- 启动活动页：`world.ex:1859/1863`，`active` 只扩 L0 邻页，不像 `touched` 那样带粗层祖页。

时序反例（有前缀的重启，liquid 用例的世界）：
1. 发布前：水在 (64,3,2)（L0 页 {1,0,0}，L1 格 (32,1,1) ∈ L1 页 {0,0,0}）；另有作者编辑 (10,2,10)→L1 格 (5,1,5) 也在 L1 页 {0,0,0}。切点后 PG `coarse_overlay(1,{0,0,0}) = {(32,1,1), (5,1,5)}`。
2. 重启：活动索引只装 {1,0,0} 及其 L0 邻页；`(1,{0,0,0})` 未驻留。
3. `:liquid_commit`：`request` 全部 L0 驻留 → 推进 → `reduce_batch` 读 `cell_value(s, 1, (32,1,1))`：overlay 无此键 → 读源 baseline（空气）当旧值（`canonical.ex:340-359`）→ 与新值不等 → `put_overlay(1, …)` → `(1,{0,0,0})` 脏。
4. 下一切点：`extract` 得 `{(32,1,1) => …}`（内存只此一格）→ PG 该页版本不再含 (5,1,5)；再重启后 L1 载荷在 (5,1,5) 回到 baseline，L0 仍是编辑后的材质——粗层真值与 L0 分叉。
5. 反向：若新归约值恰等于 baseline（水全部离开该 2³ 块）而 PG 旧值是水，则 `new == old` 不写、`(1,{0,0,0})` 不标脏，PG 的 L1 仍是水——永久陈旧。

同一根因还波及树冠片段：`Canopy.fragments/2` 对 level≥2 读 `cell_value(s, level-1, …)`（`canopy.ex:165`），模拟路径下读到的是 baseline，算出的片段被持久（`canopy.ex:629`）。`page_on_demand_test` 的液体 / 热用例只断言 seq 推进与 elapsed，不检查粗层页，所以为绿。

修法（最小）：这些入口的种子改用 `Edits.edit_keys(cells)`（各级页）再 expand，与编辑闭包同一规则；启动 `active` 种子同 `touched` 带各级祖页；`{:adopt_liquid, regions}` 进 `Closure.seeds`（或在 `prepare` 的闸里一并装）。并在 `page_on_demand_test` 的液体用例里加“重启后一步液体提交 → 切点 → 再重启，L1 载荷（去 seq）等于不重启的同序操作”。

### 1.2 【严重】多轮装页期间树闭包未闭合，期间任何几何提交把“已装身份、格未装”的实例当死实例删除并写进日志

`Pages.adopt` 一次只装本轮 tokens 的页，整树的 home / 覆盖页作为 `follow_ups` 返回（`pages.ex:641-667`），由任务下一轮 `page_need` / `read_pages` / `page_adopt` 再装（`page_load.ex:142-154`）；两轮之间 World 照常处理别的消息。而每笔几何提交都按内存里的格重算活实例并裁掉其余：`edits.ex:208` `instances: Map.take(state.instances, Payloads.live_instance_ids(state))`，`live_instance_ids` = `refined_owners ∪ macro_owner_cells` 的祖先（`payloads.ex:212-214`）。

时序反例：
1. 根实例 X 的 home 在页 P，它的宏格全在页 Q（跨页 prefab，与 `page_on_demand_test` “跨页 prefab” 同形）。
2. 窗口 A 触及 P：任务第 1 轮 `page_adopt` 装入 P 的 identity 单元 → `state.instances` 有 X，`macro_owner_cells[X]` 为空（Q 未装）；`follow_ups` 返回 `{[{0,Q}], []}`。
3. 任务回到 `page_need` 前，玩家 B 在任意驻留页提交一笔编辑：`apply_batch` 裁掉 X；`Log.append_log` 写 `instances_delta: %{X => nil}`（`log.ex:24`）；`Pages.remember` 把 P 的 identity 单元标脏、`covers[X]` 删除（`pages.ex:176-193`、`pages.ex:307-309`）。
4. 第 2 轮装入 Q：`macro_owners` 指向 X，`follow_ups` 发现 X 未知 → `locate` → 根 home P 已驻留 → 无后续。X 在日志与下一切点里已被删除，Q 上的格成为无主归属格；重启后同样。

同一窗口里，按 id 的入口（`remove_prefab` / `replace_prefab` / GM `move_instance`）在第 1 轮之后过闸：`Closure.tree/2` 见 X 在内存就按 `owner_cells` 求键（`closure.ex:168-171`），只拿到已装部分，裁决会按残缺树提交（R1 只在任务结束时成立，闸却在每次过闸时假设它成立）。

修法（二选一，倾向前者）：(a) 树闭包在任务进程里按 PG 行闭合——任务读到 identity / covers / locator 行后自己迭代（都是纯 PG 读），一次 `page_adopt` 交齐整棵树与覆盖页；World 侧只保留“接纳时按当前状态复核”。(b) 保留多轮，但 `apply_batch` 的活实例裁剪只对本笔 `removed_owners` 与改动格的旧归属做（不按全表）；并让闸对“根已装、覆盖页未齐”的树继续挂起。

### 1.3 【中】异步消息挂起后装页失败，`prepare_cast` / `quote_cast` 的调用方得不到回复

`redo_one({:info, message}, _, reason, state)` 只记日志（`world.ex:1563-1566`），但 `{:prepare_cast, key, actor, request, from}` 与 `{:quote_cast, actor, request, from}` 携带 `from`，正常路径由 `info/2` 回 `GenServer.reply(from, …)` 并 `send(actor.player, {:cast_failed, key})`（`world.ex` prepare_cast / quote_cast 分支）。装页任务异常时 Gate→Player 等满 300 s；施法者在 Player 侧停在待施放。违反 R4“装页失败显式回复调用方”。修法：失败分支对这两类消息回 `{:error, {:page_load_failed, reason}}` 并发 `cast_failed`。

### 1.4 【中】`redo(:wake)` 不看任务退出原因：PG 不可用时热步前检查形成紧循环（推断）

`redo(:wake, _attempt, _reason, state)` 无条件 `send(self(), {:thermal_step, run.ref})`（`world.ex:1538-1542`）；`info({:thermal_step, ref})` 再 `request` → `sim == nil`（`finish` 已清，`page_load.ex:117`）→ 再起任务 → 任务读 PG 异常退出 → DOWN → 再 `:wake`。无定时器间隔，每轮 spawn 一个进程并写一条 error 日志，期间 World 回合被占满；液体 / 投射物路径有定时器，不紧。最小修法：`reason != :normal` 时不投 `thermal_step`，只 `Thermal.rest`，等下一拍 / 下一笔事务唤醒。

### 1.5 【中】`Closure.seeds` 兜底 `:none` 使“新入口默认不读页”成为静默回退

任何未登记的 call / info 都直接放行（`closure.ex:123`）。现有漏项：`{:adopt_liquid, regions}`（写提交，见 1.1）。其余未登记项我逐个看过（`caster_state`、`beacon_directory`、`author_regions`、`material_supply`、`subscribe`、`entries_after`、`stats` 等）本步只读全局或内存索引。建议用 Automation 测试把 `World.call/3` 的消息头与 `Closure.seeds` 的登记做差集核对，而不是运行时防御。

### 1.6 【轻】其他

- `@page_calls` 注释称“不写回热域”，但 `call/3` 的写回子句（`world.ex:791-793`）对 `page_need` / `page_adopt` 同样生效（不在 `@unflushed`）。无害，注释失真。
- `redo(:wake)` 在热运行并未暂停（只是液体任务结束）时也投一条 `thermal_step`，与正常步链并行形成双链（`world.ex:1818` 每步自投一条）：提交更快走完，“步间先处理已排队的调用”的节奏被打乱；不影响结果。
- `body_contact` 在无热环境的世界也过闸装页（`closure.ex:108`），`info/2` 随后丢弃（`world.ex` 对应 `thermal == nil` 子句）。
- `liquid_fill`：闸只按种子格求键（`closure.ex:35`），泛洪 `max_cells` 大时可伸出种子页的 26 邻页（推断，取决于 Gate 上限）。
- 热运行因装页暂停期间，`PageCut.maybe_open` 因 `thermal_run != nil` 不开切点（`page_cut.ex:180`）；装页卡住即切点卡住。
- `info(:projectile_tick)` / 投射物结果里的 `drain_thermal` 现在可能带着未完成的热运行返回（`world.ex:1827-1836`），随后 `Projectiles.accept` 的 `thermal_commit` 与暂停中的热运行交错（`disturbed` 路径能处理，但与原注释“先完成进行中的定时提交”不符）。

同序队列（`order_key` / hold / enqueue / release）与重放次序我按 `gated_call` / `gated_info` / `redo_ordered`（`world.ex:772-789`、`world.ex:1548-1552`）逐条推演：同动作 / 同身体的消息先到先处理，再次挂起时重新排队，任务失败时先回错再按序重放排队项；`page_need` / `page_adopt` 不过闸、不经积压拒绝，任务→World 单向调用，无互等。未发现丢消息或死锁。

## 2. 持久化与恢复

- 定位表与页段同事务：`PageStore.insert_rows`（`page_store.ex:189-210`）在 `write` / `publish` 同一 `repo.transaction` 内；File 后端 `put_rows` 同步改 `locators`。`row({:locator, _}, nil)` 返回 nil 且两处写入都过滤（`page_writer.ex:69`、`page_cut.ex:43`）。符合。
- 日志按键增量：`append_log` 只在表变时写 `instances_delta` / `attachment_owners_delta`（`log.ex:22-30`）；回放 `instances_after` / `owners_after`（`log.ex:421-424`）；`txn_needs` 对 `prefab_instances` 显式 raise（`pages.ex:90-92`）。但 `OverlayLog.append` 的元数据白名单仍保留 `:prefab_instances` / `:attachment_owners`（`overlay_log.ex:91`），只为旧检查点夹具——可接受。
- 粗层片段：`put_structure` 唯一写入口 + `structure_pages` 索引（`canonical.ex:489-511`），`Canopy.refresh` 在编辑 / prefab / 附件三条提交链同笔重算（`edits.ex:257`、`prefabs.ex:545`、`attachment_ops.ex:131`），`CoarseRebuild` 丢弃片段写空（`coarse_rebuild.ex:111-113`）。片段值的正确性受 1.1 影响（模拟路径读 baseline 粗层值）。
- 启动头部 + 后缀 + 活动索引：`load_head` 同一 REPEATABLE READ 快照读前缀 / 全局 / 后缀 / 活动（`page_store.ex:38-84`）；`read_pages` 同样在快照内重读前缀（`page_store.ex:92-146`）。`txn_needs` 覆盖了 entries（payload 头 / coord+coarse / structure）、coarse、liquid_units、属性行各粒度、epochs、placed_by、macro_owners、liquid_active、thermal.sources、实例增量 home 与父 id、附件归属（`pages.ex:100-137`）；我没找到 `replay_damage` 应用而 `txn_needs` 未装的字段。后缀很长只是 O(后缀) 装页，无语义漏洞。
- 与 M2a 的等价缺口：
  - 【严重，同 1.1】活动页只装 L0 邻页，重启后第一次模拟提交即破坏粗层页。
  - 【中】`replay_damage` 用 `txn.thermal` 整体替换 `state.thermal`（`log.ex:445`），`liquid_active` 也整体替换（`log.ex:443`）；两者在 M2b 下写入的是提交时的驻留集。目前靠“有热源 / 活动液体的页必被活动索引装入”保证内存表完整，所以等价成立；但该前提没有测试守护，一旦活动判定遗漏（例如 `active?` 依赖的 `thermal.config` 在参数发布后变化而页未标脏），重启回放会把这些页的热源 / 活动集从内存删掉并在下一切点写空。建议至少加一条“两页各一个热源、只触及一页后发布重启，另一页热源仍在”的用例。
  - 【轻】`stats.attachment_slots` 等整表统计现在只数驻留（`damage_world_test` 为此加 `touch`），接口语义变化未在文档记。
- 前缀 0 路径（`world.ex:1848-1853`）：`install_globals` + 全量回放 + `Canopy.refresh_all`，驻留 `:all`；`page_dirty` 由回放的 `remember` 建起。与 M2a 一致。

## 3. 测试合法性

- 改写的既有断言：`prefab_test` / `prefab_macro_world_test` 的日志字段改为增量，是契约变化，新断言仍检查条目内容（新建带 placed_by、删除为 nil、未改笔不写）；`page_store_matrix_test` / `damage_world_test` / `prefab_macro_world_test` 加 `touch` 后再比对，是驻留契约变化，比对集合未缩小；`world_refined_index_test` 按 Q5 改为确定序且加了“部分驻留相对次序不变”的独立期望；`canopy_projection_test` 只在投影前重算片段，断言不变。未见弱化。
- `thermal_domain_equivalence_test` 的 `burn/3` 改为取消启动节拍 + 显式 `:thermal_commit`（diff 行 412-424）：这是改夹具避开失败，理由（旧实现靠 >500 ms 的冷区重读让节拍先到）在 m2b §7 有记录且可信，但“记录与断言不变”只是论证，`eps 0.9` 的既有失败仍在。【轻】接受，建议在文件头把这个时序前提写成断言（已写 `elapsed_s == 0.5`，够）。
- 新增反例：用例 1（冷页编辑、载荷逐字节）、2（粗层页不装 L0、L1–L5 逐字节）、3（跨页树经定位表）、5（迟到结果不覆盖）期望独立于被测算法，能证伪。用例 6（液体活动恢复）只断言 `seq` 推进与 `active_cells > 0`，没有核对水落到哪格、也没有核对粗层页——正是 1.1 漏网的位置。【轻】用例 7（热暂停）断言充分。
- `:sys.replace_state` 夹具只删 `resident` 里一页并取消节拍（`page_on_demand_test.exs:247-250`），未改真值；该页内存内容与 PG 一致，重装无副作用。合规。
- 计划 §4 第 4（负坐标 anchor 的定位行）、8（同笔建删 + 改归属重放两次只生效一次）、9（新段判脏各一处反证）没有留下自动化用例，m2b §7 只记了手工反证。【轻】

## 4. 工程约束

- 预建：`page_generation` / 令牌代数在本步恒 0，没有当前调用方（`page_load.ex:103`、`pages.ex:557`）；按 AGENTS 规则属为 M3 预建，但实现极薄，可留。`Closure.needs` 的 `exact` 三元组、`@batch`、`attempt` 都有现用。
- 300 s：`publish_properties` / `instance_cells` 合理（装页或装全表）。`simulation_snapshot` / `sight_snapshot` 是 NPC 每拍感知，300 s 不是问题本身，问题是感知现在可能被一次冷装页（实测最长 4.7 s）同步卡住；本步接受，M3 淘汰后需要重看。
- 第二真值 / 静默回退：`adopt` 按“PG 无行 = baseline”装页是设计（R4）；`Closure` 兜底 `:none`（1.5）与 1.1 的粗层读 baseline 是本评审发现的静默回退。`remembered` 整表在 `index_loaded` 换成装入后的表（`pages.ex:624-628`），不是第二真值。
- 维护入口切 `:all` 后不再回退，内存回到 M2a 规模，计划已接受。

## 5. 结论

**不能提交。** 1.1 与 1.2 都是在真实双客户端 / 模拟并发下必然触发、且写进 PG 的真值损坏；现有测试恰好不观察受损的字段。

提交前必改：
1. 模拟 / 身体 / 投射物 / `adopt_liquid` / 启动活动页的闭包改为各级页（`Edits.edit_keys` + expand），补“重启后一步液体提交→切点→再重启，L1–L5 载荷逐字节”的反例（1.1）。
2. 树闭包在一次接纳里闭合（任务按 PG 的 identity / covers / locator 行迭代后一次 `page_adopt`），或至少让 `apply_batch` 的活实例裁剪只作用于本笔触及的归属；补“多轮装页中途另一玩家提交编辑，跨页树不丢”的反例（1.2）。
3. 装页任务失败时对带 `from` 的异步消息（`prepare_cast` / `quote_cast`）显式回错并发 `cast_failed`（1.3）。
4. `redo(:wake)` 在任务异常退出时不立即重投 `thermal_step`（1.4）。
5. 液体活动恢复用例补核对落点材质与粗层页；加“两页热源只触及一页后重启另一页热源仍在”的用例（§2 等价缺口）。

列入后续：1.5 的入口登记差集测试；§3 计划 §4 第 4 / 8 / 9 项的回归用例；`stats` 只数驻留的接口说明；1.6 各轻项；M3 淘汰前重审 `adopt_liquid` 与 NPC 感知的同步等待。

---
总评：
- 架构（闸 + 任务 + 接纳复核 + 同序队列）成立，顺序与无死锁经推演无误。
- 粗层页从未进模拟 / 身体 / adopt_liquid 闭包，首次模拟提交即以部分内容覆盖 PG 粗层页（严重）。
- 多轮装页期间几何提交按内存裁活实例，跨页树被当死实例删除并写日志（严重）。
- 异步挂起失败无回复、热步前检查失败紧循环（中）。
- 恢复路径字段覆盖完整；热源 / 活动集整表替换的等价靠活动索引隐含保证，缺测试守护（中）。
- 既有断言改写有据，新增用例大多可证伪；液体恢复用例偏弱。
- 不能提交；必改 5 条如上。
