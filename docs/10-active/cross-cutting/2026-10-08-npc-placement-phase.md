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
| M1 | NPC 注册表 + 节点重启自动恢复（`npc_specs` 表、`GateServer.Npc.Registry`、启动时拉起） | 已实现、测试通过，待复核提交（§6） |
| M2 | 创世能力组 `:genesis`（`fill_box` / `set_cells`，底层 `World.apply_edits`，只授予注册表标了 genesis 的 NPC） | 已实现、测试通过，待复核提交（§6） |
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

**实现注记（2026-10-08，以代码为准）**：

- DataService 模块是 `DataService.NpcSpecs`：`upsert/2`（置 `enabled = true`）、`list/0`（全部行含停用，按名字排序，带
  characters 的名字）、`disable/1`（按名字，`{:ok, cid} | {:error, :not_found}`）。原拟的 `get` / `list_enabled` 没有调用方，
  由 `list/0` 一个函数承担（`start_all/0` 只取 enabled 行）。`character_id` 外键 `on_delete: :delete_all`：登记依附于角色身份。
- “同名在跑先停旧的再起”要能按 cid 找到在跑的 Body：`Body.start/2` 起的 Body 在 init 里登记到 `GateServer.NpcNames`
  （Elixir 重复键 `Registry`，崩溃重启后重新登记，进程退出自动注销；gate 监督树在 NpcSup 之前起它）。重复键是为了不改
  `Body.start/2` 的既有替换语义（同 cid 新旧 Body 可以短暂并存，旧的被 claim 顶替）；注册表自己总是先停旧再起。
  依据：Elixir `Registry` 是本地进程按键查找的标准做法（https://hexdocs.pm/elixir/Registry.html ）。
- 参数先 `Jason.encode!/1 → decode!/1` 规范化成 JSON 形再解析：存进库的与 `put` 时解析的是同一份，`start_all/0` 读回再按
  `brain/2` 解析一次（持久化加载也是信任边界）。校验 = 解析本身（必填键、类型守卫）+ 与运行时同一个构造函数
  （settler 调 `Brain.Tree.init/1` 建树、llm 调 `Abilities.tools/1` 投影、patrol 调 `Brain.Patrol.init/1`）；任一 raise →
  `{:error, {:invalid_params, 说明}}`。
- llm 的 `skills` 是名字列表，只收不需要配置的 `build` / `gather`（design_house / wilderness 的配置没有 JSON 形，仍用代码起）；
  `groups` 只收本 profile 条目里出现的组（没授予创世就不能要 `genesis` 组）；工具带与采石盒的 JSON 键是字符串化的整数。
- 每行启动记 `npc_registry_start name= cid= brain= result=`（失败为 error 级），一行失败不影响其余行。

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

**实现注记（2026-10-08，以代码为准）**：

- “与 0x78 同一语义”补全了玩家 0x78 在进 World 之前的两道门：材料必须是目录合法 id（`VoxelMaterialCatalog.valid_id?/1`，
  0x78 解码同一谓词；World.apply_edits 本身不查材料）→ 否则 `invalid_command`；格在部署编辑盒内（QuicConnection 的编辑盒门，
  判定抽成 `Dispatch.within?/2`，prefab 门同用）→ 否则 `out_of_bounds`（Body 既有原因）。另外 edits 必须非空。
- 规则、条目与 Body 受理前的唯一校验集中在新模块 `GateServer.Npc.Genesis`（`entries/1`、`prepare/3`、`max_cells/0`），
  同 `Perception` 之于 look；Body 只多一个动词与一个执行分支。Body 的授予字段由启动选项 `genesis` 给出，`Registry` 从同一个
  `profile.genesis` 填它（唯一来源是注册表行）。
- `set_cells` 需要不定长数组：Abilities 参数规格新增 `{:list, spec}`（schema `{type: array, items}`，长度上限由 Body 判）。
- `fill_box` 在 Abilities 的 build 里按 x、y、z 逐格展开，只展开到 `max_cells + 1` 格：模型给的超大盒不会在 Brain 进程里
  全部展开，格数仍只由 `Genesis.prepare/3` 判一次（超出回 `invalid_command`）。

## 4 M3 碰撞基线前的 timeline

现象（I3 浸泡与 gate 全量各复现）：`CollisionUpdates.record_artifact/3`（collision_updates.ex:235，经 player.ex:772/792）
`KeyError key 1`，Player 崩溃；NPC 1 s 后重新 claim。先定位根因与是否影响流送 Scene（正式 Demo / 青岚），再修。

**根因**：非流送 Scene 允许初始快照到达前入场（scene.ex:467 只登记请求，:577 初始化后补发），此时 Player 拿到的 `updates` 是
`CollisionUpdates.new/1` 的空模板；Scene 每 tick 先向全部成员发 timeline（:734）、再发 anchor（:743 / :768）。旧 Player 在非流送且
无基线时也调 `ingest_publication`，Scene 初始化后、该 Player 的入场 marker 前若装了含 chunk 的事务，`record_artifact` 取
`artifacts[1]` 得 KeyError。**判断**：timeline 早于 anchor 是正常时序（timeline 同时是公共时钟）；anchor 带 Scene 该 tick 的完整派生
碰撞（:761 断言 seq 一致）并被整体替换（player.ex:691），所以基线前丢弃 timeline 内容在契约上正确。**修复**（690369e0）：Player 在
`baseline == nil` 时只推进 tick（与流送原有分支合并）。**流送 Scene**（正式 Demo / 青岚，`collision_window_radius_tiles` = 1）不受影响。
浸泡用例原先只计 Body 重启，Player 崩溃会假通过：已补计 Player 异常退出（`player_crashes == 0`）。

## 5 测试与实跑

- M1：data_service 迁移与读写；gate 集成——`put` 后 Body 在真实 Scene 入场、`remove` 停止、模拟节点重启（停掉 NpcSup 全部子进程后 `start_all/0`）同 cid、同大脑回来；非法 params 在 `put` 被拒、不落库。
  实现：`apps/data_service/test/data_service/npc_specs_test.exs`（3 项）、`apps/gate_server/test/gate_server/npc_registry_test.exs`
  （`brain/2` 手写期望 4 项；集成 5 项：入场 + 巡逻 + remove、同名改登记先停旧、节点重启、非法参数不落库、llm 行 genesis 授予）。
- M2：Abilities 授予（无 genesis 不投影、Body 拒绝）；真实 World：`fill_box` 后 `material_snapshot` 逐格等于期望、placed_by 为 nil、余额不变；超范围 / 超格数回本层原因。
  实现：`npc_abilities_test.exs` 全条目表补 fill_box / set_cells（手写期望命令）与授予、形状用例；`npc_body_world_test.exs`
  新增 3 项（逐格写入 + 盒外不变 + 余额不变；未授予 not_permitted；超格数 / 超距离 / 编辑盒外 / 空 / 非法材料 / 非整数格），
  接缝 T2.2 覆盖两个新条目。
- M3：改前红（复现崩溃）、改后绿。
- 实跑（机制完成后）：Demo 镜像上经 rpc 登记建设者与创世 NPC，重启容器后两者自动回来并继续工作；短双客户端看到创世 NPC 改地形。长跑最后。

## 6 进度日志

| 日期 | 内容 |
|---|---|
| 2026-10-08 | 决策稿；M1–M3 实施中 |
| 2026-10-08 | M1、M2 实现（worktree `ex_mmo_cluster-capabilities`，未提交，待复核）：`npc_specs` 迁移 + `DataService.NpcSpecs`；`GateServer.Npc.Registry`（put / remove / list / start_all / brain）、`GateServer.NpcNames` 与启动 Task；`GateServer.Npc.Genesis` + Body 动词 `genesis_edit`（`not_permitted` 为 Body 层新原因）+ Abilities `{:list, spec}`。新测试改前红（表不存在 / 模块未定义 / genesis_edit 回 invalid_command）、改后绿；gate_server 全量与基线比对见复核记录。偏差与补全见 §2、§3 的实现注记 |
| 2026-10-08 | M3 **已实现、已实跑（scene / gate 集成与 180 s 浸泡，非真实客户端）**（690369e0，合并 3e3b8863）：Player 在碰撞基线前的 timeline 只推进 tick；新增 scene 回归“join before the initial snapshot”（改前 KeyError、会话按 3 关闭；改后 22/22）；改前 180 s Settler 浸泡 1 次同栈崩溃，改后 0 次。scene 全量 243/255（12 项缺 E1/IS 夹具，补设本地夹具后 12/12）；gate 全量 223/280（57 项 T1Transport）；world_server 相关 8/8；voxel_region world_test 21/21。浸泡判据补 `player_crashes == 0` |
