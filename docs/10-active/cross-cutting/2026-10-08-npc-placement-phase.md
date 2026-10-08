# 往世界里放 NPC（决策稿）

分类：**Global system**，决策稿。状态：**进行中**（见 §6）。上位：[角色能力函数库](2026-10-07-character-capability-library.md)（I1–I4 已完成，§13 用户拍板 D-1 / D-5 / D-7 / D-11）。

## 0 目标

把能力库上的 NPC 变成可以长期放在世界里的“住民”：运维登记一次，节点重启后自动回来；
创世阶段有一个能直接塑造地形的特权 NPC；先补机制，最后做长跑验收。

用户 2026-10-08：先做机制，长跑放最后；**原始编辑后门（0x70 / 0x78）还要保留一段时间给创世 NPC 用**——
后门本身不动（D-11 原定另案处理，现改为“保留”），创世 NPC 走同一个 World 原始编辑入口。

## 1 范围与顺序

| # | 内容 | 状态 |
|---|---|---|
| M1 | NPC 注册表 + 节点重启自动恢复（`npc_specs` 表、`GateServer.Npc.Registry`、启动时拉起） | 待做 |
| M2 | 创世能力组 `:genesis`（`fill_box` / `set_cells`，底层 `World.apply_edits`，只授予注册表标了 genesis 的 NPC） | 待做 |
| M3 | scene_server：非流送 Scene 里 Player 在碰撞基线装好前收到 timeline 时 `CollisionUpdates.record_artifact/3` KeyError 崩溃 | 待做 |
| M4 | 客户端 `dead` 中文文案（Voxim 资产，随客户端一起） | 待做 |
| L | 长跑验收（建设者 / LLM 住民 / 创世 NPC，服务端浸泡 + 短双客户端） | 最后 |

## 2 M1 注册表

**数据**：DataService 新表 `npc_specs`（迁移随 release 的 `DataService.Release.migrate/0` 跑）：

| 列 | 类型 | 含义 |
|---|---|---|
| `character_id` | bigint，主键，外键 characters.id | NPC 的永久身份（`CharacterStore.ensure_npc/1` 的行，名字即身份） |
| `scene_id` | integer | 入场 Scene |
| `spawn` | jsonb `{x, y, z}` | 出生点（与玩家出生探测同义：每次入场从这里开始，不持久化位置） |
| `brain` | text | `"settler"` / `"llm"` / `"patrol"` |
| `params` | jsonb | 该大脑的参数（JSON 形，见下） |
| `enabled` | boolean | 是否随节点启动 |
| `inserted_at` / `updated_at` | | |

**API**（运维经 release `rpc` 调用；信任边界在 `put/2`：参数在登记时就解析成大脑配置一次，非法即拒绝，不落库）：

```elixir
GateServer.Npc.Registry.put(name, %{scene_id:, spawn: {x, y, z}, brain: "settler" | "llm" | "patrol", params: map})
  # → {:ok, %{cid:, pid:}}：建/取 NPC 角色行、写表、（重）启 Body；同名已在跑就先停旧的再起（Body.start/2 的替换语义）
GateServer.Npc.Registry.remove(name)   # 置 enabled=false 并停 Body；角色行、余额、记忆保留（cid 永不复用）
GateServer.Npc.Registry.list()         # 表行 + 是否在跑
GateServer.Npc.Registry.start_all()    # 启动时调用：拉起全部 enabled 行
```

**大脑解析**（`Registry.brain/2`，唯一一处把 JSON 参数变成 `{模块, profile}`）：

| brain | 模块 | params（JSON） |
|---|---|---|
| `settler` | `Brain.Tree` + `Trees.settler/1` | `definition`、`sites`、`quarries`、`revisit_ticks`、`tools`（技能 build / gather 固定） |
| `llm` | `Brain.Llm` | `goal`、`tools`、`groups`、`skills`、`spells`（可选）、`max_requests_per_hour`、`genesis`（可选，见 M2）；endpoint 不入库，启动时取运行环境 `NPC_LLM_URL / NPC_LLM_KEY / NPC_LLM_MODEL / NPC_LLM_EFFORT / NPC_LLM_CACERTFILE` |
| `patrol` | `Brain.Patrol` | `route`、`dig` |

**启动**：gate 监督树在 `GateServer.NpcSup` 之后加一个临时 Task 调 `start_all/0`。Scene 还没就绪也没关系：Body 自己维护会话，
claim 失败 1 秒后重试（npc/README 会话契约）。测试构建不起它（与现有子进程同一开关）。

**不做**：位置持久化（与玩家同义，每次入场从 spawn 开始）；注册表的 Web / CLI 界面（rpc 足够，无其他调用方）；多节点分布（Body 只在主节点，设计稿 G-6）。

## 3 M2 创世能力

| 项 | 决定（默认，用户可改） |
|---|---|
| 能力 | `fill_box{min:[x,y,z], max:[x,y,z], material}`（material 0 = 挖成空气）与 `set_cells{cells: [[x,y,z,material], …]}`，组 `:genesis` |
| 执行 | Body 动词 `genesis_edit{edits: [{{x,y,z}, material}]}` → worker → `World.apply_edits/2`，与 0x78 后门同一个 World 入口、同一语义（不扣料、不记 placed_by、不查射程与保护区；液体规则与 refined 拒绝照 World） |
| 授予 | 只有注册表 params `genesis: true` 的 NPC：Body 在启动选项里记下该标记并在受理时检查（Brain 是外部输入，Body 是信任边界）；Abilities 只在 profile.genesis 为真时投影该组 |
| 范围 | 每次 ≤ 4096 格；每格各轴离自己 ≤ `Perception.reach()`（在世界里干活，要走过去） |
| 观察 | `npc_genesis_edit cid= cells= result=` 日志；事务照常经 0x79 广播，玩家看到地形变化 |
| 不做 | 保护区 / 他人放置格的额外护栏（与后门同语义；正式开放后创世能力随后门一起收回） |

## 4 M3 碰撞基线前的 timeline

现象（I3 浸泡与 gate 全量各复现）：`CollisionUpdates.record_artifact/3`（collision_updates.ex:235，经 player.ex:772/792）
`KeyError key 1`，Player 崩溃；NPC 1 s 后重新 claim。先定位根因与是否影响流送 Scene（正式 Demo / 青岚），再修。

## 5 测试与实跑

- M1：data_service 迁移与读写；gate 集成——`put` 后 Body 在真实 Scene 入场、`remove` 停止、模拟节点重启（停掉 NpcSup 全部子进程后 `start_all/0`）同 cid、同大脑回来；非法 params 在 `put` 被拒、不落库。
- M2：Abilities 授予（无 genesis 不投影、Body 拒绝）；真实 World：`fill_box` 后 `material_snapshot` 逐格等于期望、placed_by 为 nil、余额不变；超范围 / 超格数回本层原因。
- M3：改前红（复现崩溃）、改后绿。
- 实跑（机制完成后）：Demo 镜像上经 rpc 登记建设者与创世 NPC，重启容器后两者自动回来并继续工作；短双客户端看到创世 NPC 改地形。长跑最后。

## 6 进度日志

| 日期 | 内容 |
|---|---|
| 2026-10-08 | 决策稿；M1–M3 实施中 |
