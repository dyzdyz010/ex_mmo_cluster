defmodule SceneServer.Movement.TeleportToSpawnTest do
  @moduledoc """
  只测试：传送回出生点（NPC 原子 `teleport_to_spawn` 的角色 owner 侧，决策稿
  docs/10-active/cross-cutting/2026-11-24-npc-route-and-teleport-decision.md §5.5、§6 第 2.2 行），经真实 Scene + Player 的正式接口
  `Player.teleport_to_spawn/4`。

  世界与入场同 `ReviveRelocationTest`（y = 500 一层地面，出生柱 (40, 558, 40)，入场按 `find_spawn` 落到地面上：SessionStart.state
  = 会话出生点）；本进程扮 World（流送窗口的快照与接纳回执）。读条的计时器是真实的 `Process.send_after`：测试核对它定在
  10 秒，再自己发出到点消息 `{:release_cast, key}`（扮时钟，同 `BeaconTravelTest` 扮 World 回开始 / 结束校验），不等 10 秒。
  死亡的前提用 `ReviveRelocationTest` 同一夹具（`:sys.replace_state` 写入濒死身体，再推进一次 1 Hz 身体步）。

  期望（独立依据：决策稿 §5.5 的条款与复活的同一落点）：
  - 读条：计时器 10 000 ms；读条中工具上下文回 `casting`，再发传送回 `cast_too_soon`。
  - 落地：落脚点 = SessionStart.state（出生柱不变、世界不变）；非流送 apply_tick = 放行时模拟 tick + 1，流送先请求覆盖出生柱的新窗口，
    Relocate 与窗口同一 apply_tick；回执 `{:ok, %{from, to, apply_tick}}` 恰好一次，在瞬移生效的那个 tick（from = 放行前位置）。
  - 冷却：落地后立刻再传送回 `{:teleport_cooldown, 可再用的 Unix 毫秒}`，= 放行墙钟 + 1 游戏小时 / 倍率 24 = 150 000 ms（取整到毫秒）。
  - 读条中按 +x 走，离起点超过 0.25 m 回 `teleport_moved`，不瞬移；死亡中回 `dead`。
  - 事件：`teleport_channel`（windup_s 10）、`teleport_depart`、瞬移两条事件带 `reason: "teleport"`、拒绝 `teleport_rejected` 带原因。
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias SceneServer.Body
  alias SceneServer.Movement.{Scene, Player}
  alias MmoContracts.{Session, Movement, Voxel}

  defmodule Clock do
    def now(ref), do: :atomics.get(ref, 1)
    def schedule(_ref, _pid, _delay), do: :ok
  end

  defmodule Sink do
    def reliable(pid, identity, purpose, message),
      do: send(pid, {:reliable, identity, purpose, message})

    def datagram(pid, identity, message), do: send(pid, {:datagram, identity, message})
    def close(pid, identity, reason), do: send(pid, {:closed, identity, reason})
  end

  # 同一进程既是 Scene 的 world_ref（初始快照）也是流送窗口的 authority；身体消息转给测试进程。
  defmodule Source do
    use MmoTest.WorldAuthorityDouble
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def init(opts), do: {:ok, opts}
    def authority_ref(pid), do: pid

    def canonical_snapshot_and_subscribe(pid, box, subscriber, ref, _include_chunks \\ true),
      do: GenServer.call(pid, {:canonical_snapshot, box, subscriber, ref, true})

    def ensure(_state, _level, _region), do: :ok

    def world_call({:canonical_snapshot, box, subscriber, ref, _}, _, state) do
      send(
        subscriber,
        {:canonical_snapshot, ref, SceneServer.Movement.TeleportToSpawnTest.snapshot(box)}
      )

      {:reply, :ok, state}
    end

    def handle_info({:simulation_windows, source, _boxes, ref}, state) do
      send(source, {:simulation_windows_result, ref, :ok})
      {:noreply, state}
    end

    def handle_info({:body_detach, _cid, player, ref}, state) do
      send(player, {:body_detached, ref})
      {:noreply, state}
    end

    def handle_info(message, state) do
      send(state.owner, {:authority, message})
      {:noreply, state}
    end
  end

  @probe [40.0, 558.0, 40.0]

  def snapshot({{x0, y0, z0}, {x1, y1, z1}} = box) do
    floor =
      for _z <- 0..15,
          cy <- 0..15,
          _x <- 0..15,
          into: <<>>,
          do: <<if(31 * 16 + cy == 500, do: 1, else: 0)>>

    chunks =
      for x <- (x0 * 4)..(x1 * 4 - 1),
          y <- (y0 * 4)..(y1 * 4 - 1),
          z <- (z0 * 4)..(z1 * 4 - 1),
          y == 31 do
        %Voxel.ChunkOccupancy{
          coord: {x, y, z},
          n: 16,
          scale_m: 1.0,
          origin_m: {x * 16.0, y * 16.0, z * 16.0},
          cells: floor
        }
      end

    %Voxel.CanonicalSnapshot{
      content_version: 9,
      transaction_seq: 0,
      l0_min: elem(box, 0),
      l0_max_exclusive: elem(box, 1),
      chunks: chunks,
      regions: for(x <- x0..(x1 - 1), y <- y0..(y1 - 1), z <- z0..(z1 - 1), do: {{x, y, z}, <<>>})
    }
  end

  defp config(radius) do
    path = Path.expand("../../../../../../Voxim/Docs/M0/fixtures/suite.json", __DIR__)

    profile =
      File.read!(path) |> Jason.decode!() |> Map.fetch!("profile") |> Map.put("fixed_hz", 60)

    %{
      "schema" => "voxim-m1-demo-v1",
      "l0_min" => [-1, 7, -1],
      "l0_max_exclusive" => [2, 10, 2],
      "travel_min_m" => [-48.0, 464.0, -48.0],
      "travel_max_exclusive_m" => [112.0, 624.0, 112.0],
      "spawn_probes_m" => [@probe],
      "spawn_min_y_m" => 464.0,
      "profile" => profile,
      "collision_window_radius_tiles" => radius
    }
  end

  defp identity, do: %Session.Identity{session_epoch: 1, scene_id: 1, scene_epoch: 7}

  defp setup_scene(radius) do
    clock = :atomics.new(1, signed: true)
    source = start_supervised!({Source, %{owner: self()}})
    body_store = start_supervised!({MmoTest.BodyStore, []})

    scene =
      start_supervised!(
        {Scene,
         [
           scene_id: 1,
           scene_epoch: 7,
           world_ref: source,
           config: config(radius),
           clock: {Clock, clock},
           sink: Sink,
           body_store: {MmoTest.BodyStore, store: body_store},
           world_api: Source
         ]}
      )

    wait(fn -> Scene.observe(scene).initialized end)
    %{scene: scene, clock: clock, radius: radius}
  end

  defp wait(fun, attempts \\ 4000) do
    if value = fun.(),
      do: value,
      else:
        (
          assert(attempts > 0)
          Process.sleep(1)
          wait(fun, attempts - 1)
        )
  end

  defp tick(ctx, tick) do
    :atomics.put(ctx.clock, 1, div(tick * 1_000_000 + 59, 60))
    send(ctx.scene, :tick)
    wait(fn -> Scene.observe(ctx.scene).tick >= tick end)
  end

  defp step(ctx, p, seq, axis_x) do
    frame = %Movement.InputFrame{
      input_seq: seq,
      axis_x: axis_x,
      axis_z: 0,
      yaw: 0,
      jump_pressed: 0
    }

    Player.input(p, identity(), %Movement.InputBatch{identity: identity(), frames: [frame]})
    tick(ctx, seq + ctx.origin - 1)
    wait(fn -> Player.observe(p).processed_input_seq == seq end)
  end

  # 入场、就绪，按 +x 走 12 帧离开出生点（模拟 tick = origin + 11）。
  defp walk(ctx) do
    {:ok, p} = Scene.join(ctx.scene, identity(), %{id: 20}, self())
    if ctx.radius == 0, do: wait(fn -> Scene.observe(ctx.scene).queue_length > 0 end)
    tick(ctx, 1)
    assert_receive {:reliable, _, :control, %Session.SessionStart{} = start}, 2000
    Player.time_probe(p, identity(), %Session.TimeProbe{request_id: 1, client_send_us: 1})
    %{baseline: {seq, revision}} = :sys.get_state(p)
    Player.ready(p, identity(), seq, revision)
    tick(ctx, 3)
    assert_receive {:reliable, _, :control, %Session.InputStart{origin_tick: origin}}, 2000
    ctx = Map.put(ctx, :origin, origin)
    tick(ctx, origin - 1)
    wait(fn -> Player.observe(p).simulation_tick == origin - 1 end)
    for seq <- 1..12, do: step(ctx, p, seq, 32767)
    # 零输入 28 帧停稳：读条起点之后不再被惯性带走。
    for seq <- 13..40, do: step(ctx, p, seq, 0)
    {ctx, p, start}
  end

  defp teleport(p, seq) do
    ref = make_ref()
    Player.teleport_to_spawn(p, identity(), %{client_intent_seq: seq}, {self(), ref})
    ref
  end

  # 读条已开始：计时器定在 10 秒（读条秒数是 `Player.teleport_terms/0` 的同一常量）。
  defp channelling(p) do
    %{action: %{kind: :teleport, phase: :windup, timer: timer, key: key}} =
      wait(fn ->
        match?(%{action: %{kind: :teleport}}, :sys.get_state(p)) && :sys.get_state(p)
      end)

    assert Process.read_timer(timer) in 9_000..10_000
    assert Player.teleport_terms().windup_s == 10
    key
  end

  defp same_spot?(a, b),
    do: {a.position, a.velocity, a.grounded} == {b.position, b.velocity, b.grounded}

  defp events(log, name) do
    log
    |> String.split("\n", trim: true)
    |> Enum.filter(&String.starts_with?(&1, "{"))
    |> Enum.map(&Jason.decode!/1)
    |> Enum.filter(&(&1["event"] == name))
  end

  test "非流送：读条 10 s，到点瞬移回出生柱的落脚处，落地那个 tick 回执 from / to 恰好一次；事件带原因 teleport" do
    log =
      capture_log([level: :info, format: "$message\n"], fn ->
        {ctx, p, start} = walk(setup_scene(0))
        before = Player.observe(p).state
        refute same_spot?(before, start.state)

        ref = teleport(p, 50)
        key = channelling(p)
        assert {:error, :casting} = Player.tool_context(p, identity())
        # 读条中再发：动作槽被占。
        again = teleport(p, 51)
        assert_receive {^again, {:error, :cast_too_soon}}, 2000

        released_at = Player.observe(p).simulation_tick
        send(p, {:release_cast, key})
        apply_tick = released_at + 1

        assert_receive {:reliable, _, :voxel,
                        %Voxel.Relocate{apply_tick: ^apply_tick, state: spawned}},
                       2000

        assert same_spot?(spawned, start.state)
        # 瞬移生效前不回执。
        refute_receive {^ref, _}, 50
        step(ctx, p, 41, 0)

        assert_receive {^ref, {:ok, %{from: from, to: to, apply_tick: ^apply_tick}}}, 2000
        assert from == before.position
        assert to == spawned.position
        refute_receive {^ref, _}, 50
        assert {:ok, _} = Player.tool_context(p, identity())
      end)

    assert [%{"windup_s" => 10, "probe" => @probe}] = events(log, "teleport_channel")
    assert [%{"client_intent_seq" => 50}] = events(log, "teleport_depart")
    assert [%{"reason" => "cast_too_soon"}] = events(log, "teleport_rejected")
    assert [%{"reason" => "teleport"}] = events(log, "revive_relocate")
    assert [%{"reason" => "teleport", "from" => _, "to" => _}] = events(log, "revive_relocated")
  end

  test "流送：先流送覆盖出生柱的窗口，Relocate 与窗口同一 apply_tick；冷却中再传送回 teleport_cooldown 与可再用时刻" do
    {ctx, p, start} = walk(setup_scene(1))
    ref = teleport(p, 50)
    key = channelling(p)
    released_ms = System.system_time(:millisecond)
    send(p, {:release_cast, key})

    # 覆盖出生柱的窗口异步到达：等它排进 Player 的 FIFO 再推进 tick（同 ReviveRelocationTest 流送用例）。
    wait(fn ->
      s = :sys.get_state(p)
      s.revive == :window and :queue.len(s.updates.queue) > 0
    end)

    step(ctx, p, 41, 0)

    assert_receive {:reliable, _, :voxel,
                    %Voxel.Relocate{apply_tick: apply_tick, state: spawned}},
                   2000

    assert_receive {:reliable, _, :voxel,
                    %Voxel.CollisionWindow{apply_tick: ^apply_tick, l0_min: {-1, 7, -1}}},
                   2000

    assert same_spot?(spawned, start.state)
    assert_receive {^ref, {:ok, %{to: to, apply_tick: ^apply_tick}}}, 2000
    assert to == spawned.position

    # 冷却：1 游戏小时 = 现实 150 s（倍率 24）。可再用时刻在放行前后两次墙钟读数各加 150 000 ms 之间。
    after_ms = System.system_time(:millisecond)
    cooled = teleport(p, 52)
    assert_receive {^cooled, {:error, {:teleport_cooldown, ready_ms}}}, 2000
    assert ready_ms >= released_ms + 150_000 - 1 and ready_ms <= after_ms + 150_000 + 1
    assert Player.teleport_terms().cooldown_game_s == 3600
    assert :sys.get_state(p).action == nil
  end

  test "读条中走开 0.25 m 以上回 teleport_moved、不瞬移；死亡中回 dead" do
    {ctx, p, _} = walk(setup_scene(0))
    ref = teleport(p, 50)
    channelling(p)
    origin = Player.observe(p).state.position

    Enum.reduce_while(41..120, nil, fn seq, _ ->
      step(ctx, p, seq, 32767)
      if :sys.get_state(p).action == nil, do: {:halt, seq}, else: {:cont, nil}
    end)

    assert_receive {^ref, {:error, :teleport_moved}}, 2000
    {x0, _, _} = origin
    {x1, _, _} = Player.observe(p).state.position
    assert x1 - x0 > 0.25
    refute_receive {:reliable, _, :voxel, %Voxel.Relocate{}}, 50

    # 死亡（ReviveRelocationTest 同一夹具：写入濒死身体后推进一次 1 Hz 身体步）。
    :sys.replace_state(p, fn s ->
      %{
        s
        | climate: %{"ambient_kelvin" => 293.15, "climate_zones" => []},
          body: %{Body.new() | core_k: 293.15, status: :dying, lethal_s: 129.5}
      }
    end)

    send(p, :body_tick)
    assert_receive {:reliable, _, :control, %Session.BodyState{status: 2}}, 2000
    dead = teleport(p, 60)
    assert_receive {^dead, {:error, :dead}}, 2000
    assert :sys.get_state(p).action == nil
  end
end
