defmodule SceneServer.Movement.VoximTransferTest do
  use ExUnit.Case, async: false
  alias SceneServer.Movement.{Scene, Player}
  alias MmoContracts.{Session, Movement}

  for edit_during_transfer <- [false, true] do
  @tag timeout: 60_000, edit_during_transfer: edit_during_transfer
  test "a boundary cut transfers the unprocessed prefix and activates exactly one writer edits=#{edit_during_transfer}",
      %{edit_during_transfer: edit_during_transfer} do
    base = System.fetch_env!("M4A_BASE")
    world = start_supervised!({VoxelRegion.World, [name: :m4a_transfer_world,
      source: VoxelRegion.GeneratedStore, root: base <> "/transfer-world",
      manifest_path: base <> "/Voxim/Docs/R6/runtime/s4_worldgen_manifest.json"]})
    if edit_during_transfer do
      {_, store} = GenServer.call(world, :source)
      for level <- 1..5 do
        scale = Integer.pow(2, level) * 64
        :ok = VoxelRegion.GeneratedStore.bake_region(store, level,
          {div(42, scale), div(504, scale), div(40, scale)})
      end
    end
    raw = File.read!(base <> "/Voxim/Docs/M1/fixtures/demo-config.json") |> Jason.decode!()
    anchor = System.system_time(:microsecond)
    scenes = for id <- 1..2 do
      config = raw |> Map.put("spawn_probes_m", [Enum.at(raw["spawn_probes_m"], id - 1)])
        |> Map.update!(if(id == 1, do: "travel_max_exclusive_m", else: "travel_min_m"),
          fn [_, y, z] -> [41, y, z] end)
      box = {List.to_tuple(raw["l0_min"]), List.to_tuple(raw["l0_max_exclusive"])}
      replica = start_supervised!(Supervisor.child_spec({VoxelRegion.Replica,
        [authority_ref: world, l0_box: box, name: nil]}, id: {:replica, id}))
      start_supervised!(Supervisor.child_spec({Scene, [scene_id: id, scene_epoch: 1,
        world_ref: replica, world_api: VoxelRegion.Replica, config: config,
        timeline_origin_us: anchor]}, id: {:scene, id}))
    end
    [a, b] = scenes
    for p <- scenes, do: await(fn -> Scene.observe(p).initialized end)
    previous = Application.get_env(:world_server, :movement_routes)
    Application.put_env(:world_server, :movement_routes, Map.new(Enum.with_index(scenes, 1),
      fn {p, id} -> {id, %{scene_ref: p, world_ref: world, scene_epoch: 1}} end))
    on_exit(fn -> if previous, do: Application.put_env(:world_server, :movement_routes, previous),
      else: Application.delete_env(:world_server, :movement_routes) end)
    assert :ok = WorldServer.Movement.connect_neighbours(1, 2)
    {:ok, ae} = Scene.neighbour_endpoint(a)
    {:ok, be} = Scene.neighbour_endpoint(b)
    assert ae.origin_us == be.origin_us
    old = %Session.Identity{session_epoch: 10, scene_id: 1, scene_epoch: 1}
    new = %Session.Identity{session_epoch: 11, scene_id: 2, scene_epoch: 1}
    {:ok, source} = Scene.join(a, old, %{id: 100}, self())
    assert_receive {:mmo_reliable, ^old, 1, %Session.SessionStart{} = start}, 5000
    assert_receive {:mmo_reliable, ^old, 2, %MmoContracts.Voxel.CanonicalBootstrap{}}, 5000
    Player.time_probe(source, old, %Session.TimeProbe{request_id: 1, client_send_us: 1})
    Player.ready(source, old, start.baseline_transaction_seq, start.collision_revision)
    assert_receive {:mmo_reliable, ^old, 1, %Session.InputStart{} = input_start}, 2000
    # 已生成的帧全部经唯一输入 owner 接纳；越界后仍排队，不能继续积分。
    frames = for seq <- 1..120, do: %Movement.InputFrame{input_seq: seq, axis_x: if(seq <= 45, do: 32767, else: 0),
      axis_z: 0, yaw: 0, jump_pressed: 0}
    Player.input(source, old, %Movement.InputBatch{identity: old, frames: frames})
    assert_receive {:mmo_transfer_request, ^old, ^source, 2}, 5000
    if edit_during_transfer do
      # 源停在边界；让首次编辑明确晚于已排队的 120 帧，检查历史回放而非当前 world。
      await(fn -> Scene.observe(a).tick >= input_start.origin_tick + 119 end)
      assert {:ok, 1} = VoxelRegion.World.apply_edit(world, {42, 504, 40}, 11)
      await(fn -> Scene.observe(a).transaction_seq == 1 end)
      published = Scene.observe(a).tick
      await(fn -> Player.observe(source).published_tick >= published end)
    end
    assert {:ok, cut} = Player.seal(source, old)
    assert cut.slots.processed_input_seq > 0 and cut.slots.processed_input_seq < 120
    assert elem(cut.state.position, 0) >= 41
    source_steps = Player.observe(source).physics_steps
    Process.sleep(40)
    assert Player.observe(source).physics_steps == source_steps
    if edit_during_transfer do
      assert cut.transaction_seq == 1 and cut.simulation_revision == 1
      assert {:ok, 2} = VoxelRegion.World.apply_edit(world, {43, 504, 40}, 11)
      await(fn -> Scene.observe(b).transaction_seq == 2 end)
    end
    assert {:ok, target} = WorldServer.Movement.prepare_transfer(old, new, cut, self())
    assert Player.observe(target).physics_steps == 0
    refute Player.observe(target).active
    # 控制面 Ready 到达之前，新旧重复输入都不能激活目标。
    Player.input(target, old, %Movement.InputBatch{identity: old, frames: frames})
    Player.input(target, new, %Movement.InputBatch{identity: new, frames: frames})
    Process.sleep(40)
    assert Player.observe(target).physics_steps == 0
    assert :ok = WorldServer.Movement.commit_transfer(old, new)
    await(fn -> Player.observe(target).processed_input_seq == 120 end)
    final = Player.observe(target)
    assert final.physics_steps == 120 - cut.slots.processed_input_seq
    assert final.entity_epoch == start.entity_epoch
    assert final.old_identity == 1
    if edit_during_transfer do
      assert final.collision_revision == 1
      assert final.simulation_tick == input_start.origin_tick + 119
    end
    assert Scene.observe(a).character_count == 0
    assert Scene.observe(b).character_count == 1
    refute Process.alive?(source)
    Player.input(target, new, %Movement.InputBatch{identity: new, frames: frames})
    Process.sleep(40)
    assert Player.observe(target).physics_steps == final.physics_steps
    if edit_during_transfer do
      assert {:ok, 3} = VoxelRegion.World.apply_edit(world, {42, 504, 40}, 0)
      publications = through_fence(new, 3)
      assert Enum.flat_map(publications, fn
        {:voxel_log_transaction_payload, bytes} ->
          {:ok, transaction} = MmoContracts.Voxel.Codec.decode_transaction(bytes)
          [transaction.seq]
        _ -> []
      end) == [2, 3]
      applied = Enum.filter(publications, &match?(%MmoContracts.Voxel.CollisionApplied{}, &1))
      assert [%{transaction_seq: 2, collision_revision: 3, apply_tick: second_tick},
        %{transaction_seq: 3, collision_revision: 4, apply_tick: third_tick}] = applied
      assert second_tick > cut.published_tick and third_tick > second_tick
      assert_transaction_order(publications)

      last_seq = third_tick - input_start.origin_tick + 4
      send_frames(target, new, 121..last_seq, 0)
      await(fn -> Player.observe(target).processed_input_seq == last_seq end)
      continued = Player.observe(target)
      assert continued.collision_revision == 4
      assert continued.physics_steps == last_seq - cut.slots.processed_input_seq

    end
  end
  end

  defp send_frames(player, identity, range, axis) do
    frames = for seq <- range, do: %Movement.InputFrame{input_seq: seq,
      axis_x: axis, axis_z: 0, yaw: 0, jump_pressed: 0}
    Player.input(player, identity, %Movement.InputBatch{identity: identity, frames: frames})
  end

  defp through_fence(identity, seq, acc \\ []) do
    receive do
      {:mmo_reliable, ^identity, 2, event} ->
        case event do
          %MmoContracts.Voxel.TimelineFence{transaction_seq: n} when n >= seq -> Enum.reverse([event | acc])
          _ -> through_fence(identity, seq, [event | acc])
        end
    after
      5000 -> flunk("missing transfer timeline fence N=#{seq}")
    end
  end

  defp assert_transaction_order(events, baseline \\ 1) do
    Enum.reduce(events, {nil, baseline}, fn
      {:voxel_log_transaction_payload, bytes}, {_, applied} ->
        {:ok, transaction} = MmoContracts.Voxel.Codec.decode_transaction(bytes)
        {transaction.seq, applied}
      %MmoContracts.Voxel.CollisionApplied{transaction_seq: seq}, {logged, _} ->
        assert logged == seq
        {logged, seq}
      %MmoContracts.Voxel.TimelineFence{transaction_seq: seq}, {logged, applied} ->
        assert seq <= applied
        {logged, applied}
    end)
  end

  defp await(fun, left \\ 5000) do
    unless fun.() do
      assert left > 0
      Process.sleep(10)
      await(fun, left - 10)
    end
  end
end
