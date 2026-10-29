defmodule SceneServer.Movement.GmTeleportTest do
  @moduledoc """
  只测试：GM 瞬移（`Player.gm_teleport/2`，部署开关 `:voxel_region, :gm_tools`）经真实 Scene + Player。

  世界：y = 500 一层地面（顶面 501.0 m），出生柱 (40, 558, 40) 入场按 find_spawn 落到地面。期望（独立依据）：
  开关关闭拒绝 `:gm_disabled`；开启后瞬移到 (60, 520, 60) 落在同一地面——x/z 不变、y 等于出生点落地高度
  （同一胶囊、同一地面）；目标在碰撞窗口／活动范围外拒绝 `:outside_collision_window`，位置不变。
  """
  use ExUnit.Case, async: false
  alias SceneServer.Movement.{Scene, Player}
  alias MmoContracts.{Session, Voxel}

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
    use MmoTest.WorldAuthorityDouble
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def init(opts), do: {:ok, opts}
    def authority_ref(pid), do: pid
    def canonical_snapshot_and_subscribe(pid, box, subscriber, ref, _include_chunks \\ true),
      do: GenServer.call(pid, {:canonical_snapshot, box, subscriber, ref})
    def ensure(_state, _level, _region), do: :ok
    def world_call({:canonical_snapshot, box, subscriber, ref}, _, state) do
      send(subscriber, {:canonical_snapshot, ref, SceneServer.Movement.GmTeleportTest.snapshot(box)})
      {:reply, :ok, state}
    end
    def handle_info(_message, state), do: {:noreply, state}
  end

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
      "collision_window_radius_tiles" => 0}
  end

  defp identity, do: %Session.Identity{session_epoch: 1, scene_id: 1, scene_epoch: 7}

  defp wait(fun, attempts \\ 4000) do
    if value = fun.(), do: value, else: (assert(attempts > 0); Process.sleep(1); wait(fun, attempts - 1))
  end

  defp tick(clock, scene, tick) do
    :atomics.put(clock, 1, div(tick * 1_000_000 + 59, 60))
    send(scene, :tick)
    wait(fn -> Scene.observe(scene).tick >= tick end)
  end

  setup do
    previous = Application.get_env(:voxel_region, :gm_tools)
    on_exit(fn -> Application.put_env(:voxel_region, :gm_tools, previous) end)
    clock = :atomics.new(1, signed: true)
    source = start_supervised!({Source, %{}})
    store = start_supervised!({MmoTest.BodyStore, []})
    scene = start_supervised!({Scene, [scene_id: 1, scene_epoch: 7, world_ref: source, config: config(),
      clock: {Clock, clock}, sink: Sink, body_store: {MmoTest.BodyStore, store: store}, world_api: Source]})
    wait(fn -> Scene.observe(scene).initialized end)
    {:ok, p} = Scene.join(scene, identity(), %{id: 20}, self())
    wait(fn -> Scene.observe(scene).queue_length > 0 end)
    tick(clock, scene, 1)
    assert_receive {:reliable, _, :control, %Session.SessionStart{} = start}, 2000
    Player.time_probe(p, identity(), %Session.TimeProbe{request_id: 1, client_send_us: 1})
    %{baseline: {seq, revision}} = :sys.get_state(p)
    Player.ready(p, identity(), seq, revision)
    tick(clock, scene, 3)
    wait(fn -> :sys.get_state(p).ready end)
    %{player: p, start: start}
  end

  test "GM teleport is refused when disabled, lands on the floor when enabled, and stays inside the window", c do
    landed_y = elem(c.start.state.position, 1)
    assert landed_y > 501.0 and landed_y < 503.0
    before = Player.observe(c.player).state.position
    Application.put_env(:voxel_region, :gm_tools, false)
    assert {:error, :gm_disabled} = Player.gm_teleport(c.player, {60.0, 520.0, 60.0})
    assert Player.observe(c.player).state.position == before
    Application.put_env(:voxel_region, :gm_tools, true)
    assert {:ok, {x, y, z} = position} = Player.gm_teleport(c.player, {60.0, 520.0, 60.0})
    assert {x, z} == {60.0, 60.0}
    assert_in_delta y, landed_y, 1.0e-6
    assert Player.observe(c.player).state.position == position
    assert {:error, :outside_collision_window} = Player.gm_teleport(c.player, {200.0, 520.0, 200.0})
    assert Player.observe(c.player).state.position == position
  end
end
