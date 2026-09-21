defmodule GateServer.Npc.Body do
  @moduledoc """
  全局系统功能：NPC 的无 socket 会话 owner。以 NPC cid 走 `QuicListener` 的完整 claim，自己充当 gate；
  权威状态只在 `Movement.Player`，本进程的位置是 OwnerAck 的派生缓存。

  输入由 OwnerAck 闭环驱动：`due_seq = server_tick - origin_tick + 1`，把已送序号连续补到 `due_seq + 8`；
  已过期未送的序号填零输入，新动作只写未来槽。第一片的巡逻路线写在本进程，无 Brain 抽象。
  设计见 docs/10-active/cross-cutting/2026-09-21-npc-unified-interface-design.md。
  """
  use GenServer
  import Bitwise
  alias MmoContracts.{Movement, Session}
  alias SceneServer.Movement.Player

  @lead 8
  @backlog 120
  @arrive_m 0.5

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

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
    cid = Keyword.fetch!(opts, :cid)
    # NPC cid 区间：bit 63 置 1，全集群唯一，不进 characters 表。
    true = (cid >>> 63) == 1
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
       listener: Keyword.fetch!(opts, :listener),
       scene: Keyword.get(opts, :scene_module, SceneServer.Movement.Scene),
       router: Keyword.get(opts, :route_module, WorldServer.Movement),
       scene_id: Keyword.fetch!(opts, :scene_id),
       identity: nil,
       player: nil,
       origin: nil,
       sent: 0,
       yaw: 0
     }, {:continue, :claim}}
  end

  @impl true
  def handle_continue(:claim, state) do
    {:ok, route} = state.router.route(state.scene_id)

    {identity, {:ok, player}} =
      GenServer.call(
        state.listener,
        {:claim, state.scene, Map.put(route, :scene_id, state.scene_id), %{id: state.cid}}
      )

    Process.monitor(player)
    # 只用于置 clock_ready；送帧不依赖本地时钟映射。
    Player.time_probe(player, identity, %Session.TimeProbe{request_id: 1, client_send_us: 0})
    {:noreply, %{state | identity: identity, player: player}}
  end

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
    route = advance_route(position, state.route)
    {_, _, yaw} = steering = steer(position, hd(route))
    frames = frames(state.sent, due, state.yaw, steering)

    # 与玩家解码器同一批约束：每批 1..6 帧、序号严格递增；相邻差 1 由 frames/4 保证。
    for batch <- Enum.chunk_every(frames, 6),
        do:
          Player.input(state.player, state.identity, %Movement.InputBatch{
            identity: state.identity,
            frames: batch
          })

    case frames do
      [] -> %{state | route: route}
      _ -> %{state | route: route, sent: List.last(frames).input_seq, yaw: yaw}
    end
  end
end
