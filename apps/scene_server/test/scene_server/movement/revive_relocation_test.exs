defmodule SceneServer.Movement.ReviveRelocationTest do
  @moduledoc """
  只测试：身体闭环 H2 死亡 → 复活回会话出生点（Voxim Docs/Magic.md §6.10），经真实 Scene + Player。

  世界：y = 500 一层地面，出生柱 (40, 558, 40)，入场按同一 `find_spawn` 落到地面上（SessionStart.state = 会话出生点）。
  玩家先按 +x 走 12 帧离开出生点，再把身体置为濒死最后 0.5 s（核心 20 °C、循环与神经为 0，夹具经 `:sys.replace_state`
  写入会话内身体；climate 同法给 20 °C 全局空气，因为本夹具的快照不带属性上下文）。期望（独立依据）：

  - 死亡那一秒下发 BodyState status 2；下一秒复活身体：生命 1 − √(0.15² + 0.55²) = 0.4299 → 43，伤病 = 饥饿 + 虚弱（剩 119 s）
    + 恍惚（剩 39 s）（复活后已推进 1 s）。
  - Relocate.state 的位置 / 速度 / 着地 = SessionStart.state（出生柱不变、世界不变 → 同一落脚点）；
    apply_tick 起从它推进：位置 = 在同一世界从出生点用该 tick 的输入走一步（native `step_characters`）。
  - 非流送：apply_tick = 死亡时模拟 tick + 1；流送：先收到同一 apply_tick 的 Relocate 再收到覆盖出生点的新窗口，
    并且 World（authority）收到 `{:body_death, cid, 脚位}` 与每秒的 `{:body_nervous, cid, 神经}`。
  """
  use ExUnit.Case, async: false
  alias SceneServer.Body
  alias SceneServer.Movement.{Scene, Player, CollisionUpdates}
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

  # 同一进程既是 Scene 的 world_ref（初始快照）也是流送窗口的 authority（`VoxelRegion.World` 的 prepare / canonical_snapshot 调用形状）；
  # 身体消息转给测试进程。
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
      send(subscriber, {:canonical_snapshot, ref, SceneServer.Movement.ReviveRelocationTest.snapshot(box)})
      {:reply, :ok, state}
    end

    def handle_info(message, state) do
      send(state.owner, {:authority, message})
      {:noreply, state}
    end
  end

  @probe [40.0, 558.0, 40.0]

  def snapshot({{x0, y0, z0}, {x1, y1, z1}} = box) do
    floor = for _z <- 0..15, cy <- 0..15, _x <- 0..15, into: <<>>, do: <<if(31 * 16 + cy == 500, do: 1, else: 0)>>

    chunks =
      for x <- (x0 * 4)..(x1 * 4 - 1), y <- (y0 * 4)..(y1 * 4 - 1), z <- (z0 * 4)..(z1 * 4 - 1), y == 31 do
        %Voxel.ChunkOccupancy{coord: {x, y, z}, n: 16, scale_m: 1.0, origin_m: {x * 16.0, y * 16.0, z * 16.0}, cells: floor}
      end

    %Voxel.CanonicalSnapshot{content_version: 9, transaction_seq: 0, l0_min: elem(box, 0), l0_max_exclusive: elem(box, 1),
      chunks: chunks, regions: for(x <- x0..(x1 - 1), y <- y0..(y1 - 1), z <- z0..(z1 - 1), do: {{x, y, z}, <<>>})}
  end

  defp config(radius) do
    path = Path.expand("../../../../../../Voxim/Docs/M0/fixtures/suite.json", __DIR__)
    profile = File.read!(path) |> Jason.decode!() |> Map.fetch!("profile") |> Map.put("fixed_hz", 60)

    %{"schema" => "voxim-m1-demo-v1", "l0_min" => [-1, 7, -1], "l0_max_exclusive" => [2, 10, 2],
      "travel_min_m" => [-48.0, 464.0, -48.0], "travel_max_exclusive_m" => [112.0, 624.0, 112.0],
      "spawn_probes_m" => [@probe], "spawn_min_y_m" => 464.0, "profile" => profile,
      "collision_window_radius_tiles" => radius}
  end

  defp identity, do: %Session.Identity{session_epoch: 1, scene_id: 1, scene_epoch: 7}

  defp setup_scene(radius) do
    clock = :atomics.new(1, signed: true)
    source = start_supervised!({Source, %{owner: self()}})

    scene =
      start_supervised!({Scene, [scene_id: 1, scene_epoch: 7, world_ref: source, config: config(radius),
        clock: {Clock, clock}, sink: Sink, world_api: Source]})

    wait(fn -> Scene.observe(scene).initialized end)
    %{scene: scene, clock: clock, radius: radius}
  end

  defp wait(fun, attempts \\ 4000) do
    if value = fun.(), do: value, else: (assert(attempts > 0); Process.sleep(1); wait(fun, attempts - 1))
  end

  defp tick(ctx, tick) do
    :atomics.put(ctx.clock, 1, div(tick * 1_000_000 + 59, 60))
    send(ctx.scene, :tick)
    wait(fn -> Scene.observe(ctx.scene).tick >= tick end)
  end

  defp frame(seq, axis_x), do: %Movement.InputFrame{input_seq: seq, axis_x: axis_x, axis_z: 0, yaw: 0, jump_pressed: 0}

  defp step(ctx, p, seq, axis_x) do
    Player.input(p, identity(), %Movement.InputBatch{identity: identity(), frames: [frame(seq, axis_x)]})
    tick(ctx, seq + ctx.origin - 1)
    wait(fn -> Player.observe(p).processed_input_seq == seq end)
  end

  # 入场、就绪，按 +x 走 12 帧（模拟 tick = origin + 11）。
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
    assert Player.observe(p).simulation_tick == origin + 11
    {ctx, p, start}
  end

  defp kill(p) do
    :sys.replace_state(p, fn s ->
      %{s | climate: %{"ambient_kelvin" => 293.15, "climate_zones" => []},
        body: %{Body.new() | core_k: 293.15, status: :dying, lethal_s: 129.5}}
    end)

    send(p, :body_tick)
    assert_receive {:reliable, _, :control, %Session.BodyState{status: 2}}, 2000
  end

  defp stepped(start, spawned, axis_x) do
    native = SceneServer.Native.VoximMovement
    world = native.set_chunks(native.new_world(), CollisionUpdates.operations(snapshot({{-1, 7, -1}, {2, 10, 2}}).chunks))
    <<bytes::binary-size(120), 60::16>> = Session.Codec.encode_profile(start.profile)
    profile = for(<<v::float-64 <- bytes>>, do: v) |> List.to_tuple()
    {x, z} = Movement.Codec.axes(frame(0, axis_x))
    [{20, next}] = native.step_characters(world, profile, [{20, {spawned.position, spawned.velocity, spawned.grounded}, {x, z, 0}}])
    next
  end

  defp revived(p) do
    send(p, :body_tick)
    assert_receive {:reliable, _, :control, %Session.BodyState{status: 0} = revived}, 2000
    assert revived.life == 43
    assert {"recovery.weakness", 119.0} in Enum.map(revived.injuries, &{&1.tag, &1.remaining_s})
    assert {"nervous.daze", 39.0} in Enum.map(revived.injuries, &{&1.tag, &1.remaining_s})
    assert "nutrition.hunger" in Enum.map(revived.injuries, & &1.tag)
  end

  defp same_spot?(a, b), do: {a.position, a.velocity, a.grounded} == {b.position, b.velocity, b.grounded}

  test "非流送：死亡下发 status 2 与 Relocate（apply_tick = 死亡时模拟 tick + 1，出生点 = SessionStart），该 tick 从出生点推进；下一秒复活身体" do
    {ctx, p, start} = walk(setup_scene(0))
    refute same_spot?(Player.observe(p).state, start.state)
    kill(p)
    apply_tick = ctx.origin + 12
    assert_receive {:reliable, _, :voxel, %Voxel.Relocate{apply_tick: ^apply_tick, state: spawned}}, 2000
    assert same_spot?(spawned, start.state)
    step(ctx, p, 13, 0)
    assert Player.observe(p).state |> then(&{&1.position, &1.velocity, &1.grounded}) == stepped(start, spawned, 0)
    revived(p)
  end

  test "流送：死亡请求覆盖出生点的新窗口，Relocate 先于同一 apply_tick 的 CollisionWindow；World 收到死亡脚位与神经功能" do
    {ctx, p, start} = walk(setup_scene(1))
    dead_at = Player.observe(p).state.position
    refute same_spot?(Player.observe(p).state, start.state)
    kill(p)
    {x, y, z} = dead_at
    half = start.profile.half_height
    assert_receive {:authority, {:body_death, 20, {^x, feet_y, ^z}}}, 2000
    assert_in_delta feet_y, y - half, 1.0e-12
    assert_receive {:authority, {:body_nervous, 20, nervous}}, 2000
    assert nervous == 0.0
    # 覆盖出生点的窗口异步到达：等它排进 Player 的 FIFO 再推进 tick，窗口在下一个 tick 安装。
    wait(fn -> s = :sys.get_state(p); s.revive == :window and :queue.len(s.updates.queue) > 0 end)
    tick(ctx, ctx.origin + 12)
    assert_receive {:reliable, _, :voxel, %Voxel.Relocate{apply_tick: apply_tick, state: spawned}}, 2000
    assert_receive {:reliable, _, :voxel, %Voxel.CollisionWindow{apply_tick: ^apply_tick, l0_min: {-1, 7, -1}}}, 2000
    assert apply_tick == ctx.origin + 12
    assert same_spot?(spawned, start.state)
    step(ctx, p, 13, 0)
    assert Player.observe(p).state |> then(&{&1.position, &1.velocity, &1.grounded}) == stepped(start, spawned, 0)
    assert :sys.get_state(p).revive == nil
    revived(p)
  end
end
