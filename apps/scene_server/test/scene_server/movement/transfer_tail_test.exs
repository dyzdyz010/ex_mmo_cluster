defmodule SceneServer.Movement.TransferTailTest do
  @moduledoc """
  只测试：无 stream 移交时，canonical 副本已退休 cut 之后的历史（m2a §6.3）。时钟、canonical 来源与身体持久化用本例独占替身；
  Scene、Player 与碰撞 NIF 为真实模块，cut 经真实移动与 `Player.seal` 产生。
  """
  use ExUnit.Case, async: false
  alias MmoContracts.{Movement, Session, Voxel}
  alias SceneServer.Movement.{Player, Scene}

  defmodule Clock do
    def now(ref), do: :atomics.get(ref, 1)
    def schedule(_, _, _), do: :ok
  end

  defmodule Source do
    @moduledoc "只测试：固定快照；cut 之后的增量已被退休（同 `Replica.canonical_deltas_after/2` 的显式拒绝）。"
    use GenServer
    def start_link(snapshot), do: GenServer.start_link(__MODULE__, snapshot)
    def init(snapshot), do: {:ok, snapshot}

    def canonical_snapshot_and_subscribe(pid, _, subscriber, ref, _),
      do: GenServer.call(pid, {:snapshot, subscriber, ref})

    def canonical_deltas_after(pid, seq), do: GenServer.call(pid, {:deltas_after, seq})

    def handle_call({:snapshot, subscriber, ref}, _, snapshot) do
      send(subscriber, {:canonical_snapshot, ref, snapshot})
      {:reply, :ok, snapshot}
    end

    def handle_call({:deltas_after, _seq}, _, snapshot),
      do: {:reply, {:error, :before_replica_snapshot}, snapshot}
  end

  setup do
    profile =
      Path.expand("../../../../../../Voxim/Docs/M0/fixtures/suite.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("profile")
      |> Map.put("fixed_hz", 60)

    base = %{
      "schema" => "voxim-m1-demo-v1",
      "l0_min" => [-1, -1, -1],
      "l0_max_exclusive" => [1, 1, 1],
      "spawn_min_y_m" => -20.0,
      "profile" => profile
    }

    snapshot = %Voxel.CanonicalSnapshot{
      content_version: 9,
      transaction_seq: 0,
      l0_min: {-1, -1, -1},
      l0_max_exclusive: {1, 1, 1},
      chunks:
        for(
          x <- 0..1,
          do: %Voxel.ChunkOccupancy{
            coord: {x, 0, 0},
            n: 16,
            scale_m: 1.0,
            origin_m: {x * 16.0, 0.0, 0.0},
            cells:
              for(
                _z <- 0..15,
                y <- 0..15,
                _x <- 0..15,
                into: <<>>,
                do: <<if(y == 0, do: 1, else: 0)>>
              )
          }
        ),
      regions: for(x <- -1..0, y <- -1..0, z <- -1..0, do: {{x, y, z}, <<>>})
    }

    clock = :atomics.new(1, signed: true)
    source = start_supervised!({Source, snapshot})
    store = start_supervised!({MmoTest.BodyStore, []})

    # 两个相邻 Scene 以 x = 3 m 为界；源 Scene 只在界内出生。
    [scene, other] =
      for {id, travel_min, travel_max, spawn} <- [
            {1, [-30.0, -30.0, -30.0], [3.0, 30.0, 30.0], [2.0, 10.0, 2.0]},
            {2, [3.0, -30.0, -30.0], [30.0, 30.0, 30.0], [5.0, 10.0, 2.0]}
          ] do
        config =
          Map.merge(base, %{
            "travel_min_m" => travel_min,
            "travel_max_exclusive_m" => travel_max,
            "spawn_probes_m" => [spawn]
          })

        start_supervised!(
          Supervisor.child_spec(
            {Scene,
             [
               scene_id: id,
               scene_epoch: 7,
               world_ref: source,
               world_api: Source,
               config: config,
               clock: {Clock, clock},
               body_store: {MmoTest.BodyStore, store: store}
             ]},
            id: {:scene, id}
          )
        )
      end

    for s <- [scene, other], do: await(fn -> Scene.observe(s).initialized end)
    {:ok, endpoint} = Scene.neighbour_endpoint(other)
    :ok = Scene.connect_neighbour(scene, endpoint.pid, 0, endpoint)
    %{scene: scene, other: other, clock: clock}
  end

  test "无 stream 移交遇到已退休的增量历史：目标 Scene 显式拒绝、不建 Player、自身照常运行", ctx do
    who = %Session.Identity{session_epoch: 1, scene_id: 1, scene_epoch: 7}
    profile = %{MmoContracts.Relation.blank() | name: "移交玩家"}
    {:ok, player} = Scene.join(ctx.scene, who, %{id: 10, kind: "player", profile: profile}, self())
    await(fn -> Scene.observe(ctx.scene).queue_length > 0 end)
    tick(ctx)
    assert_receive {:mmo_reliable, ^who, 1, %Session.SessionStart{} = start}, 2000
    Player.time_probe(player, who, %Session.TimeProbe{request_id: 1, client_send_us: 0})
    Player.ready(player, who, start.baseline_transaction_seq, start.collision_revision)
    Player.observe(player)
    tick(ctx)
    info = Player.observe(player)
    for _ <- (Scene.observe(ctx.scene).tick + 1)..(info.origin_tick - 1), do: tick(ctx)

    frames =
      for seq <- 1..60,
          do: %Movement.InputFrame{input_seq: seq, axis_x: 32767, axis_z: 0, yaw: 0, jump_pressed: 0}

    for batch <- Enum.chunk_every(frames, 6),
        do: Player.input(player, who, %Movement.InputBatch{identity: who, frames: batch})

    Player.observe(player)
    for _ <- 1..60, do: tick(ctx)
    assert_receive {:mmo_transfer_request, ^who, ^player, 2}, 2000
    assert {:ok, cut} = Player.seal(player, who)
    assert cut.stream == nil

    next = %Session.Identity{session_epoch: 2, scene_id: 2, scene_epoch: 7}
    assert {:error, :before_replica_snapshot} = Scene.prepare_transfer(ctx.other, next, cut, self())
    assert Process.alive?(ctx.other)
    assert Scene.observe(ctx.other).characters == []
  end

  defp tick(ctx) do
    target = Scene.observe(ctx.scene).tick + 1
    :atomics.put(ctx.clock, 1, div(target * 1_000_000 + 59, 60))
    send(ctx.scene, :tick)
    await(fn -> Scene.observe(ctx.scene).tick == target end)
  end

  defp await(predicate, attempts \\ 1000) do
    if predicate.() do
      :ok
    else
      assert attempts > 0
      Process.sleep(1)
      await(predicate, attempts - 1)
    end
  end
end
