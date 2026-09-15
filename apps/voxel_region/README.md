# Voxim Region 真值

2026-09-15 B3 碰撞材质查询（Global system）：连续行投影仍逐格调用目录 Map 查询，同一实际窗口
共 7,077,888 格。`CollisionSource` 现在从唯一 `VoxelMaterialCatalog` 在编译时派生密集 0/1 tuple，
宏格行、直接世界读取器与 refined slot 共用内联 `blocked/1`。目录仍是唯一阻挡定义；没有新运行时
缓存、世界状态、NIF 或协议。适用前提是现有 MaterialId 从 0 起连续，合法材质由既有载荷边界保证；
追加目录时照常重编译依赖模块，不在运行时猜测未知材质。
依据：[Elixir 1.18.2 Kernel.elem/2](https://hexdocs.pm/elixir/1.18.2/Kernel.html#elem/2)
明确零基索引与编译器内联；[OTP binary 指南](https://www.erlang.org/doc/system/binaryhandling.html)
说明顺序追加二进制可避免反复复制，故保留现有行构造，只消除实测查询成本。
只测试探针 `b3_collision_profile.py` 先在相同真实 seq4627 快照上证实完整投影 190.853→123.921 ms，
reductions 25,723,602→11,400,778；保存中间行的子实验有额外分配，不把它与完整调用相加。
最终 `b3_collision_compare.py --baseline-ref 97a38dad` 八组逐字节相等；
`b3_window_pipeline.py --collision-only --baseline-ref 97a38dad` 在相同 World 下只换碰撞实现，
完整窗口中位 334.808→265.707 ms，27 regions/1728 chunks/7 属性/身份全部相等。
回归覆盖完整材质目录、负坐标与行边界、细化占用，以及真实 canonical 编辑、订阅和恢复。
双端路线证据与限制见 [B3 observation](../../../Voxim/Docs/R7/B3-observation.md)。

2026-09-15 B3 窗口准备（Global system）：`prepare` 原先只看 decoded/region_bases，忽略已物化的
payloads，完整窗口已缓存仍启动 24–27 个 `source.ensure`。独立 B3 `/demo/world` 在 Windows
bind mount；相同输入单次 File.exists? 约 7–8 ms，27 项批次约 200 ms，真实路线准备中位约 303 ms。
按现有 `payload_bytes` 命中语义跳过已物化载荷的重复预备；不修改 `needs_source?` 的 decoded 语义，
不新增缓存或权威状态。缺失/失效仍从来源生成和读取。回归先证明重复预备，再验证丢弃缓存后的快照等价，
以及冷/暖编辑、跨区 ring、热前沿、属性/攻击与 FIFO。

依据：[OTP 进程效率指南](https://www.erlang.org/doc/system/eff_guide_processes.html#sending-messages)
明确进程消息复制普通 term，refc binary 同节点共享；本次先对照完整/裁剪 source_state，发现约 2.2 MB
索引复制不是主项，因而未实施索引切片。现有 payload cache 是可丢弃派生结果，复用其既定失效规则。
保留 `voxel_window_prepare` 的 regions/collision/properties；新阶段日志用 request ref、PID、cursor
关联 CollisionStream 调度、World 预备/排队/发送、Player 接收/FIFO/安装，wire 与 tick 顺序不变。
GC 仅由 Test-only `b3_window_trace.py` 在独立 B3 有界采集；高频 scheduler trace 因积压已弃用。
`b3_window_pipeline.py` 八组交替顺序、同一真实不可变窗口：完整调用 498.752→338.212 ms，全部
27 regions/1728 chunks/属性/身份相同。真实双端及剩余约 200 ms 碰撞投影见
[B3 observation](../../../Voxim/Docs/R7/B3-observation.md)。100/50 ms 只是工程预算讨论，非验收门槛。

2026-09-15 B3 广播根因续查（全局系统功能）：隔离同输入插桩发现 1 万格批次 GC 中位约 27–36 ms，
属性汇总与仅供日志的重复 wire 编码会触发额外分配。纯属性提交已由唯一目标集合产生，只有几何改变
合并删除/原属性/新叶子三种来源时才按身份去重；叶子实际观察区域仍照常补齐。删除热提交日志中为
`state_bytes` 完整编码所有状态的工作，真实观察者仍统计实际发送字节。依据
[OTP 进程效率指南](https://www.erlang.org/doc/system/eff_guide_processes.html) 与
[ERTS GC 说明](https://www.erlang.org/doc/apps/erts/garbagecollection.html) 的进程堆分配、复制和回收行为；
这里先删除无业务用途的分配，不调整堆下限、GC 策略或权威边界。复现命令：Voxim 的
`b3_pipeline_compare.py --baseline-ref 69a6ed58 --profile-fanout --out Saved/R7/B3/Server/<新目录>`，
可加 `--optimized-first` 对调运行顺序。只在独立性能 VM 插桩 GC/投影/发送，线上不启用 tracing。
同轮继续减少输入/回写分配：未改变的 geometry 直接复用（上批键集合等于 cells，编辑只会删键），
已有完整目标身份的 Damage 记录直接取值，最终提交统一盖 seq/request_id；缺记录仍由原属性函数创建默认值。
接纳改用 [Elixir 1.18 Enum.zip_reduce 源码](https://github.com/elixir-lang/elixir/blob/v1.18.2/lib/elixir/lib/enum.ex)
的双列表直接递归，省去先 zip 的中间列表。上述更改不调整模拟次序或步长；减少分配不等于保证尾延迟，
GC 落在哪个阶段随堆状态改变，仍需完整 callback 与真实窗口实测。

2026-09-15 B3 完整链路优化（全局系统功能）：World 复用有效热种子的六邻域和节点/边索引，
每批从权威记录读取 HP/温度，批量构造变化 Map；编辑使几何摘要失效，仍在固定步边界更新热前沿。
OverlayLog kind3 使用 ETF level1 压缩，旧/新元数据混合恢复，同步数据库事务完成后才确认。
普通 L0 碰撞投影改为按连续行读取，材质阻挡目录与细化格语义共用原实现。
依据是 [OTP Map 指南](https://www.erlang.org/doc/system/maps.html) 的批量构造/合并、
[binary 指南](https://www.erlang.org/doc/system/binaryhandling.html) 的连续匹配，及
[ETF 文档](https://www.erlang.org/doc/apps/erts/erlang.html#term_to_binary/2) 的向后可读压缩标记；
选择最快压缩等级来减少实测数据库字节成本，不改持久化时序、wire 或生成器身份。
同输入数据库/双观察者实验及独立 B3 真实双端结果见 [B3 observation](../../../Voxim/Docs/R7/B3-observation.md)。
性能夹具仅用 `voxim_b3_rustler_perf`；这不是大规模真实客户端容量验收。

2026-09-16 R7-B3 完整物理增量（Global system）：`ThermalGeometry` 从 canonical 实占用生成宏格／微格节点，
微格容量为宏格的1/512、面面积1/64m²；宏格与 refined 的部分接触按64个面槽位采样。
接触导热系数 `G=A/(da/ka+db/kb)`，d为半格长度；每条边只结算一次，空面按环境换热，非热实体视为绝热。
`ThermalNative.advance` 使用有限体积显式更新，步长≤min(50ms,0.45*C/(ΣG+h*A))，活动前沿变化后立即重建下一步接触。
每500ms提交0.5s模拟，与属性、热破坏占用同笔持久化。参考下述NIST FiPy离散与稳定条件；没有气流、辐射、电路或燃烧。

正常鉴权工具 `action=heat` 必须命中带 `heat.receiver` 的宏格，消费目录指定燃料并添加有限J，余额与能源同笔保存。
建造不生成能源；源绑定目标身份，拆除取消余能并记录 `discarded_source_j`，材料携带显热记入 `removed_j`。
`thermal_environment_path` 读取资产发布的ambient/h/tolerance，无自动热源；Test-only `thermal_experiment` 保留为实验入口。
已有热状态优先从同一overlay恢复，停机不补算；发布兼容扩展保留既有热材料定义、HP、身份和占用。
granularity1保存独立微格温度、2保存叶子共享HP；微格过热伤害按叶子汇总，归零时整个叶子与同批宏格破坏原子提交。
温度行不参与旧微格HP迁移，附近快照与窗口退出覆盖这些新行；未激活的热格使用已声明环境默认值。
材料数值为加速测试资产，并非真实物性标定；真实双端、剩余付费能源Docker恢复、拆建无回能与能量收支见
[B3物理验收](../../../Voxim/Docs/R7/B3-physical-acceptance.md)。32项相关服务端测试通过，120FPS／大规模容量仍延期。

2026-09-15 R7-B3 热传递首片（历史实现，现已扩展如上）：`Thermal` 是全局系统功能，只消费 canonical 派生的普通宏格六面接触摘要；
温度复用 World 的 B1 身份、稀疏属性状态、overlay 日志和确认流。50 ms 显式步进，500 ms 批量权威提交，
同步持久化后广播；只有过热归零才在同一宏格事务中删除占用，不发放采掘奖励。
`World.thermal_experiment/2` 是只测试的有限供能作者入口，不开放给玩家 Gate；Qinglan 不依赖它。
独立双客户端、真实重启、节奏与成本测量、范围边界见 [B3 首片记录](../../../Voxim/Docs/R7/B3-first-slice.md)。
数值方案沿用 [NIST FiPy 显式扩散示例](https://github.com/usnistgov/fipy/blob/master/examples/diffusion/mesh1D.py)
的守恒离散与步长稳定性约束；这里仅采用普通宏格接触模型，不引入 FiPy 或通用场框架。

2026-09-13：R7-B1 已验收收口。权威局部损伤、正常攻击节奏、双客户端一致性、持久化恢复及四项代码审查修复均已完成；最终结论见 [B1修复与复验](../../../Voxim/Docs/R7/B1-fixes.md)。宏格输入到上屏最慢约496ms，满足500ms门槛但余量较小；R6稳定120FPS欠账保留，B2–B7未开始。

2026-09-13 B1 代码审查删减：`Payload.encode` 在空CSR首次加入非均匀表皮时，由新记录恢复输出贴图尺寸；读取旧贴图池仍使用原尺寸。已删除尺寸不符时改成单色的兜底，L1的2×2与L2的4×4纹理、连续缓存编辑以及World编辑→HTTP→文件重放均有回归。这里遵循已有 `Reducer.skin_extent` / skins记录的尺寸合同，不新增层级尺寸规则或重采样。Replica内部直接消费初始化保证的 `state.damage`；旧外部几何事务仍可不携带损伤字段。阶段专用 `World.upgrade_b1` 已移除，部署和作者发布统一调用 `publish_properties`，已有损伤的属性版本约束保留。验证入口 `python tools/test_voxim_b1.py --out .demo/observe/b1-simplify-final`，28项通过；实际部署、客户端与重启证据统一见 [B1修复与复验](../../../Voxim/Docs/R7/B1-fixes.md)。下文为先前各轮定位记录。

2026-09-13 R7-B1 交互阻塞修复（最终实跑状态以 [B1验收记录](../../../Voxim/Docs/R7/B1-acceptance.md) 为准）：
工具频率仍由 World 持有 GCRA/TAT 与序号，输入时间改取 QuicConnection 已有 FIFO 入队时的服务器单调时间。
同一 Gate 连接的时间经 Dispatch 传入，刷新 Player 只更新权威身份/位置，不覆盖该入口证据；不读取客户端时钟、
不比较不同 VM 的单调时钟。依据 [ERTS time correction](https://www.erlang.org/doc/apps/erts/time_correction.html)
的 VM 单调时间定义；时间刻度只在其自身来源序列中作差。实跑 req10→11 的 Gate 间隔500.072ms，
prepare 从75.869降到60.497ms，旧 World 裁决间隔只有484.831ms，证明内部准备耗时改变了输入相位。
工具周期与既有一个Tick容差均未放宽。Gate 迁移继续保留连接进程，新 Player 仍按原有PID边界创建工具会话；
本片不声称跨 Player 迁移延续冷却。热加载须在旧连接退出、World工具会话已删除后进行。

宏格提交先排除已确定由完整 afterimage 覆盖的 core，不先编码再丢弃其稀疏候选或发送重复 coarse。
原有 afterimage 路径仍使用 canonical overlay/region_bases 物化，地形未变的缓存只替换结构后缀。
同步数据库追加仍先于广播/回执。尝试基于提交前缓存只patch本笔 changed cells，完整事务字节相同，
但因完整解码/CSR重建抵消了ring展开节省，隔离破坏355→364ms，没有收益，已撤回该候选。
另用既有54字节头证明 tiny sparse 必然更小、跳过完整候选的尝试，在含Replica的A/B中只是把L0编码
移到fanout：破坏344→348ms，广播后尾部0.127→18.391ms，事务字节相同；该候选同样撤回。

后续L0最小增量经实际 Fable 5.1 High 协商（答复在 Voxim `Saved/R7/B1/fable-consult-compact.json`）：
`Payload.replace_uniform_cells` 对已接纳的空CSR载荷直接splice固定cells数组，原样保留CSR和实例后缀；
合法非空CSR走已有decode/encode，正确删除被覆盖格的旧表皮。World仅宏格入口更新已有热L0 core/ring缓存，
宏格入口已拒绝refined cell，因此该入口不改实例后缀；Prefab/微格保持原来的细节重写。
冷缓存继续从canonical真值物化，不新增持久缓存/状态。每个区域每笔只压缩一次，选择器与Replica共同复用结果。

隔离入口 `python tools/test_voxim_b1.py --out .demo/observe/b1-l0-green`：21项通过，包含入口相位、
超频/重放、HP与失败回滚、热缓存/冷物化跨ring字节一致、文件重启。
宏格 profile 入口 `tools/profile_voxim_b1_regions.py` 只运行独立 VM 与文件日志；不连接在线节点或数据库。
优化前单笔宏格破坏产生79,695个 ring override、重建36,135个CSR记录，937万次函数调用；
profile 属于带函数采样开销的归因证据，不能当在线延迟。首次真实双端及后续性能复验由 Voxim 主任务记录。

2026-09-13：用户决定本轮园林子树编辑修复收口并提交推送。保留实跑延迟与剩余整区域处理成本；进一步优化另行启动，R7-B 仍为规划。

2026-09-12 园林大子树替换延迟修复：结构采样不再逐子格 `source.ensure`，直接复用 `cell_value` 的 decoded/read 路径；
GeneratedStore.read 自己负责 L0 缺失物化，FileStore.read 保留显式错误。依据是现有源读取合同与
[Elixir File.read](https://elixir.hexdocs.pm/1.18.1/File.html#read/1) 的成功/错误语义。
按现有 apply_batch 的 canonical 格去重方式，prefab 微格先汇集到 macro，再一次写入世界索引；占用冲突仍原子拒绝。
结构和碰撞只消费替换前后实际 slot/材质变化；身份更换照常发布新 occurrence 和完整 L0，受损同定义仍恢复。
后续修正按唯一 macro 做范围检查，复用当前子树集合与已生成的区域载荷；副本分发只消费实际 changed 区域，
不再二次外扩或解码后丢弃。地形未变时 `Payload.replace_details` 保留地形字节，仅重编 refined/结构后缀。
碰撞直接采样 canonical 值；`CollisionSource.capture` 的 payload 和采样入口共用一个投影算法。
后续 GC 实测促成两处生命周期收缩：发布目录只保留节点，节点体素以内部 ETF 二进制保存，删除重复汇总列表；
`World.serve` 本批新增的 baseline 解码数据在返回时释放，最终载荷仍走原缓存，编辑链路保留其解码复用。
`cache_clear` 同时清理两种派生缓存，已提交地形基底和 canonical 实例不受影响。
此外，A0 轴/符号只在一次 footprint 变换前计算，refined 每 macro 直接汇集成二进制，减少逐微格临时对象。
存活 owner 按 macro 直接汇总，避免先生成逐微格 owner 列表。`Payload` 的内部表皮记录用一个 48 位整数
保留六个 u8 面材质，减少常驻堆；对外 skins、wire 和坐标键不变。在线旧表示经既有 compact 重建，最终源码不保留兼容分支。
World 启动时按已有 payload_cache_bytes 预算设置二进制 GC 最小阈值，保留更高的 VM 默认值；
这是回收触发阈值，不预分配内存，也不是所有二进制数据的容量上限。实际旧二进制阈值过小曾导致一次编辑反复全量回收。
有效载荷的后缀重写复用 Codec.unpack_payload_body，删除旧 body 的重复 MD5；公开 decode_payload_body 继续完整校验。
FileStore 在文件接纳时补齐 body/hash 校验，GeneratedStore 保留其既有校验；内部不增加可信标记、模式开关或第二套解析器。
真实客户端结果、服务器退出恢复及测量限制见
[`Garden-nested-performance.md`](../../../Voxim/Docs/R7/Garden-nested-performance.md)。
相关回归覆盖 warm source、受损同定义恢复、材质变更、dense/sparse 混合 ring、历史碰撞与 checkpoint/replay。
线上 OTP 27.1 的函数 trace 曾在运行时断点代码中崩溃，当前在线工具仅计时公开 API，不安装函数断点。

R7 A4：VXPD 的稳定 child slot 按升序展开 preorder occurrence，定义目录在发布入口拒绝循环、缺失引用与实际占用重叠。
点 anchor 与格体积旋转沿用 [A0 合同](../../../Voxim/Docs/R7/A0-contract.md)，目录缓存展开结果，内部查询不重复验证。
`World.remove_prefab/2` 删除目标实际子树；`World.replace_prefab/3` 用当前确认态减去旧子树再加入新定义，一次提交完整 L0–L5 after-image。
替换继承 anchor、orientation、外部 parent 与 component slot，新根身份为 `(新 seq,0)`；失败保留状态和 seq，兄弟及父级残余不会按模板恢复。
L0 的 VXR7 在原 VXR5 instance 69 字节后追加 parent birth/occurrence 与 component slot 共 16 字节，快照保留实际 owner 的完整祖先链。
普通根仍写 VXR5，空 refined 写 VXR4，粗层仍为 VXR6。Gate 新 0x7C 为 65 字节 BE 替换意图，鉴权、场景与完整受影响范围沿既有入口检查。
格式不改变 content_version；日志追加、重放和 checkpoint 继续保存同一份完整区域字节。

发布入口 `World.publish_prefabs(world,path)` 在调用方加载、验证目录，然后合并不可变内容身份；不会改变世界、seq 或旧实例的 DefinitionId。
在线加载新模块后须先调用该入口，把旧平铺目录转换为已展开目录。旧实例根字段缺省为零，无其他状态迁移。
需更新的模块为 `MmoContracts.Voxel.{Refined,Codec,Payload}`、`VoxelRegion.{Prefab,World}`、`GateServer.Session.{Dispatch,QuicConnection}`；
Scene peer 同步纯 codec 模块后才能消费 VXR7。已有双 Scene、世界和庭院不得重建。

最小离线验证：`elixir -pa "_build/test/lib/*/ebin" scripts/test_r7_a4.exs`（需已构建依赖与 native collision 模块）。
2026-09-11 已实跑的隔离源码位于现有容器 `/tmp/voxim-a4-server`；使用其已构建依赖，不连接在线 Erlang 节点：

```powershell
docker exec -w /tmp/voxim-a4-server -e ERL_FLAGS=+S4:4 -e LANG=C.UTF-8 -e ERL_LIBS=/home/dyz/.cache/voxim-m1-demo/build/lib voxim-m1-demo-20260908 elixir scripts/test_r7_a4.exs
docker exec -w /tmp/voxim-a4-server -e ERL_FLAGS=+S4:4 -e LANG=C.UTF-8 -e ERL_LIBS=/home/dyz/.cache/voxim-m1-demo/build/lib voxim-m1-demo-20260908 elixir scripts/test_r7_a4.exs --db
```

隔离目录须包含 runner 中列出的当前源码、三个测试文件及 overlay-log migration；同级 `/tmp/Voxim` 放置
`Docs/R7/golden.json` 和 `Source/Voxim/Voxel/VoxelSpatialConstants.h`，供既有相对路径读取。该目录是可重建的测试 staging，不是在线部署路径。
`--db` 仅运行 DB 用例，使用独立 `mmo_a4_test` 数据库；默认 Docker host/port 为 `host.docker.internal:5433`，可用 `MMO_DB_HOST/PORT` 指定测试数据库主机。
测试包含跨 region 祖先快照、子树替换冲突、已删叶的兄弟替换、checkpoint/restart、原有跨 chunk/region 与历史碰撞回归。
本轮非 DB 综合实跑 14 项通过（当时共 15 项，排除 1 个 DB 用例，76.5 秒；完整输出在执行会话中，未另存日志文件）；
随后两项 DB 用例通过（共 16 项，排除 14 项，65.1 秒），原始日志为 [a4-database-test.log](../../.demo/a4-database-test.log)。
原有 current-wire golden 与 A4 协议/数学共 11 项通过，原始日志为 [a4-golden.log](../../.demo/a4-golden.log)，本轮命令：

```powershell
$env:ERL_FLAGS='+S 4:4'
elixir -pa '_build/test/lib/*/ebin' .demo/a4-golden-run.exs
```

早期仅嵌套文件日志/checkpoint 场景实跑记录为 [a4-world-test.log](../../.demo/a4-world-test.log)（1 项通过、7 项排除）；
对应 runner 是 `.demo/a4-run-tests.exs`。这些临时 runner 与原始日志供复现本次执行，长期测试入口仍是 `scripts/test_r7_a4.exs` 和 app 内测试。
`scripts/export_r7_a4_fixture.exs` 输出 [VXR7](../../../Voxim/Docs/R7/fixtures/server-a4-vxr7-fixture.vxr) 与 [替换意图](../../../Voxim/Docs/R7/fixtures/server-a4-replace-intent.bin) 跨语言 fixture。
这些是实现与隔离验证；真实双客户端验收由 Voxim 的 A4 实施记录统一记录。

R7 A3：`Structure` 从 L0 实际 prefab occupancy 派生局部完整 16³ 网格；L1 精确保留 canonical 微格，
L2–L5 的 2³ 子样本有结构时按结构材质众数保留，否则复用 `Reducer.reduce_material/1`。
没有结构的粗格仍用现有 terrain V1；普通地形编辑会刷新同一祖先格的完整结构网格。
World 独占更新与序号，跨 region 放置/删除在同一事务发布 L0 VXR5 与粗层 VXR6 afterimages（含 ring）。
VXR6 复用 VXR4 body，追加 algorithm=1、排序 cell index 与 u16[4096]；不带 owner，低八位材质、bit8 结构实体。
最后结构删除后恢复 VXR4。启动从 L0 实际占用重建派生并刷新检查点，content_version 和原编辑保持不变。
协议与质量合同见 [`Voxim/Docs/R7/A3-structure-contract.md`](../../../Voxim/Docs/R7/A3-structure-contract.md)。
最小回归：`mix test --no-start apps/voxel_region/test/structure_test.exs apps/voxel_region/test/prefab_test.exs`；
隔离已有依赖的执行命令：`python ../Voxim/Docs/R7/tools/test_a3_structure_server.py --out ../Voxim/Saved/R7/A3/server-structure`，输出目录保留日志及服务端 VXR6 golden。

M4a 区域部署采用 `Replica` 只读物化视图：每个 Scene 节点在本地运行该服务，驻留显式 `l0_box` 的完整 payload 与碰撞 chunk。
唯一 `World` 继续分配事务序号、规约、写日志；Replica 没有生成器、日志或编辑入口。Scene 的 `world_api` 为
`VoxelRegion.Replica`、`world_ref` 为本地 Replica PID；比较世界身份时调用 `authority_ref/1`，两份区域服务返回同一个上游 World PID。
配置 `Application.put_env(:voxel_region, :replica, authority_ref: world_pid, l0_box: box)` 后启动应用；该配置优先于 root，避免在 Scene 节点误启动第二个可写 World。

启动从上游原子获取快照并订阅，之后同一个 World 发出连续的 `CanonicalDelta` 与受影响区域的完整压缩 payload。
Replica 只替换不可变结果，并在自己的 mailbox 内原子提供 `canonical_snapshot_and_subscribe/5`；新订阅者的快照与后续 delta 同源有序。
含 ring 的 payload 按提交时实际 changed cells/区域同步，材质改变但 occupancy 未变也会更新 payload。越出驻留 box 显式拒绝。
上游 monitor 结束时 Replica 退出，使 Scene 已有 world monitor 立即失效；本轮不做故障接管或将旧缓存升格为 authority。
`canonical_deltas_after(replica, N)` 返回启动快照以后、严格大于 N 的有序 `CanonicalDelta`；N 早于启动快照返回 `{:error, :before_replica_snapshot}`。
该历史供跨区移交按切点前缀补齐已到达编辑，保留不可变 transaction/chunk，不保存 native physics world。
`stats/1` 暴露 `authority_ref / transaction_seq / baseline_seq / retained_deltas / regions / chunks / payload_bytes / occupancy_bytes / update_payload_bytes`，可验证实际驻留与增量流量。

决策依据（2026-09-11）：[Microsoft Materialized View](https://learn.microsoft.com/en-us/azure/architecture/patterns/materialized-view)
将缓存定义为可丢弃、由唯一数据源更新的查询视图；这里按已批准 M4a 固定区域驻留，直接传源端完成物化的字节，避免复制 reduce/replay 算法。
[OTP 进程信号顺序](https://www.erlang.org/doc/system/ref_man_processes.html#signals)只保证同一发送者到同一接收者顺序，故快照边界与全部后续更新都在 World 内发布，Replica 的读取边界也由其自身 GenServer 串行维护。
代价是每个 Scene 节点保存一份区域 payload/chunks，编辑额外传送受影响区域完整压缩 payload；其余区域保留原字节，只在读快照时将头序号标到当前前缀。
真实跨节点测试与字节/排队测量由 Voxim `Docs/M4a` 的统一入口完成，单元测试不能代替该验收。

`World` 拥有 baseline ⊕ 日志真值、订阅与内存载荷缓存；`GeneratedStore` 按显式 manifest 调用 DirtyCpu Rust NIF 并保存可丢弃的 baseline 磁盘缓存；`Bake` 是就绪门：L1–L5 全世界 baseline 齐全之前应用不完成启动、auth / gate 不开始监听；`Reducer` 只规约材质和表皮；`Payload` 只处理 66³ cells / CSR；`Codec` 只处理线格式。gate 只解码、路由和回执，auth HTTP 只调用 `World.serve`。旧 `FileStore` 只保留给既有烘焙 fixture 测试，正式运行没有文件 fallback。

`apply_edits([{coord, material}, ...])` 同一坐标最后一个值生效，先写完全部 canonical 值，再按级去重父格。某父格的材质与表皮均未变，不向上继续。一次有效批次一个 seq；全 no-op 不递增；canonical 源缺失整批不提交。原 `apply_edit` 共用此规约路径，但仍发旧 `0x77 kind=0`。

no-op 只向发起且已订阅的连接回现有 `0x79` 空事务，seq 是当前全局游标；不广播、不落盘。该确认与 backlog/实时条目同由 World 发送，连接邮箱保持 FIFO，所以不会跳过本连接应先处理的事务，也不会因最后一个全局事件在订阅外而让账本永久 pending。

事务 `0x79` 小端：`seq u64 / entry_count u32 / {length u32, LogEntry bytes} / coarse_count u32 / coarse[]`。`kind=1` 条目是 `seq u64 / kind u8 / 完整 VXR4`；`kind=0` 字节不变，批次的 canonical 条目 coarse 为空，粗格只在事务 coarse 数组出现一次。按 owned `(level, region)` 分组，精确比较 sparse 字节与 `13 + VXR4大小`，严格大于才用 region。客户端把 region 的 owned 64³ 投入所有相交 resident ring，不能只替换自己的 66³。

日志磁盘只保留选定的 region 快照和剩余 sparse 值；region 事务后自动 `compact`，也可显式调用 `World.compact`。检查点是完整累积投影，seq 等于压实前缀末尾；任意 `have_seq < checkpoint.seq` 都收到完整检查点再接 suffix。
已提交完整区域的地形保存在 World 的 `region_bases`，拥有自己的 core；`overlay` 只保留其后的逐格编辑。
refined、instances 和 structure 仍由 World 原有字段唯一持有，基底不再保留不读取的旧后缀副本。
载荷物化从相邻基底投影 ring，再覆盖真实稀疏编辑，不把快照边界展开为常驻逐格记录。
检查点先物化并持久化全部内容，成功后才更新基底并移除已吸收增量。基底来自日志真值，`decoded` 和载荷缓存仍可丢弃。
旧在线状态通过 `code_change(:region_bases,...)` 初始化空字段，再压实现有日志；正常启动直接重放，无需迁移开关。

复用旧物化快照时，只把 VXR4 头中的 seq 改成检查点 seq（不改 body/hash），使 `transaction.seq == entry.seq == payload.seq`。否则客户端会拒绝整个检查点；测试覆盖「dense seq1 → 无关编辑 seq2 → compact → 重启」。

HTTP `kind=entries`：`transaction_count u32 / {length u32, 无 opcode 的事务信封}`，均小端。每个 region 只记录最近一次完整下发的 `(seq,hash)`；请求 `have_seq > 0` 且头匹配、之后只有 sparse、精确编码更小时才回 entries。客户端把它应用在磁盘副本的解码结果上，不改原文件；服务端保留原头以支持重复读取。首次拉取、头不匹配、服务端重启丢失头、跨过影响本 region（含 ring）的 region 替换都回完整载荷。此处没有历史 payload 缓存或 LRU。

批量入口 `0x78` 大端：`request_id u64 / client_intent_seq u32 / logical_scene_id u64 / count u32 / {canonical i32×3, material u16}`；一条 `0x68` 回执，`result_ref=seq`。`Docs/R6/tools/gate_client.py explode x y z radius` 发送一个批次。r50 是 523305 格、约 7.33 MB 请求，现有 TCP `packet_size` 从 2 MB 调到 8 MB。

从 umbrella 根运行：

```powershell
mix compile
MMO_DB_PORT=5433 mix cmd --app voxel_region mix test --no-start   # WorldTest 走 DataService 表后端：需要 Postgres（test 配置 → mmo_test，test_helper 自动建库 + 迁移）
mix run --no-start apps/voxel_region/bench/s3.exs
python apps/voxel_region/bench/http_probe.py
```

跨实现 oracle 测试显式设置 `VOXIM_ORACLE_DIR=<Voxim>/Saved/S4Oracle`；如还设置 `VOXIM_SERVER_PAYLOAD_DIR=<Voxim>/Saved/S4ServerPayloads`，测试会把 NIF body 包成同名 VXR4，供 UE 的 `VoximOracle.S4.ImportServerPayloads` 再通过正式 codec 核对。

oracle 默认由 ExUnit 排除，显式运行时加 `--include oracle --only oracle`。

T-2（决策稿 §12，随机 200 region）：UE 先跑 `VoximOracle.S4.ExportRandomSample`（固定种子，写 `<Voxim>/Saved/S4OracleT2/`），再
`MIX_ENV=test VOXIM_T2_ORACLE_DIR=<Voxim>/Saved/S4OracleT2 VOXIM_STORE_ROOT=<Voxim>/Saved/S4CacheAuthority VOXIM_STORE_MANIFEST=<Voxim>/Docs/R6/runtime/s4_worldgen_manifest.json VOXIM_SERVER_PAYLOAD_DIR=<Voxim>/Saved/S4ServerPayloadsT2 mix cmd --app voxel_region mix test --no-start --only t2 test/generated_store_test.exs`——
每份用 `GeneratedStore.read`（就绪门文件 / 合成常量 / 在线 L0，即实际会发的字节）与 UE fixture 解压后逐字节 + 逐格比较，并写出同名载荷；之后 Rust `VOXIM_ORACLE_MANIFEST=<Voxim>/Saved/S4OracleT2/manifest.json cargo test --release --test oracle -- --ignored`、
`python Docs/R6/tools/t2_compare.py`、UE `VoximOracle.S4.ImportRandomSample`。2026-09-07 四方 200/200，记录在 `Voxim/Docs/R6.md` §S4 第六切片。

**就绪门（`VoxelRegion.Bake`）**：世界是以原点为中心、半边长 `world_half_extent_m` 的正方形。启动时（`Application.start`，在 `World` 之前）对 L1–L5 每一级枚举世界内所有 XZ 列，
用 kernel 的折叠边界 `Native.column_bounds`（列内最低 / 最高地表与岩性省份范围）配合 `Native.mixed_rows` 找出不能证明均匀的 ry，只有这些 region 需要生成并落盘；
纯空气 / 纯岩石的 region 不落盘，读取时 `Native.classify_region` + `Native.uniform_body` 合成常量载荷（Rust 测试保证与 `generate_region` 逐字节相同）。列边界写在 `baseline/index.etf`，
之后每次启动只加载索引、核对文件、补缺。本机 Demo 世界首次烘焙：16 km × 16 km（`world_half_extent_m` 8192）21,824 列、78,536 个 mixed region，本次生成 48,578（复用 29,958）534 s，从零约 13 min；32 km 全量约 303k region、约 1 h；之后启动核对 78,536 个 region 每级列一次目录核对 225 ms（逐文件 stat 时 91 s）。
离线执行同一段代码：`mix run --no-start apps/voxel_region/bench/bake.exs <manifest> <root> [concurrency]`。

L0 不在门内：它按玩家位置在线生成（单块几十毫秒）。`World.serve` / `apply_edit(s)` 先在调用方进程用 `Task.async_stream` 并发调用 `GeneratedStore.ensure`
把本批缺失的 L0 物化到磁盘（每请求并发上限 `VOXEL_REGION_GENERATION_CONCURRENCY`，默认 8），再进 GenServer；同一 BEAM 里对同一 region 的并发生成由 ETS 锁表去重，
跨进程仍靠硬链接发布。mixed 的 L1+ 缺文件是硬错误 `:not_baked`，不在线生成。`World.stats/0` 返回 `generated`（NIF 实际调用次数）。

`World` 内有一个内存载荷缓存 `(level, region) → {bytes, header}`：source 原样字节与 overlay 物化字节都进它；L0–L3 按最近使用淘汰，字节上限
`VOXEL_REGION_PAYLOAD_CACHE_MB`（默认 512），L4+ 常驻不计入上限；条目碰到的 region（含 ring 邻居）立即失效，region 快照重放时整个清空。命中不读盘、不解压。
`stats` 里有 `entries / lru_bytes / resident_bytes / hits / misses / evictions`；本机可用 `elixir --sname probe --cookie <cookie> -e ':rpc.call(node, VoxelRegion.World, :stats, [])'` 读取。

缓存生成先写入同目录、含 OS PID 与 BEAM 唯一值的临时文件，再用 [`File.ln/2`](https://www.erlang.org/doc/apps/kernel/file.html#make_link/2) 建立同文件系统 hardlink，完成拒绝覆盖的原子发布；目标已存在的生成者删除自己的临时文件并读取、校验胜者。文件系统不支持 hardlink 时明确返回 `cache_publish_failed`，没有 rename 或运行时生成 fallback。缓存命中会完整解压并复核 body 长度与 hash，避免截断或损坏的生成结果被永久复用；warm serve 的重复解压成本留给后续性能切片处理。

最后一个命令需要本地服务，临时改变 `(40,504,39)` 一格后恢复原材质。S4 服务启动必须同时设置 `VOXEL_REGION_ROOT=<空的生成缓存根>` 和 `VOXEL_REGION_MANIFEST=<s4_worldgen_manifest.json>`；Demo manifest 的当前导出位于 `Voxim/Docs/R6/runtime/s4_worldgen_manifest.json`。另设 `DEV_AUTO_LOGIN=true`、隔离的 `AUTH_PORT` / `GATE_TCP_PORT` 与所需数据库配置后，在 umbrella 根运行 `mix phx.server`。旧 ChunkProcess 开发世界默认不初始化；仅运行历史探针时显式设 `VOXEL_DEV_REGION_BOOTSTRAP=true`。`start_s4.ps1` 明确设为 `false`，不会继承调用 shell 的旧值。不要把 `VOXEL_REGION_ROOT` 指向原 `WorldBake`；生成 baseline cache 写入该根下的 content-version 目录，权威 overlay 写入数据库并按 `content_version` 隔离。

manifest schema 是 `voxim-worldgen-v1`，显式包含 `kernel`、完整且有序的 `materials` 24 项表、`world_half_extent_m`（世界半边长，米；只决定就绪门枚举范围，不进 content_version）与八项 config：`seed/min_height/sea_level/max_height/soil_depth/lowland_amplitude/mountain_amplitude/cave_max_depth`。`GeneratedStore.open/1` 在创建版本目录前要求 manifest 表与 `MmoContracts.VoxelMaterialCatalog` 完全相等。`content_version` 使用 `voxim-content-version-md5-64-v2`：输入依次为规则名、Rust NIF 提供的完整 kernel identity（算法名 + 构建时源码 digest）、按 id 排序的紧凑 `[[id,name],...]` JSON（当前 327 bytes），三段以 NUL 分隔，再跟 seed i64 LE、四个高度/土层 i32 LE、两个 IEEE754 f64 LE、洞穴深度 i32 LE；MD5 首 8 字节按 little-endian u64 解释。

当前 Demo manifest 配合未变的 kernel identity `worldgen_density_v3@1+sha256:72f1d31c81c337daf54e5f700fc07d1efe4dacf9e6e0df6f7f8c377fa7ee22dd` 得到 `content_version = 256b33610344964f`。旧 `0e31fc80e3ff9e17` baseline 与 overlay 命名空间保留为历史证据，不由新版本读取。源码 digest 覆盖 `build.rs`、NIF 参数映射与全部生成源文件，因此 kernel 代码或形状常量变化会进入新的缓存目录。

**权威 overlay 日志在 DataService 表里**（第七切片，决策稿 §9 第 1 项）：`voxel_overlay_log(content_version, seq, ordinal, kind, level, region_x/y/z, payload)`，一行一个条目（kind 0 = L0 cell 线格式、1 = 完整 VXR4 region、2 = 粗格线格式），
`DataService.Voxel.OverlayLogStore` 读写；`VoxelRegion.World` 通过 `VoxelRegion.OverlayLog` behaviour 追加 / 重放 / 压实（压实 = 一个数据库事务里替换成检查点）。正式启动注入 `OverlayLog.Db`（dev 库先 `MMO_DB_PORT=5433 mix ecto.migrate -r DataService.Repo`）；
`OverlayLog.File`（`<root>/<cv>/overlay.log` ETF 帧）只给不起数据库的测试。seq 仍由 World 内存计数分配（no-op 不消耗、重放取 max）。

R7-B2 的材料余额随世界事务写入现有 kind 3 元数据：`{cid, material_id} → units`，追加、重放和检查点沿用同一条日志。

2026-09-14 用户决定：Prefab 最小破坏单位为最低层 occurrence，普通攻击也不能删除单微格。构件共享 HP，最大值按实际剩余槽的材质 `max_hp_per_macro / 512` 求和；单次攻击使用命中材质的防御、响应和工具强度，不再按微格缩小伤害。归零复用拆卸事务，一次删除整个叶子并按各材质实际剩余量入账；选中父级不扩大攻击范围。既有宏格规则不变。
现有 property envelope 的 granularity=2 表示 occurrence 血量，键为 owner；0 为宏格，1 为精确微格温度（B3），也用于辨认历史微格 HP。启动重放后只迁移不带温度的旧微格 HP，把同 owner 的损失求和，从剩余几何对应的最大 HP 扣除；原有洞、余额及世界序号不变，再由既有检查点持久化。查询返回当前射线命中的身份和材质，以及共享 HP；附近温度推送保持独立微格粒度。
依据：[Epic 的分层破坏指南](https://dev.epicgames.com/documentation/en-us/unreal-engine/cluster-geometry-collections-user-guide-in-unreal-engine)以作者定义层级组织破坏单元；这里按用户要求固定最低层，不引入 Chaos。HP 密度来自既有资产，删除与结算沿用 `clear_subtree` / `prefab_reply` 的原子日志路径；不新增配方、修复或材料表。
材料由 Demo 资产发布为 `production_materials: [19, 11]`，复用木材与石材的既有 ID。1 单位是 canonical 微格体积（1/512 m³），100% 回收被工具实际摧毁的匹配材料：宏格 512，Prefab 按整个叶子的实际剩余槽逐材质计数；部分伤害不入账。微格只是计量单位，不是 Prefab 破坏单位。建造一个空宏格消耗所选材料 512 单位，两种余额不能互相抵扣。
`production_intent/3` 刷新当前 Player 身份与位置，World 串行检查距离、余额和实际占用；最近一次相同请求返回原结果，旧序号拒绝。普通玩家的作者放置、删除、替换入口仍需 creator 权限。
建造去重记录绑定已鉴权 Gate 连接，随连接退出清理；Scene 移交换 Player 和 epoch 不会使旧请求再次生效。
读取余额走已鉴权 cid，不依赖移动 Ready；每种材料各发一个 31 字节 `0x81`，客户端按材料分别确认。`0x7F` 建造意图现在为 38 字节，在 tool 后追加 material u16；客户端与服务器须一起更新。回归：`python tools/test_voxim_b1.py --out .demo/observe/b2-next`（含 B1、竞争、重复、失败写入、构件血量、旧微格损伤迁移与恢复测试）。

B2 显式拆卸沿用工具请求 `0x7D` 的 action=2：服务器重新射线命中，检查工具、距离、目标身份与现有冷却，只拆命中的叶子 occurrence。客户端选择父级不能扩大删除范围，宏格仍走局部攻击。复用 `clear_subtree` / `prefab_reply` 的同一占用、实例、损伤与日志事务；回收只计实际剩余的匹配材料槽，已采走的微格不再计数。失败追加回滚占用和入账，旧目标重发拒绝；相关回归在 `damage_world_test.exs`。

远景资产包（决策稿 §6.2）：`mix run --no-start apps/voxel_region/bench/pack.exs <manifest> <root> <out_dir> [min_level]` 把 L ≥ min_level（默认 4）的全世界 region 按 level 打成 `<out_dir>/<content_version>/L<n>.vxpack`（`MmoContracts.WorldPackShard` footer-table，条目 = region 坐标 → 完整 VXR4；范围 = 世界列 × [mixed ry − 1, +1]，均匀 region 也在内），放进 Voxim `Content/VoxelWorld/`。16 km Demo 世界 L4 47.7 MB + L5 11.4 MB，3.9 s。

实测与验收证据在 `Voxim/Docs/R6/runtime/s3_server_*`、`s4_lean_*`（D-9 线格式）与 `s4_asset_*`（资产 + 写回），设计决策与边界见 `docs/10-active/voxel-far-field/2026-09-02-voxim-region-payload-and-overlay-log-design.md` 的 S3 记录。

当前 S4 首切片只把正式 baseline 来源替换为在线 kernel，锁住生成、编辑、重启和 unchanged 闭环。DataService 日志、全 catalog 统一、LRU、L4+ 资产与完整 S4 benchmark 仍属于后续收口，不能据此宣称整个 S4 完成。
