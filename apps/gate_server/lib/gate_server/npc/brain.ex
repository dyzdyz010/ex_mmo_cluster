defmodule GateServer.Npc.Brain do
  @moduledoc """
  全局系统功能：NPC 决策后端的可插拔边界。Body 固定，Brain 可换（决策树、LLM、外部分类模型）。

  通用角色使用一个 `Brain.Llm`，拥有全部原子动词；长任务是 `profile.skills` 提供的工具，
  在独立 worker 中运行并只回一个最终 Outcome。荒野施工复用 Builder 的纯状态机，
  不启动第二个决策大脑。运行期间由父大脑调用 Jev；活动、判据、优先级均来自 profile。
  记忆工具直接读写 NpcMemory，最近经历每次现读；进度与动手依据始终由 World 现查。

  回调在 Body 进程内同步调用，必须立刻返回：慢后端在 `init/1` 里起自己的进程，事件转发过去，算好后用
  `GateServer.Npc.Body.command/2` 异步投回。返回空命令表 = 保持当前动作；停止必须显式 `:stop`。

  事件与命令都是纯数据（数字、原子、元组、map），不含 pid / ref / 闭包，进程外 adapter 负责自己的序列化。

  ## Observation（每个 OwnerAck 一次，20 Hz）

      %{self: %{entity_id:, tick:, position: {x, y, z}, yaw:, grounded:, processed_input_seq:},
        entities: [%{entity_id:, entity_epoch:, kind:, tick:, position:}],   # kind 0 = 玩家、1 = NPC；各自的 tick
        balances: [%{material:, balance:, cost:, seq:}] | nil,        # 自己的背包；nil = 还没取过
        pending: [%{id:, verb:}]}

  `balances` 是 World 余额表的原样副本，在 `query_balances` 与自己的每次世界事务之后重取；`cost` = 放置一个 macro 格
  要花的单位数。地形不进 Observation，要看就发 `look`。

  ## Command（`id` 由 Brain 给，Outcome 用它对应）

      %{id:, verb: :move_to, position: {x, z}, tolerance: m}   # 寻路走过去；顶替在途的移动命令；可选 y: 站立格（整数）
      %{id:, verb: :stop}                                       # 顶替在途的移动命令
      %{id:, verb: :probe_toward, direction: {dx, dy, dz}, tool_id:}
      %{id:, verb: :use_tool, direction:, tool_id:, target:}    # target = probe_toward 返回的 data
      %{id:, verb: :place, coord: {x, y, z}, material:, tool_id:}   # 花自己的余额放一个 macro 格
      %{id:, verb: :scoop | :pour, coord:, material:, tool_id:}     # 液体盛取 / 倾倒，工具须是对应的液体工具
      %{id:, verb: :attach, kind:, axis:, size:, anchor: {x, y, z}, material:, tool_id:}   # anchor 是 micro 坐标
      %{id:, verb: :detach, kind:, axis:, size:, anchor:, material:, tool_id:, attachment_id:}
      %{id:, verb: :prefab_place, definition_id: <<32 字节>>, anchor: {x, y, z}, orientation: 0..23}   # anchor 是 micro 坐标
      %{id:, verb: :prefab_remove, instance_id: {birth, occurrence}}
      %{id:, verb: :prefab_replace, instance_id:, definition_id:}   # prefab：所有角色可用，格在部署的编辑盒内，与玩家相同
      %{id:, verb: :query_balances}
      %{id:, verb: :look, min: {x, y, z}, max: {x, y, z}}       # macro 格闭区间，≤ 512 格，各边离自己 ≤ 32 m
      %{id:, verb: :inspect}                                     # 周围 3×3×3 个 tile 内的附件与 prefab 构件
      %{id:, verb: :say, text:}                                  # 聊天占位：正式栈还没有聊天，恒被拒 :chat_unavailable

  工具的行为由属性目录里该 `tool_id` 的 action 决定：挖掘、点火 / 灭火、加热 / 冷却、电路安装 / 投料 / 开关都是
  `use_tool` 换一个 `tool_id`，不是各自的动词。电路工具的目标是附件：`target` 给
  `%{granularity: 3, micro: anchor, incarnation: id, owner: {id, kind * 3 + axis}, material:}`，按身份寻址、不经射线。
  `coord` / `look` 是 canonical macro 格（1 格 = 1 m，Y 向上）；附件与 prefab 的 `anchor` 是 micro 坐标（1 格 = 8 micro），
  与玩家的线请求相同。

  移动命令只影响尚未送出的输入序号；世界事务一旦提交不可顶替、不可撤销。

  ## 寻路（Body 内置的系统机制，Brain 不参与）

  `move_to` 起步时 Body 经 `World.material_snapshot/3` 取一盒地形（起终点包围盒外扩 6 格），交给纯模块
  `SceneServer.Movement.Path`：4 邻接、平走 / 上 `step_height` 以内的台阶 / 下落任意高度、不起跳、液体与细化格不可过；
  同层净空的路段拉直。算完即弃，不留体素副本。单程水平超过 32 m → `:too_far`（不问 World）；盒内无路 → `:no_path`；
  路是起步那一刻的世界算的，途中 3 秒挪不动 → `:stuck`。三者都是 `:rejected`，Body 不重试，由 Brain 决定（再发一次
  `move_to` 就按当时的世界重算）。同一列有多层可站时用 `y`（脚所在的空气格）选层，不给则取最先到达的那层。
  拐弯、换层和到达前 Body 会夹零输入帧限速，所以走楼梯比走平地慢。

  ## Outcome

      %{id:, verb:, status: :done | :rejected | :superseded, reason: term | nil, data: map | nil}

  `move_to` / `stop` 的 `:done` = 首个零输入帧已被权威处理，`data` 带同一份 ACK 的 `position` 与
  `within_tolerance`；不代表已停稳。`reason` 是权威返回的原样，Body 不翻译、不重试。
  世界事务的 `data`：`probe_toward` 是目标身份，`use_tool` 与各建造动词是 `%{seq:}`，
  `query_balances` 是 `%{balances:}`，`look` 是 `World.material_snapshot/3` 的原样（`probe_occupancy` 逐格
  `%{cell:, material:, refined:, slots:, placed_by:}`，material 0 且 refined=false 才是空气；`placed_by` = 花材料放下这一格的角色 cid，
  天然地形、作者写入的格、被别的编辑改过的格是 nil）；`inspect` 是 `%{seq:, property_states:}`，取自
  `World.simulation_snapshot/3`：granularity 3 的行是附件（原样可作 `use_tool` 的 `target`，`incarnation` 即 `detach` 的
  `attachment_id`），granularity 2 的行是 prefab 构件（`owner` 即 `instance_id`）。

  ## 聊天（占位）

  事件 `{:heard, %{entity_id:, text:}}` 与命令 `say` 是为玩家聊天预留的形状；正式栈接入聊天之前不会有 `:heard` 事件。
  """

  @callback init(profile :: map) :: state :: term
  @callback handle_event({:observation, map} | {:outcome, map} | {:heard, map}, state :: term) ::
              {[map], state :: term}
end
