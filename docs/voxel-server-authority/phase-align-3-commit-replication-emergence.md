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

- 2026-06-14:决策稿落定。审计确认 field effect 直写 storage(违 RULE-11/AUTH-11)、无 outbox/watermark
  (违 AUTH-8/9/10)、复制打分寄居 AOI 无独立 Replicator(违 REPL-2/4/6)、无 flux 守恒/模型卡。拆
  3.8(system_actor 桥)/3.9(outbox+watermark)/3.10(Replicator)/3.11(flux+模型卡)。先执行 3.8。
