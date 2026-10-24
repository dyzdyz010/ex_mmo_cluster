# 第三轮评审：决策稿 v3 整体结论（Fable，2026-10-24，只读）

对象：`2026-10-24-world-region-paging.md` v3（下称“稿”，行号指该文件）；源码 b9b305f4（HEAD，与稿一致）。
路径相对 `apps/voxel_region/lib/voxel_region/`，Voxim 路径相对 `../Voxim/Source/Voxim/`。外部资料均为本轮实际打开核实，原句在 §4、§5。
标“推断”的是由源码推出、未实测的结论。本轮未改代码、未改稿、未碰 Docker。

---

## 1. 前两轮问题是否已闭合

### 1.1 我上两轮【严重】与阻断开工项的逐条核对

| 上轮条目 | v3 落点 | 结论 |
|---|---|---|
| F§2.1 kind3 无页键，按页重做不可实现；g=2/g=3 归属靠可能落后的目录 | 稿:148 “kind3 按目标拆行，页目标用已有 level/region 列”；稿:151 重做粒度按 (seq, 页)；稿:129 身份定位表“与页同一提交写入” | **闭合** |
| F§2.2 定时模拟触冷页无机制（停滞或第二真值） | 稿:174 “该步暂停、请求装页、装齐后重新裁决，期间不提交部分通量”；稿:235 ④ 液体/热以冷页为墙 | **部分闭合**，两条语义并存但适用边界没写，见 §3.1 |
| F§2.6 增量必须是绝对值 upsert | 稿:148 “每行写变化键的新绝对值或显式删除” | 闭合 |
| F§2.3 prepare→commit 无 pin | 稿:173 “跨回合等待期间闭包页被 pin” | 闭合 |
| F§2.4 脏页上限、降级编码在回合内 | 稿:162 积压边界；稿:181 冷缓存保留已持久编码字节不重编 | 闭合 |
| F§2.5 缺页当 baseline | I4（稿:114-115） | 闭合 |
| F§2.7 目录“按需查”是回合内 SQL | 稿:130 “查询走 P4 的准备流程，不在回合内同步 SQL” | 闭合 |
| F§2.8 命中 owner 的 home 页不可预知，prepare 须两段 | 稿:127 读取闭包含“外来 owner 的 home 页 + 祖链所在页”；稿:173 “先在 World 外求读取闭包” | **未写明是迭代的**：home 页要先装几何页读到页内“外来 owner 表”（稿:123）才知道，闭包求解至少两轮装页，稿只写“求出、装齐”。【轻】，M2 设计时补一句即可 |
| F§2.9 冻结后再改的页 RecLSN 记账 | 稿:161 “只把仍等于所写版本的页标干净” | 闭合 |
| F§6 M0 16 份跑不起来 / M1 不改存储不成立 / 多窗口系数 | 稿:244（1/2/4）、稿:152（一次性迁移）、稿:244-245（窗口数与密度） | 闭合 |
| F§7 Q3 页容器 ≠ 线格式 | 稿:142 | 闭合 |
| Astra 1.6 粗层树冠依赖 L0 | 稿:133-135 树冠段同笔维护并持久 | 闭合 |
| Astra 2.2 装页接纳复活旧版本 | 稿:171-172 装页令牌 + “不旧于淘汰时的版本” | 闭合 |
| Astra 2.3 热提交中间态落页 | I2（稿:111-112） | 闭合 |
| Astra 2.5 g=3 多槽无唯一 home | 稿:125 “首个槽 anchor 所在页，写入后不再迁移” | 闭合 |
| Astra 2.6 `refresh_structure` 冷子页当无细节 | 稿:135 | 闭合 |
| Astra 1.2 派生引用链钉住旧页 | 稿:182 | 闭合 |
| Astra 4.4 常驻 ≠ 模拟 | 稿:189 | 闭合 |
| 活跃页集须持久（F§1、Astra 2.7） | 稿:175 “活动索引随页提交持久” | 闭合 |

### 1.2 吸收后新暴露的问题

**【严重】1.2-1 “规模扩大后先饱和的是 World 的 CPU”（稿:34）是未经证实的前提，而 M0 的二分法会把 I/O 等待记进“提交饱和”并错误触发第二阶段。**

- 事实：每笔几何提交在 World 的 `handle_call` 内同步走 `append_journal`（`world/edits.ex:331`）→ `Log.append_journal`（`world/log.ex:20-21`）→ `OverlayLogStore.append` 的 `repo.transaction`（`apps/data_service/lib/data_service/voxel/overlay_log_store.ex:31-35`）。即 World 回合里含一次 PG 往返并等待其落盘；`voxel_macro_stages` 已单独记 `log_us`（`world/edits.ex:345`）。热核 NIF 也在 World 进程内执行（`world/thermal.ex:549` 的 `nif_us`；`world.ex:1550,1583-1588` 在 `handle_info` 中步进）。
- 后果（推断）：World 吞吐上限 ≈ 1 / (PG 提交延迟 + 回合 CPU)。去掉全表扫描（M1）后 CPU 项下降，`log_us` 的占比上升；稿:248 把回合只拆成“步进/求解/编码/组装”与“校验+应用+落日志”两类，后者包含 PG 等待。若 M0 测得后者占大头，按稿:40 的触发条件会判“提交饱和 → 第二阶段（按空间拆裁决权）”，而真正的修法是**日志追加流水线化／组批**（World 不阻塞等 PG，按 seq 顺序在 ack 后再确认与广播，原子性与“落盘后才确认”不变），成本远低于分片。
- 依据：PostgreSQL 把这类成本称为“the cost of each flush operation to be amortized across concurrently committing transactions”（wal-configuration，见 §4 引文）；Hyder 的架构里提交点（meld）正是因“单点串行”而成为最终瓶颈，但它前面的 I/O 和计算都已先摊开。
- 要求：① 稿:34 改为“M0 验证的假设”；② 稿:248 的回合拆分改成三类：**计算（步进/求解/NIF/编码/组装）、应用（校验+合并+索引）、日志 I/O 等待**，并记 PG 提交延迟分布；③ 路线表加一行“第 1.25 步：日志追加流水线化”，触发条件为 I/O 等待占大头，排在第 1.5 步之前（它只改 World 内的等待方式，不改任何不变量）。

**【中】1.2-2 P4 “暂停装页”与 Q1 “冷页为墙”对同一事件给了两种语义，适用边界未写。** 见 §3.1。

**【中】1.2-3 稿:133 “物化粗层页不再读 L0 页”与稿:135 “只按已装入的子页更新祖链”之间，L1 页的 structure 仍需读其 8 个 L0 子页的 refined/structure（`world/payloads.ex:263-346` 现逻辑）。** 稿只说树冠段持久化，没有说 L1–L5 的 structure 在子页冷时取“持久的父级结果”是否就是不更新。这是 Astra 2.6 的另一半：冷子页不删父级结构已写，**热子页改动后父级结构按什么输入更新**未写（只凭已装入子页会少算未装入兄弟页的贡献）。应写明：父级 structure 的更新输入 = 本笔改动子页的新值 + 其余子页在父级记录里持久的**逐子页摘要**，不读兄弟页。【中】，M2 前补。

其余上轮条目吸收正确；未发现吸收反向的情况。

---

## 2. 整体路线是否成立

**【中】2.1 三步划分成立，但触发条件要改成三分法。** 理由见 1.2-1。第一阶段（数据分页）→ 1.25（日志不阻塞）→ 1.5（并行计算、单点提交）→ 第二阶段（拆裁决权）才是按“改动面与不变量代价”递增的次序；跳过 1.25 会让第二阶段的触发被 PG 延迟误触。

**【轻】2.2 M0 饱和点测量在三分法下可以区分。** `voxel_macro_stages` 已按阶段计时（`world/edits.ex:345`），热核已记 `prepare_us/nif_us/accept_us`（`world/thermal.ex:549`），液体步进需补同类计时；mailbox 长度与调度器利用率用 `Process.info(:message_queue_len)` 与 `:scheduler_wall_time` 即可，不必新建观测框架。注意 World 进程只占一个调度器，“利用率”应报**该进程的 reductions 占单核比例**，不是节点总利用率，否则多核机器上永远看不到饱和。

**【轻】2.3 第一阶段为后两步预留的不变量（稿:213-221）足够且不过度**。核对：页地址不绑节点 ✓（PG 在 DataService，`config/runtime.exs:223-229`）；页重做只依赖页键日志行 ✓（P2）；读取闭包显式 ✓（P4）；模拟步纯函数化 ✓（稿:218）；按盒下发 ✓（N6）；全局水位列明 ✓（`world/attachment_ops.ex:192` 核对一致）。**漏一条**：1.5 步的版本校验需要“每个输入页在读取时的版本号”可被工作进程拿到并随结果一起交回——第一阶段的页常驻表示若不带 `page_seq`（P3 只为写回记），1.5 步要补；建议第一阶段就让常驻页携带 `page_seq`（P3 本来就需要它判干净，稿:161），零成本预留。不预做的清单（稿:221）正确。

**【轻】2.4 外部先例支持方向。** Folia（PaperMC，一手源码仓库 README）：“For a server with many spread out players, Folia will create many spread out regions and tick them all in parallel on a configurable sized threadpool.” 这正是用户前提 2 的形态；它也直接佐证 P6 稿:191 “相邻或重叠的玩家区域合成一块连续模拟区”：Folia 文档 “Adjacent regions must eventually merge to form a single region”、“Regions may not *begin* to tick if they have a neighboring adjacent region”（URL 见 §5）。

---

## 3. 新 Q1 边界语义

**【中】3.1 “暂停装页”（P4，稿:174）与“冷页为墙”（Q1 ④，稿:235）须写清各自的适用域，否则实现时二选一会把另一条抹掉。** 正确的分工（建议写进 P4 与 Q1）：
- 页**在模拟集内**（玩家半径、ticket、电路分量）但尚未常驻 → P4 暂停装页；这是瞬态，只发生在半径扩张、ticket 新发、重启恢复时。
- 页**在模拟集外** → 墙／绝热面，永不为它装页。
- 由此，模拟集页的读取闭包**不含**模拟集外的邻页（墙不需要读），驻留集 = 订阅闭包 ∪ pin ∪ 模拟集本身（稿:180 已如此，但要写明“模拟集不再外扩闭包”，否则 125 页 × 27 邻域会再乘一个系数）。

**【轻】3.2 液体／热以冷页为墙：守恒成立，体验问题可控。** 液体步只读活跃格的下方与四邻两层（`world/liquids.ex:328-330`），墙语义只需对“格所在页 ∉ 模拟集”返回不可流入；热域的视线伙伴按 `view_range_cells × micro` 射线行进（`world/thermal.ex:898`），冷页上的命中按绝热处理。两处都不产生跨墙通量，账目自然守恒。体验：① 墙消失时（玩家走近）堆在边界的液体一次性开始流动，是一次活动脉冲而非守恒问题；② 远景 LOD 带可能看到贴墙的液面（推断），稿:235 “模拟半径 = 近景窗口外加一圈”只遮近景。接受即可，写进 Q1 ④ 的“已知可见效应”。
**必须补的测试**：I4 在热路径的具体体现——现在“无温度记录的导体取其宏格所在气候区的环境温度”（`circuit.ex:80` 文档注释、热域同理），冷页的格**没有记录**，实现若不区分“冷页”与“无记录”，会把冷页当环境温度（即我上轮 2.2 的第二真值）。矩阵“跨模拟边界导热”行要写明期望 = 绝热，不是环境温度。

**【中】3.3 电路“整连通分量装入”有三处未定：**
1. **分量怎么知道在哪些页。** 分量是 BFS 现算的：从种子沿实接触扩张，逐面读 canonical（`world/thermal.ex:245-247,329-344`，`face_targets` → `circuit_target` 读格）。页冷时 BFS 停在页边界，只能“暂停装页、再 BFS、再撞冷页”——一条跨 N 页的导线要 N 轮装页才能开始求解（推断）。要么接受迭代（写明），要么像树的覆盖页集（稿:126）一样，把**分量的页集合**存在种子所在页的记录里由改动导体的事务增量维护。后者与 P1 home 规则同形，建议采用。
2. **超出 ticket 上限时怎么办。** 稿:235 ③ “超限按最早者冻结”是对有限终点过程说的；电路是整体求解（`VoxelRegion.Circuit.plan`），装不全时只有两种一致选择：(a) 整个分量冻结——即稿明确不采用的“整条网络一起暂停”；(b) 在冷页边界把导体切断当开路——这会改变玩家身边部分的解（远端电源消失、灯灭）。与液体/热不同，电路的“墙”不是局部近似而是改解。这是产品取舍，必须由用户在 Q1 里选，不能留给实现。Folia 的 “Redstone Time is maintained per region” 之所以可行，是因为 Minecraft 红石是局部传播而非全局求解，不能类比。
3. **为分量装入的页是否获得液体／热的模拟资格。** 稿:189 只排除了射线/远景/身份定位装入的页。若电路页加入模拟集，一条长导线会把液体与热的模拟区非局部地拉到 2 km 外；若不加入，则模拟资格要按过程分别记（页 × 过程），比稿当前的单一“模拟集”复杂。建议：电路页只有电路资格（最小改动：模拟集记为 `页 → 过程集合`，玩家半径页为全集，ticket 页为该过程，电路页为 {电路}）。

**【轻】3.4 与“模拟集 = 全部玩家并集”一致**；但系数要在 M0 记：近景窗口 27 区（稿:80），外加一圈 → 5³ = 125 页/玩家（推断），是常驻页的主导系数，比订阅盒大 4.6 倍；如园密度下每页约 1.8 MB 编码（上轮推断），常驻解码态更大。用户已允许内存可扩，这不是阻断，但 M0 的“活跃量模型”斜率必须以模拟半径为自变量而不是订阅盒。

---

## 4. 第 1.5 步：并行计算、单点提交

**【中】4.1 可行，且有直接一手先例；但稿的“版本校验”粒度若是 page_seq，热点页重算率会接近 100%。**

- 形态上这就是乐观并发控制（OCC）：Kung & Robinson 1981 摘要原句 “The methods used are ‘optimistic’ in the sense that they rely mainly on transaction backup as a control mechanism, ‘hoping’ that conflicts between transactions will not occur.”（ACM TODS 6(2):213-226，PDF https://www.cs.purdue.edu/homes/bb/cs542-20Spr/readings/cc/OMCC-Kung-81.pdf ，首页核实）。
- 最贴近“多处计算、单一日志、提交点校验”的系统先例是 Hyder（Bernstein, Reid, Das, CIDR 2011）：“Each transaction executes on a snapshot, logs its updates in one record, and broadcasts the log record to all servers.” “Each server rolls forward the log against its locally-cached partial-copy of the last committed state, using optimistic concurrency control to determine whether each transaction commits.” “Hyder uses a data-sharing architecture that scales out without partitioning the database or application.”（https://www.microsoft.com/en-us/research/publication/hyder-a-transactional-record-manager-for-shared-flash/ 摘要）。与稿 1.5 步的对应：工作进程 = Hyder 的执行服务器；World = 单一日志 + 提交裁决；页版本校验 = OCC 验证。差异：Hyder 的验证是确定性的、每个节点各自重放；本项目只有 World 做，正好对应稿:40 “提交本身成为单点瓶颈”再进第二阶段。
- **粒度问题**：热域一次提交覆盖 0.5 s 模拟时间、分多段推进（`world/thermal.ex:81-95,130-151`），期间液体每 0.1 s 一步、投射物 50 ms 一笔、玩家挖放随时发生，都落在玩家周围同一批稠密页。若 World 以“输入页 page_seq 未变”校验（稿:295），任何一次液体步都会使并行中的热求解作废，热点区域几乎永远重算（推断，但由三类过程共页直接推出）。Kung & Robinson 同文已指出 OCC 的饥饿问题。**修法**：校验以工作进程**实际读到的键集合**（格、damage 行、liquid_units 行）及其版本为单位，而不是页；液体写 `liquid_units`、热写温度行、挖放写格，键空间大多不相交，冲突才会稀少。这要求第一阶段的页内行带版本或 World 能按键查“自某 seq 后是否改过”（P2 的按目标拆行恰好提供了每页的键级变更日志，可直接复用）。
- **热的动态闭包**不需要先于提交确定：OCC 的读阶段本来就是边读边记读集（上引 Kung & Robinson 读/验证/写三阶段）。工作进程按需向冷缓存／PG 取“某版本的页字节”（页是不可变版本化字节，P5），记下读集，提交时整体校验。稿:296 的问题“哪些计算的输入闭包能先于提交确定”应改写为“读集随算随记、提交时校验”，否则会把 1.5 步限制在闭包可预知的少数计算上。
- **跨节点传页成本**：erlang.org 原句 “All data in messages sent between Erlang processes is copied, except for refc binaries and literals on the same Erlang node.” “When a message is sent to a process on another Erlang node, it is first encoded to the Erlang External Format”（https://www.erlang.org/doc/system/eff_guide_processes.html ）。因此 1.5 步的工作进程**先放在 World 同节点的空闲核**（页是 refc binary，零拷贝），跨节点只在同节点核用尽后考虑；Topology 现在给 peer 配 `+S 1:1`（`apps/world_server/lib/world_server/topology.ex:111-117`），World 节点其余核目前空闲（推断）。

**【轻】4.2 1.5 步的结果差量落日志仍经稿:146 的同步 PG 事务**，所以 1.5 步的收益上限受 1.2-1 约束；再次说明 1.25 步应在前。

---

## 5. 第二阶段大纲

**【中】5.1 三类跨片问题的划分正确，但第 1 类“每步交换一层边界格”在本项目不成立：边界层宽度 = 最大交互距离。** 液体读两层（`world/liquids.ex:328-330`）、热视线按 `view_range_cells × micro` 微格行进（`world/thermal.ex:898`）、投射物按飞行段跨区（`world/projectiles.ex:54-62`，上轮核实）、电路 BFS 无半径。halo 宽度应按过程取最大值并写进第二阶段必答项；若 view_range 以宏格计达数十格，halo 成本不可忽略。一手出处（稿:305 标“待核实”）：LAMMPS 开发者文档 “the simulation box is spatially decomposed (partitioned) into non-overlapping subdomains which fill the box.” “subdomains are extended with ‘ghost’ atoms up to the communication cutoff distance.” 以及负载失衡的后果 “the overall simulation rate is limited by the slowest processor”（https://docs.lammps.org/Developer_par_part.html ）。最后一句直接对应下面 5.2。

**【中】5.2 “每步交换”隐含各片锁步，最慢片决定全局步速；稿未说是锁步还是异步。** 异步方案 = 对方片的边界数据未到时按“墙”处理（与 Q1 ④ 同一语义，可复用），到达后按带编号的转移消息恰好一次应用；锁步方案 = 全局屏障，与“热点片慢”叠加会拖全图。第二阶段稿须二选一并测。

**【中】5.3 漏掉的候选方案：动态区域（Folia 模式）。** Folia 不是静态按块分片，而是按玩家附近的已加载区块动态成区，并用两条规则**避免**跨区物理：“Regions may not *begin* to tick if they have a neighboring adjacent region.” “Adjacent regions must eventually merge to form a single region.”（https://docs.papermc.io/folia/reference/overview/ ）；区的形成用 NxN 区块节与合并半径：“Region section coordinates simply represent a grouping of NxN chunks on a grid, where N is some power of two.”（https://docs.papermc.io/folia/reference/region-logic/ ）；并要求 “Code that is running in one region under no circumstance can be accessing or modifying data that is in another region.”（README）。这把三类跨片问题中的 1、2 **按构造消除**（相邻即合并，分量不会跨区），代价是热点合并成一个大区回到单写者，以及区的身份是动态的（页到片的映射随时间变）。它与稿:300 “每片拥有一组连续的 L4/L5 块”是两条路线，第二阶段稿应把“静态块 + 边界交换”与“动态合并 + 无跨区”作为 A/B 比较，并以 M0 的玩家分布数据（聚集度）为选择依据。Folia 的适用前提也要一并记：“Server types that naturally spread players out … will benefit the most”、“Ideally, at least 16 *cores* (not threads).”

**【中】5.4 必答项漏项（结合实际拓扑）：**
1. **多片订阅与合并**：Replica 只有一个 `authority_ref`（`replica.ex:41-57`）、CollisionStream 只向 `state.authority` 一个 World 取快照（`collision_stream.ex:83-85`）、Scene 的 `world_ref` 单值（`topology.ex:139-151`）。玩家窗口跨片时谁合并多片的流与切点——这是稿:310 “观察切点”之前的结构问题，须明确由 Replica/Scene 侧合并还是由一个“窗口投影”服务合并。
2. **Scene 移交的兼容判定**现要求 `a.world_ref == b.world_ref`（`apps/world_server/lib/world_server/movement.ex:39-53`）；拆片后要改成“两片都可达且切点一致”，与 Q6 绑定。
3. **非空间全局真值的 owner**：保护区／认领（电路与热分区都按 holder 切，`world/thermal.ex:240,340`、`Protection.same_holder?`）、信标（跨片传送）、prefab 目录发布、角色账。第 3 类只写了余额；holder 是每片每步都读的数据，需定“控制面 owner + 各片只读副本 + 版本”。
4. **同一片内 id 与跨片引用**：稿:311 写了 id 分配；还要写**跨片 owner 引用**（P1 的“外来 owner 的 home 页”可能在别的片）走什么读取路径——这是读取闭包跨片的具体形态。
5. **PG 作为共享后端的容量**：各 peer 各有连接池（`config/runtime.exs:229`），片数 × 池不是总额；写放大按片数线性。

**【轻】5.5 已正确的部分**：全局 seq 拆分与客户端整窗同 seq 的冲突核对一致（`VoxelGateCodec.cpp:663-664` `Header.Seq != V.TransactionSeq` 即拒）；ARIES 多日志 2PC；SpatialOS 交接丢更新警示；BodyStore owner_epoch 作拒旧参照；Q6 不在本阶段定。

---

## 6. 结论

**能否批准：第一阶段合同可开工（M0、M1 不依赖未决项）；“整体结论”须先改三处再批。**

必须改（阻断“整体结论”批准，不阻断 M0/M1 开工）：
1. **【严重】稿:34、:40、:248**：把“先饱和的是 CPU”改为 M0 假设；回合耗时拆成计算／应用／日志 I/O 等待三类；路线表增“第 1.25 步：日志追加流水线化”，触发 = I/O 等待占大头（1.2-1）。
2. **【中】稿:174 与 :235**：写明“暂停装页”只对模拟集内未驻留页、“墙”只对模拟集外页；模拟集不外扩闭包（3.1）。
3. **【中】稿:235 ④ 电路**：补分量页集的来源（持久于种子页，建议）、超限行为（整分量冻结 / 冷边界开路，二选一，用户定）、电路页只有电路模拟资格（3.3）。

建议改（可随 1.5 步／第二阶段稿补，但本稿大纲文字应先不误导）：
4. 稿:295-296：版本校验以读集键级版本为单位，不以 page_seq；“闭包先于提交确定”改为“读集随算随记”；补 Kung & Robinson、Hyder 引文（4.1）。
5. 稿:304-305：边界层宽度 = 最大交互距离；锁步/异步二选一；补 LAMMPS 引文；加 Folia 动态区域为候选 C（5.1–5.3）。
6. 稿:310-312：补多片订阅合并、移交判定、holder/信标/目录 owner、跨片 owner 引用、PG 容量（5.4）。
7. 稿:135：父级 structure 的更新输入（1.2-3）；稿:173：闭包求解是迭代的（1.1 表 F§2.8 行）。

Q1–Q6：Q1 按 3.1–3.3 补定后可批；Q2–Q5 维持上两轮一致意见；Q6 不在本阶段决定正确。

---

## 总评

1. 前两轮全部【严重】与阻断项在 v3 中吸收正确，无反向吸收；第一阶段 P1–P7、I1–I5、M0–M4 已可作为开工合同。
2. 新的【严重】只有一处：World 回合内同步等 PG（`edits.ex:331` → `overlay_log_store.ex:33`），使“先饱和的是 CPU”成为未验假设，且 M0 二分法会把 I/O 等待误判为“提交饱和”而触发分片；需三分法与“第 1.25 步”。
3. Q1 新边界：液体／热为墙正确且守恒；电路整分量装入还缺分量页集来源、超限行为与模拟资格三项定义，超限行为是产品取舍须用户定。
4. P4 暂停装页与 Q1 墙并存但适用域未分，写清即可。
5. 第 1.5 步有一手先例（Kung & Robinson 1981 OCC；Hyder CIDR 2011 单日志 + 快照执行 + OCC 验证）；但按 page_seq 校验会在热点页近乎 100% 重算，须按读集键级版本校验。
6. 第二阶段大纲：边界层宽度不是“一层”、锁步/异步未定、漏 Folia 式动态合并候选、漏多片订阅合并与移交判定、漏 holder 等全局真值 owner；域分解一手出处可用 LAMMPS 文档。
7. 结论：第一阶段开工放行；整体结论待改 §6 第 1–3 项后批准。
