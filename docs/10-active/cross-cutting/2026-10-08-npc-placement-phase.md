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
| M1 | NPC 注册表 + 节点重启自动恢复（`npc_specs` 表、`GateServer.Npc.Registry`、启动时拉起） | 已提交，run02 机制验收通过（§6） |
| M2 | 创世能力组 `:genesis`（`fill_box` / `set_cells`，底层 `World.apply_edits`，只授予注册表标了 genesis 的 NPC） | 已提交，run02 机制验收通过（§6） |
| M3 | scene_server：非流送 Scene 里 Player 在碰撞基线装好前收到 timeline 时 `CollisionUpdates.record_artifact/3` KeyError 崩溃 | 已修复、已提交，验证见 §4 / §6 |
| M4 | 客户端 `dead` 中文文案（Voxim 资产，随客户端一起） | 待做 |
| M5 | 持续扩张：技能 `expand`（区域内选址、缺料自采、放置）+ Settler 可选 `expansion`（每轮维护完再建一座） | 已实现并提交；run07 持续扩展验收未通过（§6.1、§7） |
| L | 长跑验收（建设者 / LLM 住民 / 创世 NPC，服务端浸泡 + 短双客户端） | run07 六小时与一次双端观察已收尾；持续扩展、双端完整观察均未通过，未进入 24 h（§6.1） |

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
| `settler` | `Brain.Tree` + `Trees.settler/1` | `definition`、`sites`、`quarries`、`revisit_ticks`、`tools`（技能 build / gather 固定）、`expansion`（可选，M5：`{"region": [[x0, z0], [x1, z1]], "spacing": n, "tool_id": t}`，配了再加 expand） |
| `llm` | `Brain.Llm` | `goal`、`tools`、`groups`、`skills`（build / gather / expand / design_house）、`spells`（可选）、`max_requests_per_hour`、`genesis`（可选，见 M2）；endpoint 不入库，启动时取运行环境 `NPC_LLM_URL / NPC_LLM_KEY / NPC_LLM_MODEL / NPC_LLM_EFFORT / NPC_LLM_CACERTFILE` |
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
- llm 的 `skills` 是名字列表：`build` / `gather` 无配置；`design_house` 的配置只有会话预算 `design_budget`（缺省 12 轮 / 240 000 token / 每轮输出 4096，同 D2 验收配置），模型接口与大脑同一个 endpoint（2026-10-08 补，AI 住民要能自己设计再建）；wilderness 需要调度器端点，仍用代码起；
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
| 2026-10-08 | 注册表 llm 大脑可登记 `design_house`（会话预算 `design_budget`，缺省同 D2 验收配置）：新用例 registry 10/10（改前注册表 `@skills` 没有 design_house，`Map.fetch!` KeyError）；原“design_house 不经注册表”的拒绝行按契约变化改为 wilderness |
| 2026-10-08 | **机制实跑 run02（已实跑、已验收机制项）**：镜像 `voxim-server:20261008-caplib-b82109c0`（sha256:4690e5e5…），全新森林世界。经 rpc `Registry.put` 登记“建设者”（settler）与“创世者”（llm，genesis: true，groups move/sense/genesis/memory，max_requests_per_hour 20，目标：把 x 50..55、z −526..−521 整平为顶面 y = 421 的平台）。建设者自采石 5 击后建成面板（seq 8），此后回访只回 occupied、无 idle；创世者 look → fill_box 挖空 324 格（seq 10）→ fill_box 填石 108 格（seq 12）→ look → wait，逐格核对 432 格违规 0、区域外改动 0、placed_by 全 nil。`docker restart` 后无任何 rpc，6 s 内两条 `npc_registry_start … ok`，同 cid 继续（建设者认出自家工地，创世者 look 后 wait）。双客户端约 2.5 min：两端都收到“建设者”“创世者”入场名字、载入 have_seq 13、准星落在平台顶格 6/6，截图已查看（平台、两个名牌）。LLM 共 10 次请求、0 失败。证据 Voxim `Saved/CapabilityLibrary-20261008/run02/`（summary.json、genesis-check.json、scene/judge.json）与 `Captures/CapabilityLibrary/2026-10-08/run02/`。观察：完成目标的住民每 5 min（wait 上限 300 s）被问一次 |
| 2026-10-08 | LLM `wait` 上限 300 s → 3600 s（说明同步“无事可做就等久一点”）；走近 / 说话 / 新 Outcome 仍提前询问。长期空闲的住民从约 12 次 / 小时降到约 1 次 / 小时 |
| 2026-10-08 | **长跑 run03 前 40 min 暴露三处机制缺陷（已修，均有改前红）**：① 寻路网格只把空气当可穿过，站进矮草 / 蕨格的 NPC 起点即实心、任何目标都 no_path（住民两次卡死）→ 改用碰撞同一判据 `VoxelMaterialCatalog.blocks_movement?/1`（新用例：草里出发并穿过草格，改前 no_path）；② LLM HTTP 固定 60 s 超时，gpt-6.1-sol / high 的设计会话后几轮常超时（6 次 design_house 败 5 次、约 55 万 token 白花）→ endpoint 可带 `timeout_ms`，注册表读 `NPC_LLM_TIMEOUT_MS`（缺省仍 60 s）；③ 给模型的历史只留最新一次 look 的内容，核对大于 512 格的区域时模型交替重看（创世者一小时 20 次额度耗尽）→ 保留最近 3 次 look（投影测试按契约更新，改前红）。run03 中两个 LLM NPC 已暂停、建设者继续作为稳定性浸泡；gate 全量 237/294，失败只有 T1Transport 57 |
| 2026-10-08 | **长跑 run04 第 63 min 成本保护触发（住民 trailing hour 设计 token 1 059 456 > 100 万），根因与修复（已实现）**：住民建成两座 micro 薄墙小屋后，在旁边设计第三座时，design_house 的 site（锚点起 16×16×2 宏格）把每个细化格的 micro_cells 逐个列出：56 个细化行 / 5 256 个 micro = 321 KB，首条消息约 13 万 token，两轮越过 24 万会话预算（同一块空地永远建不成第三座）。改为给模型的细化行用按材质合并的 micro 闭区间盒 `micro_boxes`（`Perception.compact_refined/1`，无损），主大脑 look 投影与设计会话的 site / look 同用；Body 的 look Outcome 仍原样。同一真实场地实测：5 256 micro → 94 盒，321 073 B → 7 261 B（约 1/44）。新纯函数用例（单面墙一盒、L 形并集等于原集合、无明细原样）；设计会话两条断言按契约更新（micro_cells → micro_boxes）；gate 全量 238/295，失败只有 T1Transport 57。run04 的建设者与创世者继续浸泡 |
| 2026-10-08 | **住民专项复验 run05（已实跑，独立容器 voxim-caplib-run05，镜像 65cecb84，76 min）**：同一块空地建成 3 座（run04 只到 2 座）：421b57f9 / cb006eb0 / 759f820d，石 52.5 / 9.8 / 8.9 m³；5 次 design_house 3 成 2 败（1 次 12 轮用满且余额 0，1 次被保护终止），首条消息最大 26.6 KB / 首轮约 1.7 万 token（run04 第五次约 13 万）；同一 site 实测 117 242 B → 9 294 B；最长单次请求 142 s（旧 60 s 超时会失败 3 次），超时 0、请求失败 0、Body 重启 0、Player 异常 0、session_lost 0；gather 内 no_path 2 次（夹具采石盒北侧站位无路，换候选继续）。11:38 被 Test-only 保护“trailing hour 主决策 > 25”撤下：大脑额度是固定窗口（每满一小时清零），跨边界的一小时最多两倍额度——不是失控（31 次决策无循环）。证据 Voxim `Saved/CapabilityLibrary-20261008/run05/` |
| 2026-10-08 | LLM 额度改为滑动窗口（`Brain.Llm.recent_asks/2`）：任意连续一小时不超过 `max_requests_per_hour`；手算小例（第 45–70 分钟 26 次：第 71 分钟 26、第 106 分钟 24、第 112 分钟 18） |
| 2026-10-08 | run04 观察：建设者每次回访的技能终态都写一条经历，约 3 h 写满 1000 条上限后逐条裁旧（`npc_memory_trimmed`）。**用户决定：照常记**——现有记忆只是过渡，后期接入更完善的独立记忆系统，与 NPC 完全解耦；本阶段不为经历写入加过滤或节流 |
| 2026-10-08 | **M5 持续扩张已实现、测试通过（未实跑、未提交，待复核）**（§7）：新技能 `expand`（`Skills.Expand`，选址 / 网格 / 分段 / 分块 / 采石候选纯函数，采石复用 `Gather.run/3`，步号命名空间经新的 `Skill.call/2`）；`read_catalog prefab` 加 `bounds_micro`；`Brain.Tree` 的 act 加 `append:`；Settler 可选 `expansion`；注册表 settler 行 `expansion`、llm `skills` 可登记 `expand`。改前红：新用例 10/10 纯函数 `UndefinedFunctionError`；注册表 settler 行带 expansion 时旧代码静默丢掉（profile 无 expansion、技能无 expand），llm `"expand"` KeyError，Settler 脚本用例 KeyError。改后：npc_expand 11/11（含真实 World：余额 0 → 地块 A 先采石堆 2 格、地块 B 跳过 A、第三次 no_site）、npc_settler 11/11（含多轮：建 A → 维护 A 建 B → no_site；拆 A 后原锚点重建、此后只维护）、npc_registry 12/12；gate 全量 254/311，失败只有 T1Transport 57（与基线同）。日志在主控 scratchpad `phase3/logs/`（red-expand-pure、red-settler-registry、gate-full-1、green-final） |
| 2026-10-08 | **长跑 run04 收尾（已实跑）**：实际 4 h 52 min（用户同意提前结束）。Body 重启 0、Player 异常 0、session_lost / claim_failed / error 行 0；BEAM 内存开跑 195 MB，峰值 252 MB（LLM 活跃），10:14 起 202–217 MB 无上涨，进程 592 → 575。建设者：拆 9 次重建 9 次（21–34 s），自采 2 次，idle 0，occupied 1 665；创世者 15 次决策（look 7 / fill_box 3 / wait 5），1 200 格核对违规 0；住民撤下前建成 2 座、design_house 6 次 2 成（根因见上，已由 65cecb84 修复）；npc_memory_trimmed 681（用户决定照常记）。双客户端观察第 2 次 O1–O5 全过（第 1 次 A 离房子太近镜头被坡挤住），14 张截图已看。证据 Voxim `Saved/CapabilityLibrary-20261008/run04/`、`Captures/CapabilityLibrary/2026-10-08/run04/` |
| 2026-10-08 | `travel` 技能（长途分段行走）：Settler 回站位与 expand 共用 `Travel.walk/2`；llm 可登记。真实 World 用例：单个 move_to 到 74.3 m 外回 too_far，travel 分 3 段到达（改前无此技能）；Settler 纯函数用例的站位命令按契约改为 travel 技能 |
| 2026-10-09 | **“持续扩展”长跑 run06 的机制缺陷与修复（已实现、测试通过，未实跑、未提交，待复核）**。run06（镜像 a8a8e1c7，证据 Voxim `Saved/CapabilityLibrary-20261008/run06/notes.md`）三个 NPC 都停在机制问题上，rpc 只读复现的根因：① **寻路与碰撞对细化格不一致**——Body 网格把细化格当作占满、可踩，规划让建设者踩 1/8 米面板顶（`[{55,420,-520}, …]`），身体落进面板格空着的 7/8 后起点不可站，对任何目标 no_path（15:23、19:08 两次永久卡死）→ 细化格既不能穿过也不能站（`Perception.walk_kind/1` 一个判据，不进网格），起点是身体的权威位置（`Path.find/7` 新选项 `trusted_start`，冻结样例 +6）；② **长途寻路的竖直范围**——`goal_y` 为 nil 时取盒竖直只到起点 ±6，travel / expand 的分段不带 y，高差 > 6 m 的段全部 no_path（住民从北坡去建房区）→ travel 每段先 survey 段终点列、取离脚下最近的可站层带 y 走（`Travel.stand_y/2`），move_to 说明写明不给 y 只看脚下 ±6；③ **expand 的失败处理**——走不到记为跳过、候选用尽回 `no_site`，与放满同一结果（住民按“放满了”每小时 wait，还写进了长期记忆）；缺料是依地块而定的，却作为终态（建设者 18:15 起每 90 s 同一拒绝）→ 走不到 / 够不着 / 附近采不到料都跳过换下一块，终态分 `region_full` 与 `no_reachable_site`；④ **选址要求逐列同高、地面只在脚下 ±4 找**——勘察结论“完全同高的 4×4 位置 0 个”，自然地形放不下房子；创世者核对整平要分 5 层 look、历史只留 3 次，永远“看不全” → 新感知原语 `survey`（地表高度图，一次 ≤ 32×32 列），expand 按每个候选自己的地表选址，高差 ≤ 2 格先平整到下中位数（挖天然格入账、填石花余额）。创世者被成本保护撤下是采样器墙钟 / 大脑单调钟 0.46 s 的口径误报（采样器已改，服务端不改）。改前红（同一 worktree 换回 HEAD 的 lib 跑新用例，日志 `phase4/logs/red-path.log`、`red-gate.log`）：面板旁的规划路点 `[{5.5,10.5},{6.5,10.5},…]` 经过面板格、站在面板格里 move_to `no_path`、8 m 台地 travel `no_path`、起伏 1–2 格的地块 `no_site`、缺料地块 `insufficient_material` 终态、Path 冻结样例 2 项 `no_path`、其余新纯函数 UndefinedFunctionError；改后全绿。scene 全量 249/261（失败只有 E1/IS 夹具 12 项）；gate 全量 266/324，失败 58 = T1Transport 57 + npc_brain_llm_test 一张手写工具表缺 survey（按契约补上后该文件 32/32），与基线同。编译无新增告警 |

### 6.1 run07 六小时收尾（2026-10-09，Codex）

**结论：完成本轮取证与停机，验收未通过。** 建设者持续扩展至区域候选用尽，住民设计失败后恢复建房；创世者第 6 小时仍重复处理已完成的第 10 块，没有新增整平范围。一次真实双客户端观察完成了鉴权、NPC 名称同步和世界版本检查，但 B 端最后一个站位请求失败，不能写成双端全通过，也不进入 24 h 验收。

**范围与时间**：服务端镜像 `voxim-server:20261008-caplib-c3e76aff`，源码 `c3e76aff`；本次只做 Test-only 取证与文档收尾。严格统计窗口是 `2026-10-08 21:09:09.094488` 至 `2026-10-09 03:09:09.094488 UTC`（末端不含）。终点副本在 `03:09:09.178–03:09:19.119` 串行读取，C / R / S 均为 seq 3302。`voxim-caplib-20261008` 于 `03:14:20.384 UTC` 停止，`exited / exit=0 / RestartCount=0`，容器保留；PG 与其他会话未停止。

**实际扩展**（小时从 register_utc 起算，面板 / 房屋以已接受的 prefab 放置及 expand 完成日志交叉核对；旧 notes 的跨小时快照不作精确小时计数）：

| 指标 | h1 | h2 | h3 | h4 | h5 | h6 | 终点 |
|---|---:|---:|---:|---:|---:|---:|---|
| 建设者新增面板 | 55 | 31 | 23 | 19 | 16 | 5 | 149 个实例 |
| 住民新增房屋 | 1 | 1 | 2 | 1 | 0 | 2 | 7 个实例 |
| 创世者：每小时内最后一条权威样本的完整 10×10 块数 | 3 | 5 | 7 | 9 | 10 | 10 | 10/16 块，1028/1600 列满足目标（含原本满足的列） |

- 建设者最后一次建成在 `02:26:07`；`02:30:29` 首次返回 `region_full`，`skipped %{crowded: 149, no_stand: 1}`，之后继续维护与检查。六小时内共 9 次 region_full，未出现 no_reachable_site；挖石净减少 18 格，记忆仍按用户决定照常写入、裁旧。
- 住民 design_house 共 9 次，7 成 2 败。第 5 小时两次失败分别用 244813 / 250694 token，最后检查都为 `[:placement]`；已保存的第 6 次终态记忆明确为 `:token_budget`。第 6 小时两次设计以 6 轮、127159 / 124204 token 成功，`02:10:46`、`02:27:51` 实际建成第 6 / 7 座。补料仍有 gather 18 次 rejected、3 次 done；住民移动 no_path 30、stuck 3，建设者 stuck 1，均照实保留。
- 创世者第 6 小时 20 次决策 = 18 次 look + 2 次 genesis_edit，仍针对已完成的第 10 块（x10..19、z-556..-547）；本轮最长连续 look 为 16 次。两次 edit 返回成功不等于新增范围：最后一小时的权威样本和终点逐格核对均仍为 10 块 / 1028 列，尚有 6 块未完成。采样器 / 原 summary 的 last_ok 含只读 probe，不能用其“最近成功”代替实际扩展。

**运行与成本证据**：严格六小时日志 error 行、session_lost、claim_failed 均 0；三个 Body 的观测 PID 始终各 1 个，成本保护撤下 0。两个 LLM NPC 每个运行小时各 20 次主决策；请求 trace 为主请求 240 次 / 3032252 token、设计请求 82 次 / 1737147 token，合计 4769399 token，322 次均 ok，最长请求 108.8 s。34 条窗口内权威样本的 BEAM 内存为 347.2–552.9 MB，首条 351.5、末条 552.9 MB，进程 582–592；不据此宣称内存无增长或已排除泄漏。

采样器在 `00:41:03 UTC` 以 `sampler7.py --hours 6` 恢复，`03:10:00` 自行结束。`--hours` 是从 register_utc 起的**总时长**，不是剩余时长。`00:11:44.553 → 00:41:04.296` 存在 1759.743 s（约 29 min 20 s）的权威采样空档；日志与 trace 已按游标补读，但缺失的 World / 内存快照及当时的实时保护不能补回。六小时后的采样、观察期新增动作均不计入上述扩展与请求数字。

**创世区边界核对限制**：C 取证盒内、目标完整 XYZ 体积外有 9 个砾石格从 6 变为 0，坐标在 x40..41、y430..434、z-555..-551。原 check_c 也报告 outside=9，未抹去。住民 `01:14:14` 的 gather 盒 `[[40,428,-558],[47,435,-551]]` 包含这 9 格，提供了另一动作来源的旁证；这是推断，不能当作逐事务归因。查询时保留日志前缀已压实（最早 seq 3579），无法从该接口复原这些格的改动者。本轮不宣称“创世者越界”，也不宣称“边界核对 0 违规”。

**一次真实双客户端观察**：`03:10:09.013–03:13:27.558 UTC`，198.545 s（约 3 min 19 s，含启动与关闭），客户端 `/Game/Voxel/Gameplay/L_GameplayDemo` 正式组合根、Voxim HEAD `b40f922c`，二进制 digest 见 record。复用原 `observe07.py` 的回放与 O1–O5 判定；原夹具在平台变大、宏格房屋聚组后两次离线 no stand，故在本 worktree 加 Test-only 适配器：平台聚焦首个完整 10×10 块，房屋用成功放置 seq + `World.instance_cells/2` 区分实例，完整几何副本不改。8 项反例自检通过；最终 plan/dry 重新读取 seq 3302，7 座房屋、149 块面板。`@place` 与 `@look_settled` 是站位 / 相机夹具，本轮不证明真实步行到达。

| 检查 | 实际结果 |
|---|---|
| O1 鉴权角色 / 单会话 | 两端通过 |
| O2 三个 NPC 的 cid 与名称 remote_enter | 两端通过 |
| O3 世界版本至少达到副本 seq 3302 | 两端通过（最小 have_seq 均 3449） |
| O4 平台、房屋、面板准星目标 | 11/12；A 6/6、B 5/6，B 面板目标 `[67,415,-514]` 缺失 |
| O5 回放完成 | A success，B fail |

B 在最后的 `@place 67.5 416.91 -510.5` 失败：原生 `find_spawn` 返回 `:not_found`，Test-only `:sys.replace_state` 回调匹配失败，随后回放显式 fail；更深的碰撞 / 站位原因尚未定位。保留 `placements.jsonl` 与 client.log，没有改判据、重跑或重启容器。

**截图已逐张查看**：实际 14 张（A 8、B 6；原计划 16），均非黑帧。两端可见整平台面、房屋墙面与准星框选；A 可见门洞及近距离面板，B 可见创世者，A 可见建设者名称与部分身体。住民方向被地形 / 树木遮挡，不能证明住民名称的视觉呈现通过；B 缺建设者 / 面板两张，B 房屋检查图还有“目标已失效或不允许攻击”提示（原因未定位）。没有把单栋房屋画面当作七栋全景，名称同步的日志结果与视觉结果分别记录。

**可复现产物**：以同级 Voxim 为根，`Saved/CapabilityLibrary-20261008/run07/` 中的 `boundary-manifest.json`、`{C,R,S}-at-6h.json`、`creator-check-at-6h.json`、`authority-at-6h.json`、`server-soak.log`、`llm-requests-soak.jsonl`、`summary-6h.json`、`audit-6h.json`、`archive-manifest.json`；观察为 `observe-{world,house-instances,plan}.json`、`dry/`、`scene/{record,judge}.json`、`scene/session/{a,b}/`、`observation-failure.json`、`visual-review.json`。截图在 `Captures/CapabilityLibrary/2026-10-09/run07/`。`closeout-tools/` 保留本 worktree `.demo/observe/npc-run07-closeout/` 的脚本源副本及离线失败证据（源副本用于追溯，原路径是执行入口）。日志 / trace 归档前在内存检查 LLM key，未发现密钥字节；没有读取或写入主树 .env。

本轮执行入口依次为 `evidence.py boundary`、`observe07_closeout.py fetch / plan / dry / run`（out 为 run07/scene、captures 为上述截图目录）、`docker stop --time 30 voxim-caplib-20261008`、`evidence.py archive`、原 `run07/summary.py --log run07/server-soak.log --trace run07/llm-requests-soak.jsonl --out run07/summary-6h.json` 与 `analyze.py`；完整工作目录 / 参数见 run07/notes.md。原 summary 的样本序列含窗口后的记录，严格窗口内内存与采样空档以 audit-6h.json 为准。未改产品代码，因此没有重复运行无关 mix / UE suite。

**后续须用户确认**：优先待定的是创世者重复查看 / 不再扩展，以及 B 端站位失败；住民补料与设计预算余量、M4 dead 文案、后续复验 / 24 h、合并决定仍待确认。本轮只提交本 worktree 文档，不 push、不合并 master。

### 6.2 run07 阻塞项修复（2026-10-09，续接）

用户要求继续 NPC 工作；本轮先诊断并修复持续扩展与观察夹具的已知阻塞，原 run07 失败证据保留。

**创世者上下文根因与方案**：日志中调用 98–103 用六次 look 核对第 10 块的 y422..450，104 起又回到
y422..426。`Perception.project/3` 在第四次 look 时清空第一份内容，`Brain.Llm` 本来另有最近八条 Outcome 上限；
在整块核对完成前，三份下层观察已丢失。survey 只描述可站地表，不能证明完整地下实心／上方空气体积。
删除 look / survey 投影层的三次裁剪，保留既有的有界 Outcome 窗口；每项仍带自己的 seq、XYZ 范围及结果，
不合成原子快照、不持有第二份世界状态、不新增进度缓存。持久记忆写入与预算不变。

依据：[Anthropic 的上下文工程实践](https://www.anthropic.com/engineering/effective-context-engineering-for-ai-agents)
建议先保证必要信息的召回，再去除冗余；过早清除工具结果可能丢失关键上下文。本项目已按单次查询限量和
大脑历史限长，因此删除重复且破坏同一轮核对的裁剪。取舍：最近八条里可能携带更多观察内容；这修复已证实的
信息丢失，不承诺任意大的工程都能放进八条上下文，更不把模型下一步必然扩展当作纯测试能证明的事实。

**最小测试计划**：纯投影验证后续 look / survey 不清空先前结果；真实 Llm 事件入口接收九份观察，捕获请求，
核对只留最近八份、六段 XYZ 数据与版本都在。模型 HTTP 和持久记忆使用既有替身，不起 World / 数据库／客户端，
因为本次变更只涉及从权威 Outcome 到请求的投影。再跑两个投影测试文件与共享投影调用方 HouseDesign 的相关测试；
不重跑无关 suite。命令从 `apps/gate_server` 执行 `mix.bat test --no-start` 加上述文件，证据写入
本 worktree `.demo/observe/npc-run07-fixes/`。双端夹具另按其碰撞原因选择回归，不以本测试代替。

**观察夹具根因与方案**：失败脚格 `(67,416,-511)` 下方是建设者实例 2060 的细化面板（宏格材料 0，
64/512 micro，原 `observe-world.json` 的 rows / refined_faces 可核对）。旧 `observe07.load` 用 `r[3] or 1`
把它当完整宏格，`smelting_plan.stand_ok` 因而接受。原生 `find_spawn` 在同一要求高度返回 `not_found`；
最小碰撞副本复现：完整格落点 y416.91、薄面板同高度 not_found、下探后天然地面 y415.91。
修复入口为仓库 `scripts/npc_run07_observe.py`：复用既有驱动及判定器，细化格在离线投影记为部分占用（-1，
不是材料 id），仍遮挡射线／净空，但不满足完整宏格地面条件。依据是共享原生运动内核的实际几何查询及
既有 Body 寻路的保守细化格契约，未改变生产碰撞／站位入口。该脚本只适配 run07 观察，依赖同级 Voxim 的
`Saved/CapabilityLibrary-20261008/observe07.py`、`observe_short.py` 及 `Docs/Gameplay`、`Docs/R7` 现有工具，
不是第二条生产运行路径。`--run-dir` 必填；输出用新目录，原 run07 不覆盖。

**验证结果**（当前是已实现、局部验证通过，未完成新版长跑／真实双端复验）：

- 上下文回归改前 3/3 失败，准确呈现旧观察被置 nil；改后相关 50 项通过。完整命令：在 `apps/gate_server`，
  环境 `MIX_ENV=test MMO_DB_PORT=26909 MMO_DB_PASSWORD=p0_body_test_only`，执行
  `mix.bat test --no-start test/gate_server/npc_brain_llm_test.exs test/gate_server/npc_survey_test.exs test/gate_server/npc_skill_house_design_test.exs`。
  前两文件的新增／修改用例不启动 World / DB，HouseDesign 文件沿其原有真实 World / DB 夹具验证共享调用方。
  日志 `red-context.log`、`green-context.log`；编译输出仍有既有未修改模块告警。
- `python scripts/test_npc_run07_observe.py`：站位反例改前失败、改后通过；独立审查发现的共享函数改写已删除，
  补普通 World 不受导入影响的反例（改前 AttributeError），最终 2/2 通过。日志 `red-stand.log`、
  `red-shared-planner.log`、`green-stand-final.log`；复核无重要遗留发现。原生复现入口：根目录
  `MIX_ENV=test mix.bat run --no-start .demo/observe/npc-run07-fixes/stand_probe.exs`，见 `native-stand.log`。
- 把原 run07 的 `observe-world.json` / `observe-house-instances.json` 复制到新目录
  `.demo/observe/npc-run07-fixes/replan-final/`，执行
  `python scripts/npc_run07_observe.py plan --run-dir .demo/observe/npc-run07-fixes/replan-final`，再执行
  `python scripts/npc_run07_observe.py dry --run-dir .demo/observe/npc-run07-fixes/replan-final --out .demo/observe/npc-run07-fixes/replan-final/dry`。
  A/B 为 54/58 步、计划 121.98/135.98 秒；原 O1–O5 的 8 项反例自检通过。B 面板新站位脚格为 `(66,415,-511)`，
  其下是完整天然地面。只有离线检查通过，没有把它写成双端已经通过。
- 一次真实模型短探针：根目录 `python .demo/observe/npc-run07-fixes/live_probe.py`，从原任务已停止容器读取
  模型环境到内存（不落密钥），以 C-at-6h 的 seq3302 第 10 块完整六段观察加固定进度笔记发一次请求。
  `gpt-6.1-sol/high`、输入 8281 / 输出 121 / 合计 8402 token；模型调用 remember，明确第 10 块已完成、
  下一块为第 11 块，没有再次 look。`live-context-request.json` / `live-context-response.json` / `live-context.log`
  保存输入与返回；这是固定副本上的单次决策，不证明在线世界持续扩展，也不评价记忆检索或绕过六小时验收。

下一步：新版正式镜像上的短双端复验，再安排六小时持续扩展复验；通过后才进入 24 h。
run07 容器保持停止，本轮未修改 Voxim 主树产品代码、未推送／合并／公网部署。

### 6.3 run08 执行（2026-10-09）

用户明确要求开始执行：先新版真实双端短回归，再六小时持续扩展。源码 `74e9ca3b`，镜像
`voxim-server:20261009-caplib-74e9ca3b`（`sha256:8de278ee97640e3c67d349d7ebb877e29fbfa482ad5ed61a99860b120d4ca866`）。
客户端 Voxim `b40f922c`，协议 39，正式 `/Game/Voxel/Gameplay/L_GameplayDemo` 入口。

- 本轮编排：本 worktree `.demo/observe/npc-run08/run.py`；参数 `prepare/start/fetch/plan/dry/scene --mode smoke`，
  复用既有部署与修正后的观察驱动。构建日志在同目录 `image-build.log`。不改上轮驱动与失败证据。
- 短场景环境：`voxim-caplib-20261009-smoke08`、库 `voxim_caplib_smoke08`，从已停止 run07 的完整世界与数据库复制，
  新可写目录 `Voxim/Saved/CapabilityLibrary-20261008/server-smoke08/`；这是明确 checkpoint 的回归副本，不是全新世界验收。
  权威副本 seq3660，7 屋 / 149 面板；O1–O5 判据沿用，8 项反例自检通过。产物 `smoke08/`，截图 `Captures/CapabilityLibrary/2026-10-09/smoke08/`。
- 长跑必须用独立全新库／世界（`--mode soak`，`run08/`），目标、三类大脑、每小时 20 次决策与一次木料作者样本沿用 run07。
  不修改记忆策略。采样器每分钟读日志并执行既有成本保护、每五分钟取权威快照；从 `register_utc` 起满六小时。
  首末边界另取权威结果，报告真实扩展／已完成区域、运行错误、请求与成本；缺样照实记录，不把存活当作持续扩展。

短回归结果（06:42:16–06:45:57 UTC，220.564 s）：O1–O5 全部通过，12/12 目标命中、两端 replay success 且正常退出，
22/22 权威站位成功；B 端最终站位为 `(66.5,415.91,-510.5)`，不再踩薄面板顶。16 张截图全部人工查看：平台、房墙与薄面板呈现可见，
三 NPC 名牌可见，住民／建设者身体部分被树木遮挡，不声称三者身体均清楚可见；部分帧显示查询拒绝提示，本场景不包含攻击验收。
判据原件 `smoke08/scene/judge.json`，站位 `scene/session/{a,b}/placements.jsonl`，视觉记录在本 worktree
`.demo/observe/npc-run08/visual-review.json`。短场景容器已停止并保留。

长跑于 **2026-10-09 06:50:28.167014 UTC** 开始，严格终点 **12:50:28.167014 UTC**（北京时间 14:50:28–20:50:28）。
容器 `voxim-caplib-20261009-run08`、库 `voxim_caplib_run08`，启动时 seq0、注册表空；三个 NPC 注册文件与 C/R/S 初始副本在 `run08/`。
原采样进程 PID175312（20 次阶段；现已替换，见下），命令 `python .demo/observe/npc-run08/run.py sample --mode soak`，首样本 elapsed0.2min。
独立收尾曾为 PID178984（报告修正阶段；现已替换，见下）执行 `.demo/observe/npc-run08/finish.py`：到时取 C/R/S 与权威汇总，停止并保留容器，归档严格窗口日志与请求，
复用 run07 统计脚本生成 `summary-6h.json` / `audit-6h.json`；自动收尾状态在 `finish-result.json`，**验收仍须复核实际增量，不能把自动收尾成功当通过**。
收尾脚本的严格结束边界与内存脱敏已用合成数据验证；日志在本 worktree `.demo/observe/npc-run08/{sampler,finish}.{stdout,stderr}.log`。
当前六小时仍在进行，24 h 尚未进入。

**08:44 UTC 途中核对**：权威 seq1014，建设者 83 面板、住民 5 屋、创世者 3/16 块。两 LLM 已达每小时 20 次决策上限；
创世者 07:56 的记忆明确记录前三块完成、下一块第四块，随后耗尽本小时额度；不能把这一段等待直接判作遗忘或卡死。
截至 08:35 采样状态，无请求失败／成本撤下／Body 重启，采样与结束时间不变。

途中发现并修正**报告计数**：`World.stats.instances` 是所有实例记录数（`world.ex:1137`），含房屋子构件，不能用总数减面板数表示房屋；
原 `resident.instances` 又只从细化格 slots 去重，会漏纯宏格房屋（run07 该数为 0，但实际 7 屋）。最终报告统一复用
`scripts/npc_run07_observe.py:read_instances/1` 的已接纳放置 seq 与 `World.instance_cells({birth, 0})` 根实例占用；
时间序列按 `birth <= sample.seq` 统计累计接纳的建筑放置，终点另外确认根实例占用。原始日志、采样、运行中的 NPC 均不改。
实际反例：08:38 样本旧算法报 225 屋，根实例实际 5；纯宏格 run07 根实例仍正确为 7。
最小测试：`python .demo/observe/npc-run08/test_report_counts.py`（2 项，子构件不放大、纯宏格不漏计、未来 seq 不提前算）；
`python -m unittest discover -s scripts -p test_npc_run07_observe.py`（2 项，既有站位语义）。
本轮只读取证在 `run08/status-check-0845/`，调度记录 `finish-scheduled-v3.json`，新收尾日志 `.demo/observe/npc-run08/finish-v3.{stdout,stderr}.log`；
前两版调度记录保留，均未执行终点动作。最终报告仍待六小时结束后复核。

**12:08 UTC 用户调整额度并恢复运行**：用户明确要求“额度放宽至60次”，现行值为**每个 LLM NPC 每滑动小时 60 次**。
核对时发现住民已于 08:51:10 UTC、创世者已于 09:51:06 UTC 被旧采样器以“窗口内 21 次决策”撤下，原记录在 `run08/guards.jsonl`；
因此原六小时三者持续扩展已中断，后续恢复不改变这一结论。21 次应答计数与大脑请求起点窗口的差异仍待专项核对，不据此断言服务端额度失效。

通过现有 `GateServer.Npc.Registry.put/2` 于 **12:08:14.398345 UTC** 恢复两者，仅改持久参数 `max_requests_per_hour: 20 → 60`。
这是注册表规定的重启生效路径（`registry.ex` / `NpcSpecs` 的公开契约），原 cid、世界、余额与持久记忆保留；Body 从登记出生点重新入场、短期历史重建。
观察到创世者 `recall work_blocks` 后继续编辑，住民重新勘察／采料。建设者未重启。
本轮编排 `run.py` 的 `LLM_REQUESTS_PER_HOUR = 60` 同时用于后续登记与采样器 `DECISION_LIMIT`，旧 run07 脚本不改；
旧采样状态及两次保护事件在 `run08/quota60/` 保留后，显式解除已恢复角色的撤下锁存，保护规则继续生效。
持久值、`Registry.brain/2` 解析值均为 60、两者 enabled/running、相同 cid 已实查；证据 `quota60/{before,applied,verified}.json`。

现采样 PID40800，日志 `sampler-quota60.*.log`；收尾 PID173916，记录 `finish-scheduled-v4.json`、日志 `finish-v4.*.log`。
**终点仍为 12:50:28 UTC（北京时间 20:50:28）**，不重新计六小时。`operator-events.jsonl` 记载人工调整；
最终 summary/audit/finish 都保留全部 guard 事件并标记 `original_uninterrupted_soak_not_passed`，只能作为中断前后分段观察，不能宣称完成六小时 60 次额度验收。

**run08 已收尾（2026-10-10 北京时间复核）**：终点取证于 10 月 9 日 12:50:28.179 UTC 开始，C/R/S 和汇总均为 seq1856；
容器于 12:50:43.846 UTC 正常退出（exit0、restart_count0），收尾于 12:50:48 UTC 完成、`errors: []`。采样与收尾进程均已退出，容器／库／世界保留。
最终权威量：**建设者 149 面板、住民 10 屋、创世者 8/16 块／829/1600 列**。10 个房屋根放置实例均有占用，房屋子构件不重复计数；
创世区完整 XYZ 之外变更 0。建设者最后已接纳扩展为 12:06:51 UTC，随后持续返回 `region_full`，跳过原因为 `crowded:149, no_stand:1`。

60 次额度阶段约 42 分钟：住民由 5 屋增至 10 屋，创世者由 5 块增至 8 块；创世者于 12:29:14 UTC 用满本小时 60 次请求，等待下个额度窗口。
住民另有 **每小时 1,500,000 设计 token** 保护（用户此次只调整主决策次数），12:47:29 UTC 累计设计 token 达 **1,539,537** 后被撤下；
本阶段 8 次设计会话，3 次 rejected、5 次 done。原全程 20 次保护撤下、途中修改配置和这次 token 保护都原样保留，**原六小时持续扩展验收未通过，24 h 未进入**。

证据：`run08/{finish-result,boundary-manifest,creator-check-at-6h,summary-6h,audit-6h,archive-manifest}.json`，
`observe-house-instances.json`、`guards.jsonl` 与 `operator-events.jsonl`。严格窗口有 70 条权威样本，最大间隔 311.94 s；
331 次模型 HTTP 请求均 ok、总 token 5,234,759（主请求 206 次，设计请求 125 次），设计结果仍有 4 次 rejected，不能把接口成功当任务完成。
BEAM 离散样本范围 311.5–695.8 MB，进程 568–593；不据此宣称无泄漏。容器业务日志 error 行为 0；
终点后的最后一次采样与停机重叠，发生一次 World RPC `shutdown`，已记入 samples/stderr；不影响之前完成的 seq1856 终点副本，不把它隐去或计为运行期崩溃。
剩余工作：查明旧保护“应答时间计数”与大脑“请求开始时间滑窗”的差异；按已批准 60 次额度重新定义相容的观测／成本预算，再从新环境做连续验收。

### 6.4 run09：200 万设计 token 额度重跑（2026-10-10）

用户明确要求「token 放宽至 200 万，重跑」。沿用每个 LLM NPC 每滚动小时 60 次主请求，
把住民设计保护从每滚动小时 150 万提高到 **200 万 token**；单次设计仍为 12 轮／24 万 token。
本轮从全新数据库与 baseline 开始跑六小时，仍使用 `74e9ca3b` 的同一正式镜像、协议 39、相同目标与一次性木料样本。
run08 的全部中断和失败证据保留。此次只改测试保护与取证，不改产品运行时，已通过的 smoke08 双端回归不重复。

**保护计数根因与修正**：旧采样器按应答完成时间统计，生产 Llm owner 按请求开始的单调时间限额。
run08 创世者撤下窗口实际有 21 次完成、20 次开始；因此不能用完成数证明主请求超额。
测试 trace 新增主请求的 canonical `self.entity_id` 与同一 VM 的单调时钟起点 `m0_us`，
采样器向该 VM 读取当前单调时间后按 NPC 计数；完成数继续保留为观测。
沿用辅助保护的 5 秒时钟／调度容差（3595 秒观测窗口），生产 owner 的 3600 秒／60 次契约不变。
trace 仅在请求完成后落盘，所以该辅助检查不计尚未完成的请求；它不替代生产 owner 的准入限制。
设计 token 仍复用原 trace／Outcome 两路用量取较大值的保护；连续失败保护不变。

依据：[Erlang/OTP 27 时间修正文档](https://www.erlang.org/docs/27/apps/erts/time_correction.html)
要求以单调时钟差度量持续时间；本仓 `Brain.Llm` 的额度窗口也使用单调时钟。
这里采用同 VM 时钟避免主机 UTC 与 VM 持续时间混用，保留原取证生命周期，不新增生产额度 owner。

最小验证：`python scripts/test_npc_soak_sampler.py`，4 项覆盖跨窗口完成不得误撤、真实超额应撤、
不同 NPC／设计请求不混计与窗口边界、200 万允许而超一 token 撤下。
旧实现 1 项失败，新实现 4 项通过，证据 `.demo/observe/npc-run09/guard-{red,green}.log`。
新入口为 `scripts/npc_soak_sampler.py`、`scripts/npc_soak_trace.exs`；依赖冻结的 run07 采样工具，明确只供此次测试。
编排 `.demo/observe/npc-run09/run.py`，自动收尾 `.demo/observe/npc-run09/finish.py`；
产物写入 `Voxim/Saved/CapabilityLibrary-20261008/run09/`，运行数据写入 `server-run09/`。
到六小时取证并停止容器；自动报告标为 `pending_review`，按真实扩展、完成区域和异常复核后才判验收。

**启动核验**：`prepare/start/register --mode soak` 顺序执行；库 `voxim_caplib_run09`、容器
`voxim-caplib-20261010-run09`，启动 seq0、注册表空、协议 39、镜像 ID 与 run08 相同。
严格窗口为 **2026-10-09 16:58:31.973853—22:58:31.973853 UTC**，
即北京时间 **10 月 10 日 00:58:32—06:58:32**。
后台采样 PID137308，自动收尾 PID147160；命令分别为
`python .demo/observe/npc-run09/run.py sample --mode soak` 与 `python .demo/observe/npc-run09/finish.py`。
首样本 seq9、建设者 1 面板、三个 NPC 均运行、trace 存活，两份主请求记录身份与单调起点齐全。
`request-budget-samples.jsonl` 确认 60／2000000 已生效；`finish-scheduled.json` 已记录严格终点。
此刻只证明启动和观测接通，六小时持续扩展仍待终点复核。

## 7 持续扩张（M5）

用户 2026-10-08 问“建设者为什么不一直盖新房子”：Settler 只维护作者给定的工地清单，建完就只会被拆重建。要让它在作者划定的扩展
区域里持续扩张——建完已知工地就去找下一块地、建下一座，材料不够自己找天然石料采；LLM 住民也能调用同一能力。

**契约**（代码正文：`GateServer.Npc.Skills.Expand`、`GateServer.Npc.Trees` 的 moduledoc）：

| 项 | 内容 |
|---|---|
| 技能 | `expand{definition: hex64, region: [[x0, z0], [x1, z1]]（整数格水平闭区间）, tool_id, spacing ≥ 0}`，内置技能（`Skills` 的 `@builtins`），strict schema。只经 Body 原子动作：`read_catalog` / `move_to` / `look` / `query_balances` / `prefab_place`；采石调 `Skills.Gather.run/3`（同一套原子动作，不复制采石逻辑；步号在本调用号下另起命名空间 `{:gather, n}`，技能内部一步统一由新的 `Skill.call/2` 发出） |
| 步行网格 | Body 的寻路网格只用 `Perception.walk_kind/1`：挡路、非液体、非细化 = 能踩；不挡路（空气、花草）= 能穿过；液体与**细化格既不能穿过也不能站**（不进网格）。起点是身体的权威位置：`Path.find/7` 的 `trusted_start: true` 让落不到站立格的起点（站在细化格空着的部分或其上）照常出发；草稿检查（`PrefabDesigner.Check`）的假设入口点不受影响。冻结样例新增 `blocked` / `trusted_start` 两个键与 6 例（2026-10-09，run06 根因 ①） |
| 勘察 | 新感知原语 `survey{x0, z0, x1, z1}`（`:sense` 组，strict，描述数字由源常量插值）：列闭区间每边 ≤ 32 列、各边离自己 ≤ reach，竖直取自己所在高度上下 reach（与 look 同一距离护栏），按 x 分片经 `World.material_snapshot/3` 读，`seq` 给 [首片, 末片]。每列 `floors`（站得下的地面层：能踩、其上身高格数都能穿过且在范围内，`Perception.floors/2`）、地表 `y`（最高一层）及其材质 / `placed_by`、`refined`（这一列有细化格）；LLM 投影为按行的 `[y, material]` 高度图 + placed / refined 稀疏表，与 look 一样随大脑最近 8 条 Outcome 保留和淘汰（§6.2）。创世者核对整平、expand 选址、travel 找落脚共用这一份列扫描规则（run06 根因 ②④） |
| 选址 | `read_catalog prefab` 新增 `bounds_micro`（朝向 0 时相对锚点的 micro 半开包围盒）→ 足迹；只用朝向 0。候选地块 = 区域内从 (x0, z0) 起、间距“足迹宽 + spacing”的网格，按地块中心离自己由近到远。逐个 survey 勘察窗口（足迹外扩 max(spacing, 2) 列），地面取**每个候选自己的地表**（原先只在自己脚下 ±4 格找）。判定（纯函数 `site/4`，依次）：足迹外扩 spacing 的列里地表有放置记录或有细化格（`crowded`）→ 足迹每列都有可站的地面（`no_ground`）→ 足迹各列地表高差 ≤ 2 格（`uneven`，原先要求逐列同高）→ 四个边中点站位里有一个离目标地面 ≤ 2 格、站得下（`no_stand`）。锚点在宏格角上（满足对齐门），底层落在目标地面 + 1 |
| 平整 | 目标地面 g = 足迹各列地表的**下中位数**（规则与依据见下文取舍）。分块 look 平整体积（足迹各列从最低地表到 g + 建筑高度，纯函数 `level/2`）：g 以上的非空气天然格（含花草）挖掉，g 及以下的空位（空气或花草，放置会直接覆盖花草）填石；要动的格有放置记录 / 细化 / 液体 → `blocked`（依据 w/prefabs.ex `place_aligned_tree`：prefab 只放进格值 `{0, _}`）。到站位后逐格挖（`Gather.mine/3`，与 gather 同一套探测与逐击；材料照常入账；命中作者 prefab 宏格 → `blocked`，这次打不到 → `out_of_reach`），补料后自下而上 `place` 填石（与玩家同一入口、花自己的余额，石料 id 取材质契约的 stone）。只动足迹内的格，站位不动 |
| 行走 | 勘察窗口不在 survey 范围内时，先 travel 走到地块最近的站位（`Travel.walk/2`：直线分段、每段 ≤ reach − 2，每段先 survey 段终点列、取离脚下最近的可站层带 y 走）；某段 no_path / stuck / too_far → 跳过这块地 |
| 取料 | `query_balances` 按材料单加填坑石料算缺额；缺的材料在站位周围（区域内、各轴离自己 ≤ 14 格）找露天的天然格（`placed_by == nil`、非细化、地面层或其上 2 层，层自上而下先挖料堆；离足迹 ≥ spacing + 2 格），逐格交给 gather（单格盒）直到不缺；附近采不到够用的 → 跳过这块地（`insufficient_material`），不硬建；缺的是本世界不入账的材料 → 终态 |
| 结果 | done `%{anchor_micro, orientation: 0, stand, site_cell, seq, skipped}`。跳过原因分两类：地块不成立（`crowded` / `no_ground` / `uneven` / `no_stand` / `blocked`，放置或填坑被拒 `occupied` / `out_of_bounds` / `protected_region`）与本可成立但此刻做不到（`no_path` / `stuck` / `too_far` / `out_of_reach` / `insufficient_material`）。候选用尽（纯函数 `ending/1`）：有第二类 → `no_reachable_site`，否则 → `region_full`（含区域里一块候选都没有）；其余拒绝（会话丢失、死亡…）原样作为终态。LLM 描述写明：region_full = 区域放满可以停；no_reachable_site = 暂时到不了或缺料，换个位置或稍后再试 |
| Settler | profile 可选 `expansion: %{region, spacing, tool_id}`（注册表 settler 行的 JSON 同名键，配了才加 expand 技能）。每轮巡完已知工地后调一次 expand：done 的新工地（anchor_micro / orientation / stand）经 `Brain.Tree` 新增的 `append:` 追加进黑板 `:sites`，下一轮起与作者工地同样维护（被拆重建）；其余结果记 `npc_settler_idle entity= act=expand reason=region_full` / `no_reachable_site` / …，下一轮再找 |
| 观察 | 每次 expand 结束记 `npc_expand entity= result= site= skipped= gathers=`；Settler 的 idle 行；放置照常 `character_intent` |

**护栏**：`region` 是唯一的作者护栏——只在区域内动土（平整只动足迹内的格；gather 的盒子是区域内的单格）与建造（足迹整个在区域内），
行走与只读 survey / look 可以出区域；不拆、不改任何已有放置（足迹只放进空气，间隔带里地表有放置记录或有细化格的地块整个跳过，平整与
gather 只动天然格，挖前按探测命中的 owner 挡住作者 prefab 宏格）。作者 prefab 宏格 look
看不到（能力库 F20），在间隔带里不算拥挤，在足迹里照样不是空气。

**取舍**：

- 网格而非逐格枚举（**原创决策**：UAlbertaBot 逐格由近到远试，本仓改成从区域角起的网格；风险是网格位有障碍就整块跳过，
  验证见 §7 测试的地块顺序与 Settler 多轮用例）：相邻地块之间恰好留出 spacing；候选数是逐格的 1 / 间距²，每个候选一两次 look；自己建过的地块重启后仍在网格
  原位（被拆后会被原地重建）。代价：网格位上有障碍就整块跳过，不左右挪动找位置。
- 只用朝向 0：选址规则与朝向无关，足迹换成旋转后的包围盒即可；当前没有需要其他朝向的调用方。
- ~~地面带：看它时自己脚下地面上下 4 格~~（2026-10-09 撤销）：run06 勘察表明自然地形处处起伏，地面改取每个候选自己的地表（survey）。
- 平整到下中位数：各列要挖或要填的格数是 |地表 − g|，中位数使总土方量最小（L1 损失的最优解是中位数）；偶数列时两个中间值之间任何
  高度同样最小，取低的——少填多挖，挖出的天然格入账、填坑花石料。工程上的土地平整用最小二乘平面（平均高程）再升降到挖填比 1.1–1.5
  （土被扰动后变密）；本项目目标面水平、按整格计、填方要花材料而非就近搬土，所以取中位数并偏挖。高差上限 2 格由用户在
  run06 复盘时给定（2026-10-09），站位不平整，只要求离目标地面 ≤ 2 格、站得下。
- 平整与放置之间不是事务：挖 / 填之后放置才被拒（被抢先、缺料）时已改的天然格不回滚，已入账 / 已花的材料照实；填过石的地块因地表有
  自己的放置记录，此后算拥挤（放置射程按足迹任一格在射程内，站位离足迹 1.5 米，正常不会在填完后被拒）。
- 细化格整格挡住、不可站（保守）：碰撞按 micro 几何，宏格网格表达不了“格里 7/8 是空气”；把细化格当可踩（原做法）会规划出物理上不存在
  的台阶，当可穿过会撞进 micro 墙。代价：NPC 不走进 micro 构件的空隙、不在 micro 地板上走（住宅用 micro 墙时 NPC 只在屋外）。
  起点放宽为权威位置：身体在哪里就从哪里出发，网格的保守不能让身体“哪儿都去不了”。
- 终态二分：LLM 与 Settler 要区分“可以停”与“稍后再试”；判定按跳过原因的类别，不另做可达性预检（走到才知道）。
- 扩张出来的工地只在黑板里，不存档、不写记忆（记忆将来换成独立系统，现在不依赖它）：重启后扩张从世界现状继续（已建地块因
  间隔带里有放置记录不再是候选），代价只是重启前扩张出来的建筑不再被维护；它们被拆后地块空出，又会被扩张在网格原位重建。
- Settler 的 `expansion` 带 `tool_id`（挖掘工具）：工具带可有多把工具、采石盒的 tool_id 按材料各配，没有唯一来源，显式配置。
- Settler 回工地站位改走 `travel` 技能（`Skills.Travel`，与 expand 走向地块同一个 `Travel.walk/2`）：扩张出去超过单程上限的工地也能回去维护（2026-10-08 补，原先单程 move_to 会 too_far）。
- 每轮最多新建一座（扩张接在每轮维护之后）；候选都不成立时每轮多一次勘察（区域别太大：耗时与地块数成正比）。

**依据**：

| 来源 | 要点 | 本项目怎样用 | 取舍 |
|---|---|---|---|
| UAlbertaBot `BuildingPlacerManager::getBuildLocationNear` / `canBuildHereWithSpace`（https://github.com/davechurchill/ualbertabot/blob/master/UAlbertaBot/Source/BuildingPlacerManager.cpp ，2026-10-08 查证源码） | 成熟 RTS 机器人选址：候选格按离期望点由近到远（`getClosestTilesTo`）逐个试，第一个“足迹外扩 buildDist 内都可建”的就用 | 由近到远、足迹外扩 spacing 判定空地 | 候选从逐格改为网格（见上）；“可建”用权威的放置规则（只放进空气）与本仓的放置记录 |
| Botea, Müller, Schaeffer, *Near Optimal Hierarchical Path-Finding*（J. Game Development 1(1):7–28, 2004，https://papersdb.cs.ualberta.ca/~papersdb/view_publication.php?pub_id=585 ） | HPA*：长路程拆成局部簇内的寻路段，全局层一大步跨一个簇 | 超出单程上限时沿直线分段，每段交给 Body 的局部寻路（S1 的单程上限不变） | 不建抽象图：直线分段失败就换候选，没有当前调用方需要绕远 |
| BehaviorTree.CPP 黑板（https://www.behaviortree.dev/docs/tutorial-basics/tutorial_02_basic_ports/ ） | 黑板是“树内所有节点共享的键值存储”，节点经端口读写 | `append:` 只是 `store:` 的列表形写入；扩张工地不另存档，进度以世界为准 | 与 Settler 既有“进度不存档，以权威为准”一致 |
| 本仓 w/prefabs.ex `place_aligned_tree` / `prefab_alignment` / `prefab_reach` | 放置只进空气、宏格定义锚点须对齐、足迹任一格在射程内即可 | 空地判定与锚点对齐直接照这几条；够不够得着仍由权威裁决 | 不在技能里复刻射程判定 |
| Recast `rcConfig::walkableRadius` / `rcErodeWalkableArea` / `rcFilterLedgeSpans`（https://github.com/recastnavigation/recastnavigation/blob/main/Recast/Include/Recast.h ，2026-10-09 查证源码注释） | 体素化是保守的（障碍触到的体素算占用）；离障碍或边缘不足身体半径的可走面被腐蚀掉 | 细化格整格挡住；1/8 米的面板顶薄于身体，不可站 | 宏格粒度不做 micro 级腐蚀，直接整格不可站 |
| Detour `dtNavMeshQuery::findNearestPoly`（https://github.com/recastnavigation/recastnavigation/blob/main/Detour/Source/DetourNavMeshQuery.cpp ） | 寻路从“查询盒内离点最近的可走多边形”出发；只给水平目标时同样投到最近的可走面 | 起点即身体所在格（`trusted_start`）；travel 段终点取离脚下最近的可站层 | 起点不另找邻格（身体就在那里）；段终点按竖直距离取最近层，同距取低的 |
| Hastie, Tibshirani, Friedman, *The Elements of Statistical Learning*（2nd ed., §2.4）；FAO 灌溉手册第 6 章 Land levelling（https://www.fao.org/4/T0231E/t0231e08.htm ，2026-10-09 查证） | L1 损失的最优解是中位数；土地平整用最小二乘平面并把挖填比调到 1.1–1.5 | 平整目标 = 下中位数 | 见上文取舍（水平目标面、整格、填方花材料） |

**测试（2026-10-09 run06 修复）**：Path 冻结样例 +6（`blocked` 格不可踩不可穿、绕开它；假设起点在 blocked 格里无路；`trusted_start` 在
blocked 格里 / 其上出发、悬空照旧先落地）；`npc_survey_test.exs`（walk_kind、手算小世界的列扫描：花草、水面、细化格、悬空两层、离地一格的悬空、
放置者、净空伸出范围；范围校验；投影与只留 3 次；`stand_y`；strict schema）；`npc_body_world_test.exs` 2 项（面板旁的规划路点不进面板列、
身体在面板格里照常出发）与接缝补 survey；`npc_expand_test.exs` 纯函数（survey 列上的 `site/4`：同高、起伏 2 格取下中位数、62/62/64/64 取 62、
高处的地块按自己的地面、高差 3、无地面、拥挤；`level/2`：挖凸起与花草、填坑与坑里的花草、四种 blocked；`ending/1`；描述）与真实 World 3 项
（8 m 台地 travel 一段到达并经 Body 的 survey 逐列核对；起伏 64/63/62 的地块平整后建成，余额与足迹及周围逐格手算核对，第二次 region_full；走不到的
A、附近只有土的 B 跳过，C 采三格后建成，skipped `%{no_path: 1, insufficient_material: 1}`）；原有“第三次 no_site”与 Settler 的 idle 断言按契约改为
region_full；能力表用例补 survey；npc_skills_test 的自定义技能改名（survey 已是内置条目名）。

**测试（M5 首版）**（`apps/gate_server/test/gate_server/npc_expand_test.exs`、`npc_settler_test.exs`、`npc_registry_test.exs`）：选址纯函数手算小世界
（平地放得下与站位排序、首列 / 别列高一格、足迹上有草、间隔带内有别人放置的格或细化格、外扩一格之外放得下）；规格换算、网格
顺序、分段路点、分块、采石候选的手算用例；strict schema。真实 World：余额 0 的 NPC 连续三次 expand——地块 A（先采石堆两格）、
地块 B（跳过已建的 A，`skipped %{crowded: 1}`）、`no_site`，余额、石堆、邻居的格与地面逐格核对。Settler 多轮：配 expansion 后
第一轮建 A、第二轮维护 A 并建 B、第三轮 no_site；拆掉 A 后下一轮维护把它在原锚点重建，此后只维护。纯函数脚本用例：done 的
新工地进列表并在下一轮被维护、no_site 记 idle。
