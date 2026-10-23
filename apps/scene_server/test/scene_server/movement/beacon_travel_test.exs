defmodule SceneServer.Movement.BeaconTravelTest do
  @moduledoc """
  只测试：传送信标出发（Voxim `Docs/Gameplay/Beacon.md`）的角色 owner 侧，经真实流送 Scene + Player。

  世界与入场同 `ReviveRelocationTest`（y = 500 一层地面，出生柱 (40, 558, 40)，碰撞窗口半径 1 tile）；本进程扮 World：
  收到 Player 发来的 `{:prepare_beacon …}` / `{:commit_beacon …}` 后按场景回 `{:beacon_prepared …}` / `{:beacon_committed …}`。
  期望（独立依据）：

  - 放行后落点在当前窗口里（半径 1 tile 的窗口覆盖整个 3×3 tile 世界）：不请求新窗口，Relocate 的 apply_tick =
    放行时模拟 tick + 1；落脚点 = 落点探针 x/z 不变、y 与出生点相同（同一胶囊、同一层地面），回执 `{:ok, 0}` 恰好一次。
    落点在窗口外时走复活同一条流送路径（`ReviveRelocationTest` 覆盖）。
  - 读条中按 +x 走，离起点超过 0.25 m 即回 `{:error, :beacon_moved}`，不发结束校验、不瞬移。
  - 结束校验拒绝（目的核心已失）照实回原因，不瞬移，动作槽释放。
  """
  use ExUnit.Case, async: false
  alias SceneServer.Movement.{Scene, Player}
  alias MmoContracts.{Session, Movement, Voxel}

  defmodule Clock do
    def now(ref), do: :atomics.get(ref, 1)
    def schedule(_ref, _pid, _delay), do: :ok
  end

  defmodule Sink do
    def reliable(pid, identity, purpose, message), do: send(pid, {:reliable, identity, purpose, message})
    def datagram(pid, identity, message), do: send(pid, {:datagram, identity, message})
    def close(pid, identity, reason), do: send(pid, {:closed, identity, reason})
  end

  defmodule Source do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def init(opts), do: {:ok, opts}
    def authority_ref(pid), do: pid

    def canonical_snapshot_and_subscribe(pid, box, subscriber, ref, _include_chunks \\ true),
      do: GenServer.call(pid, {:canonical_snapshot, box, subscriber, ref, true})

    def ensure(_state, _level, _region), do: :ok
    def handle_call({:prepare, _keys}, _, state), do: {:reply, {__MODULE__, nil, []}, state}
    def handle_call({:adopt_liquid, _regions}, _, state), do: {:reply, :ok, state}

    def handle_call({:canonical_snapshot, box, subscriber, ref, _}, _, state) do
      send(subscriber, {:canonical_snapshot, ref, SceneServer.Movement.BeaconTravelTest.snapshot(box)})
      {:reply, :ok, state}
    end

    def handle_info(message, state) do
      send(state.owner, {:authority, message})
      {:noreply, state}
    end
  end

  @landing {70.5, 558.0, 40.5}

  # y = 500 一层地面（同 ReviveRelocationTest）。
  def snapshot({{x0, y0, z0}, {x1, y1, z1}} = box) do
    floor = for _z <- 0..15, cy <- 0..15, _x <- 0..15, into: <<>>, do: <<if(31 * 16 + cy == 500, do: 1, else: 0)>>

    chunks =
      for x <- (x0 * 4)..(x1 * 4 - 1), y <- (y0 * 4)..(y1 * 4 - 1), z <- (z0 * 4)..(z1 * 4 - 1), y == 31,
        do: %Voxel.ChunkOccupancy{coord: {x, y, z}, n: 16, scale_m: 1.0, origin_m: {x * 16.0, y * 16.0, z * 16.0}, cells: floor}

    %Voxel.CanonicalSnapshot{content_version: 9, transaction_seq: 0, l0_min: elem(box, 0), l0_max_exclusive: elem(box, 1),
      chunks: chunks, regions: for(x <- x0..(x1 - 1), y <- y0..(y1 - 1), z <- z0..(z1 - 1), do: {{x, y, z}, <<>>})}
  end

  defp config do
    path = Path.expand("../../../../../../Voxim/Docs/M0/fixtures/suite.json", __DIR__)
    profile = File.read!(path) |> Jason.decode!() |> Map.fetch!("profile") |> Map.put("fixed_hz", 60)

    %{"schema" => "voxim-m1-demo-v1", "l0_min" => [-1, 7, -1], "l0_max_exclusive" => [2, 10, 2],
      "travel_min_m" => [-48.0, 464.0, -48.0], "travel_max_exclusive_m" => [112.0, 624.0, 112.0],
      "spawn_probes_m" => [[40.0, 558.0, 40.0]], "spawn_min_y_m" => 464.0, "profile" => profile,
      "collision_window_radius_tiles" => 1}
  end

  defp identity, do: %Session.Identity{session_epoch: 1, scene_id: 1, scene_epoch: 7}

  defp wait(fun, attempts \\ 4000) do
    if value = fun.(), do: value, else: (assert(attempts > 0); Process.sleep(1); wait(fun, attempts - 1))
  end

  defp tick(ctx, tick) do
    :atomics.put(ctx.clock, 1, div(tick * 1_000_000 + 59, 60))
    send(ctx.scene, :tick)
    wait(fn -> Scene.observe(ctx.scene).tick >= tick end)
  end

  defp step(ctx, p, seq, axis_x) do
    frame = %Movement.InputFrame{input_seq: seq, axis_x: axis_x, axis_z: 0, yaw: 0, jump_pressed: 0}
    Player.input(p, identity(), %Movement.InputBatch{identity: identity(), frames: [frame]})
    tick(ctx, seq + ctx.origin - 1)
    wait(fn -> Player.observe(p).processed_input_seq == seq end)
  end

  # 入场、就绪，原地站 4 帧。
  defp enter do
    clock = :atomics.new(1, signed: true)
    source = start_supervised!({Source, %{owner: self()}})
    body_store = start_supervised!({MmoTest.BodyStore, []})

    scene =
      start_supervised!(
        {Scene,
         [scene_id: 1, scene_epoch: 7, world_ref: source, config: config(), clock: {Clock, clock}, sink: Sink,
          body_store: {MmoTest.BodyStore, store: body_store}, world_api: Source]}
      )

    wait(fn -> Scene.observe(scene).initialized end)
    ctx = %{scene: scene, clock: clock}
    {:ok, p} = Scene.join(scene, identity(), %{id: 20}, self())
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
    for seq <- 1..4, do: step(ctx, p, seq, 0)
    {ctx, p, start}
  end

  defp depart(p) do
    ref = make_ref()
    request = %{request_id: 3, client_intent_seq: 50, logical_scene_id: 1, from: "qinglan", to: "ruyuan"}
    Player.beacon_travel(p, identity(), request, {self(), ref})
    assert_receive {:authority, {:prepare_beacon, key, actor, ^request}}, 2000
    assert actor.cid == 20 and actor.position == Player.observe(p).state.position
    {ref, key, request}
  end

  test "放行：落点在当前窗口里，下一个 tick 直接 Relocate 到落点柱上的地面、不请求新窗口，回执一次" do
    {ctx, p, start} = enter()
    {ref, key, request} = depart(p)
    assert {:error, :casting} = Player.tool_context(p, identity())

    send(p, {:beacon_prepared, key, {:ok, 0.05}})
    assert_receive {:authority, {:commit_beacon, ^key, _, ^request}}, 2000
    requested = :sys.get_state(p).requested_window
    committed_at = Player.observe(p).simulation_tick
    send(p, {:beacon_committed, key, {:ok, @landing}})
    assert_receive {^ref, {:ok, 0}}, 2000
    apply_tick = committed_at + 1
    assert_receive {:reliable, _, :voxel, %Voxel.Relocate{apply_tick: ^apply_tick, state: spawned}}, 2000
    {lx, _, lz} = @landing
    {_, ground_y, _} = start.state.position
    assert spawned.position == {lx, ground_y, lz}
    assert :sys.get_state(p).requested_window == requested

    step(ctx, p, 5, 0)
    {x, _, z} = Player.observe(p).state.position
    assert {x, z} == {lx, lz}
    assert {:ok, _} = Player.tool_context(p, identity())
    refute_receive {^ref, _}, 50
  end

  test "读条中走开 0.25 m 以上即打断，不发结束校验、不瞬移" do
    {ctx, p, _} = enter()
    {ref, key, _} = depart(p)
    send(p, {:beacon_prepared, key, {:ok, 30.0}})
    origin = Player.observe(p).state.position
    Enum.reduce_while(5..80, nil, fn seq, _ ->
      step(ctx, p, seq, 32767)
      if :sys.get_state(p).action == nil, do: {:halt, seq}, else: {:cont, nil}
    end)

    assert_receive {^ref, {:error, :beacon_moved}}, 2000
    {x0, _, _} = origin
    {x1, _, _} = Player.observe(p).state.position
    assert x1 - x0 > 0.25
    refute_receive {:authority, {:commit_beacon, _, _, _}}, 50
    refute_receive {:reliable, _, :voxel, %Voxel.Relocate{}}, 0
  end

  test "结束校验拒绝照实回原因，不瞬移，动作槽释放" do
    {_ctx, p, _} = enter()
    {ref, key, _} = depart(p)
    send(p, {:beacon_prepared, key, {:ok, 0.01}})
    assert_receive {:authority, {:commit_beacon, ^key, _, _}}, 2000
    send(p, {:beacon_committed, key, {:error, :beacon_lost}})
    assert_receive {^ref, {:error, :beacon_lost}}, 2000
    assert {:ok, _} = Player.tool_context(p, identity())
    refute_receive {:reliable, _, :voxel, %Voxel.Relocate{}}, 50
  end
end
