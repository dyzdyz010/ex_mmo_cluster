defmodule GateServer.Npc.Brain do
  @moduledoc """
  全局系统功能：NPC 决策后端的可插拔边界。Body 固定，Brain 可换（决策树、LLM、外部分类模型）。

  回调在 Body 进程内同步调用，必须立刻返回：慢后端在 `init/1` 里起自己的进程，事件转发过去，算好后用
  `GateServer.Npc.Body.command/2` 异步投回。返回空命令表 = 保持当前动作；停止必须显式 `:stop`。

  事件与命令都是纯数据（数字、原子、元组、map），不含 pid / ref / 闭包，进程外 adapter 负责自己的序列化。

  ## Observation（每个 OwnerAck 一次，20 Hz）

      %{self: %{entity_id:, tick:, position: {x, y, z}, yaw:, grounded:, processed_input_seq:},
        entities: [%{entity_id:, entity_epoch:, tick:, position:}],   # 各自的 tick，不是同一时刻的快照
        pending: [%{id:, verb:}]}

  ## Command（`id` 由 Brain 给，Outcome 用它对应）

      %{id:, verb: :move_to, position: {x, z}, tolerance: m}   # 直线，无寻路；顶替在途的移动命令
      %{id:, verb: :stop}                                       # 顶替在途的移动命令
      %{id:, verb: :probe_toward, direction: {dx, dy, dz}, tool_id:}
      %{id:, verb: :use_tool, direction:, tool_id:, target:}    # target = probe_toward 返回的 data

  移动命令只影响尚未送出的输入序号；世界事务一旦提交不可顶替、不可撤销。

  ## Outcome

      %{id:, verb:, status: :done | :rejected | :superseded, reason: term | nil, data: map | nil}

  `move_to` / `stop` 的 `:done` = 首个零输入帧已被权威处理，`data` 带同一份 ACK 的 `position` 与
  `within_tolerance`；不代表已停稳。`reason` 是权威返回的原样，Body 不翻译、不重试。
  """

  @callback init(profile :: map) :: state :: term
  @callback handle_event({:observation, map} | {:outcome, map}, state :: term) ::
              {[map], state :: term}
end
