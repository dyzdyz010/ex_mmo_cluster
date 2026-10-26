# M2a 独立评审：页表与连续写回

评审日期：2026-10-26。对象：`m2a-page-store.md` draft v1；父稿：`../2026-10-24-world-region-paging.md` approved v4。源码 HEAD 实际核对为 `acb401e70906af6fd22ed40db874f23cecb98517`。

结论：**暂不能按 v1 开工。增量方向可取，但归属规则、提交前像、切点冻结和恢复装入还存在会丢失真值的缺口。**

本次独立阅读简报、设计稿、父稿、状态调研和当前源码，未使用其他评审报告作结论来源。遵守只读范围：未修改代码或设计稿，未提交，未运行服务、测试或基准，未操作 Docker／数据库；唯一写入为本报告。下文“事实”来自静态源码，“推断”是按该设计实施时的反例或风险，均不冒充实跑结果。

证据路径除显式写出的 `apps/...` 外，均相对于 `apps/voxel_region/lib/voxel_region/`；例如 `world/log.ex:22` 是该目录下的源码及当前行号。稿内章节均指 M2a，父稿另行注明。严重度：【严重】阻塞正确性或已批准的资源边界；【中】须补齐的合同／验证缺口；【轻】可接受的范围安排或说明修订。

## 1. 页内容与归属规则是否完整，身份归属会不会变化？

### 1.1【严重】`attachment_owners` 的 `slot` 不是空间槽，不能用于计算页键

**对应：§3；父稿 P1 home 规则。**

事实：`attachment_owners[aid] = {owner, slot}` 的第二项是 prefab 定义里的整数槽编号。定义编码把它写为 `slot::32-little`，展开后仍是 `g.slot`；真正的空间槽集合是另一个字段 `g.slots`。放置时保存的是 `{g.owner, g.slot}`，不是 `{kind, axis, anchor_micro}`。

源码证据：`prefab.ex:59`、`prefab.ex:119`、`prefab.ex:303`、`prefab.ex:339`；`world/prefabs.ex:456`、`world/prefabs.ex:470`。玩家独立安装附件只写 `attachments` 和 `attachment_serial`，并不创建 `attachment_owners`：`world/attachment_ops.ex:190`。parcel 搬移也只是保留这个编号：`world/parcel.ex:128`。

推断：按“`slot` 所在 L0 页”实现会无法寻址，或把模板编号误当坐标。它也不能充当所有 aid 的 home 表。存量附件可能已失去创建时的首槽，不能声称由当前任意存活槽精确还原原 home。

最小修订：明确 aid 身份记录与不可迁移 home 的实际来源，覆盖 prefab 附件和独立附件；列明存量数据的 home 赋值规则及删除规则。`attachment_owners` 仍保存其现有归属语义，不把整数编号改释为空间坐标。实例 `anchor` 本身使用微格坐标，页换算须先换算为宏格；parcel 对它应用 `delta × micro_resolution` 可直接证明单位：`world/parcel.ex:111`、`world/parcel.ex:126`。

### 1.2【严重】g=2/3 行的 `micro` 会变，且按命中格归页偏离父稿的 home 合同

**对应：§3、§4。**

事实：g=2 的键是 `{2, owner}`，g=3 的键是 `{3, aid}`，均不含 `micro`（`damage.ex:340`）。`Canonical.property_state/3` 对已有行执行 `Map.merge(t, target)`，以本次目标覆盖 `micro`（`world/canonical.ex:357`）。微格命中创建 g=2 目标（`world/canonical.ex:294`），附件命中使用本次槽坐标（`world/tools.ex:19`）；成功损伤把更新后的整行重新写入 `damage`（`world/tools.ex:188`、`world/tools.ex:226`）。

推断反例：同一跨页部件先在 A 页受损，再在 B 页受损；身份键未变，属性行的归页却从 A 变为 B。稿中“若变同时标两页”可覆盖一般成功提交，但前提是拿到了真正的旧行，并把 A 页写成删除该键后的完整版本；它不能证明“行生命期不变”，也不符合父稿“整件 HP 只在 home 页”。

最小修订：采用父稿已批准的身份 home 存储 g=2/3，`micro` 保持既有观察／命中语义。若坚持按 micro 存储，须承认这是归属合同变更，并明确旧页移除、身份定位和重复键拒绝规则，不能称为 P1 的子集。

实例移动／替换方面，当前 GM 搬移清旧树后按 `before.seq + 1` 重新创建身份；替换也走重新放置。并非同一 id 原地迁移：`world/gm.ex:207`、`world/prefabs.ex:125`、`world/prefabs.ex:393`。parcel 同样映射为新 id：`world/parcel.ex:107`。脏页判定必须覆盖旧身份删除与新身份创建两端。

### 1.3【严重】直接逐页复用 `replay_entry` 会让网络实例投影覆盖 home 页完整记录

**对应：§3 的 VXR 复用、§7 的“地形段装入、元数据按键并入”。**

事实：区域载荷带跨度内实例及祖先，并非仅带 home 实例（`world/payloads.ex:178`）。回放执行 `Map.merge(state.instances, p.instances)`，然后按当前已装入几何裁剪存活实例（`world/log.ex:129`、`world/log.ex:144`）。VXR 实例编解码只含定义、锚点、方向、父级与部件编号，**不含 `placed_by`**：`apps/mmo_contracts/lib/mmo_contracts/voxel/refined.ex:18`、同文件 `:107`。完整实例却确实保存 `placed_by`：`world/prefabs.ex:451`。

推断反例：先装 home 页 A，并从 ETF 恢复实例的 `placed_by`；再装引用同一实例的 B 页，B 的 VXR 简化记录覆盖完整记录，放置者事实丢失。B 自己的元数据不拥有该实例，无法补回。当前整世界日志最后用 `prefab_instances` 整表覆盖，所以原路径可以消除这种投影损失（`world/log.ex:437`）；分页后不再有这一步。逐页装入时按尚未装齐的几何裁剪实例，也可能提前删掉 home 记录。

最小修订：页装入必须明确“core 几何来自地形段，完整身份只来自 home 元数据”。可以复用编解码和 core 装入逻辑，但不能无条件复用该函数的实例 merge／全局存活裁剪副作用；装页顺序不得影响最终真值。

### 1.4【中】字段清单大体覆盖现有检查点，但粗层结构和独立资产的恢复语义要写清

**对应：§3、§7。**

事实：§3 所列页／全局字段基本覆盖现有检查点的元数据白名单；`thermal` 除 sources 的“其余”还应包含已有拟态等动态键，不能实现成只取几个已知账目。证据：`world/log.ex:334`、`world/log.ex:38`、`overlay_log.ex:67`。

但 L1–L5 的 `p.structure` 虽在载荷里，现有回放未将它装入 `state.structure`，`rebase_region` 还会清空载荷内的 structure／canopy 等段：`world/log.ex:109`、`world/log.ex:208`。当前靠启动全量 `refresh_structure` 补回：`world.ex:685`。故本步可以明确保留该重算，但不能声称旧 rebase 已实现“粗层完整页恢复”，更不能把这个假设带入 M2b。

`properties`、prefab 定义和 `published` 有独立资产来源，并非本次漏列的 PG 页字段：`world.ex:631`、`world/catalogs.ex:13`、`world.ex:1152`。迁移等价的前提应固定同一资产集；不应借分页另造它们的第二持久真值。`protection` 的桶索引等派生物也须通过已有构造入口重建，不能只把 ETF 填进错误层级。

## 2. 方案 A 是否可靠，是否存在不经过 `append_log` 的改动？

### 2.1【严重】“唯一出口是 `append_log/3`”不成立，普通液体提交会漏标

**对应：§4。**

事实：`Edits.append_journal` 在纯液体数量优化分支直接调用 `Log.append_journal/2`，只在另一分支调用 `Log.append_log/3`：`world/edits.ex:366`、`world/edits.ex:374`。真正共同的持久出口是 `Log.append_journal/2 → backend.append`：`world/log.ex:22`、`world/log.ex:30`。

推断：只在 §4 指定的 `append_log/3` 合并 `dirty_pages`，正常液体／散体数量变化不会进入本轮页集；安全前缀推进并删除日志后，重启丢失已确认数量或相态。并且当前 `append_log` 返回 `:ok`，调用点不接收新 state，不能在这个纯函数内部“改 state”就让 World 获得新脏页集：`world/edits.ex:333`、`world/tools.ex:242`。

最小修订：把覆盖范围定义为**所有成功 WAL 提交的统一接纳边界**，明确成功结果如何回到 World 并更新脏页／版本；覆盖优化后的 journal 表示，失败不得标成已提交。不是统计 17 个调用点即可证明完整。

### 2.2【严重】现有 `before` 不等于上一已提交状态，热源与活动液体差异不能直接据此计算

**对应：§4 的 thermal／liquid_active 前后差异，§5 的合法切点。**

事实：热内核步已更新 sources 剩余能量和热账（`world/thermal.ex:480`、`world/thermal.ex:526`）；提交函数才执行 `before = state`（`world/heat_commit.ex:57`）。因此在这个调用中，`before.thermal.sources == state.thermal.sources` 并不表示它相对上一提交未变。测试热源安装也先改 thermal，再调用 `thermal_commit`：`world.ex:862`。

液体定时回调在进入步进前直接清空 `liquid_active`（`world.ex:1430`），步进又在调用 `commit_liquid` 之前把新活动集并入（`world/liquids.ex:355`）；无几何、无数量变化时还可以直接返回而不追加日志（`world/edits.ex:192`）。`Thermal.flush` 则确实在 WAL 之前改写 damage，属于进行中的状态：`world/thermal.ex:563`、`world/thermal.ex:584`。

推断：热源页可能未被标脏，却与已经更新的全局供热账一起发布，恢复后出现旧能量余额配新账；源删除的旧页尤其不能只从新 sources 找到。液体活动集可能在相同 seq 下改变，既有整世界检查点能捕获它，A 只看提交前后差异却未必能捕获。

最小修订：由对应 owner 明确已提交前像或本次提交实际触及／删除的键，持续维护到成功提交；对无 seq 的活动集变化先定义持久语义。标脏可以由键推导，冻结仍只能取合法提交版本。测试对拍也必须比较两个真正的提交边界，不能复用已经被推进过的 `before` 来自证。

### 2.3【中】GM／parcel 主提交可复用，但启动、离线重建和目录资产是明确的旁路

**对应：§4、§7。**

已核查路径如下，不能全部概括成“都走 append_log”：

- GM 清理、填充、搬移分别走 `prefab_reply`／`apply_batch`／`place_tree`；灌排液可进入上述 journal 分支。证据：`world/gm.ex:120`、`:149`、`:201`、`:217`。
- parcel 几何和属性走 `Prefabs.prefab_reply`，定义字节却独立发布到文件。证据：`world/parcel.ex:158`、`:228`。
- 参数目录变更的属性迁移走 `Log.append_log`；prefab 目录发布本身不产生体素事务。证据：`world/catalogs.ex:86`、`:103`；`world.ex:1142`、`:1152`。应明确资产边界，不要求把只读定义重复塞进页。
- 启动会迁移旧 g=1 damage、调整环境配置并重算结构；这些不经过 append。证据：`world.ex:673`、`:685`；`world/heat_commit.ex:234`；`world/catalogs.ex:34`。
- `CoarseRebuild` 在同一 seq 下丢弃并重建粗层，最后直接写 checkpoint，既不 append，也不增加 seq。证据：`world.ex:484`、`world/coarse_rebuild.ex:35`、`:68`、`:93`。

推断：删去启动 checkpoint 后，仅由 A 建脏页，不能自动持久化上述规范化变换；离线维护继续写旧表，还可能变成与新页恢复脱节的持久入口。应明确这些入口如何接入同一页持久合同，以及同 seq 维护与不可变 `cut_seq` 主键的关系。

取舍：仍倾向**修正后的 A**，不推荐把 B 的全量扫描放进每笔提交。B 可作为测试侧独立判定器，但不能弥补未定义的提交语义；现有 `changed_refined_cells` 仍枚举区域键，并非整个过程 O(实际脏页)：`world/canonical.ex:187`。

## 3. 页输入能否离开 World 物化同一字节，epochs 应如何存？

### 3.1【严重】§5 的页输入闭包不完整；粗层尤其没有“27 邻页”的固定上界

**对应：§2、§5。**

`Payloads.payload_bytes` 的实际依赖可从以下调用链逐项核对：

- 选缓存或物化路径需要 `payloads`、缓存计量状态、`overlay_regions`、`snapshots`；地形读取需要目标及邻区 `region_bases`、`overlay`、目标 `decoded`，缺项会走 `source.read(source_state, ...)`。证据：`world/payloads.ex:66`、`:128`、`:350`；`world/canonical.ex:239`。
- L0 细节需要 `refined_regions/refined/refined_encoded`、`refined_owners`、`macro_owner_regions`、`liquid_regions`、`attachment_regions/attachments`，以及引用实例的完整祖链。只带主 map 而不带／重建对应局部索引，现有 helper 会把内容视为空。证据：`world/payloads.ex:158`；`world/canonical.ex:75`、`:107`、`:141`、`:183`；`apps/mmo_contracts/lib/mmo_contracts/voxel/refined.ex:129`。
- L1+ 还读 `structure`；所有级别都会进入 `Canopy.project`。后者读取 L0 宏格归属、实例、定义的 `presentation_bindings`、L0 当前材料；粗层残余归约进一步读沿途层级的地形、结构、细化和附件支撑。证据：`world/payloads.ex:152`、`:197`；`world/canopy.ex:9`、`:58`、`:71`。

事实：`Canopy.span_regions` 按 `2^level` 放大范围，L5 core 对应 32³ 个 L0 区域，含 ring 的候选范围为 34³，而不是 27：`world/canopy.ex:51`。实例祖链也不保证 home 在这 27 页内。旧检查点特意携带精简的 prefab bindings，恰好是当前草稿没列清的依赖：`world/log.ex:299`。

推断：照 §5 的输入直接调原函数，可能缺键失败、丢细节，或通过 source／全局表重新拉入大范围数据。缓存命中只能绕过当次编码，无法证明缓存 miss 时闭包有界。粗层树冠段若完全留到 M2b，本步必须承认并约束其跨层输入成本，不能同时承诺单页只复制固定邻域。

最小修订：逐级明确离线物化所需的不可变输入和引用闭包，在唯一物化入口复用算法；缓存 miss、跨页祖链、粗层树冠都须可运行。若该自然单元仍过大，应调整上游页段划分或提前落实父稿的粗层树冠段，而不是在消费侧增加备用真值路径。

### 3.2【严重】只冻结 D_C 的页键不等于冻结 C 的页值，分批跨回合存在混合切点

**对应：§5、§6；父稿 I2、P3。**

事实：现实现于 `thermal_run == nil` 时一次取得完整不可变 `checkpoint_input`，后续任务始终读取该版本：`world.ex:1609`、`world/log.ex:299`。新稿只明确“取出 dirty_pages、清空、分批抽页”，没有交代每个尚未抽取的页及其依赖怎样保留 C 时的值。

推断反例：C 时 A、B 都脏；先冻结 A；C+1 的跨页提交修改 A、B；再从当前 World 抽取 B 并标 `cut_seq=C`。发布后 A 是 C、B 是 C+1，全局行甚至可能是另一个时刻。若两批之间开始热步进，后批还可能带入尚未提交的 damage／sources。只在“打开切点”时检查 `thermal_run == nil` 不够。

反过来，在同一个 World 回合把全部 D_C 及闭包抽完再发出，虽然语义一致，却仍可能形成 O(D_C) 的长回合，不能由“每条消息有上限”推出单回合有界。

最小修订：明确 C 时冻结的页版本根／不可变引用、跨页依赖和全局行；之后只分批运输该版本。C 后的新写入不得改变未发送页的输入，旧版本存活量纳入预算；提交成功后才确认相应版本。需要写清这一机制，不能只以最终数据库事务代替内存快照一致性。

### 3.3【中】epochs 倾向区域嵌套作为唯一表示；其余元数据按页提取也缺接线

**对应：§5。**

选择：倾向 `region → cell → epoch` 为 epochs 的唯一常驻表示，并用 owner 访问函数维护；不建议同时保留完整平铺表与大份区域索引作为长期方案。理由是本任务已经需要按页取值，而 epochs 持续增长，双表示额外占用并不改善语义。此为设计取舍，性能收益尚未实测。

源码证据：单点读取在 `world/canonical.ex:322`，批量写入在 `world/tools.ex:495`、`:565`，恢复在 `world/log.ex:420`，观察输出在 `world/observation.ex:194`。已有按区域维护子表的具体模式可参考 `world/canonical.ex:91`、`:195`；不要把改动扩成无当前需求的通用分页框架。对外 wire／观察契约保持原语义，不要在每笔提交重新扁平化整张 epochs。

另外，§5 只为 epochs／damage／placed_by 加索引，尚未说明按 home 提取 instances／aid 元数据，以及按页提取 sources／liquid_active 的复杂度。若每个脏页都扫描这些全表，冻结成本仍随世界或活动集增长。证据：实例／owner 当前是平铺 map（`world.ex:556`、`:633`），sources 是整表（`world/catalogs.ex:79`），活动集是单个 MapSet（`world.ex:561`）。必须逐项给出提取入口与增长轴。

### 3.4【严重】“先只计量、实测积压再限流”取消了本阶段已经承诺的资源上界

**对应：§5 最后两条、§6 的可排队切点；父稿 P3。**

事实：当前只有一个进行中 checkpoint job，输入一次冻结，但可继续提交后缀：`world.ex:1602`、`:1609`；内存历史随提交增长：`world/log.ex:64`。新稿允许提前排队切点，却没有限定待发送输入、工作进程 mailbox、未发布版本、重脏页和日志后缀的总量。

推断：即使消费端每秒限速，生产端持续发送仍可使队列及旧版本增长；PG 暂停或单个大页编码变慢即可触发，不需要等 M0 正常负载先出现。统计与报警不能维护“不靠 mailbox 吸收”的不变量。

最小修订：本步必须明确并实现有限在途窗口、上游接纳行为及超限可诊断结果；速率自适应可以后置。每个切点整行写全局账的成本也必须单独计量，不能被“与脏页数成正比”掩盖。平滑检查点 I/O 的工业依据可参考 [PostgreSQL WAL Configuration](https://www.postgresql.org/docs/current/wal-configuration.html)，但它不替本应用实现生产者背压。

## 4. 多版本页与安全前缀是否满足 I1–I3，退休与补发是否完整？

### 4.1【严重】多版本方向成立，但崩溃恢复后的脏集合、未发布版本和重试尚未形成闭环

**对应：§6、§7；父稿 I1–I3。**

在“页值确为 C、全部脏目标覆盖、C 单调发布”的前提下，只发布完整切点可以保留现有“切点状态 + 完整日志后缀”语义，不必为本步引入按页跳过 WAL 的规则。PG 事务能原子发布水位与最后一批，依据是 [PostgreSQL Transactions](https://www.postgresql.org/docs/current/tutorial-transactions.html)；它不能证明前述应用层前提。

当前稿的缺口是：进程崩溃会丢失 D_C 和“在途”内存，不能靠“确认前不丢”保证下次仍脏。现有恢复直接 `replay_entry/replay_liquid/replay_damage`，不调用 append：`world/log.ex:84`。新稿必须明确从安全前缀之后的 WAL 重建待持久页，而非只恢复世界值。

推断反例：P 后一笔提交改 A、B，C 的 A 已写、B 未写即崩溃；恢复 P+后缀后内存真值正确，但若 dirty 集未重建，下一切点仅写新改动 X 并删掉旧后缀，再重启就丢 B。仅验证第一次重启看不出。

还须明确：未发布的 `cut_seq > P` 行怎样处理；相同 C 重做遇到已有主键怎样判定；最后事务已提交但回调丢失时从持久水位恢复；旧任务不能倒退 safe_prefix。`max(cut_seq) <= P` 不是独立的“已发布标记”：未来 P 越过遗留版本时，它会落入可见范围。若依靠完整重放重建脏集并在下一发布前覆盖这些页来保证安全，须把这一条件写入合同。

I1：PG 版本和写回输入只能是不可变已提交表示，唯一在线写者仍是 World。I2：取决于第 3.2 条的冻结。I3：取决于完整覆盖、单调发布及重启后的恢复协议；当前稿还不能声称已经满足三者。

### 4.2【严重】删除旧日志时必须同步替换订阅／诊断／Replica 的历史合同

**对应：§6；父稿 P3 末。**

事实：`subscribe` 仅从 `state.entries` 取 `seq > have_seq` 的事务，没有“游标早于安全前缀”拒绝：`world.ex:1319`。当前检查点作为完整补丁被保留：`world/log.ex:319`、`:383`。`entries_after` 对纯属性投影从 backend 补正文，缺正文会 `Map.fetch!`：`world.ex:1331`。区域增量读取也依赖 `entry_regions/entries`：`world/payloads.ex:44`。

推断：新页表删掉前缀且不再保留完整检查点后，旧游标可能只收到剩余后缀却被当作成功；保留旧投影而删掉正文又可能让诊断读取失败。页版本不能拿来伪造历史切点补丁。§6 不能只改 SQL。

最小修订：明确 `cursor < P`、`cursor == P`、`cursor > P` 的读／订阅语义，旧游标显式要求当前完整快照；成功发布后退休 `entries` 与 `entry_regions`，保留真正需要的后缀，安排好数据库发布至 World 确认间的读取行为。`compact/1` 仍须保证覆盖调用时序号并在持久后回复：`world.ex:481`、`:1408`。

Replica 当前按“落后一轮 checkpoint”保留 delta：`replica.ex:201`；`canonical_deltas_after` 对太旧游标显式失败：`replica.ex:108`。应由 World 在持久安全前缀发布后发送退休通知，保留与事务消息的顺序（现发送点 `world/log.ex:387`）。从约 60 秒变成约 2 秒后，“一轮”的时间保障明显变短；推断：原转移窗口更容易越过退休边界，需验证调用方显式失败／重新准备，不能默认原行为不受影响。

### 4.3【中】一致读、分世界删除和清理速率必须成为存储 API 的明确合同

**对应：§6、§7。**

事实：旧恢复是一次 `read_all` 查询；新恢复要分别读取水位、页、全局行与日志：`apps/data_service/lib/data_service/voxel/overlay_log_store.ex:63`。PG 默认 Read Committed 下连续 SELECT 不保证同一快照；只写“读到的是一致快照”不足以定义实现。可使用同一只读 Repeatable Read 快照，或明确恢复期间写回／GC 的互斥生命周期；依据：[PostgreSQL Transaction Isolation](https://www.postgresql.org/docs/current/transaction-iso.html)。这只要求存储边界保证一致，不要求下游重复扫描验真。

`DELETE voxel_overlay_log WHERE seq <= C` 必须带 `content_version` 约束，页／全局旧版本清理也相同；旧实现明确这样做，并把 u64 cv 按补码转 bigint：`apps/data_service/lib/data_service/voxel/overlay_log_store.ex:40`、`:44`、`:118`。当前草稿 SQL 省略这些内容，应补齐，不能照字面执行成全世界删除。

最后一批捆绑一次性删除全部前缀，事务成本随积压后缀增长，不受“每批页数／字节”上限约束；父稿要求渐进删除。可让持久安全前缀作为删除授权，后续分批清理，读方只消费 `seq > P`，而不把逻辑退休绑定成一个大 DELETE。旧版本清理还应保留每个未更新页的最新可见版本，明确清理 `voxel_world_globals` 旧行、失败切点垃圾及单批预算。证据：现有删除本来就是一个整体 SQL（同文件 `:48`），并非已存在的限速清理器。

## 5. M2a／M2b 拆分是否合理，会不会造成格式返工？

### 5.1【轻】可以拆交付，但需要保留父稿的最终页语义，不能把 M2a 当作分页完成

**对应：§2、§3、§7；父稿 P1、M2。**

允许本步全页驻留、延后淘汰和按需准备，能够把连续写回与装页调度分开验证。现有启动确实全量重放并重建派生物：`world.ex:662`、`:685`。因此 M2a 只证明写回路径变化，启动／常驻仍随全世界增长，稿中明确这一点是正确的。

但归属和页格式应尽量一次对齐：按命中 micro 保存整件 HP、未定义 aid home，以及粗层页依赖 L0 现算，都不是简单“以后补一个 loader”。它们会改变未来定位、读取闭包和数据迁移。依据见第 1.1–1.3、3.1 条及其源码。

`format: 1` 可以承载版本化 envelope，但须列明 canonical core、home 元数据、派生 ring／canopy 各自的权威性和恢复入口。只加格式号不能消除语义返工；本步若保留过渡段，应写出 M2b 的转换边界，不必提前实现完整按需装页。

### 5.2【严重】“表空才迁移”不能覆盖中途崩溃；“全部页”必须包含纯元数据页

**对应：§7。**

推断：首次迁移已写若干页但未发布 safe_prefix 就崩溃，新表非空而安全前缀不存在；按“表空才迁移”无法选定合法恢复路径。下一次用同一 `S.seq` 重写还可能碰撞主键。迁移是否完成必须由已发布水位／完整发布状态判定，并明确未完成数据的重做或清理；全过程继续只使用隔离库，源库与备份只读。

“S 的全部页”不能仅取 snapshots／overlay 区域：epochs 可在地形回到 baseline 后仍存在，home 身份可在无本地实占用的锚点页，热源／damage 也可能只改元数据。现有检查点把这些全表单独保存，分页后必须从各 canonical 字段的归属并集枚举；证据：`world/log.ex:319`、`:334`；`world/canonical.ex:322`；`world/prefabs.ex:393`、`:451`。空内容页仍须保存显式版本，不能物理删除后将其解释成“从未编辑”（父稿 I4）。

还须定下迁移发生在 `restore` 后还是启动迁移／环境规范化后。现有 `restore` 明确不迁移，后续 init 才转换旧 damage：`world.ex:502`、`:685`、`world/heat_commit.ex:234`。两条路线只要选择一致并验证即可；不能一边截取旧 S，一边在另一侧比较经过迁移的新 S。

## 6. 测试与验收能否证伪漏写真值和崩溃不一致？

### 6.1【严重】现有场景目录还不足以覆盖已经找到的反例，应补成最小失败矩阵

**对应：§8；共同测试规则 `../Voxim/Docs/Testing.md` §1、§2.2、§5。**

恢复逐字段比较是正确主判定器，但“每类一个场景 + 第 k 批退出”不能覆盖本稿的关键交错。最小增加以下场景，均由正常入口产生真值；故障只注入写回／持久边界：

1. **脏页判定**：纯液体 journal；热源消耗至删除；活动液体由非空变空；跨页部件连续命中与独立附件。必须切掉相应日志前缀且不让后缀再次修补该字段。源码：`world/edits.ex:374`、`world/thermal.ex:480`、`world.ex:1433`、`world/canonical.ex:363`。
2. **切点并发**：C 的 A 页已冻结、B 未冻结时，从正常入口提交跨页 C+1；全局账随同一提交变化；其间启动热步进。对冻结状态和恢复后缀分别断言。源码：`world.ex:1581`、`world/heat_commit.ex:57`，对应第 3.2 条推断。
3. **恢复装入顺序**：跨页实例带 `placed_by`、祖链跨 home；交换页读取顺序，结果完全一致；覆盖仅元数据页和删除后空页。源码：`world/log.ex:129`、`world/prefabs.ex:453`、`apps/mmo_contracts/lib/mmo_contracts/voxel/refined.ex:107`。
4. **崩溃后再发布**：半切点崩溃 → 恢复 → 提交无关页 → 再发布 → 再重启；另覆盖首次迁移半写、发布已提交而确认丢失、重复处理同一 C。源码边界：`world/log.ex:84`、`world.ex:1408`、`apps/data_service/lib/data_service/voxel/overlay_log_store.ex:48`。
5. **退休读者**：分别以 P−1／P／P+1 订阅和读历史；Replica 在两次快速退休之间读取转移后缀，明确成功或过期错误；页版本不得伪装成旧切点。源码：`world.ex:1319`、`:1332`、`replica.ex:108`、`:204`。

测试侧 B 对拍应独立覆盖字段清单和归属，不得与 A 共用同一个漏字段的枚举器。故意漏标须是明确的 Test-only 故障注入；若后缀重放又恢复该字段，测试会假绿。上述反例直接来自本次变更的信任边界，不要求扩大到无关全套。

### 6.2【中】原子性必须用真实隔离 PG 证明，现有 File 测试不能代表新页表

**对应：§8。**

事实：默认 World 测试后端是 File（`world.ex:511`），File 的 checkpoint 是单文件 rename（`overlay_log.ex:137`）；它不具有新方案“多表、多次事务、最终发布”的失败面。现有前缀测试覆盖了后缀保留、重复 checkpoint；真实 DB 测试覆盖第二插入批失败整体回滚，可复用其测试意图：`apps/voxel_region/test/overlay_log_prefix_test.exs:18`、`:42`；`apps/data_service/test/data_service/voxel/overlay_log_store_test.exs:86`。

最小修订：纯归属／脏集测试不启数据库；页存储的跨连接可见性、进程崩溃、重启和发布用真实隔离 PG，固定 cv 并包含另一个 cv 不受删除影响的断言。现有 DB 测试 setup 会调用全表 `reset`（同测试文件 `:14`；实现 `apps/data_service/lib/data_service/voxel/overlay_log_store.ex:78`），不得把它直接指向源库或共享存量库。跨重启用例不能依靠会回滚或屏蔽可见性的事务夹具。

本次未执行这些测试；它们是设计稿需要补齐的后续验收安排。

### 6.3【中】等价判定与性能门槛还需限定观察时点和比较对象

**对应：§7、§8。**

事实：rebase 会吸收稀疏 overlay、转换 `region_bases` 并使缓存失效，表示变化不等于真值变化（`world/log.ex:185`、`:208`）。`payload_bytes` 缓存命中可保留旧 header seq，而 canonical 发送另行盖当前序号（`world/payloads.ex:69`、`:420`）。因此不能直接用所有私有 map 或未经同序号处理的 VXR 字节逐项相等替代语义等价。

最小修订：在合法提交边界记录同一 seq 的 canonical core 与完整持久元数据；区分表示归一化和属性数值。恢复不得先让热／液体继续演化后再与停机前比较。保留 g=2/3 max_hp／现存 HP 的精确语义，不擅自添加容差；当前代码专门保留 refined 的全表遍历顺序以维持浮点结果，证据为 `world/canonical.ex:210`、`:413`。恢复场景也应覆盖新 VM ETF 解码边界，复用 `apps/voxel_region/test/overlay_log_fresh_vm_test.exs:11` 的意图。

性能部分的“毫秒级、与改动量成正比”尚不是通过阈值。应区分单次 World 回合与整个切点总耗时，记录冻结输入／旧版本／mailbox／后缀／全局行的字节数、缓存 miss 的粗层成本、写入与删除速率，以及受限存储下的接纳行为。采用 §8 已有 M1 负载即可，补一个能证伪预算的受控慢写回；不因本报告扩成更大的全套。源码中 `Payloads` 的粗层跨层读取及整行 checkpoint 元数据正是需要分开观察的成本来源：`world/canopy.ex:51`、`world/log.ex:334`。

## 总评

【严重】不能按 v1 直接开工；“多版本页 + 完整切点发布”方向可保留。
最少修订一：改正 aid 槽编号误用，按父稿明确身份 home；页加载不得用网络实例投影覆盖完整元数据。
最少修订二：覆盖全部 WAL 出口，补热／液体的真实提交前像，以及启动和离线维护的持久接线。
最少修订三：定义 C 时不可变页输入与跨层闭包，落实有限在途量和接纳边界。
最少修订四：补崩溃后脏集重建、未发布版本／重试、首次迁移和同 seq 维护语义。
最少修订五：将安全前缀接到订阅、entries、Replica、compact 与分批 GC，保证分世界及一致读。
最少修订六：补上述最小反例和真实隔离 PG 验收；本评审没有运行验证，不构成运行验收结论。
