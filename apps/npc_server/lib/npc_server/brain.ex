defmodule NpcServer.Brain do
  @moduledoc """
  全局系统功能：NPC 决策后端的可插拔边界。Body 固定，Brain 可换（决策树、LLM、外部分类模型）。

  所有后端由 `Runtime` 组合，拥有同一组原子动作、技能与记忆命令。现有后端：`Brain.Llm`、`Brain.Routine`、`Brain.Patrol`、
  行为树 `Brain.Tree`（树定义在 `NpcServer.Trees`）。
  长任务来自 `profile.skills`，由 Runtime 的独立 worker 执行并只回一个最终 Outcome。
  荒野施工驱动 Builder 纯状态机。中断检查只由 `interrupt_policy` 开启；不配置时不调用外部调度模型。
  记忆读写经 Memory，进度与动手依据始终由 World 现查。
  输入规范见 docs/10-active/cross-cutting/2026-09-22-npc-context-memory-contract.md。

  回调在 Runtime 进程内同步调用，必须立刻返回。慢后端在 `init/1` 保存调用者 self() 作为命令接收端，
  起自己的进程处理事件，算好后用 `NpcServer.Body.command/2` 异步投回该接收端。
  返回空命令表 = 保持当前动作；停止必须显式 `:stop`。每个调用 id 在本次 Runtime 生命周期中唯一，
  `{:skill, call_id, step_id}` 保留给技能内部命令。不得从后端私自穿透 Runtime 取得 Body/World。

  ## 共用技能与记忆命令

      %{id:, verb: :skill, skill: :build, args: %{"definition" => hex, "anchor_micro" => [x,y,z], "orientation" => 0}}
      %{id:, verb: :skill, skill: :gather, args: %{"box" => [[x0,y0,z0],[x1,y1,z1]], "material" => m, "units" => n, "tool_id" => t}}
      %{id:, verb: :skill, skill: :expand, args: %{"definition" => hex, "region" => [[x0,z0],[x1,z1]], "tool_id" => t, "spacing" => n}}
      %{id:, verb: :skill, skill: :travel, args: %{"x" => x, "z" => z}}
      %{id:, verb: :cancel_skill, call: 原技能调用号}
      %{id:, verb: :remember, key:, text:}
      %{id:, verb: :recall, key:}
      %{id:, verb: :search_memory, query:}

  参数契约由 `NpcServer.Abilities` 给出（技能条目的 schema 原样取自技能的 `definition/1`）；Skills 的每个模块实现 Skill behaviour。
  技能终态的 verb 是所调用的技能名。取消命令有自己的 Outcome：受理为 done（data.call），没有对应在途技能为
  no_active_skill；被取消的技能仍以原调用号回终态。取消等待 worker DOWN，再等带 settle 的 Body.stop：
  移动停稳且该调用已投递的世界调用都有了结果；期间落定的结果放在终态 data.settled，已提交事务不撤销，
  stop 失败明确返回 stop_failed。
  Body.observe 可读取技能终态。首个正式 Observation 前的技能和记忆调用回报 invalid_session。

  事件与命令都是纯数据（数字、原子、元组、map），不含 pid / ref / 闭包，进程外 adapter 负责自己的序列化。

  ## Observation（每个 OwnerAck 一次，20 Hz）

      %{self: %{entity_id:, tick:, position: {x, y, z}, yaw:, grounded:, processed_input_seq:, body:, body_state:, caster:},
        entities: [%{entity_id:, entity_epoch:, kind:, name:, relation:, relation_source:, tick:, position:}],
        balances: [%{material:, balance:, cost:, seq:}] | nil,        # 自己的背包；nil = 还没取过
        pending: [%{id:, verb:}]}

  `balances` 是 World 余额表的原样副本，在 `query_balances` 与自己的每次世界事务之后重取；`cost` = 放置一个 macro 格
  要花的单位数。地形不进 Observation，要看就发 `look`。
  `self.body` 由权威 Session profile 经 Context.body/1 投影：完整身高、半高、半径、直径、速度、
  加减速与台阶高度，字段显式标注米/秒；设计净空与 Body 宏格寻路限制分别列出。
  `self.body_state` 是本人身体的推导视图（与玩家 HUD 同一条 Session.BodyState 下行，字段原样）：
  `%{life:, recoverable:, status:, core_k:, skin_k:, protein_g:, injuries: [%{tag:, severity:, heal:, remaining_s:}]}`，
  life / recoverable 0..100，status 0 存活 / 1 濒死 / 2 死亡；nil = 本会话还没收到（会话丢失后重新入场前也是 nil）。
  真值在 Scene 的身体 owner，这里是派生缓存；无热环境的世界不推进身体，只在入场与受伤时更新。
  `self.caster` 是最近一次施法回复里的施法者状态 `%{energy_j:, capacity_j:, coherence:}`（与玩家 0x83 同一来源），
  nil = 还没施过法；真值在 World，跨会话保留这份缓存（World 按 cid 记账）。
  `entities` 的 kind 0 = 玩家、1 = NPC，各自带 tick；`name`（无名为空串）、`relation`（`MmoContracts.Relation.code/1`：
  0 中立、1 自己、2 同属、3 友好、4 敌对，按本角色这个观察者算）、`relation_source`（来源文字，与玩家名牌悬停相同）
  取自 EntityEnter，保留到 Leave 或换代；Snapshot 只更新位置。关系只回答敌我颜色，不回答能否攻击。

  ## Command（`id` 由 Brain 给，Outcome 用它对应）

  下面是 Body / Runtime 受理的规范命令，形状只在这里定义。JSON 形参数的后端（LLM、design_house 的共享工具、行为树）
  经 `NpcServer.Abilities.command/4` 构造这些命令（一份参数规格同时生成 strict schema 与译码）；代码写的后端直接产出。

  观察与目标的能力条目在 `Attention.entries/0`（经 Abilities 投影）；同一组命令供所有后端调用。
  Observation 的 `view` 给出眼点、独立观察方向、最远距离和视锥半角；`targets` 给出 enemy/friendly 组与 mark。
  `get_view` / `look_at` / `get_aim` / `get_visible_entities` / `get_target_status` 与
  `select_target` / `remove_target` / `get_targets` / `set_focus` / `cycle_focus` / `remove_focus` /
  `clear_targets` / `toggle_mark` 不改变移动或攻击。目标参数为 `%{entity_id:, entity_epoch:}`，group 为 :enemy/:friendly。
  `look_at` 接 `position: {x,y,z}` 或 `target`，一次转向，不持续跟踪；`cycle_focus` 的 direction 为 ±1。
  视野角色以中心点采样，不枚举地形；`get_aim` 返回最近胶囊或 canonical 方块／构件命中、点、距离和属性。
  角色尺寸沿用当前场景的已发布移动 profile；独立附件未采样。查询范围不是攻击范围，关注组不是阵营真值。
  World 查询结果携带 self_tick/entity_tick/world_seq；这些是独立 owner 的采样版本，不是跨 owner 原子快照。
  AOI 离开／代次替换／场景转移清理选择；旧身份选择拒绝 stale_target，查询状态返回 valid:false。

      %{id:, verb: :move_to, position: {x, z}, tolerance: m}   # 寻路走过去；顶替在途的移动命令；可选 y: 站立格（整数）
      %{id:, verb: :stop}                                       # 顶替在途的移动命令；settle: 技能调用号 见上文取消
      %{id:, verb: :probe_toward, direction: {dx, dy, dz}, tool_id:}   # 可选 target: %{granularity: 5, owner: {cid, 0}} 探测人物
      %{id:, verb: :use_tool, direction:, tool_id:, target:}    # target = probe_toward 返回的 data；direction 可省（见下）
      %{id:, verb: :dismantle, direction:, tool_id:, target:}   # 拆解 prefab 构件，按剩余燃料退料；direction 可省
      %{id:, verb: :place, coord: {x, y, z}, material:, tool_id:}   # 花自己的余额放一个 macro 格
      %{id:, verb: :scoop | :pour, coord:, material:, tool_id:}     # 液体盛取 / 倾倒，工具须是对应的液体工具
      %{id:, verb: :craft, material:}                            # 按目录配方合成 material 一次
      %{id:, verb: :eat, material:}                              # 吃一株可食材料（一株 = 目录 place_units）
      %{id:, verb: :attach, kind:, axis:, size:, anchor: {x, y, z}, material:, tool_id:}   # anchor 是 micro 坐标
      %{id:, verb: :detach, kind:, axis:, size:, anchor:, material:, tool_id:, attachment_id:}
      %{id:, verb: :prefab_place, definition_id: <<32 字节>>, anchor: {x, y, z}, orientation: 0..23}   # anchor 是 micro 坐标
      %{id:, verb: :prefab_remove, instance_id: {birth, occurrence}}
      %{id:, verb: :prefab_replace, instance_id:, definition_id:}   # prefab：所有角色可用，格在部署的编辑盒内，与玩家相同
      %{id:, verb: :query_balances}
      %{id:, verb: :look, min: {x, y, z}, max: {x, y, z}}       # macro 格闭区间，≤ 512 格，各边离自己 ≤ 32 m
      %{id:, verb: :survey, min: {x, z}, max: {x, z}}           # 地表高度图：列闭区间每边 ≤ 32 列、离自己 ≤ 32 m，竖直自己上下 32 m
      %{id:, verb: :inspect}                                     # 周围 3×3×3 个 tile 内的附件与 prefab 构件
      %{id:, verb: :read_catalog, what: :prefab | :prefabs | :materials | :tools, definition: <<32 字节>> | nil}
                                                                 # 读目录；:prefab 必须给 definition，其余为 nil
      %{id:, verb: :cast_spell, program: <<程序字节>>, target:, direction:}   # 0x82 施放；target 同 use_tool 的句柄（g0–g2）；direction 可省
      %{id:, verb: :cancel_cast}                                 # 取消在前摇的施法（同一 client_intent_seq 的 0x82 action 2）
      %{id:, verb: :genesis_edit, edits: [{{x, y, z}, material}]}   # 创世：只有启动选项 genesis: true 的 Body 受理（见下）
      %{id:, verb: :say, text:, target_id: 0, conversation_id: 0}  # 附近公开说话；0 表示未指定对象 / 新话题

  工具的行为由属性目录里该 `tool_id` 的 action 决定：挖掘、点火 / 灭火、加热 / 冷却、电路开关都是
  `use_tool` 换一个 `tool_id`，不是各自的动词。电路开关的目标是附件：`target` 给
  `%{granularity: 3, micro: anchor, incarnation: id, owner: {id, kind * 3 + axis}, material:}`，按身份寻址、不经射线。
  `coord` / `look` 是 canonical macro 格（1 格 = 1 m，Y 向上）；附件与 prefab 的 `anchor` 是 micro 坐标（1 格 = 8 micro），
  与玩家的线请求相同。世界写命令由 `NpcServer.WorldRequest` 拼成玩家线帧的同形请求，经与玩家相同的
  `SceneServer.Movement.Intent.run/3` 裁决（死亡、施法中、重放、同 key 结果、射程、余额等拒绝原样回报）。
  `use_tool` / `dismantle` 不给 `direction` 时由 Body 按目标句柄从眼点瞄准（`WorldRequest.aim/2`：g0 宏格中心、
  g1 / g2 micro 中心、g3 任意方向、g5 句柄里探测时的方向）；位置还未知时回 `invalid_session`。
  人物目标（g5）的合法性只由权威的战斗范围裁决，正式世界一律拒绝。

  施法与玩家同一个角色 owner 入口 `Player.cast_spell/5`（不经 Intent，前摇由 Player 推进；只在流送 Scene 可用）。
  `program` 是 0x82 的程序字段（UTF-8 JSON），经 Abilities 时由作者法术带 `profile.spells`（`%{名字 => 程序字节}`）按名字
  填入，LLM 只选名字；目录 digest 由 Body 的执行进程投递前经 `World.magic_digest/1` 填入。前摇期间工具与非工具世界意图
  回 `casting`，再施放回 `cast_too_soon`；同一角色同时只有一个前摇，`cancel_cast` 取消的是它。

  创世编辑 `genesis_edit`（能力组 `:genesis`，`NpcServer.Genesis`）：`edits` 是 macro 格与材料（0 = 空气），交给
  `World.apply_edits/3`（主体 `{:genesis, cid}`；不扣料、不记 placed_by、不查射程，受保护区约束 → `protected_region`）。授予只来自
  注册表行（`NpcServer.Registry`）：Body 启动选项 `genesis: true` 才受理，否则 `not_permitted`；每次 1..4096 格、
  整数格与目录合法材料，否则 `invalid_command`；任一格某轴离自己超过 32 m → `too_far`；编辑盒外 → `out_of_bounds`。

  移动命令只影响尚未送出的输入序号；世界事务一旦提交不可顶替、不可撤销。

  ## 寻路（Body 内置的系统机制，Brain 不参与）

  `move_to` 起步时 Body 经 `World.material_snapshot/3` 取一盒地形（起终点包围盒外扩 6 格，竖直从脚所在格到 `y` 再上下外扩
  6 格；不给 `y` 时只有脚下上下 6 格，高差更大的目标要给 `y`），交给纯模块 `SceneServer.Movement.Path`：4 邻接、平走 /
  上 `step_height` 以内的台阶 / 下落任意高度、不起跳；液体与细化格既不能穿过也不能踩（细化格按整格挡住，不站在 micro 构件
  上面）；身体当前所在的格总能出发（站在细化格空着的部分里也一样）。同层净空的路段拉直。算完即弃，不留体素副本。单程水平超过 32 m，或给了 `y` 且与脚所在格相差超过 32 格
  → `:too_far`（不问 World）；盒内无路 → `:no_path`；
  路是起步那一刻的世界算的，途中 3 秒挪不动 → `:stuck`。三者都是 `:rejected`，Body 不重试，由 Brain 决定（再发一次
  `move_to` 就按当时的世界重算）。同一列有多层可站时用 `y`（脚所在的空气格）选层，不给则取最先到达的那层。
  拐弯、换层和到达前 Body 会夹零输入帧限速，所以走楼梯比走平地慢。

  ## Outcome

      %{id:, verb:, status: :done | :rejected | :superseded, reason: term | nil, data: map | nil}

  `move_to` / `stop` 的 `:done` = 首个零输入帧已被权威处理且身体停稳（权威速度 ≤ 0.05 m/s，含落地；最多再等 1 秒），
  `data` 带同一份 ACK 的 `position`、`within_tolerance` 与 `settled`（false = 1 秒内没停稳，如在坡上被推着）。`reason` 是权威返回的原样，Body 不翻译、不重试。
  世界事务的 `data`：`probe_toward` 是目标身份加本次 `direction`（原样可作 `use_tool` 的 `target`）；探测人物（g5）时是
  `%{granularity: 5, owner: {cid, 0}, incarnation: 目标生命代次, micro: {0,0,0}, material: 0, direction:}` 加人物回执字段
  （`source_id`、`target_id`、`target_life`、`part`、`life`、`recoverable` 等，与玩家下行 ToolState 同一投影）；
  对人物 `use_tool` 的 `data` 是同一份人物回执；其余 `use_tool`、各建造动词与 `genesis_edit` 是 `%{seq:}`，
  `query_balances` 是 `%{balances:}`，`look` 是 `World.material_snapshot/4` 的精确投影（`probe_occupancy` 逐格
  `%{cell:, material:, refined:, slots:, placed_by:}`，material 0 且 refined=false 才是空气；`placed_by` = 花材料放下这一格的角色 cid，
  天然地形、作者写入的格、被别的编辑改过的格是 nil；`slots` 逐个 prefab 实例 `%{material:, instance:, count:, placed_by:}`，
  `placed_by` 是放下这个实例的角色，作者放置与旧实例为 nil）；细化行额外给 `micro_cells` 精确世界 micro 坐标、材质与归属（Body 的 Outcome 原样；给 LLM 的投影换成按材质合并的 `micro_boxes`，见 `Perception.compact_refined/1`）。
  `survey` 是 `%{seq: [首片, 末片], bounds_columns_inclusive: [[x0, z0], [x1, z1]], scanned_y: [y0, y1], clearance:, outside: :unknown,
  columns: [%{column: [x, z], floors: [y], y:, material:, placed_by:, refined:}]}`（`Perception.surfaces/2`：`floors` 是这一列站得下的
  地面层，地表 `y` 是最高的一层，没有为 nil；`refined` = 这一列扫描范围里有细化格；给 LLM 的投影换成按行的高度图）。
  感知额外返回采样边界与版本；窗口外未知、未采样附件不是空。`inspect` 是 `%{seq:, property_states:}`，取自
  `World.simulation_snapshot/3`：granularity 3 的行是附件（原样可作 `use_tool` 的 `target`，`incarnation` 即 `detach` 的
  `attachment_id`），granularity 2 的行是 prefab 构件（`owner` 即 `instance_id`）。
  `read_catalog` 只读 World 的公共目录（单位与余额相同，都是微格体积单位）：
  `:prefab` 是 `%{definition_id:, materials: %{material => units}, size_m: [x, y, z], bounds_micro: [[x0, y0, z0], [x1, y1, z1]]}`
  （bounds_micro 是朝向 0 时相对锚点的 micro 半开包围盒；作者目录与运行时发布都查得到，
  没有这个 id 回 `definition_not_found`）；`:prefabs` 是 `%{prefabs: [%{definition_id:, name:, publisher:, materials:}], total:}`
  （最近 20 条运行时发布，新在前；不含作者目录）；`:materials` 是
  `%{materials: [%{material:, name:, edible: %{protein_g:, energy_j:} | nil, recipe: %{inputs: %{material => units}, units:} | nil}]}`
  （列全部材料；edible 是一株 = 一次 `eat` 的营养，recipe 是一次 `craft` 扣的输入与得到的产物单位，两者只对本世界的
  生产材料给出，与 World 进食 / 合成门一致：非 nil 时 `eat` / `craft` 不会因 `not_edible` / `unknown_recipe` 被拒，
  余额不足照常回 `insufficient_material`）；`:tools` 是
  `%{tools: [%{tool_id:, action:, range_m:, interval_s:}]}`。
  `cast_spell` 的 `:done` = 前摇结束且 World 已结算，`data` 是 World 回复原样 `%{seq:, outcome:, caster:}`：`outcome` 为
  nil 是正常施放，`:misfire_energy` / `:misfire_coherence` 是走火（同样是已提交事务）；`caster` 是结算后的
  `%{seq:, energy_j:, capacity_j:, coherence:, quote_j:, quote_s:, spent_j:, quote_windup_s:}`。拒绝原样来自权威
  （`cast_too_soon`、`dead`、`out_of_domain`、`stale_target`…）；前摇中被 `cancel_cast` 或 `Player.stop/1` 撤销回
  `cast_cancelled`，会话丢失回 `session_lost`（Body 先察觉）或 `invalid_session`（World 先察觉），每次施法恰好一个终态，
  `session_lost` 不保证未结算。`cancel_cast` 的 `:done` data 为 `%{}`；没有待施法回 `no_active_cast`，前摇已结束回
  `already_released`（原样来自 Player）。

  ## 对话

  `say` 经 Body 的异步 FIFO 执行进程调用 `Scene.say/3`，统一 Outcome；done 只代表权威接纳并排入可靠出口，
  不表示听者理解、答应或已持久记住。`request_id` 由 Body 单调分配，与任意 term 的命令 id 无关，不自动重试。
  Scene 公共调用超时或退出回 `status: :rejected, reason: :delivery_unknown`：这里只表示调用未获成功确认，
  不能当作 Scene 已裁定拒绝，也不保证未产生 Speech；Body 不重发或退出，已收到的权威 Speech 仍如实进入上下文/记忆。
  target_id=0 向附近公开说；指定对象仍会被附近其他角色听到；conversation_id=0 开新话题，否则引用实际收到的会话。

  Runtime 的 `{:dialogue, [speech]}` 和 Observation.heard 是按权威接收顺序排列的最近 24 句，含本人回声；
  speech 为 `%{conversation_id:, turn:, speaker_id:, speaker_epoch:, speaker_kind:, speaker_name:, target_id:, at_ms:, text:}`。
  只有他人直接 target_id 指向本角色时才另投 `{:heard, speech}` 唤醒与检查技能中断；旁听与本人回声只更新尾部。
  尾部不随技能开始/结束清空。Llm 将其放入独立 input.heard，不写入 instructions；原话是不可信角色声明。
  Routine / Patrol / Tree / Social 没有语言决策，忽略 dialogue/heard，保留自己的在途工作。
  """

  @type command :: %{
          required(:id) => term(),
          required(:verb) => atom(),
          optional(atom()) => term()
        }
  @type outcome :: %{
          id: term(),
          verb: atom(),
          status: :done | :rejected | :superseded,
          reason: term(),
          data: map() | nil
        }
  @type event ::
          {:observation, map()} | {:outcome, outcome()} | {:heard, map()} | {:dialogue, [map()]}
  @callback init(profile :: map()) :: state :: term()
  @callback handle_event(event(), state :: term()) :: {[command()], state :: term()}
end
