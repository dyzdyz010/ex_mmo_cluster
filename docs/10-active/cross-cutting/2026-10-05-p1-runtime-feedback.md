---
status: active
---

# P1：运行停顿、身体反馈与弱网呈现

分类：产品改动为 Global system；诊断、运行器和验收场景为 Test-only。用户于 2026-10-05 授权 P1，基础优先；不包含容量扩张或 Qinglan 分发。

## 契约与可运行增量

- [ ] **World 检查点与交互停顿**：先测当前代码的 select／image／persist／rebase 与 SQL 分段，使用同一合法生成场景、独立数据库与同条件前后测量。只改已证实的瓶颈；原事务落盘后才确认、检查点原子替换与冷恢复内容保持。优先考虑保持现有写入顺序的局部优化，只有测量证明不足才改变并发契约。相关入口为 `World.Log.compact_log`、`OverlayLog.rows`、`DataService.Voxel.OverlayLogStore` 和既有 `thermal_fire_benchmark_test`。
- [ ] **身体变化主动刷新相干度**：沿 Player 既有 1 Hz 身体上报，World 在值变化时用既有 0x83 状态通知当前连接。客户端保留报价、实际支出和前摇，只刷新当前权威状态。已确认 World 直推与 Dispatch 二次转发会因跨发送者而乱序，因此报价／结算／首次状态／身体推送统一由 World 发送；Gate 继续按既有 session／已接纳回执身份拒旧，不加线协议版本字段或第二份身体真值。用延迟 Dispatch 返回的受控反例证明旧报价不能晚到回退，另覆盖客户端消息消费与真实玩家恢复场景。
- [ ] **弱网远端呈现**：先用当前构建、现有 M2a／M1 运行器与相同正常输入采基线，区分缺插值括号后的外推与真正冻结；确认根因后修最短路径。保留现有 100 ms 插值延后、100 ms 外推上限及正确性门槛，不通过扩大延后或改统计口径把旧失败变绿。旧 <1% 缺样为优化观察目标，不把数学上正常的外推误报为卡住；原指标与新增诊断同时保留。

## 验证与边界

先跑能证伪修复的最小用例，再回归直接接缝。涉及 World 持久化时用真实 PostgreSQL、后续事务及冷恢复；涉及状态消息时覆盖已接纳回执与重连／移交身份；涉及玩家体验时使用真实双客户端与正常输入。性能测量保留共同窗口、规模、版本、实际时长、失败与并发背景，诊断短跑不冒充 benchmark。

服务端从 `7b607ab1` 的隔离工作树 `ex_mmo_cluster-p1` 开始，客户端从 `1a8a6a6d` 开始。现有 P0 工具环境只复用编译缓存与测试基础设施，每 VM 独立数据库；共享 Mix／UE 构建及性能运行串行协调。用户正在进行的 UI 调研文件和其他 UE 会话不属于本轮所有物。

本机 Mix 入口：`wsl -d Ubuntu-22.04 --exec /bin/bash <Voxim>/Saved/P1/Environment/mix.sh <app> test --no-start <tests> --seed 0`。客户端沿正式 UE Automation／M2a 入口，截图只进 `Captures/`。

## 依据与当前证据

- [Erlang 信号顺序](https://www.erlang.org/docs/27/system/ref_man_processes.html#signals)：同一发送者到同一接收者的信号保序，不保证两个发送者之间的先后；相干度的所有状态包需要同一权威出口，周期覆盖不能消除已确认的乱序。
- [PostgreSQL 16 TOAST](https://www.postgresql.org/docs/16/storage-toast.html)：大 bytea 默认可能先压缩再外置，压缩策略可逐列指定。先测编码与数据库实际成本，不把 `persist_us` 全部推断成磁盘等待。
- [PostgreSQL 16 事务隔离](https://www.postgresql.org/docs/16/transaction-iso.html)：保持当前单事务替换的原子性；若以后将检查点移出 World，必须先设计前缀与并发后缀，不允许直接异步执行“删除全世界日志”。本轮尚未选择异步方案。
- 旧林火观察：2026-09-30 检查点约 185–222 ms，写库 163–213 ms；当前 P0 小世界约 3.6 ms。二者规模不同，均不能替代本轮大场景前后基线。
- 首轮弱网诊断 `Voxim/Saved/P1Remote/baseline01` 受另一 UE 会话与 Demo 日志级别影响，未形成有效样本；原始失败保留，不作基线或通过。
- 当前森林诊断 `Saved/P1/Checkpoint/forest375.log`：375 s 自然演化，配对提交跨度 374 s／墙钟 375.9 s；6 次检查点约 203–1163 ms，主要是 select（粗层完整区域候选计算后仍选稀疏），persist 约 9–26 ms。375 s 后既有 heap 统计继续让 World 演化，导出的固定样本为 thermal 470 s／seq 943，不能混称为 375 s 状态。
- 固定样本 `forest375-storage/storage.json`：619 行／70506 B，无完整 region 行；元数据编码中位约 1.73 ms。pglz→EXTERNAL→lz4→pglz 的 full replace 中位约 12.01／11.97／11.88／10.06 ms，实际 `pg_column_compression` 全为 none，波动大于策略差异。不改 PostgreSQL 压缩策略，继续剖析 select。
- [RFC 1951 §3.2.5／§3.2.7](https://www.rfc-editor.org/rfc/rfc1951)：一个 match 最多输出 258 B，length 和 distance 至少各占 1 bit；忽略树和封装只会削弱下界。因此完整载荷至少为 `54 + ceil(raw_min / 1032)` B，另外计算事务条目头 13 B。`raw_min` 由既有固定段和最终 CSR 记录集合得到：空表不带行索引；非空表加 17428 B 行索引及每条 10 B，省略非负的贴图和细节尾部。计数与实际编码共用覆盖规则，在 overlay 和邻区 ring 合并后执行，不用经验压缩率决定事务。
- 固定样本改后 `forest375-select-after/comparison.json`：从同一冷态丢弃返回缓存，三次 select 为 925.079／790.462／831.071 ms，改前单次 1182.815 ms。均跳过 L3 `{0,0,-2}`、L5 `{0,0,-1}` 两个不可能更小的候选；12 个区域的诊断记录完整。结果逐值等于改前事务，21904 B 协议编码完全一致。剩余约 0.8–0.9 s 同步选择成本尚未解决，不宣称检查点停顿已消除。
- 旧导出样本缺少 `World.Log.attachment_metadata` 添加的持久化 envelope，首次恢复诊断因此失败；原始失败保留在 `forest375-select.log`。后续固定样本对照仅从同版正常空 World 补出缺失的 catalog 单位信息，并立即暂停诊断 World，在离线不可变状态副本上比较；不属于产品冷恢复验收。原始命令、环境、失败及复判范围见 `Voxim/Saved/P1/Checkpoint/commands.txt`。

## 已集成增量

- 相干度：服务端 `5ac92109`、客户端 `f07c97d2`；状态／成功回执共用 World 出口，新 identity 必须首推，客户端保留请求结果。World 25、Scene 12、Gate 4 项相关用例通过（重跑不重复累计），改前反例保留在 `Saved/P1/coherence-*.log`。客户端 Automation 已写，未构建／未执行；真实 QUIC 双客户端和界面未验收。
- 弱网工具：客户端 `22be0e23`；现有运行器支持当前隔离部署和新角色，逐帧诊断区别缺括号、外推与保持，离线反例通过。未修改远端产品算法；真实后续入口在 `Voxim/Docs/M2a/README.md`。
- 检查点候选选择：先按格式下界跳过必输候选，仍由实际字节严格选择稀疏／完整区域；缓存和来源字节直接返回，存储及确认顺序不变。20 格小编辑反例从改前失败转为通过；新增 CSR World 反例用 644 B 稀疏条目证伪旧实现，记录下界为 652 B。当前源码定向验证共 10 项：Payload 纯格式 3 项、World 选择／ring／冷恢复／checkpoint stamp 与 damage 5 项、Payloads ring 合并／等号／删除／缓存 2 项。日志为 `bound-{red,green}.log`、`record-*.log`；首次 ring 夹具没有经过正式 encode/decode，失败保留，修正合法夹具后两项通过。位置过滤排除的用例未计入通过数。
- 诊断运行器：检查点耗时按当前四段日志相加，缺段不能判成有效总耗时；导出改为公开 compact 后读取真实后端 replay，且先于昂贵 heap 统计。`BENCH_SECONDS=1` 的 `thermal_fire_benchmark_test.exs --only benchmark` 实际执行 2 项、0 失败、退出码 0；新导出 `exporter-check/checkpoint.etf` 为 seq 5／thermal 1.0 s／19 entries＋21 coarse。离线检查确认 `material_units_per_micro=4096` 与独立 catalog JSON 一致，其他持久化 envelope 字段存在，导出日志先于 heap 日志。只验证导出接缝，不算冷恢复或性能验收；无需重复 375 s 场景。

检查点定向复跑参数（接在上述 Mix wrapper 后）：

```text
mmo_contracts test --no-start test/mmo_contracts/payload_test.exs --seed 0
voxel_region test --no-start test/world_test.exs:51 test/world_test.exs:387 test/world_test.exs:557 test/damage_world_test.exs:1201 test/damage_world_test.exs:1229 --seed 0
voxel_region test --no-start test/payload_candidate_test.exs --seed 0
```

2026-10-05 用户明确选择“先保留，暂缓 UE 实跑”：保留另一项 UI 工作的 UE 会话，本轮继续后端与离线验证；UE 构建、真实双客户端和独占性能验收待空闲时进行。并发背景下的存储对照仅用于诊断，不冒充性能验收。

当前状态：相干度链路与检查点第一项优化已实现并完成对应后端验证；弱网诊断工具已接通。P1 保持 active：需要当前版本 UE 构建／Automation、真实双客户端身体反馈与弱网场景，以及独占条件下的性能验收；剩余同步 select 开销也需继续处理。
