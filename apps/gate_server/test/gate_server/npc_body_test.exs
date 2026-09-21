defmodule GateServer.NpcBodyTest do
  @moduledoc """
  只测试：NPC Body 第一片。真实 Session.Claims、真实 Movement.Scene / Player / P1 NIF、真实时钟；
  只有世界来源是平地替身（不属于本片被验证的责任主体）。观察者是测试进程，以普通玩家 cid 走同一 claim。
  """
  use ExUnit.Case, async: false
  alias GateServer.Npc.Body
  alias GateServer.Npc.Brain.Patrol
  alias MmoContracts.{Movement, Session, Voxel}
  alias SceneServer.Movement.{Player, Scene}

  @npc_a 9001
  @npc_b 9002

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
  end

  describe "patrol decision tree (pure, hand-sequenced events)" do
    alias GateServer.Npc.Brain.Patrol
    @target %{micro: {1, 2, 3}, incarnation: 7, owner: {0, 0}, material: 11, current_hp: 72.0}
    defp obs(tick), do: {:observation, %{self: %{tick: tick}}}
    defp done(id, data \\ nil), do: {:outcome, %{id: id, status: :done, data: data}}

    test "without dig it walks the route in a cycle, one move_to per arrival" do
      state = Patrol.init(%{route: [{1.0, 0.0}, {9.0, 0.0}]})
      {[%{id: 1, verb: :move_to, position: {1.0, 0.0}}], state} = Patrol.handle_event(obs(5), state)
      assert {[], state} = Patrol.handle_event(obs(6), state)
      {[%{id: 2, verb: :move_to, position: {9.0, 0.0}}], state} = Patrol.handle_event(done(1), state)
      # 不是自己在等的 id：忽略。
      assert {[], state} = Patrol.handle_event(done(1), state)
      {[%{id: 3, verb: :move_to, position: {1.0, 0.0}}], _} = Patrol.handle_event(done(2), state)
    end

    test "with dig: probe on arrival, attack the returned identity, cool down 36 ticks, re-probe, leave when it changed" do
      dig = %{direction: {1.0, 0.0, 0.0}, tool_id: 1}
      state = Patrol.init(%{route: [{1.0, 0.0}, {9.0, 0.0}], dig: dig})
      {[%{id: 1}], state} = Patrol.handle_event(obs(100), state)
      {[%{id: 2, verb: :probe_toward, direction: {1.0, 0.0, 0.0}, tool_id: 1}], state} = Patrol.handle_event(done(1), state)
      {[%{id: 3, verb: :use_tool, target: @target}], state} = Patrol.handle_event(done(2, @target), state)
      {[], state} = Patrol.handle_event(done(3, %{seq: 9}), state)
      assert {[], state} = Patrol.handle_event(obs(135), state)
      {[%{id: 4, verb: :probe_toward}], state} = Patrol.handle_event(obs(136), state)
      # 同一身份（HP 变了不算身份变化）→ 继续攻击。
      {[%{id: 5, verb: :use_tool}], state} = Patrol.handle_event(done(4, %{@target | current_hp: 44.0}), state)
      {[], state} = Patrol.handle_event(done(5, %{seq: 10}), state)
      {[%{id: 6, verb: :probe_toward}], state} = Patrol.handle_event(obs(200), state)
      # 命中的是另一个身份 → 原目标没了，走向下一个路点。
      {[%{id: 7, verb: :move_to, position: {9.0, 0.0}}], _} = Patrol.handle_event(done(6, %{@target | incarnation: 8}), state)
    end

    test "a rejected probe or attack is not retried: on to the next waypoint" do
      dig = %{direction: {1.0, 0.0, 0.0}, tool_id: 1}
      state = Patrol.init(%{route: [{1.0, 0.0}, {9.0, 0.0}], dig: dig})
      {_, state} = Patrol.handle_event(obs(1), state)
      {[%{id: 2}], state} = Patrol.handle_event(done(1), state)
      rejected = {:outcome, %{id: 2, status: :rejected, reason: :no_target}}
      {[%{id: 3, verb: :move_to, position: {9.0, 0.0}}], _} = Patrol.handle_event(rejected, state)
    end
  end

  describe "two NPCs in a real Scene" do
    setup do
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
        # 只有一个玩家 probe：两个 NPC 靠显式出生点入场，不占它。
        "spawn_probes_m" => [[44.0, 503.0, 40.0]],
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

      claims = start_supervised!({GateServer.Session.Claims, route_module: Route})

      npc = fn id, cid, spawn, route ->
        start_supervised!(
          {Body,
           claims: claims,
           route_module: Route,
           scene_id: 1,
           cid: cid,
           spawn: spawn,
           brain: {Patrol, %{route: route}}},
          id: id,
          restart: :temporary
        )
      end

      a = npc.(:npc_a, @npc_a, {40.0, 503.0, 40.0}, [{30.0, 40.0}, {40.0, 40.0}])
      b = npc.(:npc_b, @npc_b, {42.0, 503.0, 40.0}, [{42.0, 30.0}, {42.0, 40.0}])

      {:ok, route} = Route.route(1)
      {identity, {:ok, player}} = GenServer.call(claims, {:claim, Scene, Map.put(route, :scene_id, 1), %{id: 20}})
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

    test "input backlog: exactly 120 behind keeps feeding, 121 behind exits for a supervised re-claim",
         %{scene: scene, a: a} do
      assert_receive {:mmo_reliable, _, 1, %Session.EntityEnter{entity_id: @npc_a}}, 8_000
      c = Enum.find(Scene.observe(scene).characters, &(&1.entity_id == @npc_a))
      monitor = Process.monitor(a)

      # 只测试：伪造一条“权威只处理到 seq 10”的 OwnerAck，代表输入补给链路停摆；due = server_tick − origin + 1。
      ack = fn server_tick ->
        %Movement.OwnerAck{
          identity: c.identity,
          server_tick: server_tick,
          processed_input_seq: 10,
          collision_revision: c.collision_revision,
          state: c.state,
          substituted_through_seq: 0
        }
      end

      send(a, {:mmo_datagram, c.identity, ack.(c.origin_tick + 129)})
      refute_receive {:DOWN, ^monitor, _, _, _}, 300
      send(a, {:mmo_datagram, c.identity, ack.(c.origin_tick + 130)})
      assert_receive {:DOWN, ^monitor, :process, ^a, {:input_backlog, 131, 10}}, 1_000
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
