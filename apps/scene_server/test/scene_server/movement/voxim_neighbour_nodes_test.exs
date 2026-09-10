defmodule SceneServer.Movement.VoximNeighbourNodesTest do
  use ExUnit.Case, async: false
  alias SceneServer.Movement.{Scene, Player, Replication, Clock}
  alias MmoContracts.{Session, Movement}

  @tag timeout: 120_000
  test "remote Scene derives collision from the same canonical World without moving native source state" do
    base = System.fetch_env!("M4A_BASE")
    nodes = Enum.reduce(1..2, [], fn id, previous ->
      {:ok, peer, host} = :peer.start_link(%{name: String.to_atom("m4a_shared_#{id}_#{System.unique_integer([:positive])}"),
        connection: :standard_io, args: [~c"+S", ~c"2:2"]})
      Process.unlink(peer)
      on_exit(fn -> if Process.alive?(peer), do: :peer.stop(peer) end)
      :ok = :peer.call(peer, :code, :add_paths, [:code.get_path()])
      true = :peer.call(peer, :code, :add_patha, [String.to_charlist(base <> "/ebin")])
      {:ok, _} = :peer.call(peer, :application, :ensure_all_started, [:elixir])
      {:ok, _} = :peer.call(peer, :application, :ensure_all_started, [:logger])
      :ok = :peer.call(peer, Logger, :configure, [[level: :info]])
      :peer.call(peer, Code, :require_file, [Path.join(__DIR__, "voxim_neighbour_probe.exs")])
      world = if previous == [], do: nil, else: hd(previous).world
      info = :peer.call(peer, SceneServer.Movement.VoximNeighbourNodesProbe, :boot, [base, id, world])
      assert Node.connect(host)
      await(fn -> Scene.observe(info.scene).initialized end, 5000)
      previous ++ [info]
    end)
    [a, b] = nodes
    assert a.world == b.world
    assert node(b.scene) != node(b.world)
    {:ok, ae} = Scene.neighbour_endpoint(a.scene)
    {:ok, be} = Scene.neighbour_endpoint(b.scene)
    assert ae.content_version == be.content_version
    identity = %Session.Identity{session_epoch: 2, scene_id: 2, scene_epoch: 1}
    {:ok, player} = Scene.join(b.scene, identity, %{id: 2}, self())
    assert_receive {:mmo_reliable, ^identity, 1, %Session.SessionStart{} = start}, 10_000
    assert start.state.grounded == 1
    assert_receive {:mmo_reliable, ^identity, 2, %MmoContracts.Voxel.CanonicalBootstrap{}}, 10_000
    assert node(player) == b.node
  end

  @tag timeout: 120_000
  test "two BEAM Scene/World nodes move through P1 and publish neighbouring authority to their own observers" do
    base = System.fetch_env!("M4A_BASE")
    peers = for id <- 1..2 do
      {:ok, peer, node} = :peer.start_link(%{name: String.to_atom("m4a_scene_#{id}_#{System.unique_integer([:positive])}"),
        connection: :standard_io, args: [~c"+S", ~c"2:2"]})
      Process.unlink(peer)
      on_exit(fn -> if Process.alive?(peer), do: :peer.stop(peer) end)
      :ok = :peer.call(peer, :code, :add_paths, [:code.get_path()])
      true = :peer.call(peer, :code, :add_patha, [String.to_charlist(base <> "/ebin")])
      {:ok, _} = :peer.call(peer, :application, :ensure_all_started, [:elixir])
      {:ok, _} = :peer.call(peer, :application, :ensure_all_started, [:logger])
      :ok = :peer.call(peer, Logger, :configure, [[level: :info]])
      :peer.call(peer, Code, :require_file, [Path.join(__DIR__, "voxim_neighbour_probe.exs")])
      # 远端仅加载探针模块，测试注册不参与运行。
      info = :peer.call(peer, SceneServer.Movement.VoximNeighbourNodesProbe, :boot, [base, id])
      assert Node.connect(node)
      await(fn -> Scene.observe(info.scene).initialized end, 15_000)
      info
    end
    [a, b] = peers
    assert a.node != b.node and a.os_pid != b.os_pid
    assert node(a.scene) == a.node and node(b.scene) == b.node
    assert node(a.world) == a.node and node(b.world) == b.node
    routes = Map.new(Enum.with_index(peers, 1), fn {p, id} ->
      {id, %{scene_ref: p.scene, world_ref: p.world, scene_epoch: 1}}
    end)
    Application.put_env(:world_server, :movement_routes, routes)
    on_exit(fn -> Application.delete_env(:world_server, :movement_routes) end)
    :ok = WorldServer.Movement.connect_neighbours(1, 2)
    {:ok, ae} = Scene.neighbour_endpoint(a.scene)
    {:ok, be} = Scene.neighbour_endpoint(b.scene)
    assert ae.origin_us != be.origin_us

    players = for {p, id} <- Enum.with_index(peers, 1) do
      identity = %Session.Identity{session_epoch: id, scene_id: id, scene_epoch: 1}
      {:ok, player} = Scene.join(p.scene, identity, %{id: id}, self())
      assert_receive {:mmo_reliable, ^identity, 1, %Session.SessionStart{} = start}, 15_000
      assert start.state.grounded == 1
      assert_receive {:mmo_reliable, ^identity, 2, %MmoContracts.Voxel.CanonicalBootstrap{}}, 15_000
      Player.time_probe(player, identity, %Session.TimeProbe{request_id: id, client_send_us: 1})
      Player.ready(player, identity, start.baseline_transaction_seq, start.collision_revision)
      assert_receive {:mmo_reliable, ^identity, 1, %Session.InputStart{} = input_start}, 3000
      %{pid: player, identity: identity, initial: start.state, origin: input_start.origin_tick}
    end
    # 每100ms生成真实6帧，两个 Scene 使用正常 wall clock，各自按历史碰撞积分。
    samples = for batch <- 0..19 do
      for p <- players do
        frames = for i <- 1..6 do
          seq = batch * 6 + i
          %Movement.InputFrame{input_seq: seq, axis_x: 0,
            axis_z: cond do seq <= 45 -> -32767; seq <= 90 -> 32767; true -> 0 end, yaw: 0,
            jump_pressed: if(seq == 30, do: 1, else: 0)}
        end
        Player.input(p.pid, p.identity, %Movement.InputBatch{identity: p.identity, frames: frames})
      end
      Process.sleep(100)
      values = Enum.map(players, &Player.observe(&1.pid))
      IO.puts("M4A_SAMPLE " <> inspect(Enum.map(values, &Map.take(&1, [:entity_id, :state, :processed_input_seq]))))
      values
    end
    await(fn -> Enum.all?(players, &(Player.observe(&1.pid).processed_input_seq == 120)) end, 5000)
    final = Enum.map(players, &Player.observe(&1.pid))
    assert Enum.all?(final, &(&1.physics_steps >= 120 and &1.rejected_inputs == 0 and &1.active))
    assert Enum.all?(0..1, fn i -> Enum.any?(samples, fn pair ->
      elem(Enum.at(pair, i).state.position, 1) > elem(Enum.at(players, i).initial.position, 1) + 0.5
    end) end)
    assert Enum.all?(0..1, fn i -> Enum.any?(samples, fn pair ->
      abs(elem(Enum.at(pair, i).state.position, 2) - elem(Enum.at(players, i).initial.position, 2)) > 1
    end) end)
    for {p, remote_id} <- Enum.zip(peers, [2, 1]) do
      assert [%{visible: [%{entity_id: ^remote_id}]}] = Replication.observe(Scene.observe(p.scene).replication_pid)
    end
    events = drain([])
    snapshots = for {:mmo_datagram, identity, %Movement.Snapshot{} = s} <- events, do: {identity, s}
    for {local, remote, offset} <- [{hd(players), List.last(final), be.origin_us - ae.origin_us},
                                  {List.last(players), hd(final), ae.origin_us - be.origin_us}] do
      matching = for {identity, s} <- snapshots, identity == local.identity,
        Enum.any?(s.records, &(&1.entity_id == remote.entity_id)), do: s
      assert length(matching) >= 10
      newest = Enum.max_by(matching, & &1.server_tick)
      # 最后快照允许一次发布延迟；时钟转换必须接近真实源的历史步。
      expected = Clock.translate_tick(remote.simulation_tick, offset)
      assert abs(newest.server_tick - expected) <= 9
    end
    # 真实 canonical 源终止后 Scene 停 tick；邻区仍须可靠清理，不能等下一帧。
    :ok = :erpc.call(b.node, Supervisor, :terminate_child, [b.supervisor, VoxelRegion.World])
    ai = hd(players).identity
    assert_receive {:mmo_reliable, ^ai, 1, %Session.EntityLeave{entity_id: 2}}, 2000
    await(fn -> Scene.observe(b.scene).character_count == 0 end, 2000)
    assert Scene.observe(b.scene).failure == 5
    assert :erpc.call(b.node, Process, :alive?, [be.pid])
    assert [%{visible: []}] = Replication.observe(ae.pid)

    summary = %{nodes: Enum.map(peers, &%{node: Atom.to_string(&1.node), os_pid: &1.os_pid}),
      origin_offset_us: be.origin_us - ae.origin_us, snapshots: length(snapshots),
      processed: Enum.map(final, & &1.processed_input_seq), steps: Enum.map(final, & &1.physics_steps),
      sources: "GeneratedStore + independent file overlay; production Scene/Player/P1",
      boundary_x_m: 41, transport: "distributed BEAM + production Sink; no UE/QUIC",
      snapshot_body_bytes: Enum.sum(Enum.map(snapshots, fn {_, s} ->
        {:ok, bytes} = Movement.Codec.encode(s)
        byte_size(bytes)
      end))}
    File.write!(base <> "/nodes.json", Jason.encode!(summary))
    IO.puts("M4A_TWO_NODE " <> Jason.encode!(summary))
  end

  defp await(predicate, remaining) do
    if not predicate.() do
      assert remaining > 0
      Process.sleep(10)
      await(predicate, remaining - 10)
    end
  end
  defp drain(events) do
    receive do event -> drain([event | events]) after 0 -> events end
  end
end
