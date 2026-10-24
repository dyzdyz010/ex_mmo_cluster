# 交叉评审：对 review-astra.md 的逐条意见（Fable，2026-10-24，只读）

对象：同目录 `review-astra.md`；源码 b9b305f4。只对其【严重】【中】条目表态；路径相对 `apps/voxel_region/lib/voxel_region/`。
“同意”= 我按源码复核成立；“部分同意”= 事实成立但级别或结论需修正；“反对”= 源码或推理不支持。

## 1. 逐条表态

| Astra 条目 | 级别 | 表态 | 理由（file:line） |
|---|---|---|---|
| 1.1 全局标量混入随内容增长的表（protection/beacons/回执/attunements/thermal.sources/semblances） | 严重 | **部分同意，降为【中】** | 事实成立：`protection.ex:17` regions+index、`world/beacons.ex:5,130-135` 全表 nearest、`parcel.ex:12` cid=0 回执、`world/catalogs.ex:79` `thermal.sources` 在 thermal 内。但 protection/beacons 行极小、增长系数低，不阻塞目标；`thermal.sources` 与 semblances 无落点才是实质漏洞（我稿 §1 已列）。“逐项指定唯一持久 owner”同意 |
| 1.2 缓存与目录漏项（L4+ 常驻、GeneratedStore 索引/ETS、published 字节、component_cache/thermal_run/seen 引用链） | 严重 | **部分同意，降为【中】** | L4+ 常驻 `world/payloads.ex:355,368-381` 成立（我稿已列）。GeneratedStore：`generated_store.ex:84` 整份 bounds 索引进 source_state、`:128-138` ETS 只增，成立，但随世界**范围**非内容增长，heap-probe 实测 2.1 MB，属应列明的小项。published `.vxpd` 字节常驻 `world.ex:628`、`prefab.ex:25-31` 成立。引用链成立：`world/observation.ex:153-154` tag 持 inputs、`world/thermal.ex:90` run 持 damage、`:585` seen 持整张 damage/liquid_units——淘汰页后这些旧 term 仍钉住内存直到下一次 flush，是我漏掉的真问题 |
| 1.3 启动/检查点仍 O(L) 日志后缀 | 严重 | **部分同意，降为【中】** | ARIES 本身就是 O(脏页) + O(RedoLSN 之后的日志)，稿把后者省略了，Astra 指出正确。但 L 由“检查点间隔 + 写回积压”界定，只要规定脏页年龄/数量上限触发提前检查点（我稿 §2.4，InnoDB 已引），L 就是有界常数，不构成随世界增长的斜率。应改稿写成 O(D + L)、L 有界并给出界 |
| 1.5 ticket 不等于资源有界；电路沿导体无界扩张 | 严重 | **同意** | `world/thermal.ex:245-247,327-345` 电路从种子沿实接触 BFS 无半径；`world/liquids.ex:328-330` 液体读两层邻域。与我稿 Q1“只给有限终点过程发 ticket”一致，另需 ticket 页数上限（Luanti forceload 有限额） |
| 1.6 粗层页物化读 L0（Canopy）与 N6 远景覆盖 | 严重 | **同意，这是我漏掉的最大一项** | `world/canopy.ex:9-12`：`project(state, level, region)` 对**全部** `candidates`（全世界 macro_owners）判 L 级 span 后 `cell_value(s, 0, cell)` 读 L0；`:61-69` 再逐级读 `cell_value(level-1, child)`。L5 页若只存 coarse overlay+structure，树冠段要么漏、要么拉 32³ 个 L0 页。稿 P1:95 必须把树冠锚点/残余作为粗层页的持久段，由同笔事务（`Canopy.affected_keys`，`canopy.ex:30-45`）增量维护。N6 远景：`log_projection.ex:55-58,106-112` 粗格对旧 subs 全局通过，同意须写明 LOD 带覆盖 |
| 2.2 可变页不能套用不可变 baseline 的两段 prepare | 严重 | **同意** | `world.ex:751` 接纳只看 `needs_source?`，前提是来源按 cv 不可变（`world.ex:147` 注释）。页会被改写：调用方交回 A@10 而 World 已有/已写回 A@11，按现逻辑“不驻留即接纳”会复活旧真值。接纳须比 page_seq，旧于当前持久版本的装入结果拒绝。补我稿 §2.3（pin）之前的另一半 |
| 2.3 写回/页版本/截断点同一不变量；热提交中间态不可落页 | 严重 | **同意** | `world.ex:703-705` + `world/thermal.ex:568-580`：读调用前 `flush` 把原生热域值写进 `damage`，此时热事务**尚未**落日志；现检查点以 `thermal_run == nil` 为冻结边界（`world.ex:1611`），新淘汰/写回路径必须同样只在该边界冻结。截断点须覆盖无空间条目的事务（进食/施法，`production.ex:160-167`）、目录、角色行与 seq/attachment_serial 水位——同意，我稿只写了页 |
| 2.4 page_seq 幂等单位、kind3 路由、旧档迁移 | 严重 | **同意** | 同 seq 多行靠 ordinal（`overlay_log.ex:48-70`），页版本应在整笔应用完后推进；kind3 路由与迁移即我稿 §2.1、§6“M1 不改存储不成立”。补充具体做法：kind3 按页拆行、用现有 region 列 |
| 2.5 home 规则未闭合（页自足 vs g=2 只在 home；g=3 多槽） | 严重 | **同意** | `Contracts/voxel/refined.ex` ancestors 沿父链 `Map.fetch!`；`world/canonical.ex:232-238` 整件 HP 跨页累加；g=3：`world/attachment_ops.ex:193,204` 一个 aid 对应多个槽，槽各有 anchor（`attachments.ex:35`），稿:91-92 “anchor 在本区的附件的 g=3 行”在槽跨区时没有唯一 home。P1 “一页自足”措辞错误，应改为“页 + 其外来 owner 的 home 页”构成读取闭包 |
| 2.6 ring/粗层/依赖闭包须在裁决前完成；`refresh_structure` 把缺项当无细节 | 严重 | **同意** | 与我稿 §1 “27 邻域”同源，新增一处我漏的：`world/payloads.ex:278-283` `has_structure` 用 `Map.has_key?(refined/structure)`，冷页缺项会被判“无结构”进而删父格网格——这是分页后静默改真值的具体路径 |
| 2.7 ticket 创建/恢复/边界物理 | 严重 | **同意** | 即我稿 §2.2 与 §1 “活跃页集须持久化”，Astra 把液体两层邻域、投射物下一段（`world/projectiles.ex:54-62`）写得更具体 |
| 2.8 旧游标、全局 seq 与 N 系列联合合同 | 严重 | **同意（N1 排序项标为推断成立）** | `world/payloads.ex:421` 载荷头盖 `state.seq`，客户端要求每头 `Seq == TransactionSeq`（Voxim `VoxelGateCodec.cpp:664`）→ page_seq 不能直接当窗口切点。N1 排序：`world/edits.ex:285-288` 后像先生成，`:296` `damage_geometry` 才算 epochs（`world/tools.ex:482`），世代进载荷必须调整提交数据流，否则发旧世代。N3：客户端附件无整件行即返回空（`VoxelDamageState.cpp:176-177`），默认语义须覆盖 g=3。N5：`VoxelDamageState.cpp:74-77` Complete 即 Reset，改差集需显式退出清除 |
| 3.2 GeneratedStore “有界”印象错误 | 中 | **部分同意** | 事实见 1.2；但“有界”在附录里指 L0 baseline 字节缓存，索引随范围增长应单列，不必推翻整段 |
| 3.7 “液体每步写全量 instances/owners”过度概括 | 中 | **同意** | `world/edits.ex:364-375` 纯数量路径走 `liquid_journal`（`world/log.ex:23-25`）去掉二者；但条件要求 refined/instances/owners 全未变（`:365-366`），稠密区液体接触细化格时仍走 `append_log`；`liquid_active` 全量每步都写。稿:39 应改写 |
| 3.15 0.74 s 单样本不能推“与窗口无关” | 中 | **同意** | 扫描复杂度成立（`world/observation.ex:184,194`），耗时结论需 M0 补测 |
| 3.16 “事务 entries 不裁剪”需限定 canonical 链路 | 中 | **同意** | `log_projection.ex:55-58` 旧 subs 已按盒裁 L0 |
| 3.18 edit_keys 只是钩子 | 中 | **同意** | 同我稿 §1 |
| 3.20 protection/beacons 非标量 | 中 | **同意** | 见 1.1 |
| 4.1 单切点 C 的增量检查点优于逐页 RecLSN | 中 | **部分同意** | 单切点确实少一份状态（与现 `checkpoint_input` 冻结思路同形，`world/log.ex:268-285`），我倾向采用；但“脏页先写回再淘汰”路径仍要存在（否则 1.3 的 L 无界），两者可共用同一写回合同 |
| 4.2 每笔同库原子更新触及页、不做应用层重放 | 中 | **反对作为默认，同意作为 M0 对照项** | 稠密页约 1.8 MB（推断），每笔几何事务要 upsert 本页 + 5 级粗页；液体夹具 0.1 s 一步、投射物 50 ms 一笔（`world/projectiles.ex:10`），写放大是现 kind3 问题的另一种形式。仅在 M0 量出页字节与事务率后比较 |
| 4.3 目录/缓存按职责收敛 | 中 | **同意** | 与我稿 §4 “目录可删（协议带 anchor）”相容：若目录不存在，这条自然满足 |
| 4.4 常驻集 ≠ 模拟集 | 中 | **同意，我漏掉** | 为射线/远景装入的页若自动恢复物理并产生日志，读取改变演化；模拟资格应由模拟 owner 判定，I/O 常驻只管内存 |
| 5.1 ARIES 不证 O(脏页) 启动；“steal”用词 | 中 | **部分同意** | O(L) 项同 1.3。“steal”：本系统每笔 WAL 追加即提交，脏页只含已提交状态，steal/no-steal 之分在此退化，用词无害；但热提交多步中间态（2.3）确实是“未提交页”，须按 2.3 处理 |
| 5.3 Minecraft Wiki 非一手，不能批准冻结语义 | 中 | **部分同意** | 按 AGENTS §2.2-8 二手只作线索，稿应以 Luanti 源码（一手）为主、MC Wiki 为佐证；但“无人区域不模拟”是行业通行做法，不因来源降级而改变 Q1 建议 |
| 5.5 原创标注范围 | 中 | **同意** | 与我稿 §5 列表互补（Astra 多列 N5 生命周期、默认 HP/epoch 语义；我多列 ring 依赖邻页、WAL 表+页表同库） |
| 6.1 M2/M3 依赖倒置 | 严重 | **部分同意，降为【中】** | 稿:173 “启动只读后缀”与“页仍可全部常驻”确实矛盾：M2 必须含按需装页与接纳边界（2.2），否则启动仍 O(世界)。但淘汰与 ticket 留 M3 可行；不必把 M2 扩成全部状态类别 |
| 6.2 M0 “现状全部线性”会造成错误基准 | 严重 | **同意** | `property_observation.ex:19` 已按盒过滤 epochs/行，固定窗口字节今天就与远处份数无关，只有组装 CPU 线性；刚装 16 份即测检查点时脏页也在增加。M0 须分离冷内容、脏集合、后缀长度、远处事务率。加我稿一条：现状 16 份内存跑不起来 |
| 6.3 规模样本覆盖真正增长轴 | 中 | **同意** | |
| 6.4 恢复测试覆盖新失败窗口 | 严重 | **同意** | 五条反例全部必要，与我稿矩阵缺项 1–3 重叠并更完整 |
| 6.5 几何/物理/协议矩阵缺项 | 中 | **同意** | |
| 6.6 “每处扫描一个计时测试”不最小 | 中 | **部分同意** | 64 处里维护/测试入口不必各配测试，同意按事务入口计“触及页数/字节”；但每个热路径读点一个计数断言很便宜，不算膨胀 |
| 6.7 10%/1 MB/3.9 GiB 不够明确 | 中 | **同意** | 与我稿 Q4 一致；Astra 补了“总进程峰值含 refc/Task/NIF/Scene”，正确 |

## 2. Astra 发现、我漏掉且核实成立的问题

1. **粗层页的树冠依赖 L0**（1.6）——`world/canopy.ex:9-12,61-69`。严重级，直接影响 P1 粗层页定义。
2. **装页接纳可能复活旧版本**（2.2）——`world.ex:751` 只判 `needs_source?`。
3. **热提交中间态会被当成可落页状态**（2.3）——`world/thermal.ex:568-580`、`world.ex:1611`。
4. **`refresh_structure` 把冷页缺项当无细节**（2.6）——`world/payloads.ex:278-283`。
5. **g=3 一个 aid 多槽、跨区无唯一 home**（2.5）——`world/attachment_ops.ex:193,204`。
6. **载荷头 seq = 观察切点，客户端强校验**（2.8）——`world/payloads.ex:421`、`VoxelGateCodec.cpp:664`；N1 世代进载荷需改提交顺序（`world/edits.ex:285-296`）。
7. **派生引用链钉住已淘汰页**（1.2）——`world/observation.ex:153-154`、`world/thermal.ex:90,585`。
8. **常驻集 ≠ 模拟集**（4.4）。
9. **M0 窗口字节指标今天就与份数无关**（6.2）——`property_observation.ex:19`。
10. **纯液体数量路径已不写 instances/owners**（3.7）——`world/edits.ex:364-375`，稿:39 措辞过度。
11. GeneratedStore 索引/ETS 随范围增长、published 字节常驻（1.2）；D3 重叠盒戳随安装次数增长（1.4）。

## 3. 我坚持而 Astra 未提到的问题

1. **kind3 按页拆行的具体修法**（我稿 §2.1）：用迁移 `20260907000001` 已有的 `level/region_x/y/z` 列，每页一行增量 + 一行全局；Astra 2.4 指出问题但没给落点。
2. **全局实例目录可以删除**（§4）：协议 42 让 `voxel_prefab_remove_v1/replace_v1`（`world.ex:374-378`）带 anchor，home = `region_of(anchor)`，树覆盖集存 home 页实例记录；少一张表、少一次热路径 DB 读、少一条恢复依赖。
3. **目录“按需查”是 World 回合内阻塞 I/O**（§2.7），与 P5 自相矛盾。
4. **降级编码成本在 World 回合内**（§2.4）：约 100–200 ms/区（推断自旧稿 image 15–29 s/145 区），换窗 9–27 页即秒级停顿，须在 Task 内。
5. **kind1 整区后像仍随每笔几何事务进 WAL**（§1）：`world/log.ex:207-259`；斜率平但系数与 10-15 事故同源；可选“WAL 只记增量、页是唯一全量形式”删掉 `select_transaction/rebase_region/snapshots/region_bases` 四个概念。
6. **页行缺失 = baseline 的静默还原**（§2.5）：Astra 2.2 一句带过，我主张显式失败模型 + 测试。
7. **角色账分页第一阶段可不做**（§4）：角色数是独立轴。
8. **Q3 页容器 ≠ 线格式载荷**：否则 M2 提前改 VXR 版本。
9. **M0 16 份现状基线内存跑不起来**（1 份 VmHWM 6.5 GB）→ 1/2/4。
10. **`in_refined_order` 改确定序会改既有 g=2 行 max_hp**（`world/observation.ex:145-146`）。
11. **Replica 退休通知**（`world/log.ex:360`）改发截断点 seq。
12. **`prefabs` 整目录 compiled 常驻**：`prefab.ex:17-22`，D1 只去解码列表（Astra 只提 published 字节与淘汰缺失，方向相同）。

## 4. Q1–Q4 最终立场

- **Q1**：双方都支持无人页冻结。Astra 不批准“瞬时过程 ticket 直到静止”；我的“只给有限终点过程发 ticket”与之相容。**最终**：稳态过程（有源电路、恒温源）无人页直接冻结、不补算；有限终点过程（液体趋静、燃料燃尽、相变完成、投射物落地）才持页，并设 ticket 页数上限（Luanti forceload 限额同理），超限按最早冻结并记日志；跨冷热页的热传导/电路/液体边界 = 该过程暂停（非绝热、非环境温度）。读取装页不授予模拟资格（Astra 4.4）。
- **Q2**：一致，PG 新表。补：页写回、目录/角色/全局行与截断水位放同一 DB 事务；接纳按 page_seq 拒旧。
- **Q3**：一致，分开交付、联合设计接口。我补：页容器 ≠ 线格式载荷；Astra 补：先定观察切点、g=2/g=3 整件汇总与世代读取再定 P1。两者都应进稿。
- **Q4**：Astra 主张先批测量定义、不拍数字；我给了样本规则与绝对预算的草案。**最终**：先批测量定义（Astra），把我的样本规则（p50/p99 各 ≥1000 次、1 份跑两次取噪声底、阈值 = max(10%, 2×噪声)、每常驻稠密页字节、N 窗口分落多份的总进程峰值）作为 M0 的测量规格；数值在 M0 之后定。

## 5. 一句话

两份评审在“方向可行、合同未闭合”上一致；Astra 的 1.6（树冠）、2.2、2.3、2.6（refresh_structure）是我漏掉的真值风险，我的 kind3 按页拆行、删目录、降级编码、页容器≠线格式是它未给的修法；合并后阻断项为：粗层页树冠段、装页接纳拒旧、热提交边界、kind3 页键、模拟触冷页机制、M0 变量分离。

## 6. 按补充目标的调整

用户补充（转述）：不为极致优化牺牲太多性能；要的是资源占用**平滑、无不可控尖峰**；考虑集群架构；线上内存可扩，不以现生产 3.9 GiB 为最终目标。
拓扑事实：World 与 Auth/Gate 由一个节点唯一拥有，Scene 可在 `peer` 节点、各带只读 `Replica`（按固定盒订阅 World，`world_server/topology.ex:4-16,88-98,143-153`、`replica.ex:34-54,189-194`）；DataService 拥有 PG；NPC 独立。第二阶段才按空间拆 World。

据此我的建议调整如下：

1. **4.1 vs 4.2 → 明确选 4.1（单切点增量检查点 + 连续限速写回），4.2 退出候选。** 4.2 每笔同库 upsert 触及页，写 I/O 随事务率成脉冲（稠密页 ~1.8 MB × 本页 + 5 级粗页，液体 0.1 s/步、投射物 50 ms/笔），正是“不可控尖峰”。4.1 把写回变成后台匀速流（InnoDB adaptive flushing、PG `checkpoint_completion_target` 同理，已在依据表）。但要把现稿“每 60 s 一次检查点”改成“**持续按页限速写回（N 页/s），检查点只是推进切点**”——今天的尖峰恰是 60 s 定时整批 image 15–29 s（`world/log.ex:298-301`）+ World 内同步落库（`:333`）+ 整堆 full GC（`world.ex:1394`）。
2. **D4（槽记录二进制作常驻表示）→ 从“省内存的条件项”改为“消尖峰的候选项”，由 GC 停顿数据决定。** 内存可扩，但 BEAM 复制式 GC 代价 ∝ 活堆（已引 ERTS 文档），310 MB 的 map 每次 full sweep 都是停顿尖峰；refc binary 不复制。M0 应记录 `gc_us` 分布与最大单回合停顿，若 map 表示下 p99 停顿超出验收线再做 D4，否则不做。同理，`checkpoint_input` 把非 binary map 拷进 Task 堆（`world.ex:1613-1614`，瞬时 2 份）应改为先编码成 binary 再交 Task——这是消尖峰项，与省内存无关。
3. **验收线从 3.9 GiB 绝对值改为“平台 + 带宽 + 停顿”三类可控指标**：
   - 内存：预热后稳态工作负荷（持续换窗、编辑、液体、投射物）下 World 进程内存与 beam 总内存的**平台值**与**峰/平台比**（今天 1.26↔2.07 GB 锯齿、VmHWM 6.5 GB vs 稳态 2.2 GB ≈ 3×；目标例如 ≤ 1.2×，数值 M0 后定）；写回/淘汰/检查点期间不得出现与常驻量成比例的瞬时翻倍。
   - 容量可规划：常驻 = 基线 + 斜率 × 活跃窗口数，斜率在 M0 用 N=1/4/8 窗口分落多份测出并写进稿；这是“可扩内存”的依据，取代单一上限。
   - 停顿：单个 World 回合最长耗时（含 `finish_checkpoint`、淘汰、装页接纳、`Thermal.flush`）与提交 p99；写回与检查点期间的 p99 不得高于平时 p99 的 k 倍（k 待定）。
   - I/O：PG 写入速率有上限、无脉冲（每秒页数/字节数曲线平坦）。
   - 保留原三条斜率测试（与世界总量无关）——这仍是用户原目标。
4. **因“内存可扩”而降级的建议**：`prefabs` 整目录常驻、`protection/beacons/回执`、角色账分页、GeneratedStore 索引（我稿 §1、Astra 1.1/1.2）从“必须分页”降为“列明斜率、不在第一阶段做”；它们是平滑的常量项，不产生尖峰。M0 的 16 份现状基线仍受开发机限制，若用户提供大内存机器可直接跑 1/4/16。
5. **为第二阶段（按空间拆 World 到多节点）预留，只留不变量、不预建机制**（AGENTS §2.2-7）：
   - **页自足可搬**：页重做只依赖页键 `(cv, level, rx, ry, rz)` 的日志行与页自身，不依赖全局行或目录——这正是把 kind3 按页拆行（我稿 §2.1）的第二个理由；第二阶段按区域范围把页与其日志行整块划给另一个 authority，不需要重写格式。
   - **id 分配不得继续依赖“全局 seq 唯一”**：附件 id = `max(serial, seq)+1`（`world/attachment_ops.ex:192`）、实例 id = `{birth seq, occ}`。第一阶段不改，但稿要写明这是第二阶段必须拆的全局水位，不要在新目录/页格式里再把 seq 当跨区唯一键。
   - **读取闭包显式化**：跨页依赖（27 邻域、home 页、电路/液体邻域）在第一阶段以“本笔读取闭包”显式求出并装页（Astra 2.6/2.7、我稿 §1），第二阶段同一闭包即跨 authority 取数/交接的单位；ARIES 多日志需 2PC 已在依据表，第一阶段不做。
   - **流按盒投影**：N6/Replica 已是按盒订阅（`replica.ex:189-194`）；坚持每条下发流只含订阅盒内容，第二阶段 Scene 可同时订阅多个 World 分片而不改客户端协议。
   - **页存储不绑节点**：Q2 选 PG（DataService 共享）而非 World 节点本地文件，页才能在 authority 迁移时不搬文件；这是 Q2 的新增理由。页表可按区域范围分区。
   - **不预做**：分片路由、2PC、authority 交接、跨分片目录——第二阶段另立决策稿。
