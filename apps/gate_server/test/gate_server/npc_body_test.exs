defmodule GateServer.NpcBodyTest do
  @moduledoc """
  只测试：NPC Body 第一片。真实 QuicListener claim、真实 Movement.Scene / Player / P1 NIF、真实时钟；
  只有世界来源是平地替身（不属于本片被验证的责任主体）。观察者是测试进程，以普通玩家 cid 走同一 claim。
  """
  use ExUnit.Case, async: false
  import Bitwise
  alias GateServer.Npc.Body
  alias MmoContracts.{Movement, Session, Voxel}
  alias SceneServer.Movement.{Player, Scene}

  @npc_a (1 <<< 63) + 1
  @npc_b (1 <<< 63) + 2

  defmodule Source do
    use GenServer
    def start_link(snapshot), do: GenServer.start_link(__MODULE__, snapshot)
    def init(snapshot), do: {:ok, snapshot}

    def canonical_snapshot_and_subscribe(pid, _box, subscriber, ref, _chunks \\ true),
      do: GenServer.call(pid, {:snapshot, subscriber, ref})

    def handle_call({:snapshot, subscriber, ref}, _, snapshot) do
      send(subscriber, {:canonical_snapshot, ref, snapshot})
      {:reply, :ok, snapshot}
    end
  end

  defmodule Route do
    def route(1), do: {:ok, %{scene_ref: Process.whereis(:npc_body_scene), scene_epoch: 7}}
  end

  describe "pure input generation (hand-computed)" do
    test "steer uses canonical world axes; yaw 0=+X, 16384=+Z, 32768=-X, 49152=-Z" do
      assert {32767, 0, 0} == Body.steer({0.0, 9.0, 0.0}, {10.0, 0.0})
      assert {0, 32767, 16384} == Body.steer({0.0, 9.0, 0.0}, {0.0, 10.0})
      assert {-32767, 0, 32768} == Body.steer({5.0, 9.0, 0.0}, {-5.0, 0.0})
      assert {0, -32767, 49152} == Body.steer({0.0, 9.0, 5.0}, {0.0, -5.0})
      # 3-4-5：0.6·32767=19660.2，0.8·32767=26213.6，atan2(4,3)=0.927295 rad → 9672.2
      assert {19660, 26214, 9672} == Body.steer({1.0, 0.0, 1.0}, {4.0, 5.0})
    end

    test "first feed sends seq 1..8; steady state appends only the missing tail" do
      steering = {32767, 0, 0}
      assert Enum.to_list(1..8) == Enum.map(Body.frames(0, 0, 0, steering), & &1.input_seq)
      assert [9, 10, 11] == Enum.map(Body.frames(8, 3, 0, steering), & &1.input_seq)
      assert [] == Body.frames(11, 3, 0, steering)
    end

    test "expired unsent slots are zero input with the last sent yaw; new action only in future slots" do
      frames = Body.frames(3, 10, 777, {0, 32767, 16384})
      assert Enum.to_list(4..18) == Enum.map(frames, & &1.input_seq)
      {expired, future} = Enum.split_with(frames, &(&1.input_seq <= 10))
      assert Enum.all?(expired, &({&1.axis_x, &1.axis_z, &1.yaw} == {0, 0, 777}))
      assert Enum.all?(future, &({&1.axis_x, &1.axis_z, &1.yaw} == {0, 32767, 16384}))
    end

    test "route advances only inside the arrival radius and cycles" do
      route = [{10.0, 0.0}, {20.0, 0.0}]
      assert route == Body.advance_route({10.6, 0.0, 0.0}, route)
      assert [{20.0, 0.0}, {10.0, 0.0}] == Body.advance_route({10.4, 0.0, 0.0}, route)
    end
  end

  describe "two NPCs in a real Scene" do
    setup do
      {:ok, _} = Application.ensure_all_started(:quicer)
      certs = System.fetch_env!("VOXIM_TEST_CERTS") <> "/"
      port = System.get_env("VOXIM_TEST_QUIC_PORT", "25443") |> String.to_integer()

      profile =
        Path.expand("../../../../../Voxim/Docs/M0/fixtures/suite.json", __DIR__)
        |> File.read!()
        |> Jason.decode!()
        |> Map.fetch!("profile")
        |> Map.put("fixed_hz", 60)

      config = %{
        "schema" => "voxim-m1-demo-v1",
        "l0_min" => [-1, 7, -1],
        "l0_max_exclusive" => [1, 9, 1],
        "travel_min_m" => [-48.0, 464.0, -48.0],
        "travel_max_exclusive_m" => [48.0, 560.0, 48.0],
        "spawn_probes_m" => [[40.0, 503.0, 40.0], [42.0, 503.0, 40.0], [44.0, 503.0, 40.0]],
        "spawn_min_y_m" => 464.0,
        "profile" => profile
      }

      # 平地：y=500 一层实心。
      chunks =
        for x <- -4..3, y <- 28..35, z <- -4..3 do
          cells =
            for _ <- 0..15, cy <- 0..15, _ <- 0..15, into: <<>>, do: <<if(y * 16 + cy == 500, do: 1, else: 0)>>

          %Voxel.ChunkOccupancy{
            coord: {x, y, z},
            n: 16,
            scale_m: 1.0,
            origin_m: {x * 16.0, y * 16.0, z * 16.0},
            cells: cells
          }
        end

      snapshot = %Voxel.CanonicalSnapshot{
        content_version: 9,
        transaction_seq: 0,
        l0_min: {-1, 7, -1},
        l0_max_exclusive: {1, 9, 1},
        chunks: chunks,
        regions: for(x <- -1..0, y <- 7..8, z <- -1..0, do: {{x, y, z}, <<>>})
      }

      source = start_supervised!({Source, snapshot})

      scene =
        start_supervised!(
          {Scene,
           [
             name: :npc_body_scene,
             scene_id: 1,
             scene_epoch: 7,
             world_ref: source,
             world_api: Source,
             config: config
           ]}
        )

      listener =
        start_supervised!(
          {GateServer.Transport.QuicListener,
           [
             port: port,
             certfile: certs <> "server.pem",
             keyfile: certs <> "server.key",
             hello: %Session.Hello{
               protocol_version: Session.Codec.protocol_version(),
               kernel_id: <<1::256>>,
               profile_id: <<2::256>>
             },
             route_module: Route
           ]}
        )

      npc = fn id, cid, route ->
        start_supervised!(
          {Body, listener: listener, route_module: Route, scene_id: 1, cid: cid, route: route},
          id: id,
          restart: :temporary
        )
      end

      # 先 claim 的占 probe 0（x=40）与 probe 1（x=42）。
      a = npc.(:npc_a, @npc_a, [{30.0, 40.0}, {40.0, 40.0}])
      b = npc.(:npc_b, @npc_b, [{42.0, 30.0}, {42.0, 40.0}])

      {:ok, route} = Route.route(1)
      {identity, {:ok, player}} = GenServer.call(listener, {:claim, Scene, Map.put(route, :scene_id, 1), %{id: 20}})
      Player.time_probe(player, identity, %Session.TimeProbe{request_id: 1, client_send_us: 0})
      assert_receive {:mmo_reliable, ^identity, 1, %Session.SessionStart{} = start}, 5_000
      Player.ready(player, identity, start.baseline_transaction_seq, start.collision_revision)
      %{scene: scene, a: a, b: b}
    end

    defp samples(deadline, acc) do
      receive do
        {:mmo_datagram, _, %Movement.Snapshot{records: records}} ->
          acc =
            Enum.reduce(records, acc, fn r, acc ->
              Map.update(acc, r.entity_id, [r.state.position], &(&1 ++ [r.state.position]))
            end)

          samples(deadline, acc)

        _ ->
          samples(deadline, acc)
      after
        max(0, deadline - System.monotonic_time(:millisecond)) -> acc
      end
    end

    test "observer sees both NPC entities patrol their own world-axis routes, and lifecycle cleans up both ways",
         %{scene: scene, a: a, b: b} do
      assert_receive {:mmo_reliable, _, 1, %Session.EntityEnter{entity_id: @npc_a}}, 8_000
      assert_receive {:mmo_reliable, _, 1, %Session.EntityEnter{entity_id: @npc_b}}, 8_000

      seen = samples(System.monotonic_time(:millisecond) + 6_000, %{})
      xs = for {x, _, _} <- seen[@npc_a], do: x
      zs_a = for {_, _, z} <- seen[@npc_a], do: z
      zs = for {_, _, z} <- seen[@npc_b], do: z
      xs_b = for {x, _, _} <- seen[@npc_b], do: x

      # A 沿 −X 走到 x≈30 后折返；全程 z 不变。B 沿 −Z 走到 z≈30 后折返；全程 x 不变。
      assert [_ | _] = after_turn = Enum.drop_while(xs, &(&1 >= 31.0))
      assert Enum.max(after_turn) > 33.0
      assert Enum.all?(zs_a, &(abs(&1 - 40.0) < 0.2))
      assert [_ | _] = after_turn_b = Enum.drop_while(zs, &(&1 >= 31.0))
      assert Enum.max(after_turn_b) > 33.0
      assert Enum.all?(xs_b, &(abs(&1 - 42.0) < 0.2))

      # 输入确实被权威连续消费，而不是靠 joining_zero 漂移。
      by_id = Map.new(Scene.observe(scene).characters, &{&1.entity_id, &1})
      assert by_id[@npc_a].processed_input_seq > 200
      assert by_id[@npc_b].processed_input_seq > 200

      # Body 死：Player 随 gate 退出，观察者收到 Leave，名额释放。
      Process.exit(a, :kill)
      assert_receive {:mmo_reliable, _, 1, %Session.EntityLeave{entity_id: @npc_a}}, 3_000
      refute Enum.any?(Scene.observe(scene).characters, &(&1.entity_id == @npc_a))

      # Scene 侧先结束会话：Body 消费 mmo_close 后以会话原因退出。
      monitor = Process.monitor(b)
      Scene.leave(scene, by_id[@npc_b].identity, 4)
      assert_receive {:DOWN, ^monitor, :process, ^b, {:session_closed, 4}}, 3_000
    end
  end
end
