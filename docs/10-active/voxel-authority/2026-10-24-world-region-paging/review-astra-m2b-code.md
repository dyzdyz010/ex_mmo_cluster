# M2b 按需装页代码评审（Astra，2026-10-27）

结论：**当前不能提交。** 下列五项是提交前必改；其余问题列入后续。本报告针对 HEAD `2931f09f975542dd80ee4bd43061da29a2de4749` 上的未提交改动，覆盖 `apps` 下 36 个已跟踪改动文件及 brief 指定的五个新增文件。`bench/paging_m0/migrate.py` 的实际位置为 `apps/voxel_region/bench/paging_m0/migrate.py`。

已完整阅读评审 brief、M2b 计划及 §7、M2a 设计、父稿 P1/P4 与 I1–I5、拆分稿 approved v7 §5 e，以及两仓 AGENTS.md、系统正交准则、Voxim/Docs/Testing.md。接受本轮已经批准的范围：不淘汰、触及实例即装整树、不持久 max_hp 汇总、电路跨冷页发现留待后续；这些本身不列为缺陷。

本轮只有静态阅读、Git 差异核对和时序推演；**没有运行 mix、测试、服务、基准，没有操作 Docker/数据库、切换分支或提交。唯一写入是本报告。** 下文所有反例的运行后果均为“推断”，不是本轮实跑结果；引用 §7 的测试/性能数字只表示施工记录的声明。证据路径相对仓库根，`../Voxim` 为相邻客户端仓。

同段的短路径 `world/…`、`world.ex` 分别指 `apps/voxel_region/lib/voxel_region/world/…`、`apps/voxel_region/lib/voxel_region/world.ex`；短测试名位于 `apps/voxel_region/test/`。其他短文件名沿用该段已给出的完整路径。

**提交前必改 1／5：【严重】“页已驻留”先于树闭包完整，且已装入的孤儿实例会被过滤掉定位请求。**

证据：

- `apps/voxel_region/lib/voxel_region/world/pages.ex:570` 装入本批数据，`:571` 立即把页加入 resident，`:582` 才返回后续闭包。
- `apps/voxel_region/lib/voxel_region/world/page_load.ex:149` 每批读取后经 `:page_adopt` 返回 World，再在 `:152` 发起下一轮；World 可以在两轮之间处理其他请求。
- `apps/voxel_region/lib/voxel_region/world/page_load.ex:63` 的放行条件只检查种子页驻留与身份是否存在；`apps/voxel_region/lib/voxel_region/world/closure.ex:168` 对已有实例只枚举**当前已装入**的 owner_cells，不核对根的 covers 是否装齐。
- `apps/voxel_region/lib/voxel_region/world/pages.ex:656` 对父链不完整的新实例返回该实例自身 id；但 `apps/voxel_region/lib/voxel_region/world/page_load.ex:102` 又按 `Closure.known?` 删除内存已有 id。`:known?` 仅检查 Map.has_key，见 `closure.ex:198`。

时序反例 A（推断，无 I/O 错误也成立）：

1. 正常放置实例 R，home 页 H=`{0,0,0}`，另有几何在 Q=`{3,0,0}`；发布并重启，H/Q 都冷。
2. 请求 A 触及 H。装页任务先接纳 H，R 及 covers 已可见，Q 的读取尚未完成。
3. 请求 B 调用 `World.instance_cells(R)` 或 `World.remove_prefab(R)`。B 看到 R 已知，只从当前索引得到 H 上的格；即使 B 还需装粗层/邻页，也不会由这些已知身份重新补出 Q。允许 B 的装页先完成、A 的 Q 读取仍等待。
4. `instance_cells` 可成功返回不完整足迹（`world.ex:1263`）；拆除则从驻留表算 subtree/cells 并删除 R（`world.ex:1315`、`world/prefabs.ex:50`、`:70`、`:75`）。Q 上几何尚未参与删除，形成部分拆除；Q 随后接纳还会带回指向已删除 R 的 owner。

时序反例 B（推断，单请求即可）：

1. 根 R 的 home 在 H，子实例 C 的 home 在远页 Q，C 的 parent_id=R。重启后用 `material_snapshot` 只触及 Q；该入口只装本页（`closure.ex:37`）。
2. Q 带入 C 记录和局部格。`chain_root` 找不到 R，于是 follow_ups 把 C 放进 orphans。
3. 下一轮 need 因 C 已存在而过滤 C，既不查 locator，也不装 H/根 covers。任务正常结束，R1 宣称的“整树驻留闭合”已被破坏。
4. 后续需要祖链的路径可能直接失败：`Payloads.live_instance_ids` 调用 ancestors（`world/payloads.ex:212`），后者对父记录 `Map.fetch!`（`apps/mmo_contracts/lib/mmo_contracts/voxel/refined.ex:142`）；观察/整件汇总也不能再声称完整。

修复边界：装页 owner 必须区分“已收到页内容”与“对外可裁决的闭包已完成”，并能为**已知但父链不完整**的身份继续定位。不要靠某个调用方再扫描一次整树补救。最小验证应在 H 接纳、Q 尚未返回时插入第二个正常请求，并另覆盖“先触及子 home”；现有按 id 找根后顺利拆除的用例不能证伪这两种时序。

**提交前必改 2／5：【严重】若干入口的种子不覆盖真实读写集合，仍会把冷页当 baseline，或向未驻留页提交。**

以下是同一闭包契约缺口的三个独立触发点，不能只修一个入口后宣称 I5 已覆盖。

**A. 液体洪泛仅预装 seed，搜索没有这个空间上界。**

- `apps/voxel_region/lib/voxel_region/world/closure.ex:35`、`:73` 对普通/GM 注液仅使用 `Edits.edit_keys([seed])`，再扩一圈页。
- 真正的 flood 按六邻不断扩张，直到连通域结束或超过 max_cells：`apps/voxel_region/lib/voxel_region/world/liquids.ex:236`、`:244`、`:249`。格数限制不是“离 seed 至多一页”的限制。
- `Canonical.cell_value` 缺 overlay/base 就读 baseline source，未检查该页是否已获得 PG 无行结论：`apps/voxel_region/lib/voxel_region/world/canonical.ex:313`、`:340`。

具体反例（推断）：全空气 baseline，合法液体域为半开盒 `{{0,0,0},{192,1,1}}`；通过作者入口在 `{128,0,0}` 建一格实体堵住通道，发布，待活动集收敛后重启。以 `{0,0,0}` 为 seed、level_y=0、max_cells=4096 注液。预装的 L0 x 页仅到 1；洪泛到 x=128 时，页 2 的持久墙尚未读取，却按空气通过，随后填到墙后，甚至覆盖墙格。正确结果应止于 x=127。粗层片段被预装不等于 L0 墙的 overlay/base 已装入。

**B. 定时液体与死亡掉落只装 L0，却提交 L1–L5。**

- 液体步前只检查活动格的 L0 页：`apps/voxel_region/lib/voxel_region/world.ex:1641`；死亡入口同样只有脚位 L0 页：`world/closure.ex:109`。
- 液体会走 `commit_liquid → Edits.apply_batch`（`world/liquids.ex:287`、`:306`、`:383`），死亡放置也走 apply_batch（`world/production.ex:312`）。
- apply_batch 在 `world/edits.ex:218` 逐级归约；`:427` 读所有子格、`:429` 读旧父格，`:455` 写父格。`source.ensure`（`world/liquids.ex:289`）准备的是 baseline，不能代替 PageStore 装页。
- 空后缀、活动页非空的启动仅给 active 加 L0 邻页；只有 suffix touched 才加粗层祖页：`apps/voxel_region/lib/voxel_region/world.ex:1863`。

具体反例（推断）：发布一个仍会下落的水格，同时在同一 L2 父格的另一 L1 子块留下持久实体编辑；重启时后缀为空，不请求任何粗层页。第一笔下落改变占据后进入归约。另一 L1 子块的持久粗层值尚未装入，会从 baseline 读取，父格由不完整输入重算；新粗层 overlay 已被改写、判脏，但对应 coarse page 仍不在 resident。随后首次 serve 该粗层页又能接纳旧 PG 值，覆盖这次内存改写；或者先发布，把不完整 coarse_overlay 整页写出。这里同时破坏 I3、I5 与 M2b 的 R2。热相变/热毁也复用同一几何提交链，不能用“内核仅读 L0 邻格”证明整个提交闭包充分。

**C. 玩家姿态刷新发生在过闸之后；施法授权根本未过闸。**

- `closure.ex:127`、`world/tools.ex:594` 从原 message 的 actor 求射线范围；随后 `world.ex:1183`、`:1160`、`:1169` 才 current_actor，真正裁决使用刷新后的姿态。`{:prepared_intent,...}` 也只核对旧 keys，随后直接 `call(message,...)`，见 `world.ex:848`。
- `world.ex:1502` 的 paged_infos 没有 authorize_cast，Closure 也没有其分支；但 `world.ex:1726` 合并新的 actor/方向，再 `settle_cast → check_cast` 重新读射线、脚下与作用格（`world/casting.ex:83`、`:138`）。order_key 只保序，不装新姿态所需的页。

具体反例（推断）：准备 A 时按旧位置装页；等待 I/O/前摇期间角色移动到原读取闭包之外；最终姿态指向冷页 Q 中已编辑的遮挡物。刷新/授权后的射线直接用 Q 的 baseline，可能看穿遮挡或拒绝真实目标。若业务禁止这种位移，应由已有动作契约显式拒绝；当前过闸的位置没有建立这一保证。

修复边界：入口准备必须覆盖最终裁决快照、动态搜索及其提交后果；动态闭包可按已有 P4 迭代准备或显式拒绝，不能把未知视作空气后继续洪泛。最小验证分别保留“128 m 通道冷墙”“空后缀活动液体 + 冷粗层兄弟”“装页等待后姿态变化”的反例；不要把验收扫描加到每个内部 cell_value 消费点。

**提交前必改 3／5：【严重】装入无关页会覆盖未提交热源变化的 remembered 基准，漏写耗尽/删除，重启可复活热源。**

证据：

- 热内核步已经改写 `state.thermal.sources` 的余量/成员，整段提交尚未结束：`apps/voxel_region/lib/voxel_region/world/thermal.ex:458`、`:496`、`:542`。
- 任意 page_adopt 都调用 index_loaded；它把 remembered.sources 无条件设成**此刻整张** state.thermal.sources，即使本批没有热源行：`apps/voxel_region/lib/voxel_region/world/pages.ex:576`、`:624`–`:628`。
- 热源判脏只比较 remembered 与当前 sources：`world/pages.ex:155`、`:242`–`:251`。热提交携带 thermal 日志，但 remember 不从日志枚举 sources 的变化键（`world/heat_commit.ex:65`、`:76`）。
- 全局页明确移除 sources，必须靠 sources 页段保存：`world/pages.ex:527`。

具体时序（推断）：

1. 通过正式热实验入口建立有限热源 S，发布切点 P；源的持久 remaining_j>0，sources 单元已经干净。
2. 开始一次多内核步的 0.5 s 热提交。令 S 在前几步耗尽并从 sources 删除；整个 thermal_run 尚未结束，之后没有任何步骤再次改变该 sources 子块。
3. 此时无关冷页 Q 的普通读取完成并 page_adopt；Q 可以没有任何行。index_loaded 把 remembered.sources 从“有 S”改成“无 S”，但是 adopt 又保留原 dirty，不为 S 判脏（`pages.ex:580`）。
4. 热提交结束，remember 对比“无 S”与“无 S”，漏标 S 的 sources 单元。写回发布 C，旧日志前缀退休；全局行保存新供热账，但 PG 中 S 的旧源段未被更新。
5. 重启并装入 S 页，旧 remaining_j 恢复；若热行仍活跃，该页会自动装入。已结算能量有机会再次供给，破坏恢复等价与守恒。

这不是“允许热提交期间读取中间温度”的争议：即使切点严格等 thermal_run=nil，判脏依据也已在中途被装页改坏。应仅把本次接纳的页/身份键并入 remembered，保留其他键从上次已记住提交以来的差异；不得靠结束时整表重扫另造真值。最小回归应覆盖“热源先耗尽 → 无关空页接纳 → 同次提交收尾 → 发布、重启”，核对源不复活及供热账不重复。

**提交前必改 4／5：【中】按键增量接上了旧 VXR 后像实例覆盖逻辑，后缀重放会丢未变化实例的完整字段。**

证据：

- `apps/voxel_region/lib/voxel_region/world/log.ex:22` 现在仅把变化实例写入 instances_delta；`:421` 只对这些键合并。
- 但回放仍先执行 `replay_entry` 再 `replay_damage`（`:84`–`:87`），区域后像先用 `Map.merge(state.instances, p.instances)` 覆盖已有完整记录（`:129`）。
- VXR 实例记录不包含 placed_by：`apps/mmo_contracts/lib/mmo_contracts/voxel/refined.ex:18`–`:29`、`:107`–`:115`。服务器放置时则会写该字段（`world/prefabs.ex:453`），正常观察会读它（`world.ex:984`）。
- prefab 变更会生成覆盖该区域全部现有细节的后像：`world/prefabs.ex:547`–`:549`。

具体时序（推断，单笔后缀已足够）：

1. 玩家 1001 正常放置微格实例 A，其完整记录含 placed_by=1001，发布 P。
2. 在同一区域另一格放置实例 B，保持 A 不变，不发布新切点便重启。事务后像包含 A/B 的网络投影，instances_delta 只包含 B。
3. 页恢复先装回完整 A；后缀 replay_entry 再把 A 覆盖成不带 placed_by 的网络投影；replay_damage 仅补 B，A 的 placed_by 无法恢复。
4. 同一正式 material_snapshot 的 A 槽放置者从 1001 变为 nil；再次发布会把缺字段记录固化。这与 M2a 不等价：旧版在 B 使实例表变化时写整表，后置 replay_damage 会补回完整 A。

应由完整实例元数据的唯一 owner 恢复身份记录，区域后像不能覆盖既有完整记录。最小回归须比较**此次事务没有改变的 A**，不能只核对新建 B；现有 `prefab_macro_world_test.exs:94` 附近只验证新建记录的 placed_by，不能覆盖本例。

另一个格式边界缺口【中】：`world/pages.ex:90` 仅拒绝 prefab_instances，而 `world/log.ex:424` 仍接受旧 attachment_owners 整表。M2a 可只改变附件归属、不改变实例表，因此这两种旧键不能假定同时出现。应在分页回放边界一并显式拒绝；当前 `page_on_demand_test.exs:271` 只覆盖整表实例键。

**提交前必改 5／5：【严重】装页失败仅回复 call，异步业务消息被丢弃，施法、信标与投射物可能永久挂起。**

证据：`apps/voxel_region/lib/voxel_region/world.ex:1556` 对 call 回复 page_load_failed，但 `:1563` 对 info 只有 Logger.error 和返回原 state。被挂起的 info 并非都不需要业务回复。

具体时序（推断）：

1. Player 接受施法并设 action.phase=:preparing、timer=nil，然后发送 prepare_cast；见 `apps/scene_server/lib/scene_server/movement/player.ex:307`–`:315`。
2. World 因冷页挂起它；后端读取抛错，装页任务异常 DOWN。
3. redo_one(info) 不回复消息携带的 from，也不发 cast_failed。Player 清理 action 的既有入口在 `player.ex:737`；此处永远收不到它。调用方最终超时，角色仍可能拒绝后续施法为 cast_too_soon（`:319`）。
4. prepare_beacon/commit_beacon 同样依赖 beacon_prepared/beacon_committed 清理 action（`player.ex:680`、`:714`）。死亡掉落则是已经确认死亡的后果，丢弃 body_death 后没有恢复渠道。
5. 若挂起的是投射物采样 `{ref, results}`，读取失败后不执行 `world.ex:1630` 的清理，state.projectile_task 保持非 nil。`world/projectiles.ex:8`、`:19` 因此既不唤醒下一拍，也不发起新采样；普通 DOWN 清理也不清 projectile_task（`world.ex:1792`）。

正常完成时，release → 重放原消息 → 重放排队消息的顺序是合理的；若原消息再次挂起，后续同键消息会重新入队（`world.ex:1548`、`:1519`）。问题是失败路径没有按原消息的业务契约完成拒绝/收尾，不能把“打印了日志”算作“未丢消息”。同一动作键保序也不等于所有同 actor 消息全序：order_key 仅覆盖动作键和身体 cid（`world/page_load.ex:26`）。

修复应沿现有领域失败通道收口，明确已确认后果和投射物任务的失败处置；本报告不建议自动重试或另造通用消息框架。最小验证是让真实装页后端的读取边界失败一次，逐项核对原调用收到错误、Player action 清空、held 释放，以及投射物不被死任务引用永久封住。

**持久化与恢复的其余判断。**

【轻，核对项】定位行与同批段确实经过同一个 Repo.transaction（`apps/data_service/lib/data_service/voxel/page_store.ex:54`、`:322`）；发布最后一批、全局行与前缀也在同一事务（`:65`）。不同批次不保证同一身份的全部覆盖页同时物理可见，但前缀仍是段的统一可见性边界；locator 是不可变定位提示，不能单凭提前可见就判定身份存在。未发现仅由“locator 不带 cut_seq”导致版本回退的反例；不建议据此另造第二版本协议。

【轻，核对项】对已完整驻留的同页，迟到结果会因 resident 检查被拒（`world/pages.ex:557`）；粗层片段也检查已驻留表示（`:585`）。L0/粗层读取的行键规则见 `apps/data_service/lib/data_service/voxel/page_store.ex:225`，structure/canopy 的存储编码唯一在 `world/pages.ex:476`。这些保证覆盖“完整页已装入并改写”的用例，不能修复必改 1 的半闭包暴露，也不能修复必改 2 的未驻留页已被写。

【中，范围限制】启动 head 在同一个 REPEATABLE READ 只读事务读 P、globals、后缀和 activity（`apps/data_service/lib/data_service/voxel/page_store.ex:176`）；页装入后按序重放并重算 touched 页片段（`world.ex:1862`–`:1870`）。长后缀仍整体读入和汇总，活动页也会拉起树闭包，因此其成本至少包含后缀与展开后的闭包，不能以空后缀结果代表全部恢复情况。§7 `m2b-on-demand-pages.md:124` 明确基准两轮后缀为空、活动页为 0。必改 2、3、4 已分别给出活动恢复、页段恢复、后缀恢复的具体漏洞，当前不能宣称重启状态与 M2a 逐项等价。

【中，后续】activity 查询读取所有页的最新 activity payload，再由 BEAM 判断真假（`apps/data_service/lib/data_service/voxel/page_store.ex:199`、`apps/voxel_region/lib/voxel_region/world.ex:1859`）。没有活动的历史页仍会参与查询/传输/解码；其成本不等于仅 O(活动页数)。保留这个增长轴的说明与测量即可，本轮不据此要求预建新索引框架。

**测试合法性与证明范围。**

【轻，核对项】所列既有测试改写大体有独立契约依据，没有看到删掉原行为断言来换绿：日志断言转 instances_delta/attachment_owners_delta 符合本轮格式改变（`prefab_macro_world_test.exs:333`、`prefab_test.exs:398`）；重启后先经 material_snapshot 触及目标，再比较原始真值/附件数，符合按需驻留（`page_store_matrix_test.exs:135`、`:351`，`damage_world_test.exs:1837`）。这不替代验证“无需用户触及也能恢复活动过程”，后者已有单独液体用例。

【轻，核对项】`world_refined_index_test.exs:32` 按坐标构造独立 expected，契合已批准 Q5；没有复制索引实现作 oracle。`canopy_projection_test.exs:13` 显式 refresh_all 后再 project，可继续证明片段生成/合并的算法输出，但不再证明生产提交有没有漏调用 refresh；该接线必须由正常 World 提交及重启验证。

【中，覆盖不足】`page_on_demand_test.exs:114` 的“粗层片段”例子只建微格 prefab 并断言 structure，未建立 presentation_bindings 树冠锚点，不能据此声称 canopy 片段的增量持久化已验证。`:130` 的跨页实例没有 children，且从 id 直达根，不能证伪孤儿 home 和半闭包并发；`:155` 的“后缀身份”在空世界 compact 后建实例，走的是 prefix=0 分支，并未覆盖正前缀的按需后缀恢复；`:168` 拒旧结果有明确前后状态比较，是有效的接纳边界故障注入，但不证明迭代闭包完整。

【中，覆盖不足】热暂停夹具 `page_on_demand_test.exs:247` 除 resident 外还取消/清空 thermal_timer，没有改温度、余额、HP 或燃料，未发现回填 authority 真值。但邻页内容仍留在内存，它只制造“驻留标记缺失”，没有制造“真实冷页数据缺失”。`:253` 发送 thermal_tick，`:256` 断言 thermal_run=nil，实际证明的是**开提交前**暂停，不是已开始提交的第二/后续内核步，也不能证伪必改 3。应准确缩小现有用例的证明声明，不能把它当作所有步前检查已覆盖。

【轻，核对项】`thermal_domain_equivalence_test.exs:94` 取消启动节拍，再经真实 thermal_commit 建立明确 elapsed_s=0.5，保留原记录/断言。从源码看属于让前提确定化，而非放宽容差；§7 对旧版本墙钟依赖的探针结论，本轮未复跑确认。上述判断遵循 `../Voxim/Docs/Testing.md:23` 的独立期望和真实入口要求，未把历史全套结果算作当前评审验证。

【中，后续：数据库夹具未清理新定位表】`apps/voxel_region/test/page_on_demand_test.exs:14` 固定 cv=123，`:24`/`:25` 依赖 reset_world；`apps/data_service/lib/data_service/voxel/overlay_log_store.ex:89` 只清旧四表，不清 voxel_identity_locator。推断反例：第一例把 `{birth=1,occurrence=0}` 定位到 H，reset 后第二例同 cv/同 id 建在 Q；新定位 INSERT ON CONFLICT DO NOTHING 保留 H（`page_store.ex:337`）。第二例冷启动按 id 会找错页，且结果依赖前一次测试遗留。这不证明现有这一次 PG 结果是假通过，但当前夹具不满足每次从干净世界复现的合同。后续应让现有 test-only reset 覆盖完整持久状态，并保留跨 cv 隔离断言。

**工程约束与超时。**

【中，后续】将四个入口从默认 5 s 改为 300 s 有实际动因：§7 记录整树首次装页最长 4.7 s，已逼近 5 s；这些调用本来允许等待装页。源码位置是 `world.ex:173`、`:277`、`:281`、`:431`。但 300 s 只是调用者等待上限，不是任务截止时间、队列上界或业务取消协议。PageLoad 只监控装页任务，没有监控挂起 caller，也没有自己的 deadline（`page_load.ex:92`、`:143`）。推断：调用者超时/退出后，队列里的作者编辑仍可在装齐时执行，身体 detach 也可能在慢读取后长期等待。当前可以接受明确标注的开发期统一超时，不能据此宣称生命周期已闭合。官方依据：[GenServer.call/3](https://hexdocs.pm/elixir/GenServer.html#call/3) 定义等待/超时；[Erlang 进程与 alias 文档](https://www.erlang.org/doc/system/ref_man_processes.html#process-aliases) 说明失效 alias 会丢弃迟到回复。项目所需的取消语义仍必须由已有业务 owner 定义，不能靠超时数字推导。

【中，后续】父稿 P4 要求“每个缺页最多一个装页请求”，当前是每个挂起入口一个任务，只有模拟任务有 sim 单例（`page_load.ex:60`、`:65`、`:80`、`:92`）。同一冷页并发 N 个普通读者可发起 N 组相同读取；resident 过滤只保证晚结果不覆盖，未合并 I/O。这是已批准合同尚未实现，不是需要预建通用调度框架的理由；后续在现有装页 owner 内收拢同页在途读取即可。正常 hold/release 无内部循环等待证据，但外部 I/O 停滞没有当前层的有界收尾。

【中，后续】新增基准脚本复用看门狗，避免复制实现是合理的；但看门狗选择的是“启动时未存在的所有 erl PID”，不是脚本所属的进程树（`apps/voxel_region/bench/paging_m0/run_m0.py:115`、`migrate.py:31`、`equiv.py:26`–`:35`）。推断：脚本启动后另一个工作任务拉起 erl，低内存时也会被杀。应把所有权说明与实际终止范围对齐，尤其本工作树允许并行基准/审查；本轮没有运行或干预任何看门狗。

【轻，范围判断】新增 page_generation 的 0 代数用于已批准的装页令牌合同，closure/page_load 的拆分也有当前调用方；未据此认定为无需求的抽象。相反，真正的隐式备用真值发生在缺页路径落回 baseline（必改 1/2），以及网络实例投影覆盖 home 记录（必改 4）。修复应守住这些接纳/构造边界，避免在可信内部链路层层加扫描和兜底。

**总评：**暂不建议提交；阻断依据是静态代码反例，不是本轮测试失败声明。
必改 1：闭包完成前不得对外放行，已知孤儿实例仍需补根。
必改 2：补齐动态洪泛、模拟/死亡粗层提交、刷新姿态与施法授权的闭包。
必改 3：装页不得重置其他页尚未提交的 remembered 差异。
必改 4：增量日志回放不得以 VXR 投影覆盖完整实例记录，并补全旧格式拒绝。
必改 5：异步装页失败必须完成原业务拒绝/收尾，不能只记录后丢弃。
既有测试调整总体有依据，但半闭包并发、正前缀后缀、热步间判脏和异步失败缺少对应证伪。
本轮未运行任何测试/服务或数据库操作；唯一写入为本报告。
