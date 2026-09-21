defmodule GateServer.Npc.Body do
  @moduledoc """
  全局系统功能：NPC 的无 socket 会话 owner。以 NPC cid 走 `Session.Claims` 的完整 claim，自己充当 gate；
  权威状态只在 `Movement.Player`，本进程的位置是 OwnerAck 的派生缓存。

  输入由 OwnerAck 闭环驱动：`due_seq = server_tick - origin_tick + 1`，把已送序号连续补到 `due_seq + 8`；
  已过期未送的序号填零输入，新动作只写未来槽。巡逻路线与到点挖掘写在本进程，无 Brain 抽象。

  世界事务与玩家同一条裁决：`Player.tool_context/2` 取权威 actor，再调 `VoxelRegion.World.tool_intent/3`。
  调用可能长时间阻塞，由本进程旁的 FIFO 执行进程承担，Body 继续送帧；一次只在途一个事务。
  设计见 docs/10-active/cross-cutting/2026-09-21-npc-unified-interface-design.md。
  """
  use GenServer
  alias MmoContracts.{Movement, Session}
  alias SceneServer.Movement.Player

  @lead 8
  @backlog 120
  @arrive_m 0.5
  # 两次攻击之间的 tick 数；服务端按工具 interval 做速率裁决，这里只是不去撞它。
  @attack_gap 36
  @outcomes 32

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "派生缓存与最近的世界事务结果（新在前）；不是世界真值。"
  def observe(body), do: GenServer.call(body, :observe)

  @doc "canonical X/Z 世界轴上的量化输入与朝向；yaw 不驱动移动，0 朝 +X、16384 朝 +Z。"
  def steer({x, _, z}, {tx, tz}) do
    {dx, dz} = {tx - x, tz - z}
    length = :math.sqrt(dx * dx + dz * dz)
    yaw = rem(round(:math.atan2(dz, dx) * 65536 / (2 * :math.pi())) + 65536, 65536)
    {round(dx / length * 32767), round(dz / length * 32767), yaw}
  end

  @doc "已到达当前路点则换下一个（循环）。"
  def advance_route({x, _, z} = position, [{tx, tz} | rest] = route) do
    if :math.sqrt((tx - x) * (tx - x) + (tz - z) * (tz - z)) < @arrive_m,
      do: advance_route(position, rest ++ [{tx, tz}]),
      else: route
  end

  @doc "sent 之后到 due+lead 的连续帧：seq ≤ due 已过期填零输入，其余朝 target。"
  def frames(sent, due, yaw, {axis_x, axis_z, target_yaw}) do
    for seq <- (sent + 1)..(due + @lead)//1 do
      if seq <= due,
        do: %Movement.InputFrame{input_seq: seq, axis_x: 0, axis_z: 0, yaw: yaw, jump_pressed: 0},
        else: %Movement.InputFrame{
          input_seq: seq,
          axis_x: axis_x,
          axis_z: axis_z,
          yaw: target_yaw,
          jump_pressed: 0
        }
    end
  end

  @impl true
  def init(opts) do
    # cid 来自 characters 表的 NPC 行（DataService.CharacterStore.ensure_npc/1），永久且不复用。
    cid = Keyword.fetch!(opts, :cid)
    [first, _ | _] = route = Keyword.fetch!(opts, :route)

    # 相邻路点（含回环）间距大于到达半径的两倍，advance_route/2 才必然终止。
    true =
      route
      |> Enum.zip(tl(route) ++ [first])
      |> Enum.all?(fn {{ax, az}, {bx, bz}} ->
        :math.sqrt((bx - ax) * (bx - ax) + (bz - az) * (bz - az)) > 2 * @arrive_m
      end)

    {:ok,
     %{
       cid: cid,
       route: route,
       # 显式出生点：不占玩家 probe 名额。
       spawn: Keyword.fetch!(opts, :spawn),
       claims: Keyword.get(opts, :claims, GateServer.Session.Claims),
       scene: Keyword.get(opts, :scene_module, SceneServer.Movement.Scene),
       router: Keyword.get(opts, :route_module, WorldServer.Movement),
       scene_id: Keyword.fetch!(opts, :scene_id),
       # 到达路点后朝该方向探测并挖掉命中的目标：%{direction: {dx, dy, dz}, tool_id: id} | nil。
       dig: Keyword.get(opts, :dig),
       identity: nil,
       player: nil,
       world_ref: nil,
       worker: nil,
       origin: nil,
       sent: 0,
       yaw: 0,
       position: nil,
       tick: 0,
       work: nil,
       request_seq: 0,
       outcomes: []
     }, {:continue, :claim}}
  end

  @impl true
  def handle_continue(:claim, state) do
    {:ok, route} = state.router.route(state.scene_id)

    {identity, {:ok, player}} =
      GenServer.call(
        state.claims,
        {:claim, state.scene, Map.put(route, :scene_id, state.scene_id),
         %{id: state.cid, spawn: state.spawn}}
      )

    Process.monitor(player)
    # 只用于置 clock_ready；送帧不依赖本地时钟映射。
    Player.time_probe(player, identity, %Session.TimeProbe{request_id: 1, client_send_us: 0})
    {:noreply,
     %{
       state
       | identity: identity,
         player: player,
         world_ref: Map.get(route, :world_ref),
         worker: spawn_link(&world_calls/0)
     }}
  end

  @impl true
  def handle_call(:observe, _, state),
    do: {:reply, Map.take(state, [:position, :tick, :work, :outcomes]), state}

  @impl true
  def handle_info(
        {:mmo_reliable, identity, 1, %Session.SessionStart{} = start},
        %{identity: identity} = state
      ) do
    # 内部会话就绪：无头 Body 不建体素镜像，只回 baseline。
    Player.ready(
      state.player,
      identity,
      start.baseline_transaction_seq,
      start.collision_revision
    )

    {:noreply, state}
  end

  def handle_info(
        {:mmo_reliable, identity, 1, %Session.InputStart{first_input_seq: 1} = start},
        %{identity: identity} = state
      ),
      do: {:noreply, feed(%{state | origin: start.origin_tick}, start.state, start.anchor_tick)}

  def handle_info(
        {:mmo_datagram, identity, %Movement.OwnerAck{} = ack},
        %{identity: identity, origin: origin} = state
      )
      when origin != nil do
    due = ack.server_tick - origin + 1

    if due - ack.processed_input_seq > @backlog,
      do: {:stop, {:input_backlog, due, ack.processed_input_seq}, state},
      else: {:noreply, feed(state, ack.state, ack.server_tick)}
  end

  def handle_info({:npc_world_result, id, result}, %{work: {_, id, _}} = state),
    do: {:noreply, world_result(state, result)}

  def handle_info({:mmo_close, identity, reason}, %{identity: identity} = state),
    do: {:stop, {:session_closed, reason}, state}

  # 第一片路线必须留在当前 authority 内。
  def handle_info({:mmo_transfer_request, identity, _, target}, %{identity: identity} = state),
    do: {:stop, {:unexpected_transfer, target}, state}

  def handle_info({:DOWN, _, :process, player, reason}, %{player: player} = state),
    do: {:stop, {:player_down, reason}, state}

  def handle_info(_, state), do: {:noreply, state}

  defp feed(state, %Session.State{position: position}, server_tick) do
    due = max(0, server_tick - state.origin + 1)
    state = %{state | position: position, tick: server_tick} |> work()
    route = if state.work, do: state.route, else: advance_route(position, state.route)
    arrived = route != state.route

    {_, _, yaw} =
      steering =
      cond do
        state.work != nil or (arrived and state.dig != nil) -> {0, 0, dig_yaw(state)}
        true -> steer(position, hd(route))
      end

    frames = frames(state.sent, due, state.yaw, steering)

    # 与玩家解码器同一批约束：每批 1..6 帧、序号严格递增；相邻差 1 由 frames/4 保证。
    for batch <- Enum.chunk_every(frames, 6),
        do:
          Player.input(state.player, state.identity, %Movement.InputBatch{
            identity: state.identity,
            frames: batch
          })

    state = if arrived and state.dig != nil, do: request(state, 0, nil), else: state

    case frames do
      [] -> %{state | route: route}
      _ -> %{state | route: route, sent: List.last(frames).input_seq, yaw: yaw}
    end
  end

  defp dig_yaw(%{dig: %{direction: {dx, _, dz}}}),
    do: rem(round(:math.atan2(dz, dx) * 65536 / (2 * :math.pi())) + 65536, 65536)

  # 冷却到期后重新探测：目标还是同一个才继续攻击。
  defp work(%{work: {:cooldown, until, target}, tick: tick} = state) when tick >= until,
    do: request(state, 0, target)

  defp work(state), do: state

  # action 0 = 沿方向探测实际命中；action 1 = 攻击探测返回的那个目标身份。
  defp request(state, action, target) do
    seq = state.request_seq + 1

    request =
      %{
        request_id: seq,
        client_intent_seq: seq,
        logical_scene_id: state.scene_id,
        action: action,
        direction: state.dig.direction,
        micro: {0, 0, 0},
        incarnation: 0,
        owner: {0, 0},
        material: 0,
        tool_id: state.dig.tool_id,
        granularity: 0
      }
      |> Map.merge(if(action == 1, do: identity_of(target), else: %{}))

    true = MmoContracts.Voxel.Codec.tool_intent?(request)
    send(state.worker, {:call, self(), seq, state.player, state.identity, state.world_ref, request})
    kind = if action == 0, do: :probing, else: :attacking
    %{state | request_seq: seq, work: {kind, seq, target}}
  end

  defp identity_of(target), do: Map.take(target, [:micro, :incarnation, :owner, :material])

  defp world_result(%{work: {:probing, _, previous}} = state, {:ok, %{} = target}) do
    if previous == nil or identity_of(previous) == identity_of(target),
      do: request(state, 1, target),
      else: outcome(state, :probe, :done, :target_gone)
  end

  defp world_result(%{work: {:probing, _, nil}} = state, {:error, reason}),
    do: outcome(state, :probe, :rejected, reason)

  defp world_result(%{work: {:probing, _, _}} = state, {:error, _}),
    do: outcome(state, :probe, :done, :target_gone)

  defp world_result(%{work: {:attacking, _, target}} = state, {:ok, seq}) do
    state = outcome(state, :use_tool, :done, seq)
    %{state | work: {:cooldown, state.tick + @attack_gap, target}}
  end

  defp world_result(%{work: {:attacking, _, _}} = state, {:error, reason}),
    do: outcome(state, :use_tool, :rejected, reason)

  # 权威返回的 reason 原样记录，不翻译、不重试；记下后回到巡逻。
  defp outcome(state, verb, status, detail) do
    entry = %{verb: verb, status: status, detail: detail, tick: state.tick}
    %{state | work: nil, outcomes: Enum.take([entry | state.outcomes], @outcomes)}
  end

  defp world_calls do
    receive do
      {:call, body, id, player, identity, world_ref, request} ->
        result =
          with {:ok, actor} <- Player.tool_context(player, identity) do
            actor =
              Map.merge(actor, %{
                received_us: System.monotonic_time(:microsecond),
                clock_node: node()
              })

            VoxelRegion.World.tool_intent(world_ref, actor, request)
          end

        send(body, {:npc_world_result, id, result})
        world_calls()
    end
  end
end
