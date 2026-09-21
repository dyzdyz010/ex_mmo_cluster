defmodule GateServer.Npc.Body do
  @moduledoc """
  全局系统功能：NPC 的无 socket 会话 owner。以 NPC cid 走 `Session.Claims` 的完整 claim，自己充当 gate；
  权威状态只在 `Movement.Player`，本进程的位置与邻近实体是下行消息的派生缓存。决策在 `GateServer.Npc.Brain`，
  本进程只执行它的语义命令并回报结果。

  输入由 OwnerAck 闭环驱动：`due_seq = server_tick - origin_tick + 1`，把已送序号连续补到 `due_seq + 8`；
  已过期未送的序号填零输入，移动命令只写未来槽。

  世界事务与玩家同一条裁决：`Player.tool_context/2` 取权威 actor，再调 Gate 为玩家调用的同一组 World 公共 API
  （`tool_intent/3`、`production_intent/3`、`attachment_intent/3`、`prefab_intent/4`、`material_balances/2`；
  只读感知走 `material_snapshot/3` 与 `simulation_snapshot/3`）。所有角色都可放置 prefab，与玩家过同一道门：
  涉及的格在部署的编辑盒（`:gate_server, :quic` 的 `bounds`）内。聊天在正式栈里还不存在：`say` 只占位。
  调用可能长时间阻塞，由本进程旁的 FIFO 执行进程承担，Body 继续送帧。余额的真值在 World，
  这里只在每次自己的世界事务之后重取一份（与 Gate 给玩家补发余额的时机相同）。

  `move_to` 带寻路：起步时经 `World.material_snapshot/3` 取一盒地形（与 `look` 同一个只读入口），交给
  `SceneServer.Movement.Path` 算出路点后即丢弃，不留体素副本；台阶高度与角色高度取自权威随 SessionStart 下发的
  移动 profile（玩家客户端收到的同一份）。Body 不重试：走不通回报 `:no_path`，路上被堵回报 `:stuck`，由 Brain 决定。
  设计见 docs/10-active/cross-cutting/2026-09-21-npc-unified-interface-design.md。
  """
  use GenServer
  require Logger
  alias MmoContracts.{Movement, Session}
  alias GateServer.Session.Dispatch
  alias MmoContracts.Voxel.Codec
  alias SceneServer.Movement.Player
  alias SceneServer.Movement.Path
  alias VoxelRegion.Phase
  alias VoxelRegion.World

  @lead 8
  @backlog 120
  @outcomes 32
  # production_intent 的 action；0（余额）与 Gate 一样直接读 material_balances，不进事务。
  @production %{place: 1, scoop: 2, pour: 3}
  @attachment %{attach: 0, detach: 1}
  @prefab %{
    prefab_place: :voxel_prefab_place_v1,
    prefab_remove: :voxel_prefab_remove_v1,
    prefab_replace: :voxel_prefab_replace_v1
  }
  # look 的上限：Brain 是外部输入，而快照在 World 进程内逐格求值、冷区域还会触发生成。
  @look_cells 512
  @look_reach 32
  # 寻路取盒：起终点包围盒水平外扩 @path_margin 格、上下各 @path_margin 格；单程水平不超过 @look_reach。
  @path_margin 6
  # 这么多 tick 里挪动不到 @stall_m 米 = 被堵住（60 Hz，3 秒）。
  @stall_ticks 180
  @stall_m 0.5
  # 中途点走到这么近（或已越过）就换下一个。
  @waypoint_m 0.25
  # 拐弯、换层与到达前的限速（m/s）：输入没有模拟量（权威把方向归一化），已送出的 @lead 帧也改不了，
  # 全速 8 m/s 下一次转向要滞后 1 米多，会绕着路点打转。限速靠夹零输入帧实现，与玩家点按方向键同理。
  @corner_speed 2.0

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "进程外 / 慢 Brain 异步投回命令；形状见 `GateServer.Npc.Brain`。"
  def command(body, command), do: GenServer.cast(body, {:command, command})

  @doc "派生缓存、在途命令与最近的 Outcome（新在前）；不是世界真值。"
  def observe(body), do: GenServer.call(body, :observe)

  @doc "canonical X/Z 世界轴上的量化输入与朝向；yaw 不驱动移动，0 朝 +X、16384 朝 +Z。"
  def steer({x, _, z}, {tx, tz}) do
    {dx, dz} = {tx - x, tz - z}
    length = :math.sqrt(dx * dx + dz * dz)
    yaw = rem(round(:math.atan2(dz, dx) * 65536 / (2 * :math.pi())) + 65536, 65536)
    {round(dx / length * 32767), round(dz / length * 32767), yaw}
  end

  @doc "sent 之后到 due+lead 的连续帧：seq ≤ due 已过期填零输入，其余用 steering。"
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
    {brain, profile} = Keyword.fetch!(opts, :brain)

    {:ok,
     %{
       # cid 来自 characters 表的 NPC 行（DataService.CharacterStore.ensure_npc/1），永久且不复用。
       cid: Keyword.fetch!(opts, :cid),
       # 显式出生点：不占玩家 probe 名额。
       spawn: Keyword.fetch!(opts, :spawn),
       claims: Keyword.get(opts, :claims, GateServer.Session.Claims),
       scene: Keyword.get(opts, :scene_module, SceneServer.Movement.Scene),
       router: Keyword.get(opts, :route_module, WorldServer.Movement),
       scene_id: Keyword.fetch!(opts, :scene_id),
       # 与玩家 QUIC 连接同一份部署编辑盒。
       bounds: Keyword.get(opts, :bounds, Application.get_env(:gate_server, :quic, [])[:bounds]),
       brain: brain,
       mind: brain.init(profile),
       identity: nil,
       # 权威下发的移动 profile（SessionStart）；寻路的台阶高度与角色高度取自它。
       profile: nil,
       player: nil,
       world_ref: nil,
       worker: nil,
       origin: nil,
       sent: 0,
       yaw: 0,
       position: nil,
       velocity: {0.0, 0.0, 0.0},
       # 已送出、权威还没处理的帧：[{seq, 是否带方向}]；限速用它推算这些帧生效后的速度。
       inflight: [],
       tick: 0,
       processed: 0,
       entities: %{},
       # 在途移动命令：%{id, verb, target, tolerance, zero_from, path, from, mark}；zero_from = 首个零输入帧的序号，
       # path = :planning | 剩余要走到的水平点（末项恒为 target），from = 当前这一段的起点，
       # mark = {position, tick}：上次挪动超过 @stall_m 时的位置与 tick。
       move: nil,
       # 在途世界事务：id => verb。
       world: %{},
       request_seq: 0,
       # World 返回的余额表原样；nil = 还没取过（`query_balances` 或任一次世界事务之后才有）。
       balances: nil,
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
         %{id: state.cid, spawn: state.spawn, kind: "npc"}}
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
    do:
      {:reply,
       Map.take(state, [:position, :tick, :move, :world, :entities, :balances, :outcomes]), state}

  @impl true
  def handle_cast({:command, command}, state), do: {:noreply, apply_commands(state, [command])}

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

    {:noreply, %{state | profile: start.profile}}
  end

  def handle_info(
        {:mmo_reliable, identity, 1, %Session.InputStart{first_input_seq: 1} = start},
        %{identity: identity} = state
      ),
      do: {:noreply, feed(%{state | origin: start.origin_tick}, start.state, start.anchor_tick, 0)}

  def handle_info(
        {:mmo_datagram, identity, %Movement.OwnerAck{} = ack},
        %{identity: identity, origin: origin} = state
      )
      when origin != nil do
    due = ack.server_tick - origin + 1

    if due - ack.processed_input_seq > @backlog,
      do: {:stop, {:input_backlog, due, ack.processed_input_seq}, state},
      else: {:noreply, feed(state, ack.state, ack.server_tick, ack.processed_input_seq)}
  end

  def handle_info(
        {:mmo_reliable, identity, 1, %Session.EntityEnter{} = e},
        %{identity: identity} = state
      ) do
    entity = %{
      entity_epoch: e.entity_epoch,
      kind: e.kind,
      tick: e.server_tick,
      position: e.state.position
    }

    {:noreply, %{state | entities: Map.put(state.entities, e.entity_id, entity)}}
  end

  def handle_info(
        {:mmo_reliable, identity, 1, %Session.EntityLeave{} = e},
        %{identity: identity} = state
      ),
      do: {:noreply, %{state | entities: Map.delete(state.entities, e.entity_id)}}

  def handle_info(
        {:mmo_datagram, identity, %Movement.Snapshot{} = snapshot},
        %{identity: identity} = state
      ) do
    # 只更新仍是同一 entity_epoch 的已知实体；每个实体保留自己的 tick。
    entities =
      Enum.reduce(snapshot.records, state.entities, fn r, entities ->
        case Map.get(entities, r.entity_id) do
          %{entity_epoch: epoch} = known when epoch == r.entity_epoch ->
            Map.put(entities, r.entity_id, %{
              known
              | tick: snapshot.server_tick,
                position: r.state.position
            })

          _ ->
            entities
        end
      end)

    {:noreply, %{state | entities: entities}}
  end

  def handle_info({:npc_world_result, id, result, balances}, state)
      when is_map_key(state.world, id) do
    {verb, world} = Map.pop(state.world, id)

    outcome =
      case result do
        {:ok, %{} = data} -> %{id: id, verb: verb, status: :done, reason: nil, data: data}
        {:ok, seq} -> %{id: id, verb: verb, status: :done, reason: nil, data: %{seq: seq}}
        {:error, reason} -> %{id: id, verb: verb, status: :rejected, reason: reason, data: nil}
      end

    {:noreply, emit(%{state | world: world, balances: balances || state.balances}, outcome)}
  end

  def handle_info({:npc_path, id, result}, %{move: %{id: id, path: :planning} = move} = state) do
    case result do
      {:ok, path} -> {:noreply, %{state | move: %{move | path: path, from: flat(state.position), mark: {state.position, state.tick}}}}
      :no_path -> {:noreply, reject_move(state, :no_path)}
    end
  end

  def handle_info({:mmo_close, identity, reason}, %{identity: identity} = state),
    do: {:stop, {:session_closed, reason}, state}

  # 跨 Scene 移交，与玩家连接同一条路：seal 源 → Claims 预留并在目标 Scene 准备 → 提交。玩家要等客户端换好世界再回
  # Ready 才提交；无头 Body 没有要换的东西，准备好就提交。输入序号与 origin 随切点延续，在途的移动命令照常继续。
  # 任一步失败就退出，由监督者重新 claim（玩家连接在同样情形下是断开重连）。
  def handle_info({:mmo_transfer_request, identity, player, target}, %{identity: identity, player: player} = state) do
    with {:ok, artifact} <- Player.seal(player, identity),
         {:ok, fresh, route, next} <- GenServer.call(state.claims, {:prepare_transfer, identity, target, artifact}),
         :ok <- GenServer.call(state.claims, {:commit_transfer, identity, fresh, state.cid}) do
      Process.monitor(next)
      Logger.info("npc_transfer cid=#{state.cid} old_scene=#{identity.scene_id} new_scene=#{target} cut=#{artifact.simulation_tick}")
      {:noreply, %{state | identity: fresh, player: next, scene_id: target, world_ref: Map.get(route, :world_ref), entities: %{}}}
    else
      {:error, reason} -> {:stop, {:transfer_failed, target, reason}, state}
    end
  end

  def handle_info({:DOWN, _, :process, player, reason}, %{player: player} = state),
    do: {:stop, {:player_down, reason}, state}

  def handle_info(_, state), do: {:noreply, state}

  defp feed(state, %Session.State{} = session, server_tick, processed) do
    due = max(0, server_tick - state.origin + 1)

    state =
      %{
        state
        | position: session.position,
          velocity: session.velocity,
          tick: server_tick,
          processed: processed,
          inflight: Enum.drop_while(state.inflight, fn {seq, _} -> seq <= processed end)
      }
      |> finish_move()

    state = think(state, {:observation, observation(state, session)})
    {state, {_, _, yaw} = steering, limit} = steering(state, due)
    {frames, inflight} = govern(state, frames(state.sent, due, state.yaw, steering), limit)
    state = %{state | inflight: inflight}

    # 与玩家解码器同一批约束：每批 1..6 帧、序号严格递增；相邻差 1 由 frames/4 保证。
    for batch <- Enum.chunk_every(frames, 6),
        do:
          Player.input(state.player, state.identity, %Movement.InputBatch{
            identity: state.identity,
            frames: batch
          })

    case frames do
      [] -> state
      _ -> %{state | sent: List.last(frames).input_seq, yaw: yaw}
    end
  end

  defp observation(state, session) do
    %{
      self: %{
        entity_id: state.cid,
        tick: state.tick,
        position: session.position,
        yaw: session.yaw,
        grounded: session.grounded,
        processed_input_seq: state.processed
      },
      entities: for({id, e} <- state.entities, do: Map.put(e, :entity_id, id)),
      balances: state.balances,
      pending:
        if(state.move, do: [Map.take(state.move, [:id, :verb])], else: []) ++
          for({id, verb} <- state.world, do: %{id: id, verb: verb})
    }
  end

  # 首个零输入帧已被权威处理 → 移动命令完成；position 与 within_tolerance 取自同一份 ACK。
  defp finish_move(%{move: %{zero_from: zero} = move, processed: processed} = state)
       when zero != nil and processed >= zero do
    within = move.target == nil or distance(state.position, move.target) <= move.tolerance

    emit(%{state | move: nil}, %{
      id: move.id,
      verb: move.verb,
      status: :done,
      reason: nil,
      data: %{position: state.position, within_tolerance: within}
    })
  end

  defp finish_move(state), do: state

  defp steering(%{move: %{zero_from: nil, path: :planning}} = state, _due), do: {state, {0, 0, state.yaw}, 0.0}

  # 移动命令只写未来槽：零输入从下一个未送且未过期的序号开始。
  defp steering(%{move: %{zero_from: nil, verb: :stop} = move} = state, due),
    do: {%{state | move: %{move | zero_from: max(state.sent, due) + 1}}, {0, 0, state.yaw}, 0.0}

  defp steering(%{move: %{zero_from: nil} = move} = state, due) do
    move = advance(move, state.position)
    [target | rest] = move.path
    {marked, since} = move.mark

    move =
      if distance(state.position, flat(marked)) > @stall_m, do: %{move | mark: {state.position, state.tick}}, else: move

    cond do
      rest == [] and distance(state.position, target) <= move.tolerance ->
        {%{state | move: %{move | zero_from: max(state.sent, due) + 1}}, {0, 0, state.yaw}, 0.0}

      state.tick - since > @stall_ticks ->
        {reject_move(%{state | move: move}, :stuck), {0, 0, state.yaw}, 0.0}

      true ->
        # 从“已送帧生效时”的预计位置瞄准，抵消送帧提前量带来的转向滞后。
        {px, _, pz} = state.position
        {vx, _, vz} = state.velocity
        ahead = @lead / state.profile.fixed_hz
        aim = Enum.find([{px + vx * ahead, 0.0, pz + vz * ahead}, state.position], &(distance(&1, target) > 0.05))

        # 每个路点都是拐点、换层点或终点：离它还有多远就允许多快（v² = 2·braking·d），不低于拐弯速度。
        limit = max(@corner_speed, :math.sqrt(2 * state.profile.braking * distance(state.position, target)))
        {%{state | move: move}, if(aim, do: steer(aim, target), else: {0, 0, state.yaw}), limit}
    end
  end

  defp steering(state, _due), do: {state, {0, 0, state.yaw}, 0.0}

  # 中途点：走近了、或沿这一段的方向已经越过它，就换下一个；末项（target）由 tolerance 判定，不在这里丢。
  defp advance(%{path: [{wx, wz} = point, _ | _] = path, from: {fx, fz}} = move, {px, _, pz} = position) do
    passed = (px - wx) * (wx - fx) + (pz - wz) * (wz - fz) >= 0

    if passed or distance(position, point) <= @waypoint_m,
      do: advance(%{move | path: tl(path), from: point}, position),
      else: move
  end

  defp advance(move, _position), do: move

  defp flat({x, _, z}), do: {x, z}

  # 逐帧限速：按已送未处理的帧推算生效时的水平速度（带方向帧 +acceleration/hz，零输入帧按 braking 与摩擦减速），
  # 超过 limit 的帧改成零输入。模型只用来决定夹不夹帧；位置真值始终是权威的 ACK。
  defp govern(state, frames, limit) do
    profile = state.profile
    {vx, _, vz} = state.velocity

    advance = fn speed, on ->
      if on,
        do: min(profile.speed, speed + profile.acceleration / profile.fixed_hz),
        else: max(0.0, speed - (profile.braking + profile.friction * profile.braking_friction_factor * speed) / profile.fixed_hz)
    end

    speed = Enum.reduce(state.inflight, :math.sqrt(vx * vx + vz * vz), fn {_, on}, speed -> advance.(speed, on) end)

    {frames, {_, sent}} =
      Enum.map_reduce(frames, {speed, []}, fn frame, {speed, sent} ->
        on = (frame.axis_x != 0 or frame.axis_z != 0) and speed < limit
        frame = if on, do: frame, else: %{frame | axis_x: 0, axis_z: 0}
        {frame, {advance.(speed, on), [{frame.input_seq, on} | sent]}}
      end)

    {frames, state.inflight ++ Enum.reverse(sent)}
  end

  defp distance({x, _, z}, {tx, tz}), do: :math.sqrt((tx - x) * (tx - x) + (tz - z) * (tz - z))

  defp think(state, event) do
    {commands, mind} = state.brain.handle_event(event, state.mind)
    apply_commands(%{state | mind: mind}, commands)
  end

  defp emit(state, outcome) do
    state = %{state | outcomes: Enum.take([outcome | state.outcomes], @outcomes)}
    think(state, {:outcome, outcome})
  end

  defp apply_commands(state, commands), do: Enum.reduce(commands, state, &apply_command(&2, &1))

  defp apply_command(
         %{position: {px, py, pz}, profile: %{} = profile} = state,
         %{id: id, verb: :move_to, position: {x, z}, tolerance: tolerance} = command
       )
       when is_number(x) and is_number(z) and is_number(tolerance) and tolerance > 0 do
    goal_y = Map.get(command, :y)
    move = %{id: id, verb: :move_to, target: {x, z}, tolerance: tolerance, zero_from: nil, path: :planning, from: nil, mark: nil}

    cond do
      not (goal_y == nil or is_integer(goal_y)) ->
        invalid(state, command)

      abs(x - px) > @look_reach or abs(z - pz) > @look_reach ->
        emit(state, %{id: id, verb: :move_to, status: :rejected, reason: :too_far, data: nil})

      true ->
        # position 是胶囊中心；脚所在的格 = 中心下移半高（+0.5 容忍贴地的 skin / snap）。
        start = {floor(px), floor(py - profile.half_height + 0.5), floor(pz)}
        plan = %{
          start: start,
          from: {px, pz},
          target: {x, z},
          goal_y: goal_y,
          step: floor(profile.step_height),
          height: ceil(2 * profile.half_height),
          radius: profile.radius
        }

        send(state.worker, {:plan, self(), id, state.world_ref, state.cid, plan})
        move(state, move)
    end
  end

  defp apply_command(state, %{id: id, verb: :stop}),
    do: move(state, %{id: id, verb: :stop, target: nil, tolerance: nil, zero_from: nil, path: [], from: nil, mark: nil})

  defp apply_command(state, %{id: id, verb: verb} = command)
       when verb in [:probe_toward, :use_tool, :query_balances, :look, :inspect] or
              is_map_key(@production, verb) or is_map_key(@attachment, verb) or
              is_map_key(@prefab, verb) do
    case world_call(state, command) do
      nil ->
        invalid(state, command)

      call ->
        submit(state, id, call)
        %{state | request_seq: state.request_seq + 1, world: Map.put(state.world, id, verb)}
    end
  end

  # 聊天占位：正式栈有玩家聊天后接同一条通道，届时收到的话以 `{:heard, ...}` 事件给 Brain。
  defp apply_command(state, %{id: id, verb: :say, text: text}) when is_binary(text),
    do:
      emit(state, %{id: id, verb: :say, status: :rejected, reason: :chat_unavailable, data: nil})

  # Brain 是可插拔的外部输入（含 LLM）：不合法的命令回报为拒绝，不让 Body 崩溃。
  defp apply_command(state, command), do: invalid(state, command)

  # 语义命令 → World 公共 API 的一次调用；nil = 命令不合法。取值约束用 Codec 里与线解码共用的谓词，这里只补类型。
  # action 0 = 沿方向探测实际命中；action 1 = 攻击 probe_toward 返回的那个目标身份。
  defp world_call(state, %{verb: verb, direction: {dx, dy, dz}, tool_id: tool} = command)
       when verb in [:probe_toward, :use_tool] and is_number(dx) and is_number(dy) and
              is_number(dz) and is_integer(tool) do
    request =
      state
      |> request(%{
        action: if(verb == :probe_toward, do: 0, else: 1),
        direction: {dx, dy, dz},
        micro: {0, 0, 0},
        incarnation: 0,
        owner: {0, 0},
        material: 0,
        tool_id: tool,
        granularity: 0
      })
      |> Map.merge(
        # granularity 3 = 附件（电路工具的目标）：没有射线，按身份寻址。
        Map.take(Map.get(command, :target) || %{}, [
          :micro,
          :incarnation,
          :owner,
          :material,
          :granularity
        ])
      )

    if Codec.tool_intent?(request), do: {:tool, request}
  end

  # anchor 是 micro 坐标；detach 要带上那件附件的 id（attachment_id）与材料，与玩家请求同形。
  defp world_call(
         state,
         %{verb: verb, kind: _, axis: _, size: _, anchor: {x, y, z}, material: material, tool_id: tool} =
           command
       )
       when is_map_key(@attachment, verb) and is_integer(x) and is_integer(y) and is_integer(z) and
              is_integer(material) and is_integer(tool) do
    id = Map.get(command, :attachment_id, 0)

    request =
      state
      |> request(Map.take(command, [:kind, :axis, :size, :anchor, :material, :tool_id]))
      |> Map.merge(%{action: @attachment[verb], id: id})

    if is_integer(id) and Codec.attachment_intent?(request), do: {:attachment, request}
  end

  defp world_call(state, %{verb: :prefab_place, definition_id: id, anchor: {x, y, z}} = command)
       when is_binary(id) and is_integer(x) and is_integer(y) and is_integer(z) do
    request = request(state, Map.take(command, [:definition_id, :anchor, :orientation]))

    if is_map_key(request, :orientation) and Codec.prefab_place?(request),
      do: {:prefab, @prefab.prefab_place, request}
  end

  defp world_call(state, %{verb: verb, instance_id: {birth, occurrence}} = command)
       when verb in [:prefab_remove, :prefab_replace] and is_integer(birth) and
              is_integer(occurrence) do
    fields = if verb == :prefab_remove, do: [:instance_id], else: [:instance_id, :definition_id]
    request = request(state, Map.take(command, fields))

    if verb == :prefab_remove or match?(%{definition_id: <<_::binary-size(32)>>}, request),
      do: {:prefab, @prefab[verb], request}
  end

  defp world_call(state, %{verb: verb, coord: {x, y, z}, material: material, tool_id: tool})
       when is_map_key(@production, verb) and is_integer(x) and is_integer(y) and is_integer(z) and
              is_integer(material) and is_integer(tool) do
    request =
      request(state, %{
        action: @production[verb],
        coord: {x, y, z},
        material: material,
        tool_id: tool
      })

    if Codec.production_intent?(request), do: {:production, request}
  end

  defp world_call(_state, %{verb: :query_balances}), do: :balances

  # macro 格闭区间，限制在自己周围：玩家也只看得到流送到身边的世界。
  defp world_call(%{position: {px, py, pz}}, %{verb: :look, min: {x0, y0, z0}, max: {x1, y1, z1}})
       when is_integer(x0) and is_integer(y0) and is_integer(z0) and is_integer(x1) and
              is_integer(y1) and is_integer(z1) and x0 <= x1 and y0 <= y1 and z0 <= z1 and
              (x1 - x0 + 1) * (y1 - y0 + 1) * (z1 - z0 + 1) <= @look_cells and
              x0 >= px - @look_reach and x1 <= px + @look_reach and y0 >= py - @look_reach and
              y1 <= py + @look_reach and z0 >= pz - @look_reach and z1 <= pz + @look_reach,
       do: {:look, for(x <- x0..x1, y <- y0..y1, z <- z0..z1, do: {x, y, z})}

  # 自己所在 tile 周围 3×3×3 个 tile：与玩家客户端收到属性状态的窗口相同。
  defp world_call(%{position: {x, y, z}}, %{verb: :inspect}) do
    {rx, ry, rz} = {floor(x / 64), floor(y / 64), floor(z / 64)}
    {:inspect, {{rx - 1, ry - 1, rz - 1}, {rx + 2, ry + 2, rz + 2}}}
  end

  defp world_call(_state, _command), do: nil

  # 与玩家请求同形的公共字段；client_intent_seq 在本会话内跨所有事务严格递增。
  defp request(state, fields) do
    seq = state.request_seq + 1

    Map.merge(fields, %{
      request_id: seq,
      client_intent_seq: seq,
      logical_scene_id: state.scene_id
    })
  end

  defp submit(state, id, call),
    do:
      send(
        state.worker,
        {:call, self(), id, Map.take(state, [:player, :identity, :world_ref, :cid, :bounds]), call}
      )

  defp invalid(state, command) when is_map(command) do
    emit(state, %{
      id: Map.get(command, :id),
      verb: Map.get(command, :verb),
      status: :rejected,
      reason: :invalid_command,
      data: nil
    })
  end

  defp reject_move(%{move: move} = state, reason) do
    Logger.warning("npc_move_rejected cid=#{state.cid} reason=#{reason} position=#{inspect(state.position)} target=#{inspect(move.target)} path=#{inspect(move.path)}")
    emit(%{state | move: nil}, %{id: move.id, verb: move.verb, status: :rejected, reason: reason, data: nil})
  end

  defp move(%{move: nil} = state, move), do: %{state | move: move}

  defp move(%{move: old} = state, move) do
    emit(%{state | move: move}, %{
      id: old.id,
      verb: old.verb,
      status: :superseded,
      reason: nil,
      data: nil
    })
  end

  defp world_calls do
    receive do
      {:call, body, id, session, call} ->
        result = execute(session, call)

        # 与 Gate 给玩家补发余额的时机相同：探测与只读感知之外的每次调用之后。
        balances =
          unless match?({:tool, %{action: 0}}, call) or match?({kind, _} when kind in [:look, :inspect], call),
            do: World.material_balances(session.world_ref, session.cid)

        send(body, {:npc_world_result, id, result || {:ok, %{balances: balances}}, balances})
        world_calls()

      {:plan, body, id, world, cid, %{start: {sx, sy, sz} = start, target: {tx, tz} = target, goal_y: goal_y} = plan} ->
        {gx, gz} = goal = {floor(tx), floor(tz)}
        [y0, y1] = Enum.sort([sy, goal_y || sy])

        cells =
          for x <- (min(sx, gx) - @path_margin)..(max(sx, gx) + @path_margin),
              y <- (y0 - @path_margin)..(y1 + @path_margin),
              z <- (min(sz, gz) - @path_margin)..(max(sz, gz) + @path_margin),
              do: {x, y, z}

        # 细化格（含 micro 内容）一律当作占满；液体不进表：不能踩也不能穿过。
        grid =
          for %{cell: [x, y, z], material: material, refined: refined} <-
                World.material_snapshot(world, [cid], cells).probe_occupancy,
              not Phase.liquid?(material),
              into: %{},
              do: {{x, y, z}, if(material == 0 and not refined, do: :open, else: :solid)}

        result =
          with {:ok, cells} <- Path.find(grid, start, goal, goal_y, plan.step, plan.height),
               do: {:ok, Path.smooth(grid, plan.from, sy, cells, target, plan.radius, plan.height)}

        send(body, {:npc_path, id, result})
        world_calls()
    end
  end

  defp execute(_session, :balances), do: nil

  defp execute(session, {:look, cells}),
    do: {:ok, World.material_snapshot(session.world_ref, [session.cid], cells)}

  # 附件（granularity 3）与 prefab 构件（granularity 2）的身份和状态；热账、液体量等不属于角色感知。
  defp execute(session, {:inspect, box}),
    do:
      {:ok,
       session.world_ref
       |> World.simulation_snapshot([session.cid], box)
       |> Map.take([:seq, :property_states])}

  defp execute(session, call) do
    with :ok <- prefab_gate(session, call),
         {:ok, actor} <- Player.tool_context(session.player, session.identity) do
      actor =
        Map.merge(actor, %{
          received_us: System.monotonic_time(:microsecond),
          clock_node: node()
        })

      case call do
        {:tool, request} -> World.tool_intent(session.world_ref, actor, request)
        {:production, request} -> World.production_intent(session.world_ref, actor, request)
        {:attachment, request} -> World.attachment_intent(session.world_ref, actor, request)
        {:prefab, kind, request} -> World.prefab_intent(session.world_ref, actor, kind, request)
      end
    end
  end

  # Gate 在进 World 之前对玩家 prefab 请求做的同一道门。
  defp prefab_gate(session, {:prefab, kind, request}) do
    if Dispatch.prefab_within?(session.world_ref, kind, request, session.bounds),
      do: :ok,
      else: {:error, :out_of_bounds}
  end

  defp prefab_gate(_session, _call), do: :ok
end
