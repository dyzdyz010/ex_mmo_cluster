# M2a 交叉评审（astra）：设计稿 v2

日期：2026-10-26。按 `review-brief-m2a-cross.md` 阅读 `review-fable-m2a.md`，对照本人的 `review-astra-m2a.md`，重新核对 v2 与源码。源码 HEAD：`acb401e70906af6fd22ed40db874f23cecb98517`；本次所评 v2 的 SHA256：`3E02FF72C5CDC308B2D433AE4ABB93CB83A92B890433AA92D3812AE496B15D9A`。

**结论：仍不能按 v2 直接开工。原始页段、冻结引用和有限写回窗口可以保留；六组必须先修订的事项列在第 6 节。** 本报告只做静态评审，未修改代码或设计稿，未提交，未运行服务、测试或基准，未操作 Docker／数据库；唯一写入为本报告。下文“推断”均未经实跑。

证据路径除显式 `apps/...` 外，均相对于 `apps/voxel_region/lib/voxel_region/`。稿内章节指 v2；“F”指 Fable 首轮条目，“A”指本人首轮条目。【严重】表示阻塞项；【中】【轻】可在相关阻塞合同修正后随实现落实，不单独扩大开工门槛。

## 对 Fable 首轮意见的校正

### X1【中】F1.1／F5.1 的“与父稿 home 一致”不成立；但不能据此断言现行无主附件必然跨页迁移

同意 F1.1 关于 `slot` 是定义编号、g=2/3 的 `micro` 可变，以及 `world/tools.ex:461` 改写 before 的证据。不同意其建议与父稿等价的结论：父稿 P1 明定 **aid home = 创建时首槽 anchor 所在页，之后不迁移**；owner 实例 anchor 可以离附件很远，因此“有主 aid 归 owner home”是新的归属规则。源码中 owner anchor 与附件世界槽来自不同数据：`prefab.ex:339`、`prefab.ex:353`、`world/prefabs.ex:456`、`world/prefabs.ex:470`。

另一方面，现行正常玩家无主附件只允许 size 1／8，size 8 要求 anchor 按宏格对齐；足迹沿正方向展开至多 8 微格，因此同一 aid 的槽都在同一宏格／L0 页内。证据：`apps/mmo_contracts/lib/mmo_contracts/voxel/codec.ex:130`、`world/attachment_ops.ex:178`、`attachments.ex:13`。parcel 对槽做宏格整数倍平移：`world/parcel.ex:111`、`world/parcel.ex:117`。

推断：对上述合法来源，删掉最小槽会换“代表槽”，**不会换 home 页**。v2 可利用这个已有不变量，不必为假想跨页情况增加运行时迁移协议；但须核定存量迁移输入也满足它。若允许跨页无主 aid，则动态最小槽规则与父稿确实不同，须明确选择，不能同时宣称 home 不迁移。

### X2【严重】F1.2 把实例投影装入问题仅看作 M2a 启动成本，严重度偏低

原 `replay_entry` 会把载荷实例覆盖到完整实例表；VXR 编解码没有 `placed_by`，而实例持久记录有该字段。即使 M2a 全量装页，也会因顺序丢失它，不只是 M2b 才有正确性问题：`world/log.ex:129`、`world/prefabs.ex:453`、`apps/mmo_contracts/lib/mmo_contracts/voxel/refined.ex:18`、同文件 `:107`。这与 A1.3 的严重度一致。

v2 改存原始值并取消该 merge／live 裁剪，已解决此项的设计原因，不要求重复修改；剩余新装入问题见 R2。

### X3【严重】F1.4 的“liquid_active 下一笔自愈、无害”与 F2.3 的“没有其他在线旁路”结论过强

World 在液体回调前清空在线活动集，数量不变时可能不产生日志：`world.ex:1430`、`world/liquids.ex:355`、`world/edits.ex:192`。不存在保证“必有下一笔”的合同。即使后来恰有事务，v2 还需要解决在线 remember 收不到 WAL 补入活动集的问题，见 R1。

`liquid_active` 控制是否安排后续步进（`world/liquids.ex:17`），不是可忽略的显示缓存。不能把未批准的恢复差异定为无害，或者让邻区未来编辑承担修复责任。v2 也不能通过把验收字段换成 committed 副本就宣称旧语义已等价，见 R4。

### X4【中】不采纳 F2.3 的额外热域门禁，也不采纳 F3.2 在 World 内补算粗层载荷的建议

`Thermal.tick` 完成时同步调用 `settle_run`，后者先 flush；World 再完成热提交，然后尝试 checkpoint：`world/thermal.ex:121`、`world/thermal.ex:158`、`world.ex:1581`。当前切点 owner 已有合法提交边界。`domain.pending == false` 应由热 owner 在该边界维护，可用测试证明，不应让分页 owner 再穿透热工作域追加一层正确性判定。v2 §4.2／§5.1 这一吸收增加了不必要的内部耦合。

粗层缓存 miss 在 World 内现场物化，则会把跨层读取／编码长回合留在目标路径：`world/canopy.ex:51`、`world/canopy.ex:71`。v2 选择原始页段更直接，已使 F3.2 的补算建议不再需要。

### X5【中】F4.2／F4.5 的重试建议缺少“发布结果未知”分支；F4.4 的时间窗也不是已有保证

进程退出不等于数据库事务未提交；不能无条件把在途页回脏后重写，也不能笼统用 `ON CONFLICT DO UPDATE` 覆盖不可变切点。当前实现明确区分持久化与 World 完成回调：`world/log.ex:292`、`world.ex:1408`；新协议须补状态转换，见 R5。

“让 World 失败等于整节点重启”也不准确，当前应用是 `one_for_one` supervisor，World 是其子进程：`application.ex:23`、`application.ex:48`。采用 monitor 还是失败后由 supervisor 恢复，是失败模型选择；不能为避免 World 重启默认增加一个未闭合的自动重试路径。

Replica 现在按上一退休序号裁剪，而 checkpoint 是按活动触发，故 60–120 秒不是严格时间保证：`world/log.ex:77`、`replica.ex:204`。同意把新节拍与历史保留需求分开，但应声明需要维护的时长／过期结果，而不是把原节拍推成现有 SLA。F2.4／F3.3 所谓嵌套表和 B 比较“免费、必不增内存”同样应收敛为待测判断；区域键仍需枚举：`world/canonical.ex:187`。

## 1. v2 是否正确吸收首轮意见？逐条对照 §0

以下依 §0 表中顺序逐项核对；详细反例在后续对应编号展开。

1. **【中】slot 编号错误：已修正输入误读，但新 home 并非父稿原规则。** §3 改归 owner anchor，须说明归属变更与无主附件合法来源；见 X1／第 2.2 条。证据：`prefab.ex:339`、`world/prefabs.ex:470`。
2. **【轻】micro 可变／before 被改：改用身份和旧页索引方向正确。** 删除行先使用旧索引、再退休索引，应成为构造入口的顺序合同。证据：`world/canonical.ex:357`、`world/tools.ex:461`。
3. **【严重】取消实例 merge／live 裁剪：原问题关闭，但新 loader 漏了物化标记。** 见 R2。证据：`world/log.ex:214`、`world/payloads.ex:77`。
4. **【轻】载荷闭包过大：已解决页写回的闭包问题。** §3 不再调用网络物化，原 `Canopy.project` 跨层依赖不再进入页编码；无需再补 v1 的 27 邻页输入。证据：`world/payloads.ex:152`、`world/canopy.ex:51`。
5. **【严重】共同 WAL 出口：remember 是共同成功点，但它未收到草稿假定的完整事务。** 见 R1。证据：`world/log.ex:22`、`world/prefabs.ex:572`、`world/edits.ex:335`。
6. **【严重】before 不代表已提交状态：sources 的提交副本合理，liquid_active 的新恢复语义尚未批准。** 见 R1／R4。证据：`world/heat_commit.ex:57`、`world.ex:1433`。
7. **【轻】分批混合切点：frozen 引用解决逻辑快照问题。** 所有页段、全局行及索引都必须取该引用，见第 4.1 条。现选择输入的先例：`world/log.ex:299`。
8. **【中】资源上界：信用窗口与拒绝入口已补，单个全局行、提取成本及恢复唤醒仍需落实。** 见第 4.2–4.3 条。证据：`world/log.ex:334`、`world/liquids.ex:17`。
9. **【严重】崩溃脏集／孤儿／重复 C／回调丢失：只闭合了节点重启的一部分。** “C>P”推不出“同 C 不重试”；见 R5。证据：`world/log.ex:84`、`world.ex:1408`。
10. **【严重】旧游标与 Replica：补了文字，但所选合成快照不具备所称协议语义。** 见 R6；Replica 时长细节列【中】。证据：`log_projection.ex:55`、`apps/mmo_contracts/lib/mmo_contracts/voxel/codec.ex:930`、`replica.ex:204`。
11. **【中】一致读／cv／渐进删除：原则正确。** 实现时明确先读取哪个稳定 P 再清孤儿，清理期间禁止旧写回继续发布；无需多加下游验真层。原单查询／cv 边界：`apps/data_service/lib/data_service/voxel/overlay_log_store.ex:44`、同文件 `:63`。
12. **【严重】写回进程死亡：monitor 不能证明未发布。** 与第 9 项合并为 R5，不另算阻塞项。证据：`world/log.ex:292`、`world.ex:1408`。
13. **【严重】CoarseRebuild／启动规范化：标脏不足以满足严格新 seq 的切点条件。** 见 R3；维护空事务还需有真实重做或重跑合同。证据：`world/coarse_rebuild.ex:68`、`world/heat_commit.ex:234`。
14. **【中】迁移完成标志及全字段页并集：已修复“表空”与纯元数据页遗漏。** 首次无页／seq=0 的 bootstrap 仍需在 R3 中定义。证据：`world.ex:545`、`world.ex:646`、`world/log.ex:334`。
15. **【中】structure：本步保留重算可以；“不比较派生物”不能免除正式读取等价。** M2b 仍需增加 structure／canopy 持久段，不宜写成页段永远不变。证据：`world/payloads.ex:197`、`world.ex:686`。
16. **【中】反例矩阵：明显改进，但还缺本次发现的边界，见第 6 节。** 只比私有真值不能抓到 R2 的正式读取错误。证据：`world/canonical.ex:239`、`world/payloads.ex:77`。
17. **【轻】epochs／placed_by 嵌套：采纳合理。** 实现中测实际空间和展开成本，不额外要求 B 做产品路径。证据：`world/canonical.ex:322`、`world/tools.ex:565`、`world/observation.ex:194`。

## 2. 原始页段是否完整、能否衔接 M2b，无主附件 home 是否可靠？

### 2.1【严重】R2：原始字段基本齐备，但 loader 只填 base 会让正式载荷绕过权威数据

**对应：§3、§6.2、§8。**

事实：`payload_bytes` 缓存 miss 后，只要该区没有 overlay 索引、没有 `snapshots` 标记、没有相邻 region base，就直接返回 source。它的这条快路径不检查**本区** `region_bases`：`world/payloads.ex:73`、`world/payloads.ex:128`。旧 `rebase_region` 在装 base 的同时写 `snapshots`：`world/log.ex:214`。v2 新 loader 只说“base 进 region_bases”，取消旧装入路径后没有恢复这个必要派生状态；`put_refined`、`put_liquid` 也不负责该标记：`world/canonical.ex:38`、`world/canonical.ex:60`。

推断反例：隔离区域经旧 checkpoint 变成一个 base，已无稀疏 overlay，同层邻区无 base。迁入 v2 页并重新启动后，`cell_value` 能读到编辑后的 base，`payload_bytes` 却走 source 返回原始地形。只比较 canonical core／元数据可能全绿，客户端读回仍错。

开工前最小修订：在唯一装页构造入口，从 base／实际细节段恢复该页应物化的标记及必要索引，或者把快路径改为消费同一明确的装入合同。此为重建派生状态，不是把 snapshots 新增为第二份持久真值。页加载后的正常 serve／canonical snapshot 必须读取与 `cell_value` 相同的权威内容。

### 2.2【中】home 需区分已批准规则、当前可推导不变量和坐标单位

**对应：§3；父稿 P1。**

有主 aid 归 owner home 是可实现的稳定方案，但与“附件创建首槽页”不同，须修正“父稿 P1／页段归属不变”的表述；不要为了附会旧文字去改变 `attachment_owners` 的业务值。无主 aid 采用最小存活槽的**页**，对 X1 所列现行正常来源可证明不迁移；全部槽删除时用 `damage_pages` 的旧页移除行，不能对空集合求 min。证据：`world/tools.ex:107`、`world/attachment_ops.ex:201`、`attachments.ex:35`。

§3 示例的 `div(anchor, micro)` 应改为对每轴向负无穷取整。正常纯微格 prefab 没有宏格对齐要求：`world/prefabs.ex:35`；现有标准换算用 `Integer.floor_div`：`prefab.ex:416`。推断反例：anchor.x = −1 微格，截零除法会错误归到 x=0 页，正确是 x=−1 页。这是明确可修的小规则，不需要新坐标层。

### 2.3【中】原始页格式减少返工，但不是“加 loader 即完成 M2b”

**对应：§2、§3 最后一段。**

原始段包含核心真值、完整实例以及独立来源的全局账，避免网络投影损失，是可保留的格式方向。base 中现有 66³ 的 ring 是派生冗余，声明只由 core 拥有真值即可，不要求现在另造地形压缩算法；证据：`world/log.ex:186`、`world/payloads.ex:128`。

但 M2b 要去掉全量结构重建与 L0 树冠读取，仍需增加粗层 structure／canopy 段及父稿要求的身份覆盖／汇总。当前求整件 HP 仍跨全部该身份占用：`world/canonical.ex:413`、`world/canonical.ex:426`；粗层仍读 L0：`world/canopy.ex:51`。因此应写成“已有段可沿用，M2b 增加已列明的段／定位能力”，不能承诺格式和归属无任何扩充。

## 3. remember_entry 判脏是否覆盖全部路径，活动液体语义差异能否接受？

### 3.1【严重】R1：共同成功回调不等于共同完整提交输入，online／replay 仍不对称

**对应：§4.1、§0 第 5 项。**

事实：`append_log(before, state, txn)` 内部通过 `attachment_metadata` 为 WAL 加入 `prefab_instances`、`attachment_owners`、`liquid_active` 等字段，然后只返回 `:ok`（`world/log.ex:22`、`world/log.ex:38`）。调用者随后给 remember 的仍是原 `txn`：`world/prefabs.ex:565`、`world/prefabs.ex:572`、`world/prefabs.ex:574`；附件入口同样如此：`world/attachment_ops.ex:98`。纯液体分支也仅给日志表示补元数据，remember 使用另一份原事务：`world/edits.ex:333`、`world/edits.ex:374`。回放则拿到已经补齐元数据的事务（`world/log.ex:84`）。

推断：照 §4.1 “按事务字段”实现，新实例／aid home 索引可能根本不更新，`committed_liquid_active` 也停留在旧值。几何页被 kind1 顺带标脏，并不能保证远处 home 页被标脏，或 `page_instances` 能抽到新实例。在线写回会漏，而重启回放又可能暂时补回来。

开工前最小修订：定义一份成功提交后实际交给判脏的完整内部输入，让在线和回放都消费它；WAL 优化形态与广播形态可以不同，但元数据／变更键不能在其中一条链上丢失。也可由成功回调基于明确的 committed 状态更新索引，但必须写清依据，不能仍声称缺失字段存在。删除身份先读取旧页映射再更新索引，不依赖已经被改写的 before。

### 3.2【严重】R4：不接受“恢复活动少了就等相邻改动唤醒”作为本次持久化优化的默认行为

**对应：§4.2、§8 的 committed liquid_active 判定。**

事实：旧 checkpoint 保存在线 `liquid_active`（`world/log.ex:38`、`world/log.ex:352`），该集合决定液体是否继续排程（`world/liquids.ex:17`）。在线回调会清空、重建它，而无变化分支可以不写 WAL：`world.ex:1433`、`world/liquids.ex:355`、`world/edits.ex:192`。所以它相对最后一次日志记录可能不同，不能把在线状态和已提交副本混为同一个事实。

推断：差异不一定是稿中说的“少几个格”，也可能是旧活动格重新复活。一个已稳定、在线活动集已清空的世界可以在 committed 副本里仍保留旧活动集。无论变多还是变少，v2 都改变了旧 checkpoint 的恢复行为；§8 改比 committed 副本只证明新表示自洽，不证明迁移等价。

开工前最小修订：采用稿中已列出的无几何 `liquid_active` 提交方向，让需要持久的活动集转换由液体 owner 提交并进入 R1 的同一完整输入；明确无变化步、停止与恢复的语义。不要求靠邻区操作、自愈扫描或重新注入液体来修复。若决定活动集本就不需要精确持久，应单独修改其产品恢复合同并证明活性，不能作为 M2a 的隐含例外。

### 3.3【严重】R3：只有脏页才能开切点，漏了纯全局提交；规范化标脏与 C>P 也冲突

**对应：§4.3、§5.1、§6.1、§6.3、§7。**

事实：正常供料、进食可只写全局账而没有任何几何页变化：`world/production.ex:92`、`world/production.ex:164`。§4.1 把它们归为“全局行脏”，但 §5.1 要求 `dirty_pages` 非空，当前列出的状态也未把全局行纳入可开切点的条件。

推断：只有这类事务时，WAL／entries 无法退休，`compact` 也可能永远等不到可开的切点；不是只有性能差一点。恢复至已发布 P 后，启动规范化直接改 damage／thermal 且不增 seq（`world.ex:673`、`world.ex:685`、`world/heat_commit.ex:234`），即使标脏，也被 §6.1 的 C>P 拦住。首次迁移 S.seq=0、没有空间页的合法初态还没有明确初始化发布路径。

开工前最小修订：以“有需要持久的新提交／维护结果”驱动切点，允许 D_C 为空而只写全局行；不必再发明一个与 seq 重复的全局真值。规范化发生实质改变时，要有可重做的提交或明确的启动维护发布合同。`compact` 在目标已被 P 覆盖且无待提交维护时直接成功，首次 bootstrap 单独处理“尚无 P”。CoarseRebuild 的空维护事务只推进编号，不能单靠空事务重做粗层重建；应明确失败后重跑的独占维护合同或记录实际变化。旧维护入口不增加 seq、以检查点完成为成功边界：`world.ex:484`、`world/coarse_rebuild.ex:68`。

## 4. frozen、在途窗口与接纳边界是否足够，persist_backlog 是否合适？

### 4.1【轻】同进程 frozen + 信用窗口可以保留，消除了 v1 的混合切点与无界发送

**对应：§5.1–§5.3。**

只要页段、页索引、committed sources／活动集以及最后的全局行全部从 C 时的 frozen 读取，后续 World 改 map 不会改变这些不可变值。每批确认后再给信用，也能约束工作进程前的批队列。原实现已经以不可变输入做后台计算，只是一次把整份输入复制给 Task：`world/log.ex:299`、`world.ex:1609`。

实现时宜沿用原 `checkpoint_input` 的“只选择持久输入”原则，在 World 内保留必要字段的引用，避免 `frozen = state` 额外钉住 entries、订阅和无关任务／原生资源；这不改变冻结方案，不要求新的抽象。

### 4.2【中】批数上限不等于单回合／单消息字节上限；全局行仍是未分解的大单元

**对应：§5.2、§5.3、§8 基准。**

事实：全局账包含按历史增长的回执，当前 checkpoint 会把它们整值取走：`world/log.ex:334`、`world/production.ex:88`、`world/production.ex:161`。v2 把全局行放在最后一批，却没有说明它超过 `batch_bytes` 或复制超过 5 ms 时怎样处理。sources 和活动集也仍是平铺 committed 集合，§4.1 未列按页提取它们的索引；现有形态见 `world/catalogs.ex:79`、`world.ex:561`。

推断：如果按页扫描全 sources／活动集，单页提取仍随全局活动量增长；如果整份全局 map 发送跨进程，设置“5 ms 预算”并不能中断一次已经开始的复制。参数本身不是硬界证明。

可随实现落实：给出实际按页提取入口、单页／全局行的最大自然单元成本，单独计入字节窗口和观测；若全局行保留整行，则诚实列为当前已测的残余上界，不宣称所有回合已与全部增长轴无关。不要为赶验收在消费侧额外扫世界或把最后一批变成特殊真值事务。是否需上游再分段，由这一单元的实测与批准预算决定。

### 4.3【中】persist_backlog 可复用现有拒绝通道，但暂停必须有恢复唤醒和完整入口范围

**对应：§5.3。**

同意采用显式拒绝：`ResultFrame.error` 会把任意 reason 转成诊断字符串，不需要新增 opcode：`apps/gate_server/lib/gate_server/voxel/result_frame.ex:17`；正式 dispatch 已将 `{:error, reason}` 送入该入口：`apps/gate_server/lib/gate_server/session/dispatch.ex:287`。应在扣账、创建身份、消费意图状态之前做接纳，不把已接受的一半提交伪装成拒绝。

但新热／液体定时器暂停后，若没有新玩家操作，单靠“回落软阈值”不会自然唤醒。写回确认处理应由 owner 恢复既有调度，保留活动集，避免时间性不变量无人维护：`world/thermal.ex:22`、`world/thermal.ex:33`、`world/liquids.ex:17`。已有在途热事务允许到达合法提交边界，不能半途停住使 checkpoint 永远无机会开始。

接纳面也应覆盖会新增提交的作者入口、异步施法／投射物／身体后果，而非只匹配“玩家／GM／parcel”几个名字；入口实例见 `world.ex:1188`、`world.ex:1424`、`world.ex:1485`、`world.ex:1507`。这些是实现时的边界接线与短场景，不要求新增另一套事务调度系统。

## 5. 发布、清理、订阅与 Replica 是否闭合 I1–I3？

### 5.1【严重】R5：C>P 不保证不重复写 C；DOWN 也不证明当前切点未发布

**对应：§5.3、§6.1–§6.2、§8 第 4 项。**

推断反例一：P=10，C=12 的第一批已成功插入；写回进程在后续批退出，World 没有新事务，按 §5.3 把 D_C 回脏并重开。此时 C 仍为 12，仍满足 C>P，却与遗留 `(page,12)` 主键冲突。孤儿清理只在启动时执行，World 未重启时不会发生。即使故意推进到新 C，也没有定义旧未发布数据怎样退休。

推断反例二：最后事务已经提交 P=12，但通知前进程退出。World 按“未发布即不可见”丢弃切点是错误判断；它可能重写已发布版本、遗留 waiter 或错误处理退休边界。当前持久化完成与回调本就分离：`world/log.ex:292`、`world.ex:1408`；DB 事务完成后会持久生效，而不是由 World 消费消息才生效。此处采用的原子性含义见 [PostgreSQL Transactions](https://www.postgresql.org/docs/current/tutorial-transactions.html)。

开工前最小修订：写出无新事务的同 C 重试、已发布但未确认、旧结果迟到三种状态转换。失败处理先确定持久水位／该次尝试是否完成，成功的切点只做确认与退休；未发布的尝试按选定规则清理或重做，并保证没有旧写者继续写入。`UPDATE ... WHERE seq<C` 影响零行不是发布成功，应明确结果处理。不要仅凭 callback 丢失重放一轮，也不要把 `ON CONFLICT UPDATE` 当作不可变版本合同的替代。

### 5.2【严重】R6：当前 seq 的“合成完整快照事务”不是现有完整恢复合同，之后也不能回补旧后缀

**对应：§6.3；父稿 P3 末。**

事实：旧 subscribe 经 `LogProjection.message → Codec.encode_transaction` 发送日志事务，编码只含 entries、coarse、液体落体和操作字段，**不编码 property_states**：`world.ex:1319`、`log_projection.ex:55`、`apps/mmo_contracts/lib/mmo_contracts/voxel/codec.ex:930`。当前 canonical 快照走另一条明确快照入口，并通过同一 feed 在其后有序发送增量：`world.ex:1343`、`canonical_feed.ex:18`。把一个普通事务加上属性行，不会自动变成具有完整替换／清除语义的快照。

推断反例：P=10，当前 K=15，旧游标=8。先发 seq=15 的当前状态，再“照旧补发后缀”11…15，会产生倒序／重复；若接收者把它们拒掉，补发本身无意义；若接收者应用旧后像，就可能回退。v2 没有定义后缀从 K 开始，亦未给旧属性行的删除／complete 语义。

开工前最小修订：优先采用父稿已允许的最小方案——旧日志游标显式拒绝并要求走已有当前快照入口；`serve_item` 直接返回该区域完整 payload。若确实保留主动快照，则必须使用真实快照合同，在同一 owner 屏障取得 K 并只接后续 `seq>K`，不能另造同名“合成事务”混用。当前源码已经提供顺序正确的组合方式，不需要第二条恢复流水。

### 5.3【中】一致读与渐进 GC 可实施；Replica 仍需核对消费者和退休通知去重

**对应：§6.2–§6.3。**

单个 Repeatable Read 快照读 P／页／全局行／后缀、所有 SQL 以 cv 隔离、只删每页最新可见版本以下的历史，原则上可保留。隔离级别的必要性可核对 [PostgreSQL Transaction Isolation](https://www.postgresql.org/docs/current/transaction-iso.html)。清孤儿所用 P 必须来自明确的恢复阶段，且禁止与旧尝试写入交错；不要在逻辑上“读 P 之前”使用一个尚未确定的 P。

延后 60 秒发送安全前缀可避免每 2 秒立即退休，但应只发送单调推进的目标，明确无新切点时的收尾、发布时间记录的容量及软／硬预算。当前 Replica 仍使用上一次通知值作为实际 horizon：`replica.ex:204`；应按这个算法验证实际窗口，而不是再次用节拍估算。

消费者也不能只因 Replica 会返回错误就宣称传播完整。Scene 的无 stream 移交分支拿返回值后直接 `length(tail)`，未处理错误元组：`apps/scene_server/lib/scene_server/movement/scene.ex:369`、同文件 `:381`。有 stream 的分支绕过该读取，因此不能断言所有现行移交都会失败；但只要无 stream 分支仍在本次支持范围，就应覆盖其显式过期传播，或明确它的兼容范围。这属于直接受影响的既有接口验证，不需扩大全套。

I1–I3 的判断：I1 的唯一写者与原始页段方向成立；I2 的冻结方向成立，但须关闭 R1／R4 的 committed 输入差异；I3 仍受 R5 的尝试／发布状态和 R6 的读者顺序阻塞，不能只靠 SQL 水位单调宣布成立。

## 6. §8 能否证伪这些失败，是否可以开工？

### 6.1【中】保留现有矩阵，补针对 v2 的最小反例；派生结构不逐字段比较，但正式输出必须比较

**对应：§8；共同测试规则 `../Voxim/Docs/Testing.md` §1、§2.2、§5。**

现有纯液体分支、双重启、混合切点、装页次序、PG 隔离与新 VM ETF 用例值得保留。以下只补本次能直接证伪的边界，不增加无关 suite：

- **R1**：以正常 prefab／附件入口创建远处 home 身份，验证在线 remember 的元数据与实际 WAL 语义一致；切掉日志后不靠 suffix 修补。证据：`world/prefabs.ex:574`、`world/log.ex:38`。
- **R2**：一个有旧 rebase base、无 overlay、无同层邻 base 的页，启动后同时读 canonical core、serve 与正式快照，断言同一内容；不是只检查 map。证据：`world/payloads.ex:77`、`world/canonical.ex:239`。
- **R3**：只有供料／进食全局账，无空间脏页；第一次 bootstrap 无页且 seq=0；P 后无新用户事务的启动规范化；已经达到 P 时调用 compact。证据：`world/production.ex:92`、`world/production.ex:164`、`world.ex:1597`。
- **R4**：活动集非空 → 无数量变化步 → 活动集清空 → 无其他事务 → 持久／重启；核对运行时活动与调度，以及与旧路径的规范化真值，而非只对拍 committed 副本。证据：`world.ex:1433`、`world/liquids.ex:17`。
- **R5**：第一批完成后只杀写回进程、不产生新事务；最后发布已提交而确认丢失；显式处理影响零行的旧发布结果。新进程必须收口，不能靠下一笔新事务改变 C 才恢复。证据：`world/log.ex:292`、`world.ex:1408`。
- **R6**：P=10、K=15、旧游标=8 的实际接收方／实际 codec 轨迹；不能只观察服务端 send 成功。证据：`log_projection.ex:67`、`apps/mmo_contracts/lib/mmo_contracts/voxel/codec.ex:930`。
- **实现接线**：慢写回触发拒绝，写回恢复后无新用户输入也会恢复热／液体调度；负微格 anchor 的 home 正确；副本过期错误不变成 Scene 崩溃。证据：`world/thermal.ex:33`、`prefab.ex:416`、`apps/scene_server/lib/scene_server/movement/scene.ex:381`。

不要求比较整个派生 structure／cache 私有布局，但至少验证它们派生出的正常读取结果；v2 删除这一层验证会漏掉 R2。原始真值精确比较、同一资产集、新 VM、真实隔离 PG、不用全表 reset 等要求继续保留。本次没有执行上述用例。

### 6.2【严重】开工前必须修改的最少六项

1. **R1：完整提交输入。** 修正 remember 在线事务缺少 WAL 补入元数据的问题，统一成功提交／回放的判脏和索引更新合同（§4.1）。
2. **R2：完整页装入。** 明确 base／细节装入时恢复物化标记和必要索引，使正式 serve 与 canonical 真值一致（§6.2）。
3. **R3：可完成的切点触发。** 支持纯全局切点、首次 bootstrap、无新用户事务的规范化和 compact 已满足情形；明确维护结果的重做／重跑边界（§4.3、§5.1、§6.1、§7）。
4. **R4：活动集恢复语义。** 不以 committed 副本比较替代旧合同；采用明确提交的活动集变化，撤掉“等相邻改动自愈”的隐含行为差异（§4.2、§8）。
5. **R5：尝试与持久发布结果。** 定义同 C 重试、已发布未确认、孤儿清理与旧结果处理；C>P 不是去重协议（§5.3、§6.1–§6.2）。
6. **R6：旧游标与快照边界。** 采用现有快照／显式重取合同，去掉普通事务伪装 complete 的路径，并固定 K 后只发送 `seq>K`（§6.3）。

其余【中】【轻】项随上述修订后的实现落实：home 与父稿的差异说明、负坐标换算、无主附件来源约束、全局行和提取成本、接纳入口／恢复唤醒、Replica 消费者、M2b 段扩充与针对性测试。它们不能被写成已验证，但不要求为此另开一轮架构设计或提前实现 M2b。

## 总评

【严重】v2 仍不能直接开工；原始页段、frozen 和信用窗口这三项可以保留。
开工前收口 R1–R6：完整提交输入、完整装页、切点触发、活动集语义、失败尝试／发布结果、旧游标快照合同。
Fable 的 slot／micro／回放脏集发现成立；其 home 与父稿等价、活动集自愈无害、monitor 后可直接重试等结论需纠正。
不再要求 v1 的跨层载荷闭包，也不建议将粗层缓存 miss 编码搬回 World。
其余【中】【轻】项可随实现完成，验收增加本报告的定点反例，不扩成无关全套。
本次只读源码与文档，未运行任何服务、测试、基准或数据库操作，不构成运行验收。
