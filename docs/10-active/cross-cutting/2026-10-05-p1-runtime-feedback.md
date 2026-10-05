---
status: completed
---

# P1：运行停顿、身体反馈与弱网呈现

分类：产品改动为 Global system；诊断、运行器和验收场景为 Test-only。用户于 2026-10-05 授权 P1，基础优先；不包含容量扩张或 Qinglan 分发。

## 契约与可运行增量

- [x] **World 检查点与交互停顿**：先测 select／image／persist／rebase 与 SQL 分段，只改已证实的瓶颈；原事务落盘后才确认、检查点原子替换与冷恢复内容保持。局部编码优化后仍有长同步计算，继而实现后台冻结前缀，完成实际 World／PG／NIF 长场景与恢复回归。固定冷态样本可逐值和逐字节对照；旧长场景存在并发背景差异，不声明同条件性能加速比。相关入口为 `World.Log.compact_log`、`OverlayLog.rows`、`DataService.Voxel.OverlayLogStore` 和既有 `thermal_fire_benchmark_test`。
- [x] **身体变化主动刷新相干度**：沿 Player 既有 1 Hz 身体上报，World 在值变化时用既有 0x83 状态通知当前连接。客户端保留报价、实际支出和前摇，只刷新当前权威状态。已确认 World 直推与 Dispatch 二次转发会因跨发送者而乱序，因此报价／结算／首次状态／身体推送统一由 World 发送；Gate 继续按既有 session／已接纳回执身份拒旧，不加线协议版本字段或第二份身体真值。用延迟 Dispatch 返回的受控反例证明旧报价不能晚到回退，另覆盖客户端消息消费与真实玩家恢复场景。
- [x] **弱网远端呈现**：先用当前构建、现有 M2a／M1 运行器与相同正常输入采基线，区分缺插值括号后的外推与真正冻结；确认根因后修最短路径。保留现有 100 ms 插值延后、100 ms 外推上限及正确性门槛，不通过扩大延后或改统计口径把旧失败变绿。旧 <1% 缺样为优化观察目标，不把数学上正常的外推误报为卡住；原指标与新增诊断同时保留。

### 检查点第二增量：后台计算冻结前缀

格式下界及规范形复用后，固定样本同步选择仍为 0.62–0.92 s，已证明仅编码局部优化不足。改为一个后台任务计算不可变前缀 P 的 select／image，World 继续接受并持久提交 P+1…Q；目前 9–26 ms 的 persist 仍留在 World 内，避免数据库已替换但内存历史尚未更新时 `entries_after` 缺正文。

冻结须在现有热运行完整提交边界，正在进行的热步自然完成后再启动。后台只持有选型及元数据所需值，不带原生热域、订阅和计时器；结果不装回缓存或旧身体／资源状态。单任务共用手动和自动入口，手动 compact 只在覆盖调用时序号后返回。存储以原事务原子替换 `seq <= P`，完整保留 `>P`；内存也保留后缀并重建历史索引，持久成功后由 World 发 `checkpoint(P)`。仅当当前 seq 仍为 P 时沿用原 rebase，否则保留当前 canonical 表示，避免旧结果清除后续同格／ring 编辑。不增加重试框架、任务池或第二真值。

直接证伪范围：计算未完成时后缀仍能提交、手动不提前回复；真实 PG／File 前缀替换与回滚；同区域／ring 和属性后缀冷恢复；热提交边界；Replica 两轮退休保留后缀。最终测冻结／应用／GC 停顿及峰值内存，后台总计算时间不能冒充 World 阻塞时间。

## 验证与边界

先跑能证伪修复的最小用例，再回归直接接缝。涉及 World 持久化时用真实 PostgreSQL、后续事务及冷恢复；涉及状态消息时覆盖已接纳回执与重连／移交身份；涉及玩家体验时使用真实双客户端与正常输入。性能测量保留共同窗口、规模、版本、实际时长、失败与并发背景，诊断短跑不冒充 benchmark。

服务端从 `7b607ab1` 的隔离工作树 `ex_mmo_cluster-p1` 开始，客户端从 `1a8a6a6d` 开始。现有 P0 工具环境只复用编译缓存与测试基础设施，每 VM 独立数据库；共享 Mix／UE 构建及性能运行串行协调。用户正在进行的 UI 调研文件和其他 UE 会话不属于本轮所有物。

本机 Mix 入口：`wsl -d Ubuntu-22.04 --exec /bin/bash <Voxim>/Saved/P1/Environment/mix.sh <app> test --no-start <tests> --seed 0`。客户端沿正式 UE Automation／M2a 入口，截图只进 `Captures/`。

## 依据与当前证据

- [Erlang 信号顺序](https://www.erlang.org/docs/27/system/ref_man_processes.html#signals)：同一发送者到同一接收者的信号保序，不保证两个发送者之间的先后；相干度的所有状态包需要同一权威出口，周期覆盖不能消除已确认的乱序。
- [PostgreSQL 16 TOAST](https://www.postgresql.org/docs/16/storage-toast.html)：大 bytea 默认可能先压缩再外置，压缩策略可逐列指定。先测编码与数据库实际成本，不把 `persist_us` 全部推断成磁盘等待。
- [PostgreSQL 16 事务隔离](https://www.postgresql.org/docs/16/transaction-iso.html)：保持单事务替换的原子性；本轮后台任务只计算冻结前缀，World 仍串行持久化，以 `seq <= P` 的替换保留并发后缀，避免异步删除整个世界日志。
- 旧林火观察：2026-09-30 检查点约 185–222 ms，写库 163–213 ms；当前 P0 小世界约 3.6 ms。二者规模不同，均不能替代本轮大场景前后基线。
- 首轮弱网诊断 `Voxim/Saved/P1Remote/baseline01` 受另一 UE 会话与 Demo 日志级别影响，未形成有效样本；原始失败保留，不作基线或通过。
- 当前森林诊断 `Saved/P1/Checkpoint/forest375.log`：375 s 自然演化，配对提交跨度 374 s／墙钟 375.9 s；6 次检查点约 203–1163 ms，主要是 select（粗层完整区域候选计算后仍选稀疏），persist 约 9–26 ms。375 s 后既有 heap 统计继续让 World 演化，导出的固定样本为 thermal 470 s／seq 943，不能混称为 375 s 状态。
- 固定样本 `forest375-storage/storage.json`：619 行／70506 B，无完整 region 行；元数据编码中位约 1.73 ms。pglz→EXTERNAL→lz4→pglz 的 full replace 中位约 12.01／11.97／11.88／10.06 ms，实际 `pg_column_compression` 全为 none，波动大于策略差异。不改 PostgreSQL 压缩策略，继续剖析 select。
- [RFC 1951 §3.2.5／§3.2.7](https://www.rfc-editor.org/rfc/rfc1951)：一个 match 最多输出 258 B，length 和 distance 至少各占 1 bit；忽略树和封装只会削弱下界。因此完整载荷至少为 `54 + ceil(raw_min / 1032)` B，另外计算事务条目头 13 B。`raw_min` 由既有固定段和最终 CSR 记录集合得到：空表不带行索引；非空表加 17428 B 行索引及每条 10 B，省略非负的贴图和细节尾部。计数与实际编码共用覆盖规则，在 overlay 和邻区 ring 合并后执行，不用经验压缩率决定事务。
- 固定样本改后 `forest375-select-after/comparison.json`：从同一冷态丢弃返回缓存，三次 select 为 925.079／790.462／831.071 ms，改前单次 1182.815 ms。均跳过 L3 `{0,0,-2}`、L5 `{0,0,-1}` 两个不可能更小的候选；12 个区域的诊断记录完整。结果逐值等于改前事务，21904 B 协议编码完全一致。剩余约 0.8–0.9 s 同步选择成本尚未解决，不宣称检查点停顿已消除。
- 旧导出样本缺少 `World.Log.attachment_metadata` 添加的持久化 envelope，首次恢复诊断因此失败；原始失败保留在 `forest375-select.log`。后续固定样本对照仅从同版正常空 World 补出缺失的 catalog 单位信息，并立即暂停诊断 World，在离线不可变状态副本上比较；不属于产品冷恢复验收。原始命令、环境、失败及复判范围见 `Voxim/Saved/P1/Checkpoint/commands.txt`。

## 已集成增量

- 相干度：服务端 `5ac92109`、客户端 `f07c97d2`；状态／成功回执共用 World 出口，新 identity 必须首推，客户端保留请求结果。World 25、Scene 12、Gate 4 项相关用例通过（重跑不重复累计），改前反例保留在 `Saved/P1/coherence-*.log`。2026-10-05 当前隔离客户端正式 Native／UE 构建成功，Automation `Voxim.Magic.CasterStatePushKeepsQuoteAndSettlement` 实际选中／完成 1 项，失败／缺失 0；包含非零支出保留。
- 相干度真实双端：工具与只读组件观察入口为客户端 `e1aab367`，原始记录 `Saved/P1/Resume/coherence-live01`，独立 BodyLive 镜像 `voxim-server:20261005-p1-777f3db3`。正常零能量施法留下报价、准星放木／点火后受伤、离火自然恢复，期间无新施法请求。157 条主动更新按本轮 cid／epoch 逐值匹配权威身体，相干度 `4 → 3.648489564 → 3.709160181`，报价 `13290.013869039 J`／结构 `1`／前摇 `0.639568556 s`／支出 `0 J` 保持。双端同一燃烧事务 `7`，两端回放与退出成功，已检查烧伤及恢复截图。初判跨时钟方向假设失败保留；判定器增加反例后 10 项通过，同轮日志复判为 `verification-recheck.json`，不声称单向延迟。未覆盖非零支出实跑、完全治愈、跨 Scene 或帧性能；详情与命令在 `Voxim/Docs/Gameplay/README.md`。
- 弱网工具：客户端 `22be0e23`；现有运行器支持当前隔离部署和新角色，逐帧诊断区别缺括号、外推与保持，离线反例通过。未修改远端产品算法；真实后续入口在 `Voxim/Docs/M2a/README.md`。
- 复制发布修复：`8c0dd030` 使用既有 60 Hz tick 合并 dirty 事实，Player 仍 20 Hz；无变化不构帧，不等所有玩家，普通邻帧不回传，桥退休仍导出。4 个相关测试文件实际 42 项通过，精确定序的 Scene 反例另保留 RED／GREEN。正式镜像与相同客户端双端基础弱网前后各 180 s，以及改后抖动 180 s 完成，完整命令与版本在 `Saved/P1Remote/`、`Saved/P1/Live/phase-fix-8c0dd030`。按实际出生位置配对，样本年龄中位 `134.817→109.338`／`144.636→102.032 ms`，保持帧比例 `1.178%→0.279%`／`4.426%→0.344%`；CPU 0.214→0.206 核、下行 353→324 pps 为单对观察，不声称统计改善。抖动档两端保持 0.830%／0.533%；缺括号原值仍保留，保持包含静止，不能称可见卡顿率。当前完成本修复的真实输入与弱网验证，不替代完整 M2a／GPU／容量验收；详情见客户端 M2a README。
- 检查点候选选择：先按格式下界跳过必输候选，仍由实际字节严格选择稀疏／完整区域；缓存和来源字节直接返回，存储及确认顺序不变。20 格小编辑反例从改前失败转为通过；新增 CSR World 反例用 644 B 稀疏条目证伪旧实现，记录下界为 652 B。当前源码定向验证共 10 项：Payload 纯格式 3 项、World 选择／ring／冷恢复／checkpoint stamp 与 damage 5 项、Payloads ring 合并／等号／删除／缓存 2 项。日志为 `bound-{red,green}.log`、`record-*.log`；首次 ring 夹具没有经过正式 encode/decode，失败保留，修正合法夹具后两项通过。位置过滤排除的用例未计入通过数。
- 诊断运行器第一增量：当时的同步检查点按四段日志相加，缺段不能判成有效总耗时；导出改为公开 compact 后读取真实后端 replay，且先于昂贵 heap 统计。`BENCH_SECONDS=1` 的 `thermal_fire_benchmark_test.exs --only benchmark` 实际执行 2 项、0 失败、退出码 0；新导出 `exporter-check/checkpoint.etf` 为 seq 5／thermal 1.0 s／19 entries＋21 coarse。离线检查确认 `material_units_per_micro=4096` 与独立 catalog JSON 一致，其他持久化 envelope 字段存在，导出日志先于 heap 日志。此项只验证导出接缝，不算冷恢复或性能验收；后续异步增量另测冻结、后台计算、应用与 GC。
- 规范形复用：`3567f599` 在单次 Payload 编码内按源纹理 index＋面 ID 复用规范化结果，输出池首次使用顺序与字节不变。新增手算 raw／完整编码、同索引不同面 ID、覆盖删除与跨调用隔离测试；旧实现 12 次调用超过 4 次上界的 RED 保留，最终 6 项 Payload＋1 项纹理编辑边界通过。固定 seq943 三次 `920.944／801.844／620.925 ms`，每次事务值及 21904 B wire 与原样本相同。历史 831.071 ms 中位含 UE 并发，本次无 UE，故 801.844 ms 中位只能方向性诊断，不能认定准确收益。命令和环境位于 `Saved/P1/Checkpoint/face-reuse-after/`；同步停顿仍需上述第二增量解决。

- 后台前缀正确性：真实 PostgreSQL Store 3 项、Db／File 3 项、World 整文件 21 项、热提交边界 2 项通过。受控阻塞真实选型后，正常编辑仍落盘；两轮 compact 分别覆盖各调用者的序号，同格／ring／属性／余额后缀及 Replica 退休与冷恢复完整。任务异常会使 World 明确失败，不回复假成功；原持久数据能恢复。真实 PG 的第二批插入故障回滚删除及首批插入，File 临时文件写失败保留原日志。原失败与改后记录分别在 `Saved/P1/Checkpoint/prefix-*`、`async-world-*`、`async-phase-thermal-*`，不是只测编码自洽或进程未崩溃。
- 异步测量入口：原四段判定器接受缺冻结／GC 样本的 RED 已保留；当前 3 个直接判定器反例通过，另保留窗口不足和无周期检查点反例。正式森林场景 `BENCH_SECONDS=375 BENCH_SCENE=forest BENCH_HEAP=0`、实际 PostgreSQL／World／NIF／原有限作者入口；6 个周期完整配对 start／finish／GC，750 次自然热提交至模拟时间 375.0 s。采样墙钟 `374.730431 s`，首尾热提交跨度为 `374.5 s` 模拟／`374.516920 s` 墙钟；375 是模拟终点，不能写成精确 375 秒墙钟窗口。正式命令总耗时 426.2 s，实际执行长场景 1 项加判定器 3 项，0 失败、退出 0。原日志、JSON、运行环境及源码差异在 `Saved/P1/Checkpoint/async375/` 与 `async375.log`。
- 检查点当前结果：后台 select／image 最长 `465.756 ms`；World 冻结最长 `23.732 ms`，写库＋应用＋GC 最长 `29.050 ms`，这是分开的同步阶段。20 ms 单请求探针共 17619 条，`World.seq` 响应 p50／p95／p99／max 为 `0.017／0.074／11.144／39.216 ms`，包含全窗口的热提交等其他工作，不等同玩家端到端延迟。最后一轮 `P=728、Q=729`，后台计算期间真实热事务继续提交。100 ms 采样峰值 World／worker／整个 VM 为 `168.310／55.083／342.485 MB`，是采样峰值而非精确分配高水位。未与受其他 UE 负载影响的旧 375 s 样本宣称同条件加速比；本次没有 UE／构建竞争，其他既有闲置容器记入 environment.json。

- 原始采样关联：17619 条读均在实际墙钟窗口内且严格单在途；首末请求约 20.473／374709.702 ms，最大相邻发起间隔 59.847 ms。3706 个内存样本最大间隔 201.524 ms，100 ms 是目标周期，不能声称精确无间断或真实内存高水位。五轮较长后台计算期间分别完成 6／12／13／22／23 次读，各轮最长为 0.745／0.614／0.646／0.215／1.777 ms，直接证明 World 继续服务；第一轮计算太短没有探针命中，不能记作零阻塞。全局最长读 39.216 ms 位于 seq378，远离 checkpoint，对应最慢热几何 callback；不把它全部归因于压缩。详情 `async375/correlation.json`；合法导出为 seq753、thermal375.0、429 entries＋172 coarse，持久化 envelope 完整。

检查点定向复跑参数（接在上述 Mix wrapper 后，当前行号与选择范围）：

```text
mmo_contracts test --no-start test/mmo_contracts/payload_test.exs --seed 0
data_service test --no-start test/data_service/voxel/overlay_log_store_test.exs --seed 0
voxel_region test --no-start test/overlay_log_prefix_test.exs --seed 0
voxel_region test --no-start test/world_test.exs --seed 0
voxel_region test --no-start test/phase_world_test.exs --only checkpoint_thermal --seed 0
voxel_region test --no-start test/phase_world_test.exs:223 --include realtime --seed 0
voxel_region test --no-start test/payload_candidate_test.exs --seed 0
voxel_region test --no-start test/thermal_fire_benchmark_test.exs --only benchmark --seed 0
```

2026-10-05 用户先选择“先保留，暂缓 UE 实跑”，随后明确恢复并通知另一项双臂录制的 UE／服务资源已释放。本轮使用隔离 `Voxim-p1`，避免混入主树正在制作的魔法资产与 UI；身体实跑完成后停止独立 BodyLive 容器，再开始无 UE／构建竞争的 180 秒弱网前后采样。此前并发背景下的存储对照仍仅用于诊断。

既有真实 60 s 自动维护生命周期于最终异步源码再次执行：`phase_world_test.exs:223` 实际选中／完成 1 项，发现 44 项、排除 43 项，0 失败、退出 0、61.7 s。覆盖真实 timer #1、休眠与原回执保留、新供给消费唤醒、手动 compact #2 及冷恢复。日志为 `Saved/P1/Checkpoint/async-phase-lifecycle-60s.log`。

当前状态：P1 三项增量已实现并完成各自范围的验证：相干度及复制相位经过真实双客户端，检查点经过真实 World／PG／File／NIF、自然林火测量与定时维护冷恢复。所有本轮 UE 已退出，BodyLive 与弱网独立容器已停止；用户的符号定位、魔法及 UI 工作不在本轮改动中。最终异步源码未重建正式镜像或运行打包客户端；`8c0dd030` 镜像只证明先前弱网修复，不冒称当前异步版本的部署验收。本轮不包含 Qinglan 分发、完整 M2a 矩阵、GPU 帧率或 MMO 容量验收。
