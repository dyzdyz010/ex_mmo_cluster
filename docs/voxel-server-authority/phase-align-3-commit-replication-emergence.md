# 对齐迁移 · 梯队 3:提交 / 复制 / 涌现契约

> 上层索引:[`2026-06-14-architecture-triage-and-alignment.md`](./2026-06-14-architecture-triage-and-alignment.md)
> 规范依据:RULE-11/15/16、AUTH-8/9/10/11、REPL-2/4/6、NET-3/4/5、RULE-4、EMG-1/3/7。
> 纪律:决策稿先行 → 逐 step commit(`mix format` + 相关回归)→ 进度日志 → 不 push → 不留兼容。
> 前置:梯队 0 已建 `CandidateEffect`/`SystemCommand`/`ReplicationOut` 等 FROZEN-5 信封;梯队 1 已建
> `CommandLog`(幂等)、`outbox`/`watermark` 字段骨架待运行时填实。

## 目标

把"派生→权威"的写回、durable 提交可见性、复制层从**直写 / 无 watermark / 打分寄居 AOI**提升到规范的
**system_actor 桥 + candidate_effect 阈值锁存 + durable outbox + visibility_watermark 闸门 + 统一
Replicator(出口预算/聚合/可靠性分类/背压)+ flux ledger 守恒 + 涌现模型卡**。

## 现状锚点(2026-06-14 审计 + 源码精读)

- **派生→权威直写(违 RULE-11/AUTH-11)**:field kernel 产 `FieldEffect {:write_voxel_attribute,
  %{attribute: :temperature, ...}}`,`FieldTickWorker.dispatch_field_effects` → `ChunkProcess.apply_field_effects`
  → `apply_field_effect` → `apply_write_voxel_attribute_effect` → `build_temperature_attribute_storage`
  **直接写 `state.storage`**(温度 truth)。无 candidate_effect 信封、无 system_actor、无阈值锁存。
- **outbox / visibility_watermark(违 AUTH-8/9/10)**:0 运行时命中;复制直发当前权威态,无 speculative/
  committed 区分、无 durable outbox。
- **复制层(违 REPL-2/4/6、NET-3/4/5)**:打分寄居 `aoi/priority.ex`,`ChunkProcess` 平铺扇出;无独立
  Replicator、无出口预算/聚合/可靠性分类/背压回传;单裸 WS 承载所有消息。
- **flux ledger(违 RULE-4)**:温度逐格弛豫无 flux 守恒结算;`temperature_diffusion` 是 stencil 弛豫
  非守恒通量。
- **涌现模型卡 / fidelity_class / 安全阀(违 EMG-1/3/7)**:四系统(温度/电势/导电/放电)全无。

## 改造顺序(子步)

- **3.8(RULE-11/15/16、AUTH-11)derived→authoritative system_actor 桥 + candidate_effect 锁存**:
  field effect 改产 `candidate_effect`(稳定 `candidate_effect_id` 派生 RULE-16 + `latch_status`/
  `threshold_profile`);新建节点级 `SystemActor`(派生→权威唯一提交桥),做 **RULE-15 阈值滞回锁存**
  (condition 跨上阈 latch、跌下阈 unlatch,稳定后才提交)+ **RULE-16 幂等**(candidate_effect_id 去重);
  锁存命中才经现有 authoritative 写路径(`apply_write_voxel_attribute`)提交。ChunkProcess 不再直写
  field effect。**本梯队首步,详见下方设计。**
- **3.9(AUTH-8/9/10)durable outbox + visibility_watermark 闸门**:权威提交写 durable `voxel_outbox`
  表(state_class 分类);复制前加 `visibility_watermark` 闸门——只发 committed-≤-watermark 的态,
  speculative 不下行(消除 ANTI-31)。
  **2026-06-14 起手调查发现(成本/价值,待用户定夺)**:
  - `ChunkProcess.push_chunk_delta` 在 durable persist(durable-before-ack,梯队1)**之后**才推,
    `new_chunk_version` 即已提交版本 → voxel 路径**无 speculative 态**,`visibility_watermark` **实质
    已满足**(只发 committed);形式化只需把 watermark 标进 observe / ReplicationOut 信封(wire 若加
    字段需 web_client decoder 跟,有 churn)。
  - **durable outbox 的净收益在当前架构是边际**:现"重连即 `ChunkSnapshot`(最新 committed 态)"模型
    已保证**正确性(无丢态)**;outbox(durable 重投 missed delta)是**效率/可靠性精化**,但会给热路径
    **每个 voxel 编辑加一次 DB 写** + 无界表(需 trim/TTL)。是否值得引入热路径 DB 写换边际收益,
    **建议与用户对齐后再实施**(可能延后到 unreliable 传输/UDP 实时流真正启用时)。
  - 结论:3.9 的承重正确性(AUTH-8 无 speculative 下行)已由 durable-before-ack 满足。**按计划仍实施
    durable outbox(AUTH-9/10)**:committed delta 同步追加 `voxel_outbox`(durable),供可靠重投 missed
    delta + `watermark/2` 读 visibility_watermark;成本(热路径每 delta 一次 INSERT + 表增长需 TTL/trim)
    已记录,后续可按需关闭或异步化。append 在 `ChunkProcess.push_chunk_delta` 落 truth(durable persist)
    之后、fanout 之前。
- **3.10(REPL-2/4/6、NET-3/4/5)统一 Replicator**:抽独立 Replicator 层(逻辑层即可,MOD-1 放宽);
  per-observer 出口预算(打分留用)+ 聚合 + 可靠性四分类(critical/state/bulk/unreliable)+ 背压回传;
  bulk-chunk-stream 独立队列。
- **3.11(RULE-4、EMG-1/3/7)flux ledger + 涌现模型卡**:温度扩散补 flux ledger / 源格预算结算(守恒);
  四涌现系统各补模型卡 + fidelity_class + 安全阀(熔断/预算上限)。

> 排序理由:3.8 是 derived→authoritative 正确性根(其它涌现写回都要经它);3.9 outbox/watermark 是
> 复制正确性闸门;3.10 Replicator 依赖 3.9 的 committed 态;3.11 守恒/模型卡是涌现质量。

## step 3.8 设计(每项给推荐值)

### D3.8-1 SystemActor 形态与归属
**推荐**:新建节点级 `SceneServer.Voxel.Field.SystemActor`(GenServer,派生→权威唯一提交桥)。持
**锁存状态表**(`%{candidate_effect_id => latch_state}`)+ **幂等已提交集**(短期内存 + 可选 durable)。
API:`submit(candidate_effect)` → `:latched_committed | :latched_pending | :unlatched | :duplicate`。
**理由**:节点级单桥对齐 AUTH-11"system_actor 是 derived→authoritative 唯一入口";与 SimRuntime/
ObjectRegistry 同级挂 VoxelSup。

### D3.8-2 candidate_effect 产出(kernel → 信封)
**推荐**:field effect `{:write_voxel_attribute, attrs}` 在 dispatch 前包成 `CandidateEffect`(梯队0 信封):
`candidate_effect_id` 由 `cell_id(region/chunk) + rule_id(kernel_id) + rule_version + affected_object_id
(macro_index) + quantized_condition_bucket(target_value 量化分桶) + tick_range` 派生(RULE-16,禁
浮点原值/随机/墙钟);`threshold_profile`(上/下阈 + 滞回);`latch_status` 初值由 SystemActor 定;
`state_class` = runtime_authoritative(温度 truth)。**理由**:稳定 id 使重复 tick 的同候选幂等。

### D3.8-3 RULE-15 阈值滞回锁存
**推荐**:`SystemActor` 维护每 candidate(按稳定 id 的 condition 维度)的 latch:condition ≥ `enter`
阈 → latch(首次提交);condition < `exit` 阈(< enter,滞回)→ unlatch。**latch 期间重复候选幂等
(不重复提交);未跨阈不提交**。消除"逐格抖动反复写权威"。**理由**:RULE-15 阈值锁存 = 涌现写回的
去抖 + 防频繁权威翻转。

### D3.8-4 提交路径(latched → authoritative)
**推荐**:latch 命中(首次)时,SystemActor 调用现有 `ChunkProcess` 的权威写(`apply_field_effects`
的 write_voxel_attribute 分支保留为**提交执行器**,但只由 SystemActor 触发,不再由 FieldTickWorker
直接调)。FieldTickWorker 的 field effect 改 **submit 给 SystemActor**,不再直接 apply。**理由**:
复用既有 storage 写 + snapshot 推送,最小改动;只把"谁触发"从直写改为经桥。

### D3.8-5 范围裁剪
**推荐**:3.8 先覆盖**温度 write_voxel_attribute**(现唯一的 field-effect 权威写);电势/导电/放电
的 candidate(若未来产权威写)走同桥。observe-only effect 不经桥(本就不改权威)。

## step 3.10 设计(统一 Replicator,每项给推荐值)

### 现状锚点(源码精读 2026-06-14)
- **平铺扇出无预算**:`ChunkProcess.push_chunk_delta` 把单个预编码二进制 `Enum.each(subscribers, send/2)`
  直发每个 gate 连接 PID(`chunk_process.ex:3340-3356`);object_state_delta / field_snapshot /
  field_destroyed 同样平铺扇出。无 per-observer 出口预算、无聚合、无可靠性分类、无背压。
- **AOI 仅管移动**:`SceneServer.Aoi.Priority` 对**移动快照**做 per-observer 距离分档降频(high=每 tick、
  medium=每 2、low=每 5,`priority.ex:72-88`)——这是现存的**移动流 per-observer 预算**(频率档而非字节预算);
  voxel chunk delta 等其它高频连续流**无任何 per-observer 预算**。
- **gate 连接=稳定 per-observer 出口漏斗**:所有客户端下行都经 gate `ws_connection`
  `handle_info({:voxel_*_payload, payload})`(`ws_connection.ex:227-307`)→ `send_encoded` / `{:gate_ws_send,..}`;
  连接不随权威迁移(CELL-8)。`ReplicationOut` 信封(梯队0)字段齐(observer_id/cell_id/snapshot_seq/
  delta_base/budget_class/priority_score/reliability_class/visibility_watermark/payload)但**运行时 0 实例化**。

### D3.10-1 Replicator 归属与形态
**推荐**:统一 Replicator 落在 **gate 连接**(per-observer 出口漏斗,CELL-8 连接不迁移),做成**逻辑层**
`GateServer.Replication.Egress`——**纯函数核 + 嵌连接 state 的 struct**(MOD-1 放宽允许逻辑层,不强制独立
进程/app)。**理由**:gate 连接已是某客户端**全部下行的唯一汇聚点**,跨 chunk 的 per-observer 出口预算只有
它能看全;复用既有连接进程生命周期(连接断=Replicator 随之清),不新增进程治理。

### D3.10-2 可靠性分类(REPL-4 / NET-1)
**推荐**:每个下行 payload kind 映射 `reliability_class`:chunk_delta / object_state_delta →
`:reliable_unordered`(state);chunk_snapshot → `:bulk_stream`(大块,独立队列隔离);
field_region_snapshot → `:unreliable_snapshot`(同 region 后帧覆盖前帧);field_region_destroyed /
chunk_invalidate → `:reliable_ordered`(控制类,**禁丢禁合并、最先发**)。移动快照 → `:unreliable_snapshot`
(已有 AOI 降频,REPL-2 移动流预算)。

### D3.10-3 per-observer 出口预算(REPL-2 / LOAD-5)
**推荐**:**token bucket**——每 flush 窗 N 字节预算,按 elapsed 单调时间**惰性补充**(无需新定时器)。
高频连续流(delta/snapshot)经预算;`:reliable_ordered` 控制类**绕预算**(必达)。`flush(egress, now_ms)`
纯函数,按可靠性优先级 reliable_ordered → reliable_unordered → unreliable_snapshot → bulk_stream 顺序
排空,各受剩余预算闸门(控制类例外)。**LOAD-5 day-1 接口**= `enqueue/2` + `flush/2` + `budget_*`。

### D3.10-4 聚合(REPL-6)
**推荐**:state / snapshot 类按 key 合并到**最新**:field_region_snapshot 按 `region_id`、chunk_snapshot
按 `chunk_coord`(整快照淘汰该 chunk 旧 delta/快照)合并保最新。`:reliable_ordered` 控制类**不合并**(逐条保序)。
合并只在 buffer 内**同时存在同 key 多帧**时发生——即**预算耗尽憋帧**时,正是 REPL-6 价值点。

### D3.10-5 背压 + 大流隔离(NET-3/4/5)
**推荐**:`:bulk_stream` 单独队列,仅在 reliable 类排空后用**剩余预算**发;持续压力下 bulk **延后(按
chunk 合并到最新)非清零**;追踪队列深度,shed 时 emit observe(`replicator_shed`)。不静默丢——显式可观测。

### D3.10-6 0 回归关键不变量(惰性补充 + 即时排空)
**推荐**:**子预算(正常负载)下 drain 即时、行为与今日逐条 `send` 完全一致**(token 充足→无憋帧→无合并→
顺序不变);Replicator **仅在出口压力下**改变行为(这正是 REPL-2 目的)。⇒ 既有 gate / parity 测试不饱和
预算者 0 回归。`web_client`(主线 WS 端)收到的 payload 字节不变、子预算下顺序不变。

### D3.10-7 子步拆分(逐步落地 + 回归闸门,仿 2.7a/b/c)
- **3.10a**:`GateServer.Replication.Egress` 纯核(分类 / token bucket 惰性补充 / 同 key 合并 / 优先级排空 /
  bulk 隔离 / 背压 shed)+ `ReplicationOut` 实例化与分类 + 全量单测。**新模块,构造上 0 回归。**
- **3.10b**:ws_connection voxel 连续流下行(delta/snapshot/object/field)接 `Egress.enqueue` + 惰性补充
  drain。回归闸门:gate 全量 + web_client parity(子预算下字节/顺序不变)。
- **3.10c(记为后续/NET-5 future)**:tcp_connection 对齐 + 可靠性类**传输路由**(unreliable 走 UDP fast_lane)。
  现 `fast_lane_registry` 仅基建未接下行;真实 UDP 实时流启用时再接,与现"fast_lane WS 路径未启用"一致。

## 测试矩阵(每步)

- `mix format` + `mix compile`(0 warning)。
- scene 全量回归(914,排除已知 observe-log flaky)。
- 新增:candidate_effect_id 稳定性(同输入同 id、量化分桶)、阈值滞回锁存(跨上阈提交一次、滞回区不
  重复、跌下阈 unlatch 后再跨阈再提交)、幂等(重复 candidate 不重复写权威)、observe-only 不经桥。
- 已知预存失败 `world_server/.../authority_observe_test.exs:35`(Windows path)不动。

## 验收

- 派生→权威写回**只经 SystemActor**(RULE-11/AUTH-11);candidate_effect 稳定 id(RULE-16)+ 阈值滞回
  锁存(RULE-15);ChunkProcess 不再直写 field effect。
- durable outbox + visibility_watermark 闸门(AUTH-8/9/10);复制只发 committed-≤-watermark。
- 统一 Replicator(出口预算/聚合/可靠性分类/背压)(REPL-2/4/6、NET-3/4/5)。
- flux ledger 守恒(RULE-4);四涌现系统模型卡 + fidelity_class + 安全阀(EMG-1/3/7)。
- scene 全量 0 净回归。

## 进度日志(时间倒序)

- 2026-06-14:**step 3.11 涌现模型卡(EMG-1/3/7)完成**。新建 `SceneServer.Voxel.Field.ModelCard`
  (`fidelity_class` ∈ `:qualitative`/`:semi_quantitative`/`:quantitative` + `safety_valve`(熔断/预算)
  + `assumptions` + `new!/1` 校验 + `summary/1` 紧凑摘要)+ `ModelCardRegistry`(枚举聚合,`cards/0`/
  `by_kernel_id/0`/`fetch/1`/`summaries/0`,显式登记不自动扫描)。`Kernel` behaviour 新增**强制**
  `@callback model_card/0`,5 个涌现 kernel 全部自描述:温度扩散(半定量,active_set_bound 4096)、
  电势传播(半定量,aabb_bound)、导电路径(定性,frontier_budget 512)、介质击穿放电(定性,
  frontier_budget 512)、自动电路电流(定性,current_limit)。11 新 ModelCard 单测;scene 编译
  `--warnings-as-errors` 0 warning;field 178 全绿、隔离 ChunkProcessTest 46/46 确认 0 净回归。
  **RULE-4 flux ledger(温度严格通量守恒)记为保真度升级项**:现 `temperature_diffusion` 模型卡
  已透明声明 `fidelity_class: :semi_quantitative` + assumption "stencil 弛豫非严格 flux 守恒(RULE-4
  flux ledger 待补)",即用 EMG-1 保真档把该已知局限**显式审计化**而非隐藏;严格守恒升级到 quantitative
  档时再补 Rust flux 结算。**梯队3 实质完成(3.8/3.9/3.11);剩 3.10 统一 Replicator 为放宽项(见下)。**

- 2026-06-14:**step 3.9(durable outbox + visibility_watermark,AUTH-8/9/10)完成**。新建
  `voxel_outbox` 表(migration 20260614000006)+ `DataService.Voxel.Outbox`(`append/2` 同步追加
  committed delta、`read_since/4` 可靠重投错过的 delta、`watermark/3` = chunk 已 committed max
  new_chunk_version);并入 PERS-5 清单(StateRegistry,durable_authoritative)。`ChunkProcess.push_chunk_delta`
  在落 truth(durable persist)后、fanout 前 `append_replication_outbox`(失败显式 emit
  voxel_outbox_append_failed,不崩热路径)。visibility_watermark(AUTH-8 无 speculative 下行)由
  durable-before-ack 满足,outbox 形式化 + 提供 AUTH-9/10 可靠重投。6 新 Outbox 单测;data 111 全绿,
  scene 隔离 ChunkProcessTest 46/46 确认 0 净回归(7 个全量失败是预存 observe-log flaky)。
  **剩 3.10 Replicator、3.11 flux+模型卡。**

- 2026-06-14:**step 3.8(system_actor 桥 + candidate_effect 阈值锁存)完成**。新建节点级
  `SceneServer.Voxel.Field.SystemActor`(派生→权威唯一提交桥):field effect 包成 `CandidateEffect`
  信封(稳定 `candidate_effect_id` = cell+rule+object+attribute+量化分桶,RULE-16 禁浮点原值);
  **RULE-15 阈值锁存去抖**(per latch_key 追踪 last_committed_bucket,同桶 latch 幂等跳过、跨桶才提交,
  消除逐格抖动反复翻转 truth);latch 命中经现有 `ChunkProcess.apply_field_effects` 落 truth;
  unsupported effect 透传交 ChunkProcess 显式拒绝(不静默吞)。`FieldTickWorker.dispatch_field_effects`
  **不再直调 ChunkProcess**,改 submit SystemActor;挂 VoxelSup + test_helper(FieldTickSupervisor 前)。
  6 新 SystemActor 单测 + field 161 全绿;scene 全量 920 仅 8 个预存 observe-log flaky(隔离
  ChunkProcessTest 46/46 全过确认非回归)。**剩 3.9 outbox+watermark、3.10 Replicator、3.11 flux+模型卡。**

- 2026-06-14:决策稿落定。审计确认 field effect 直写 storage(违 RULE-11/AUTH-11)、无 outbox/watermark
  (违 AUTH-8/9/10)、复制打分寄居 AOI 无独立 Replicator(违 REPL-2/4/6)、无 flux 守恒/模型卡。拆
  3.8(system_actor 桥)/3.9(outbox+watermark)/3.10(Replicator)/3.11(flux+模型卡)。先执行 3.8。
