# NPC 统一接口层设计（决策稿）

分类：全局系统功能，设计决策稿。状态：**v2；第一片已实现、已实跑（2026-09-21），未验收**；第二、三片未实施。已与 GPT-6 Astra 三轮对抗审查。

第一片落点：`apps/gate_server/lib/gate_server/npc/body.ex`、`GateServer.NpcSup`（`gate_server/application.ex`）、
`apps/gate_server/test/gate_server/npc_body_test.exs`（4 个手算单测本机可跑；真实 `QuicListener` 集成用例依赖 quicer，只能在 Linux
服务端镜像内跑，需 `VOXIM_TEST_CERTS`）。真实客户端实跑：Voxim `Docs/Gameplay/npc.exs` + `server.py --start`，两个 NPC 在统一 Demo
巡逻，截图 `Voxim/Saved/Gameplay/npc-slice1/watch-01/`。实跑中发现并已规避：路线贴近 64 m tile 边界时，冲过路点跨 tile 会让该 NPC
每圈重申请两次碰撞窗口（§7.1 的热快照成本）。未验收项：人工观察平滑度与折返；§9 的积压超限用例未写。
范围：Voxim 正式栈（QUIC + `SceneServer.Movement.Scene` + `VoxelRegion.World`）。legacy 栈的
`SceneServer.Npc.*` 只作形状参考，不搬。

## 1. 目标与非目标

目标：NPC 的决策后端可插拔（决策树、LLM、外部系统），更换后端不改 NPC 在世界里的实现，也不改权威。

非目标（本稿不做）：

- 不新增 NPC 专用的世界动词或裁决路径。
- 不设计聊天、HP、战斗。正式栈目前没有这些能力，先有玩家版本再谈 NPC。
- 不预建多 NPC 调度、LLM 预算、限流、记忆系统、自描述动词表。撞到再做。
- 不做跨 Scene transfer。第一片 NPC 的路线留在当前 authority 内。
- 不承诺“完整 Player 复用”是长期模型，见 §7 O-1。

## 2. 现状（已对照源码）

| 事实 | 位置 |
|---|---|
| 正式配置只启动 `Movement.Scene`，`NpcSup` 在另一分支；未发现 `spawn_npc` 的正式运行时调用方（只有测试） | `scene_server/application.ex:43` |
| 下行契约是 3 个 `send/2`，发给不透明 gate pid，sink 可注入。载荷是 Erlang 消息：多数是 struct，事务载荷（`{:voxel_log_transaction_payload, bytes}`）与 `PropertyBatch` 条目是已编码字节 | `mmo_contracts/session/outbound.ex`、`player.ex:623,665` |
| 上行移动：`Player.input/3`、`ready/4`、`time_probe/3`，普通 cast。帧与批的合法性校验（轴范围、每批 1..6 帧、序号）在 codec，直调时由调用方负责 | `player.ex:12-20`、`movement/codec.ex:52` |
| 输入轴是 canonical 世界 X/Z；`yaw` 不参与物理步进，只随状态记录 | `player.ex:516-547` |
| `due_tick(seq) = origin_tick + seq - 1`。超前帧进 `pending` 等待到期，不按 lead 拒绝；已消费序号记 duplicate；同一 pending 序号内容不同记 conflict；缺下一连续序号时 `InputSlots.take_observed` 返回 `:waiting`，`advance/1` 原样返回 state，不补帧 | `input_slots.ex:33-91`、`player.ex:497-515` |
| `InputStart` 的前提：`ready`（`Ready` 的 seq/revision 等于 baseline，否则 close 8）与 `clock_ready`（任一次 `time_probe`）相互独立，且 `origin = simulation_tick + 30 > clock_tick + 8`；在后续 timeline 处理中签发，碰撞发布落后时会延后 | `player.ex:230-252,457-490` |
| `OwnerAck` 每 3 tick 下发，含 `server_tick`、`processed_input_seq`、权威 `state`；只要求 `active?`（origin 已建立且 tick ≥ origin），不要求已消费输入 | `player.ex:431-444,594` |
| 世界操作：`Player.tool_context/2` 取 actor（`eye`、`refresh`），再调 `World.tool_intent/3` / `production_intent/3` / `attachment_intent/3`；入口还需补 `received_us`、`clock_node`；World 用 `current_actor/1` 重读权威位置 | `player.ex:150-172`、`dispatch.ex:615`、`world.ex:241,4655` |
| tool / production / attachment 在 Gate 只查 overlay 状态与 scene 路由；builder / bounds 门禁只作用于 edit、batch edit、prefab | `quic_connection.ex:514-545`、`dispatch.ex:533` |
| World 公共 API 含冷数据准备与最长 300 s 的 call；Gate 用独立 FIFO edit worker 承担 | `world.ex:241`、`quic_connection.ex:613` |
| `QuicListener` 的 `{:claim,…}` 是完整会话占用入口：按 cid 踢旧会话、分配 identity、`Scene.join`、监视**调用者** pid、登记 cid；自身不鉴权 | `quic_listener.ex:84-122` |
| 普通 join 的名额 = `length(config.probes)`（只统计 `slot != nil`，transfer 导入成员不计），出生点取自 probe 槽 | `scene.ex:291,358-364`、`player.ex:341` |
| Player 监视 gate，gate 死则 Player 退出；反向不自动：`CollisionStream` 监视 gate 与 authority，不监视 Player | `player.ex:144,455`、`collision_stream.ex:26,78` |
| Replication 只发布 active 实体；观察者 AOI 为 30 m 进 / 34 m 出的三维范围 | `replication.ex:213`、`aoi.ex:89` |
| 越过 authority 且找到邻区时 Player 进入 `transfer: :requested`，`advance` 停止 | `player.ex:495,597` |
| cid 直接作 `entity_id`，全链路 `u64`；`characters.id` 是 PostgreSQL `bigint`（上界 2^63−1）；World 余额按 `{cid, material}` 随事务写入 overlay 并重放恢复 | `scene.ex:372`、`movement/codec.ex:5`、`world.ex:4113-4129`、`overlay_log.ex:41` |

## 3. 核心决策

### D-1 NPC 与玩家共用权威裁决

NPC 的世界操作走玩家同一组 World 公共 API、同一套裁决（射程、射线、余额、目标身份）。不建 NPC 专用动词或裁决。
裁决自动一致；Body 里每个语义命令到 World 请求的映射仍需逐个写。

第一片用“完整 Player 复用”（Body 以自己为 gate 走 claim/join）作为手段，只证明单个 NPC 的闭环，不是对长期模型的承诺。

### D-2 分成 Body 与 Brain，可插拔边界在语义命令层

```
Brain 后端（决策树 / LLM / 外部系统）            ← 可插拔
   ↑ event: observation | outcome      ↓ Command(id)
NPC Body（每 NPC 一个进程，自己当 gate）          ← 固定实现
   ↑ SessionStart / InputStart / OwnerAck / EntityEnter·Leave / Snapshot / mmo_close
   ↓ InputBatch                    ↓ 世界事务（经独立执行进程 → World 公共 API）
Scene / Player / VoxelRegion.World               ← 不改语义
```

不能把后端直接接到玩家原始接口：Player 要连续序号的输入帧，缺帧即等待；玩家原始感知（bootstrap、碰撞窗口、
属性批、事务字节）对决策后端不可用。

### D-3 Body 从不同步等待 Brain 或 World

- 慢后端（LLM、外部系统）由 adapter 自己的进程承担，异步把 Command 投回 Body。
- 世界事务由 Body 旁的独立执行进程 FIFO 调用 World（与 Gate 的 edit worker 同理），结果以消息回 Body。
- Brain 无新命令 = **保持当前动作**；停止必须显式 `stop`。

### D-4 两类命令，语义分开

- **移动控制**（`move_to` / `stop` / `look_at`）：可被新移动命令顶替。任何移动命令只影响**尚未送出**的序号；
  已送出的至多 K 帧旧动作照常执行。
- **世界事务**（`probe_toward` / `use_tool` / …）：一旦提交不可顶替、不可撤销；`timeout` 不等于未提交。

### D-5 Body 不成为第二真值

Body 内的位置、邻近实体都是下行消息的派生缓存，可丢弃可重建；保留 `entity_epoch`、`interest_generation` 与各自的
tick，不伪装成同一时刻的完整快照。Body 不读 World 私有状态，不维护体素副本。

## 4. 输入时序：由 OwnerAck 闭环驱动

Body 不持有本地时钟到 server tick 的映射；`time_probe` 只发一次用于置 `clock_ready`。

- 收到 `InputStart` 后送 seq `1..K`，K = 8。
- 此后每收到 `OwnerAck`：`due_seq = server_tick - origin_tick + 1`，把已送序号连续补到 `due_seq + K`。
- 帧与批满足解码器对玩家的同一组约束：轴范围、序号严格递增、每批 1..6 帧（8 帧拆 6+2）。序号**相邻差为 1**
  是 Body 自己的生成要求（解码器只查严格递增），缺号会让 Player 永久等待。
- K 是缓冲量不是时延保证：输入补给链路延迟超出 K 余量时，Player 等待，随后在历史碰撞版本上追赶。
- 停摆恢复：已过期而未送的序号一律填零输入帧（yaw 取最后已送值），即停摆期间不新增移动意图——已送旧帧、制动与
  重力仍然生效，位置不冻结；新动作只写入 `seq > due_seq` 的未来槽，不回填过去。
- 积压上限：严格 `due_seq - processed_input_seq > 120`（2 s；不是 `>=`，也不是未发送帧数）时 Body 不再追赶，主动
  leave 并异常退出，由 supervisor 重启后重新 claim/join。120 为第一片固定常量。

## 5. 接口草案（第三片才提取，此处只定形状）

### 5.1 Brain

```elixir
@callback init(profile :: map) :: state
@callback handle_event({:observation, map} | {:outcome, map}, state) :: {[command], state}
```

进程内后端直接实现。进程外后端由 adapter 实现这两个回调并自带进程；JSON 等序列化归 adapter。

### 5.2 Command

| verb | 类 | 展开 | done 条件 |
|---|---|---|---|
| `move_to(position, tolerance)` | 移动 | 轴 = 目标水平位移在 X/Z 上的分量（直线，无寻路）；yaw 单独量化 | 观察到进入 tolerance → 自下一个未送序号起送零输入 → `OwnerAck.processed_input_seq` ≥ 首个零输入帧序号 |
| `stop` | 移动 | 自下一个未送序号起零输入 | 同上（ack 覆盖首个零输入帧） |
| `look_at(position)` | 移动 | 只改后续帧 yaw | ack 覆盖首个新 yaw 帧 |
| `probe_toward(direction, tool_id)` | 事务 | `tool_intent` action 0：从权威 eye 沿方向探测**实际命中**，不是任意格查询 | World 返回 |
| `use_tool(tool_id, target, …)` | 事务 | `tool_intent` action 1，`target` 取自 probe 返回的目标身份 | World 返回 |
| `query_balances` | 事务 | `World.material_balances/2` | World 返回 |

`move_to` 的 done 不代表速度归零或已停稳，也不承诺最终停在 tolerance 内（K 帧旧动作 + braking 可能冲出）；
`position` 与 `within_tolerance` 必须取自同一份满足序号条件的 ACK。已被顶替的命令只报 `:superseded`，之后不得再报
done。第一片不做提前减速预测。

### 5.3 Outcome

```elixir
%{id: 3, verb: "move_to", status: :done | :rejected | :superseded | :timeout,
  reason: term | nil, data: map | nil}
```

- `reason` 以权威返回的形态透传，Body 不翻译、不重试、不维护 reject 枚举。
- `data`：移动类带 ack 的权威 `position` 与 `within_tolerance`；`probe_toward` 带目标身份（micro、incarnation、owner、
  material 等）；`query_balances` 带完整余额表。
- `:superseded` 只会出现在移动类。

### 5.4 Observation

```elixir
%{self: %{entity_id:, tick:, position:, yaw:, grounded:, processed_input_seq:},
  entities: [%{entity_id:, entity_epoch:, tick:, position:}],
  pending: [%{id:, verb:}]}
```

推送时机由 Brain/adapter 决定（拉取或声明频率），Body 不预设 4 Hz 全量推送。地形不进 Observation。

## 6. 为此必须先定或补的缺口

| # | 缺口 | 处理 |
|---|---|---|
| G-1 | NPC 身份与会话占用 | 第一片由 **Body 进程本人**调用 `{:claim,…}`（listener 监视的是调用者；由 manager 代 claim 会把所有 NPC 绑到 manager 上）。NPC cid 区间 = bit 63 置 1（2^63 ≤ cid < 2^64），静态配置，**全集群唯一**（重复 cid 会踢旧会话而不是报配置冲突）；不进 `characters` 表，不走 CharacterStore |
| G-2a | 名额 | NPC 占用 probe 名额。第一片：给 NPC 留出名额，规则写进 Scene 配置说明 |
| G-2b | 出生点 | 取自 probe 槽，不能指定。第一片：接受 probe 出生点，巡逻路线从那里开始；需要指定出生点时再给 join 加参数 |
| G-3 | 内部 Ready 的含义 | 无头 Body 不建体素镜像；收到 `SessionStart` + `CanonicalBootstrap` 元数据后回 baseline 的 seq/revision。在文档里写明这是“内部会话就绪”，不代表已应用体素 |
| G-4 | 缺内部共用的合法请求构造入口 | 只为当片用到的命令加构造函数（第二片：`tool_intent`） |
| G-5 | 生命周期双向 | Body 必须消费 `mmo_close` 并结束会话，使 `CollisionStream` 随 gate 退出而清理；不做自动重连以外的恢复 |
| G-6 | 部署位置 | 第一片 Body 放 Gate/World 主节点。远端节点直调 World 会碰到 `prepare/2` 在调用者侧执行 `source.ensure`（本地 ETS / 文件）的节点边界问题，未验证，不在第一片解决 |
| G-7 | 余额 | 复用 World 结算即持久化；固定 cid 重用会继承该世界既有余额。是否需要临时余额到第二片再定 |
| — | `EntityEnter` 无 kind / name | 产品需求项，不阻塞第一片；客户端按 entity_id 建同一种 RemoteCharacter |

## 7. 开放问题

- **O-1 多 NPC 成本**：每个 NPC 同时是 Replication 观察者，N 个互见 NPC 是 N·(N−1) 条关系；流送模式下碰撞世界按角色
  重复，机制与优化路线见 §7.1。测量 Player/NIF、碰撞构建与保留版本、Replication、Body mailbox，再决定是否分离
  “控制来源 / 观察者资格 / 客户端流送”。
- **O-2 外部系统 jev** 的接入形态未知，需确认落在“进程外 adapter”一类。
- **O-3 Body 监督树归属**（`scene_server` 下新 supervisor 或独立 app），第一片放主节点现有 app 内，不新建 app。

### 7.1 碰撞世界按角色重复：机制与优化路线

rapier 在这里只是只读查询世界（体素 chunk 的 compound collider + BVH），没有全 Scene 统一的物理 step；每个 Player 在自己
的 tick 里用 `step_characters(world, profile, [自己])` 做 `KinematicCharacterController` 扫掠，角色之间不互相碰撞
（`player.ex:542`、`VoximMovement/Native/src/movement.rs:40`）。`world` 的来源取决于 Scene 配置：

- `collision_window_radius_tiles == 0`：Scene 安装一份世界，所有 Player 共用同一个 `ResourceArc`。
- `> 0`（流送；Voxim 侧现有 Scene 配置全部为 1）：每个 Player 启动自己的 `CollisionStream`，以自己为中心申请窗口，
  `initialize_stream` 从空世界建一份只属于自己的 native world；出窗口时 `replace_window` 整份重建，旧版本保留到该 Player
  的 `simulation_tick` 越过才退休（`player.ex:104-123`、`collision_updates.ex:41-71`）。

不能直接合并成一份：`CollisionStream` 同时是该角色客户端镜像（`CanonicalBootstrap` / `CollisionWindow` / 事务）的有序来源，
`OwnerAck` / `Snapshot` 带 `collision_revision`，服务端第 T tick 用哪一版世界必须与该客户端一致，而窗口中心、
`simulation_tick`、事务生效 tick 都因角色而异。

真正重复的是几何：同一 Player 相邻版本之间未修改的 `SharedShape` 已共享（`voxim_movement_nif/src/lib.rs:69`），不同 Player
之间同一 chunk 各自从占用格重建 compound。路线：

- **A 跨 World 共享 chunk 形状**：NIF 内按“chunk 坐标 + 内容”索引 `SharedShape`，`set_chunk` 命中只克隆 Arc。每 Player 仍
  持有自己的索引与版本历史，`collision_revision` 契约、移交、客户端一致性不变；对玩家同样成立，与 NPC 接口层正交。
- **B NPC 不走每角色窗口**：NPC 无客户端、无预测，可共用一份 Scene 级世界；需要给 Player 增加“无客户端流”的形态。
- **C 按 tile 建共享世界、跨世界查询**：重构，当前无依据。

#### 测量（2026-09-21）

`tools/collision_share_measure_test.exs`（Test-only）。环境：Windows 11 本机、`MIX_ENV=test`、NIF release 构建、真实
`GeneratedStore`（`Voxim/Saved/Gameplay/Server/worldgen-manifest.json`，seed 1337）、probe `{57.5, 520, 60.5}`、半径 1 →
窗口 `{-1,7,-1}..{2,10,2}`，1728 chunk 中 638 个非空（638 compound / 18420 子形状）。单次运行，未重复取样。

| 项 | 每份世界 | 50 份合计 |
|---|---|---|
| 独立构建（现状，每 Player 一份） | 14.0 ms、约 7.2 MB 私有内存 | 702 ms、361 MB |
| 克隆共享（空操作 `set_chunks`，路线 A 下界） | 0.34 ms、约 0.5 MB | 16 ms、25 MB |
| World 出窗口快照 | 冷 248 ms、热 105 ms（每次窗口申请） | — |
| 单角色步进（地面行走 6000 tick） | 12.7 µs / 步 | — |

读数：

- 路线 A 的收益约为内存 1/14、构建 1/40，成立。
- 但现状的绝对值不大：10 个 NPC 约 72 MB / 140 ms 一次性构建；步进 100 个角色 × 60 Hz 约 76 ms CPU / 秒。几十个 NPC
  以内，碰撞世界重复不是瓶颈；到上百个时内存（约 0.7 GB）才成为问题。
- 单项最贵的是 World 侧热快照 105 ms / 次，是世界构建的 7.5 倍，每次 join 与每次出窗口都发生，路线 A 不改变它。
- 未测：Player 进程堆里的 artifact（每版本 1728 chunk 的引用）、版本历史滞留、Replication O(N²)、窗口替换频率。

结论：第一片不需要先做 A 或 B。A 作为独立的玩家侧优化保留；NPC 数量目标到上百时，再连同热快照成本一起评估 B。

运行：`apps/scene_server` 下，`NPC_MEASURE_MANIFEST=<worldgen-manifest.json> NPC_MEASURE_PROFILE=<demo-config.json> mix test ../../docs/10-active/cross-cutting/tools/collision_share_measure_test.exs`。

## 8. 顺序

1. **第一片**：单个写死巡逻的 NPC——claim/join → `SessionStart` → Ready + 一次 time_probe → 等实际 `InputStart` →
   按 §4 送帧沿世界轴走动 → 被真实客户端看见。巡逻逻辑写在 Body 里，无 Brain 抽象。
2. **第二片**：`probe_toward` + `use_tool`，成功与被拒各一次，经独立执行进程直调 World。
3. **第三片**：提取 §5 的 Brain，决策树与一个 LLM adapter 两个实现并存，用第二个实现校验接口形状。
4. O-1 的测量在第一片后做；其结论可能改变第二片之后的 Body 形态。

## 9. 验收（第一片）

- 真实客户端登录后，在 NPC 30 m 内看到同一 `entity_id` 的实体沿固定路线移动；核对 `InputStart`、
  `processed_input_seq` 递增、`OwnerAck` 权威位移。
- 杀 Body：客户端收到 `EntityLeave`，名额释放。
- Player/Scene 侧先失败：Body 消费 `mmo_close` 后退出，`CollisionStream` 不残留。
- 接缝用例（复用既有 Player 时钟测试夹具）：延迟 `InputStart`；ack 迟到但序号连续；世界轴转向的手算小例；
  积压超 120 时 Body 退出。
- 记录 O-1 的测量项。单测不代替真实客户端实跑。

## 10. 审查记录

2026-09-21 与 GPT-6 Astra（`codex exec -m gpt-6-astra`，high，read-only）三轮。v1 被纠正的主要事实：Gate 的
builder/bounds 门禁不作用于 tool intent；yaw 不驱动移动；下行并非全 struct；probe 不是任意格查询；claim 不是取号
API；成本不止下行字节。Astra 撤回的要求：Body 必须做本地时钟映射与漂移修复（改为 §4 的 OwnerAck 闭环）。
