# Phase 4-bis：ObjectStateDelta 推送链路 + 客户端最小消费

> 别名:Phase 4.5(handoff 与对话里出现过这个名字,本文统一称 Phase 4-bis,
> 对齐 README 的 `3-bis` 命名风格)。

## 目标

把 Phase 4 在决策项 D11 显式 deferred 的"ObjectRegistry 状态变化 → 0x6C
ObjectStateDelta wire 消息 → 客户端"实际推送链路接完。

这是阶段 A(可玩 demo 最低线)的第 1 个子项。完成后,后端在 ObjectRegistry
端的 damage / part_destroyed / object_destroyed 事件能够通过现有 chunk
订阅通道推送到 web_client,客户端在被清空的 micro slot 位置播碎屑粒子
特效,建立"破坏 → 客户端可视(沿 object 形状散布的小爆炸)"的闭环,
为后续多客户端联调解锁基础。

## 不在范围(明确推到 Phase 5+)

- `attribute_patch[]` / `tag_patch[]` 字段填充 — 协议 §9 已留位,Phase 4-bis
  仍固定空。Phase 5(属性目录 + 温湿度模拟)填充。
- 客户端高级可视:part 级血条、destroyed 屏幕红闪 / 音效、object 残骸
  物理掉落 — Phase 4-bis 只做"碎屑粒子 + HUD 一行提示"。
- 协议层扩展:不给 0x6C 加 `destroyed_cells` 列表字段(超出范围,见
  D6 档 C 替代被否)。
- ObjectStateDelta 重发 / lossy recovery — 客户端订阅断连后不补 0x6C
  历史。重新订阅 chunk 时通过 ChunkSnapshot 的 ObjectRefs section 重建
  当前 truth(本身 deferred 到 Phase 5,本阶段也不动)。
- 跨 chunk 一致性测试矩阵的"丢一份消息"路径 — 单元层面验证发送语义即可,
  网络层 lossy 治理是 Phase 5+ 的传输层工作。

## 名词速查(给路演 / 外行视角)

| 术语 | 含义 |
| --- | --- |
| `0x6C` | wire 协议的消息类型字节,代表 `ObjectStateDelta`(对象状态变化广播) |
| `ObjectStateDelta` | 协议 §9 定义的"某 object 整体经历了状态变化"消息体,带 object_id / version / state_flags / 受影响 chunk 列表 |
| `ObjectRegistry` | scene_server 内的 GenServer,持有该 scene 当前活着的所有 object 实例(prefab 放置后产生的"一栋房子"、"一辆车"等) |
| `ChunkProcess` | 每个体素 chunk 一个 GenServer,持有该 chunk 的权威 truth + 订阅者列表 |
| `subscriber` | gate_server 端 `WsConnection` / `TcpConnection` 进程,通过 `subscribe_chunk` 把自己的 pid 注册到 ChunkProcess.subscribers |
| `state_flags` | u32 位掩码,用 `flag_damaged` / `flag_part_destroyed` / `flag_destroyed` 三个位表达"这次事件触发了什么状态变化" |
| `affected_chunks` | 这次事件影响到的 chunk 坐标列表;客户端用它做"哪些 chunk 需要重新查询 truth"提示 |
| `micro slot` | 一个 macro cell(1m³)细分成 4×4×4=64 个 0.25m³ 微格;refined cell 用 mask 表达哪些 micro slot 被填充 |
| `owner_object_id` | 每个 micro slot 在 server-side truth 里携带的所有者标记(Phase 4-1 起);告诉客户端这一点点空间属于哪个 object |
| `ChunkDelta` | 协议 §8 定义的"chunk 内部某 cell 变了"增量消息,携带 `cell_refined` ops 等;Phase 4-bis 用它做"哪些 micro slot 刚被清空"的信号源 |
| `碎屑粒子(debris)` | 客户端 destroy 时在被清空 micro slot 位置生成的小立方体粒子;Phase 4-bis D6 选定的视觉风格 |
| `ClearedSlotCache` | 客户端缓存,记录"刚被 ChunkDelta 清空的 micro slot 属于哪个 object";给 0x6C 来时取出做粒子起点 |

## 现状对照(Phase 4 末态 → 4-bis 起点)

- `apps/gate_server/lib/gate_server/codec.ex:627`:`encode({:voxel_object_state_delta, %{} = delta})` 接收
  map,内部调用 private `encode_voxel_object_state_delta_payload/1`,产出
  `[<<0x6C>>, payload_iolist]`。这是**当前唯一的 0x6C encode 入口**,且
  Codec 函数本体在 gate_server 而不是 scene_server,与其它 server→client
  payload(`encode_chunk_delta_payload` / `encode_chunk_snapshot_payload`,
  都在 `apps/scene_server/lib/scene_server/voxel/codec.ex`)风格不一致。
- `apps/scene_server/lib/scene_server/voxel/object_registry.ex` 行 540 / 552 / 562:
  `emit_damage` / `emit_part_destroyed` / `emit_object_destroyed` 仅写
  `CliObserve.emit/2`,**没有任何 wire 推送**。
- `apps/scene_server/lib/scene_server/voxel/chunk_process.ex:1785`:
  `state.subscribers` 持有 `%{pid => %{request_id: ...}}`,通过
  `send(subscriber, {:voxel_chunk_delta_payload, payload})`(已 encoded
  binary)推送 ChunkDelta。同模式还有 `:voxel_chunk_snapshot_payload` /
  `:voxel_chunk_invalidate_payload`。
- `apps/gate_server/lib/gate_server/worker/ws_connection.ex:235` 与
  `tcp_connection.ex:300`:`handle_info({:voxel_chunk_delta_payload, payload}, ...)`
  → `send_encoded(state, {:voxel_chunk_delta_payload, payload})`,Codec 端
  对 binary payload 加 opcode prefix 后写到 socket。
- `clients/web_client/src/infrastructure/net/objectStateDelta.ts`:Phase 4-9
  落了 decoder + console.log stub,但**还没接入主循环**(在线 voxel
  adapter 不消费 0x6C)。
- `apps/gate_server` 的 wire dispatch loop **还不识别 0x6C 消息**(server→client
  方向,gate 不需要 decode 0x6C,只需 encode 然后 forward)。但 gate
  codec 已经测过 0x6C encode/decode roundtrip(gate_server 188 tests)。

## 整体架构选择

**事件源** = ObjectRegistry(emit_damage / emit_part_destroyed / emit_object_destroyed)。

**推送链路** = ObjectRegistry **同步** lookup 每个 affected chunk 的
ChunkProcess pid → 给每个 ChunkProcess `cast({:push_object_state_delta_payload, binary})` →
ChunkProcess 在自己的 handle_cast 里 fan-out `state.subscribers` 同
chunk_delta 既有路径。

**编码位置** = `apps/scene_server/lib/scene_server/voxel/codec.ex`(对齐
chunk_delta / chunk_snapshot / chunk_invalidate),gate_server codec 改为
binary pass-through。

**重复推送** = **不去重**,客户端按 `object_version` 单调递增做去重。affected_chunks
通常 1-2 个,即使一个 client 同时订阅了 affected_chunks 中的两个,看到
两条相同 object_version 的 0x6C 直接丢弃第二条即可。

**失败容忍** = ObjectRegistry 推送失败(ChunkProcess 不存在 / cast 异常)
**不阻塞**主路径(damage / persist 已经成功)。失败用 `try / catch :exit`
静默吞 + observe emit `voxel_object_state_delta_dispatch_failed`。

## 决策项(D1-D9)

> 工作流约定:**每条决策项给推荐值**,等用户审完(同意 / 改值 / 排序调整)后
> 进度日志记 D1-D9 推荐值生效 → 才动 Step 1 代码。

### D1:推送架构

**推荐**:ObjectRegistry 收完 emit 后,**同步** call ChunkDirectory
新增的 `lookup_chunk_pid/3`(返回 `{:ok, pid} | :not_started`),拿到
每个 affected chunk 的 ChunkProcess pid,然后 `GenServer.cast(pid,
{:push_object_state_delta_payload, binary})`。

ChunkProcess `handle_cast({:push_object_state_delta_payload, payload}, state)`
fan-out 给 `state.subscribers`,镜像 `push_chunk_delta` 形态:

```elixir
defp push_object_state_delta_payload(state, payload) do
  Enum.each(state.subscribers, fn {subscriber, %{request_id: request_id}} ->
    send(subscriber, {:voxel_object_state_delta_payload, payload})

    CliObserve.emit("voxel_object_state_delta_push", fn ->
      %{
        logical_scene_id: state.logical_scene_id,
        chunk_coord: state.chunk_coord,
        subscriber: subscriber,
        request_id: request_id,
        byte_size: byte_size(payload)
      }
    end)
  end)
end
```

**理由**:
- 订阅状态权威是 ChunkProcess(按 chunk 维度),其它进程不应复制
- 与 `push_chunk_delta` / `push_snapshot_fallback` 同模式,易理解、好测
- ChunkDirectory.lookup_chunk_pid 同步 call,延迟 < 100μs,非热路径不必 cast 回避
- ChunkProcess 端用 cast(已经在 GenServer 里)避免 ObjectRegistry 阻塞

**替代被否**:
- ObjectRegistry 自己持有 subscribers:违反 SRP,且 ChunkProcess 重启时
  ObjectRegistry 端的副本会失同步
- 走 `:pg` group(per-scene 或 per-object pg group):需要新建 + 维护
  group 成员,Phase 4-bis 单事件流不值得,且 Phase 5+ 真要全 scene 广播
  时再上 :pg(届时把 chunk 订阅也改造,统一治理)
- ObjectRegistry 直接 `send(subscriber_pid, ...)`:需要 ObjectRegistry
  自己穿透 ChunkProcess 拿 subscribers,引入跨进程状态读取与一致性问题

### D2:wire codec 函数主战场

**推荐**:把 `0x6C ObjectStateDelta` 的 encode/decode 主战场从
`gate_server/codec.ex` 挪到 `scene_server/voxel/codec.ex`。

具体改动:

- **scene_server/voxel/codec.ex 加**:
  - `encode_voxel_object_state_delta_payload/1`:接收
    `%{logical_scene_id, object_id, object_version, state_flags, affected_chunks}`,
    返回 `binary`。逻辑直接从 gate_server codec 行 651-681 移植。
  - `decode_voxel_object_state_delta_payload/1`:返回 `{:ok, map(),
    rest_binary}`。从 gate codec 行 689-709 移植。
  - 同位测试:`apps/scene_server/test/scene_server/voxel/codec_object_state_delta_test.exs`
    新建(从 `apps/gate_server/test/gate_server/codec/object_state_delta_test.exs`
    迁移用例 + 保留少量 gate-side wire roundtrip 用例)。

- **gate_server/codec.ex 改**:
  - 删除 `encode({:voxel_object_state_delta, %{} = delta})` 与
    `encode_voxel_object_state_delta_payload/1` private 函数(map 形式 encode)。
  - 新加 `encode({:voxel_object_state_delta_payload, payload}) when is_binary(payload)`,
    简单 pass-through `{:ok, [<<@msg_voxel_object_state_delta>>, payload]}`,
    与 `:voxel_chunk_delta_payload` / `:voxel_chunk_snapshot_payload` 同模式。
  - **保留** `decode_voxel_object_state_delta_payload/1`(server-side 测试
    与未来 gate-as-client 调试都用得上,且与 chunk_delta decode 也保留
    在 gate codec 风格一致)。

- **gate_server/test/gate_server/codec/object_state_delta_test.exs 改**:
  - 删除 map-encode 用例(已迁移到 scene 端)
  - 保留 binary-payload-pass-through 编码用例(gate 端 opcode prefix 验证)
  - 保留 decode 用例(gate 调试入口)

**理由**:
- `chunk_delta` / `chunk_snapshot` / `chunk_invalidate` 全部 server→client
  payload encode 在 scene_server/voxel/codec.ex,wire 主战场单点。0x6C
  是同一类(server→client 状态推送),不放例外。
- ObjectRegistry 在 scene_server,挪过来后能直接 `Codec.encode_voxel_object_state_delta_payload(...)`
  得 binary,不需要绕道 gate_server(scene 不依赖 gate)。
- gate codec 改 binary pass-through 后,encode 一次 → fan-out N 个 subscriber,
  对齐 chunk_delta 的 CPU 摊销策略。
- 不引入 wire 双实现风险(同份 binary 格式只在一个地方维护)。

**替代被否**:
- codec 留在 gate_server,scene 通过 message passing 传 map 给 gate-side
  encode:每个 subscriber encode 一次,N 倍 CPU;且 ObjectRegistry → gate 跨 app
  消息形态不自然
- codec 双份(gate 一份,scene 一份):wire bug 风险高,违反"未上线第一版
  不留双路径"
- 整 gate codec 全挪到 scene_server:范围爆炸,Phase 4-bis 不该做
  全 codec 重组(gate 还需要 client→server 方向的 codec,如
  `encode_voxel_edit_intent` 是 decode 不动 — 所以挪法只挪 server→client
  的 0x6C)

### D3:重复推送 / 客户端去重

**推荐**:**服务端不去重,客户端按 `object_version` 去重**。

服务端实现:ObjectRegistry 拿 `instance.covered_chunks` 列表,**所有元素**
都 dispatch broadcast,即使某个 subscriber 同时订阅了 covered_chunks 里
的 N 个 chunk,也会收到 N 份相同 `object_version` 的 0x6C。

客户端 web_client 端:`ObjectStateDeltaConsumer`(新)持有
`%{object_id => last_seen_version}`,decode 后若 `version <= last_seen`
直接丢弃,否则更新 last_seen 并触发回调。

**理由**:
- affected_chunks 通常 = 1(单 chunk prefab)或 2(跨 chunk),最多 4
  (2x2x1 大 prefab)。重复推送 N=2-4 倍,绝对量小。
- 客户端 dedupe 自然(`object_version` 已经在 Phase 4 升级)
- 服务端去重需要从 ObjectRegistry 反查"哪些 subscriber 订阅了这些 chunk
  的并集"—— 跨 ChunkProcess 状态读,且 ChunkProcess 重启时一致性麻烦
- 实际丢消息(网络层)时,客户端如果只订阅 covered_chunks 中部分,N>=2
  分发反而提供天然冗余(虽然 Phase 4-bis 不形式化这个性质,deferral 提到了)

**替代被否**:
- 服务端去重:需要跨 ChunkProcess 收 subscribers 并集 → 跨进程读 → 一致性
  烦,且 Phase 5 要扩展 affected_chunks 跨 region 时更难
- 全场景广播一次(不按 chunk 分发):违反 chunk 订阅的"客户端只看自己订阅
  的 chunk"语义,也意味着 0x6C 与现有订阅模型脱节

### D4:ObjectRegistry 端推送触发点

**推荐**:在每个现有 emit_xxx 之后,**同步 dispatch broadcast**(不抢
emit 顺序,先 observe log 再 wire 推送)。

具体改动:

```elixir
# emit_damage 之后
defp emit_damage(scene_id, object_id, part_id, part_state, damage) do
  CliObserve.emit("voxel_part_damaged", fn -> ... end)
  # NEW
  dispatch_object_state_delta(scene_id, object_id,
    flag: PartState.flag_damaged())
end
```

`dispatch_object_state_delta/3`:

1. lookup `instance` 拿 `covered_chunks` + `object_version`(persist_and_cache
   完成后 instance.object_version 已经 +1)
2. 调 `Codec.encode_voxel_object_state_delta_payload/1`
3. 对每个 covered chunk 调 `ChunkDirectory.lookup_chunk_pid/3`
4. 给每个 pid `GenServer.cast(pid, {:push_object_state_delta_payload, binary})`
5. 全程 try/catch :exit(broadcast 失败不阻塞 ObjectRegistry,emit observe
   `voxel_object_state_delta_dispatch_failed`)

**理由**:
- 单一事实源(ObjectRegistry GenServer 内),保证 broadcast 顺序与 instance
  状态一致
- 与 Phase 4 既有 emit 风格一致,易插
- emit 后再 broadcast:observe 先记录,即使 broadcast 失败也有 trace

**替代被否**:
- ChunkProcess 收 cascade 时同时 broadcast:把 broadcast 责任分散到 6 个
  路径(damage / destroy_part / cleanup / cascade / external),状态来源
  不统一
- 异步 dispatch(`Task.start_link`):Phase 4 已有 `dispatch_damage_async`
  Task.start 走异步避免 deadlock,那是因为 ChunkProcess → ObjectRegistry → ChunkDirectory → ChunkProcess
  的回环。这里 ObjectRegistry → ChunkDirectory.lookup_chunk_pid → cast
  没有回到 ObjectRegistry 自己,**无 deadlock 风险**,直接同步 lookup
  + cast 即可。

### D5:state_flags 编码语义("这次事件 vs 累计状态")

**推荐**:每次 broadcast 的 `state_flags` 只表达**这次事件**触发了什么,
不带 instance 累计的全 flags。

具体:

| 事件 | broadcast state_flags |
| --- | --- |
| `emit_damage`(part 还活着) | `PartState.flag_damaged()` |
| `emit_part_destroyed`(单 part 死) | `PartState.flag_part_destroyed()` |
| `emit_object_destroyed`(整 object 死) | `PartState.flag_destroyed()` |

注意:Phase 4 cascade 路径会同时触发 part_destroyed → object_destroyed
(只剩一个 part 的 object 杀掉这个 part 即整 object 死)。**两个事件
分别 broadcast 两条 0x6C**(版本号不同),客户端按版本号顺序处理。

`object_version` 用 `instance.object_version`(persist_and_cache 之后
的最新值,即每次状态变更 +1)。

**理由**:
- 每条 0x6C 表达"一次 atomic 状态变化",与协议设计一致
- 客户端简单:看到 `flag_destroyed` 就知道整 object 死了,不需要 mask
  reduce
- Phase 5 加 `attribute_patch[]` / `tag_patch[]` 时,patch 数组天然语义
  也是"这次变化",和 state_flags 风格统一

**替代被否**:
- broadcast `instance.state_flags`(累计 OR):每次都带"曾经 damaged
  过 + 现在 destroyed",信息冗余,客户端处理麻烦
- 不 broadcast state_flags 只 broadcast event_type 枚举:协议 §9 已
  定义 state_flags 形态,改协议 = 牵动 wire 兼容,不该在 Phase 4-bis 做

### D6:客户端消费形态(碎屑粒子 + HUD 提示)

**推荐**:web_client 端做 5 件事:

1. **`onlineVoxelWorldAdapter` 双通道接入**:
   - 在 `ChunkDelta` 处理路径加 hook:apply 之前,扫一遍 `cell_refined`
     ops,对每个"清空 micro slot"的 op,从 apply 前的 chunk truth
     副本里查 `owner_object_id`,写入 `ClearedSlotCache`(下面)。
   - 在 `ObjectStateDelta` 处理路径(新)解码 binary → 交给
     `ObjectStateDeltaConsumer`(下面)。

2. **`ClearedSlotCache`**(新模块):
   - 数据结构:`Map<object_id, Array<{worldX, worldY, worldZ, ts_ms}>>`
   - 每个 entry 设 TTL 2 秒(由 ChunkDelta 写入时记录 ts,定期 sweep
     drop > 2s 的)
   - 提供 `take(object_id): slots[]` 取出并清空该 object 的 entry
   - 容量保护:单个 object 缓存 micro slot 数量上限 `MAX_SLOTS_PER_OBJECT = 256`,
     超出 drop 旧的(防止 prefab 极大时内存涨)

3. **`ObjectStateDeltaConsumer`**(新模块):
   - decode binary → 结构化对象
   - per-object `last_seen_version` map 去重(D3)
   - 根据 state_flags 分支:
     - `flag_damaged`:`take` 缓存里属于 part 的 slot(本阶段无法精确
       筛 part,**用近似**:取该 object 所有缓存 slot 的 5 个采样点),
       触发 `DebrisEffect.spawn(slots, "damaged")`
     - `flag_part_destroyed`:同上,采样 10 个点,`DebrisEffect.spawn(slots, "part_destroyed")`
     - `flag_destroyed`:`take` 全部 slot,采样到 `MAX_DEBRIS_BURST = 20` 个
       点,`DebrisEffect.spawn(slots, "destroyed")` + HUD 一行字
       `Object #{id} destroyed`(5s 自动消失)
   - 时序兜底:如果 0x6C 比 ChunkDelta 先到(缓存为空),delay 100ms
     后再尝试一次 take;仍空则降级用 affected_chunks 的中心点位置播
     一个粒子(档 A 兜底)

4. **`DebrisEffect`**(新模块,three.js InstancedMesh + 自管理生命周期):
   - 每个采样点生成 `BURST_SIZE = 8` 个小立方体粒子(0.05m × 0.05m × 0.05m)
   - 初始位置 = 采样点 + 小随机偏移
   - 初速度 = 半球面随机方向 + 中心向外 push 1-2m/s
   - 重力 = -9.8 m/s²(简易,不接物理引擎)
   - 颜色:棕色调随机(`#8B4513` 到 `#A0522D` 之间),damage / part_destroyed / destroyed
     共用同色板(本阶段不区分材质,Phase 5 attribute 进来时再分)
   - lifetime:0.8 秒,然后销毁
   - 全局上限 `MAX_LIVE_PARTICLES = 500`,超出时 drop 最旧的
   - 用 `THREE.InstancedMesh` 单 draw call 渲染所有粒子

5. **不**修改 mesh / 材质 / collider — 这些已经被 ChunkDelta 处理。粒子
   特效**与** mesh 更新是两条独立可视化:mesh 表达"这块没了",粒子
   表达"刚才在这里炸了"。两者并行,不冲突。

**示意时序图**(单 destroy_object 事件):

```text
服务端:
  ObjectRegistry.destroy_object → ChunkProcess.cleanup_object_refs (清 micro)
                                ├─→ 推 ChunkDelta (cell_refined ops)
                                └─→ 推 0x6C ObjectStateDelta (flag_destroyed)

客户端(典型情况 ChunkDelta 先到):
  收 ChunkDelta → apply 前扫 ops 写 ClearedSlotCache → apply mesh
  收 0x6C        → take 缓存 → spawn 20 个采样点的碎屑爆炸 → HUD 一行字

客户端(0x6C 先到):
  收 0x6C        → 缓存为空 → 100ms delay 重试
  收 ChunkDelta → 写缓存 → apply mesh
  delay 触发     → take 缓存 → spawn 碎屑

客户端(完全乱序 / 缓存命中失败):
  100ms 后第二次 take 仍空 → 降级:affected_chunks 中心位置播一团粒子
```

**理由**:
- 碎屑沿 micro slot 散布是用户明确选择的视觉风格(参考"小爆炸"),
  比中心一团粒子更真实
- 缓存 + TTL 模式避免改 wire 协议(协议留干净,Phase 5 加 attribute_patch
  时不被 destroyed_cells 字段污染)
- 双通道 hook 利用了 ChunkDelta 现有的 `cell_refined` ops 信息,**不**
  需要新协议字段
- 100ms delay + 降级路径保证乱序时不会"什么都不显示"(路演 robust)
- 采样上限 + 全局粒子上限 + 单 draw call InstancedMesh 控制渲染性能
- HUD 提示与粒子并行:粒子可能因为采样位置在视野外看不到,HUD 是兜底反馈

**关键参数(可后续微调)**:

| 参数 | 值 | 含义 |
| --- | --- | --- |
| `CACHE_TTL_MS` | 2000 | ClearedSlotCache entry 过期时间 |
| `ZERO_DELTA_DELAY_MS` | 100 | 0x6C 先到时等待 ChunkDelta 的延迟 |
| `MAX_SLOTS_PER_OBJECT` | 256 | 单 object 缓存的 micro slot 上限 |
| `MAX_DEBRIS_BURST` | 20 | destroy 事件采样点数量上限 |
| `BURST_SIZE` | 8 | 每个采样点产生的粒子数量 |
| `MAX_LIVE_PARTICLES` | 500 | 屏上同时存活粒子数量上限 |
| `PARTICLE_LIFETIME_S` | 0.8 | 单粒子寿命 |
| `PARTICLE_SIZE_M` | 0.05 | 单粒子立方体边长(0.05 = 1/5 micro slot 大小) |

**替代被否(档 A / 档 C)**:
- 档 A(只在 object 中心位置播一团粒子):简单但视觉不真实,长条形
  object 显得粒子飘忽
- 档 C(改协议给 0x6C 加 `destroyed_cells` 字段):突破 Phase 4-bis
  "不动协议"原则,且 Phase 5 加 attribute_patch 时还会再动一次,
  双重改协议 wire 测试矩阵成本高
- 用 `THREE.Points`(GPU 点精灵)替 `InstancedMesh`:碎屑要立方体形态
  才像"碎块",点精灵看着像火花 / 灰尘,不符合"碎屑"风格

### D7:观测点(observe / cli)

**推荐**:新增 4 个 CliObserve key:

- `voxel_object_state_delta_dispatch`:ObjectRegistry 端 broadcast 触发,
  payload `%{scene_id, object_id, object_version, state_flags, affected_chunk_count}`
- `voxel_object_state_delta_push`:ChunkProcess 端 fan-out 到 subscriber,
  payload `%{scene_id, chunk_coord, subscriber, request_id, byte_size}`
- `voxel_object_state_delta_dispatch_failed`:lookup chunk pid 失败 / cast 异常,
  payload `%{scene_id, object_id, chunk_coord, reason}`
- `gate_voxel_object_state_delta_forwarded`(gate ws/tcp 各一):socket
  写出后,payload `%{connection_pid, cid, bytes}`

**理由**:对齐 chunk_delta 现有 4 个 observe key(`voxel_chunk_delta_push`、
`ws_voxel_chunk_delta_forwarded`、`tcp_voxel_chunk_delta_forwarded` 等)。
路演时可以用 CLI tail observe log 直观看到链路。

### D8:测试矩阵

新增 / 扩展 ExUnit:

- `apps/scene_server/test/scene_server/voxel/codec_object_state_delta_test.exs`(新):
  - encode_voxel_object_state_delta_payload roundtrip(已 Phase 4 在 gate
    codec 测试过,迁移过来)
  - 空 affected_chunks / 多 affected_chunks
  - 边界 state_flags(0、单 flag、多 flag OR)
- `apps/scene_server/test/scene_server/voxel/object_registry_broadcast_test.exs`(新):
  - emit_damage 触发 broadcast → mock ChunkDirectory 收到正确 cast
  - emit_part_destroyed 触发 broadcast
  - emit_object_destroyed 触发 broadcast(注意:cleanup 后 instance
    已不在 state,需要从 cleanup 前 capture covered_chunks)
  - cascade(damage 致命 → destroy_part → destroy_object)broadcast 两条
    0x6C,版本号单调
  - lookup chunk pid 失败 → 静默吞 + observe `dispatch_failed`
- `apps/scene_server/test/scene_server/voxel/chunk_process_object_state_delta_push_test.exs`(新):
  - `cast({:push_object_state_delta_payload, binary})` → fan-out subscribers
  - 0 subscribers 时静默
  - 多 subscribers 全收到
- `apps/gate_server/test/gate_server/codec/object_state_delta_test.exs`(改):
  - 删除 map-encode 用例(已迁移)
  - 加 binary-pass-through encode 用例(`{:voxel_object_state_delta_payload, binary}`
    → `[<<0x6C>>, binary]`)
  - 保留 decode 用例
- `apps/gate_server/test/gate_server/voxel/object_state_delta_forward_test.exs`(新):
  - WsConnection / TcpConnection `handle_info({:voxel_object_state_delta_payload, binary}, ...)`
    → socket 写出对应字节
- `clients/web_client/src/infrastructure/net/objectStateDelta.test.ts`(扩):
  - decode 后 ObjectStateDeltaConsumer 接收事件
  - 重复 object_version 去重(同 version 第二次进来不触发回调)
  - flag_destroyed 触发 HUD 回调 + DebrisEffect.spawn
  - flag_damaged / flag_part_destroyed 不触发 HUD 但触发 DebrisEffect

- `clients/web_client/src/world/clearedSlotCache.test.ts`(新):
  - put / take(写入与取出)
  - TTL 过期 sweep
  - 单 object 容量上限(超出 drop 旧的)
  - take 不存在的 object 返回空数组

- `clients/web_client/src/world/debrisEffect.test.ts`(新):
  - spawn 一个采样点 → 8 个粒子状态正确
  - lifetime 到期粒子被销毁
  - 全局粒子上限触发时 drop 最旧
  - InstancedMesh count 与活跃粒子数同步

- `clients/web_client/src/world/onlineVoxelWorldAdapter.test.ts`(扩):
  - apply ChunkDelta 前 hook 写 ClearedSlotCache(用 mock)
  - 0x6C 先到时 100ms delay 后重试 take
  - 100ms 后仍空降级到 affected_chunks 中心点

**预期测试规模变化**:
- scene_server:330 → 345-355(+ 15-25)
- gate_server:188 → 178-185(- 7 削减 map encode 用例 + 5-7 加 binary
  pass-through / forward)
- web_client vitest:216 → 240-255(+ 24-39,因粒子 / 缓存 / 时序新模块)

### D9:Step 分解

| Step | 范围 | 验收 |
| --- | --- | --- |
| 4-bis-1 | scene_server/voxel/codec.ex 加 encode/decode_voxel_object_state_delta_payload + 单测;**不**碰 gate codec 与 ObjectRegistry | scene_server 测试增、gate codec 暂时是双实现(过渡) |
| 4-bis-2 | gate_server/codec.ex 删 map encode、加 binary pass-through encode、保留 decode、改测试 | gate_server 测试通过,wire 字节序与 4-bis-1 完全一致 |
| 4-bis-3 | scene_server/voxel/chunk_directory.ex 加 `lookup_chunk_pid/3` 公共 API + 单测 | 既有测试 + 新 lookup 测试通过 |
| 4-bis-4 | scene_server/voxel/chunk_process.ex 加 `handle_cast({:push_object_state_delta_payload, payload}, ...)` + push fan-out + 测试 | chunk_process 测试增 |
| 4-bis-5 | scene_server/voxel/object_registry.ex 在 emit_damage / emit_part_destroyed / emit_object_destroyed 之后 dispatch broadcast(同步 lookup + cast)+ try/catch + 测试 | scene_server object_registry 测试增,broadcast 链路单测过 |
| 4-bis-6 | gate_server ws_connection / tcp_connection handle_info 加 `:voxel_object_state_delta_payload` clause + observe + 测试 | gate_server 测试增,forward 链路单测过 |
| 4-bis-7 | clients/web_client 加 `ObjectStateDeltaConsumer` + onlineVoxelWorldAdapter `:voxel_object_state_delta_payload` dispatch 接入(只 decode + 去重 + console.log,**不**触发粒子) | vitest + tsc 全绿,destroyed/damaged event 能在 console 看到 |
| 4-bis-8 | clients/web_client 加 `ClearedSlotCache`(数据结构 + TTL sweep + 容量上限)+ onlineVoxelWorldAdapter 在 apply ChunkDelta 前的 hook | vitest 全绿,单测覆盖 put/take/TTL/容量 |
| 4-bis-9 | clients/web_client 加 `DebrisEffect`(InstancedMesh + 粒子物理 + 生命周期 + 全局上限) | vitest 全绿,粒子模块独立可测,无场景依赖 |
| 4-bis-10 | 在 `ObjectStateDeltaConsumer` 里把 ClearedSlotCache + DebrisEffect 串起来:flag_destroyed/part_destroyed/damaged 各自采样 + spawn,加 100ms delay + affected_chunks 中心点降级路径 + HUD 一行字接入 | vitest 全绿,时序 case 都覆盖 |
| 4-bis-11 | 端到端 integration test:启 ObjectRegistry + ChunkDirectory + ChunkProcess + mock gate connection,跑 destroy 流程,断言 mock connection 收到正确字节 | scene_server 端到端测试通过 |
| 4-bis-12 | 浏览器手测验证:本地起 dev 服务,在 web_client 里破坏 prefab,**用眼睛看到碎屑** + HUD 提示。截屏存档 | 可视确认通过 |
| 4-bis-13 | docs sync:各 app README 加 0x6C 推送链路章节、phase-4-bis 决策稿进度日志、`_session-handoff.md` 推到 4-bis 末态、README.md 阶段表加 4-bis 行 | 文档完备,可作为 Phase 5 / 阶段 A 下一子项起点 |

每 step 一 commit。Elixir 改前 `mix format`;web 端 `npx tsc --noEmit && npx vitest run`。

## 风险 / 已知 trade-off

- **0x6C 与 ChunkDelta 时序**:两条独立消息,网络层不保证到达顺序。
  D6 的 ClearedSlotCache + 100ms delay + 降级路径是这个问题的工程兜底:
  - ChunkDelta 先到(典型路径,> 95%):缓存写入 → 0x6C 来 take → 粒子精准
  - 0x6C 先到:0x6C 等 100ms → 缓存可能在窗口内填充 → take 成功
  - 完全乱序 / ChunkDelta 丢:fallback 到 affected_chunks 中心点播粒子
  路演用例(单机本地传输)实际不会触发 fallback;真到生产网络 lossy
  环境时 Phase 5+ 上 sequence number 严格化。
- **state_flags 重发**:同一事件链(damage → cascade destroy_part → cascade
  destroy_object)产生 2-3 条 0x6C,客户端要按 version 顺序处理才不会
  漏 destroyed flag。服务端保证每条 broadcast 都先 persist 再 emit,所以
  version 单调(D5)。
- **粒子性能压力**:连续多 prefab 同时破坏可能触发 `MAX_LIVE_PARTICLES`
  上限。设的 500 是保守值,实测如果 `BURST_SIZE * MAX_DEBRIS_BURST = 8 * 20 = 160`
  粒子/destroy,3 个 destroy 同时就到上限。**这是个软上限,超出时 drop
  最旧粒子**(不会让粒子无限累积)。Phase 4-bis-12 浏览器手测时如果发
  现 mid-spec GPU 卡顿,把 `BURST_SIZE` 降到 4 或 `PARTICLE_LIFETIME_S`
  降到 0.5 即可。
- **采样近似(damaged / part_destroyed 不区分 part)**:0x6C 没有 part_id
  字段,客户端的 ClearedSlotCache 也按 object 聚合。flag_damaged / flag_part_destroyed
  时**采样的是该 object 所有缓存 slot**,不是该 part 的 slot。视觉上等同
  "这个 object 上随机散点冒了几个碎屑",对 damaged 提示而言够用。
  Phase 5+ 加 part_id 字段后再精准化。
- **client 重连不补 0x6C 历史**:不在范围。Phase 5+ chunk re-snapshot
  时同时附带 ObjectRefs section,即可重建当前活着的 object。
- **缓存内存泄漏防护**:ClearedSlotCache 用 TTL 定期 sweep + 单 object
  容量上限。极端情况(0x6C 永远不来,缓存条目被 sweep)粒子不播,
  mesh 仍然正确(因为 mesh 跟 ChunkDelta 走)。**用户体验降级 = "默默没了
  没特效"**,不会卡死或崩。
- **观测开销**:每次 destroy 多 4 条 observe 事件(dispatch + push + 2 个
  forwarded),CLI 端 log 会变多。如果路演 demo 期"持续破坏 / 燃烧"导致
  observe 太密,临时把 verbosity 下调即可。
- **codec 函数挪位**:Phase 4-bis-1/-2 期间 gate codec 与 scene codec 短暂
  双实现(4-bis-1 加 scene 端,4-bis-2 才删 gate 端 map encode)。两步
  之间(commit 之间)gate 端可能既能 encode map 也能 pass-through binary。
  这是可接受的过渡(每 step 测试都过,且没 production 流量在用)。

## RFC 备注 / 后续 phase 衔接

- 本阶段决策的 D5 state_flags 语义("这次事件" 而非 "累计 mask")会延续
  到 Phase 5+。Phase 5 加 attribute_patch[] / tag_patch[] 时,patch 也按
  "这次变化"语义打包,不带累计。
- D2 把 0x6C codec 挪到 scene_server/voxel/codec.ex 后,**所有
  server→client wire payload 的 encode 都在 scene_server**。Phase 5+ 加
  `0x?? AttributeUpdated` 等新 server→client 消息按同位置加。
- D6 的 `ObjectStateDeltaConsumer` 在 web_client 端会成为 Phase 5+ "对象
  级状态可视"(part 血条、destroyed 特效)的扩展点。Phase 4-bis 留好
  module shape,Phase 5 只扩 destroy 回调实现,不动 dispatcher。
- D7 的 4 个新 observe key 给 demo CLI 提供 tail 入口。在 Phase 4-bis-9
  的 docs sync 里要把 CLI 命令(`window.__voxelCli.observeTail` 之类)
  对应章节补上。

## 进度日志

- **2026-05-08**:决策稿 land。用户对 D1-D4 / D7 / D8 / D9 按推荐值
  确认;D5 按推荐"这次事件"语义生效;D6 升级为档 B(碎屑粒子沿
  micro slot 散布)+ 棕色调 0.05m 小立方体 + InstancedMesh 单 draw call。
  Step 切片由 9 个扩展到 13 个,新增 ClearedSlotCache / DebrisEffect /
  consumer 串联 / 浏览器手测各一 step。下一步:Step 4-bis-1 开始动代码。
