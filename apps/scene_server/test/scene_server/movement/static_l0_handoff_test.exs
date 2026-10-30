Code.require_file("../../../../voxel_region/test/support/world_fixtures.exs", __DIR__)
Code.require_file("../../../../voxel_region/test/support/world_clock.exs", __DIR__)
Code.require_file("../../../../voxel_region/test/support/static_l0_check.exs", __DIR__)

defmodule SceneServer.Movement.StaticL0HandoffTest do
  @moduledoc "只测试：真实 GeneratedStore、World、Scene、Player 和 CollisionStream 的 seal/import；身体存储与出站网络用声明的内存依赖，不声称 QUIC／UE 已验收。"
  use ExUnit.Case, async: false
  @moduletag timeout: 240_000
  alias VoxelRegion.{GeneratedStore, World, TestSupport}
  alias VoxelRegion.World.Pages
  alias SceneServer.Movement.{Scene, Player}
  alias MmoContracts.{Session, Movement}
  @fixtures Path.expand("../../../../voxel_region/test/fixtures/static_l0", __DIR__)
  @release Path.expand("../../../../../../Voxim/Saved/Playtest/release-20261029/Server", __DIR__)
  @page {0, {10, 8, -7}}
  @old {{11, 7, -8}, {14, 10, -5}}
  @future {{14, 7, -8}, {17, 10, -5}}

  defmodule Clock do
    @moduledoc "只测试：只控制 Scene tick 的投递，物理输入仍走正常 InputBatch。"
    def now(ref), do: :atomics.get(ref, 1)
    def schedule(_, _, _), do: :ok
  end

  defmodule Sink do
    @moduledoc "只测试：保留完整身份与消息的内存出站依赖，不启动网络端点。"
    def reliable(pid, identity, purpose, value), do: send(pid, {:reliable, identity, purpose, value})
    def datagram(pid, identity, value), do: send(pid, {:datagram, identity, value})
    def close(pid, identity, reason), do: send(pid, {:closed, identity, reason})
  end

  test "旧 Player 和 Scene 退出不能释放新 owner 的天然页，最后观察释放后才退休" do
    test = self()
    root = Path.join(System.tmp_dir!(), "static_l0_handoff_#{System.pid()}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "prefabs"))
    on_exit(fn ->
      assert Path.dirname(Path.expand(root)) == Path.expand(System.tmp_dir!())
      File.rm_rf!(root)
    end)
    manifest = Path.join(@release, "worldgen-manifest.json")
    source_root = if path = System.get_env("STATIC_L0_BASELINE_CACHE"), do: Path.join(path, "scene"), else: Path.join(root, "source-cache")
    prepare_cache(source_root, manifest)
    File.cp_r!(Path.join(source_root, "4ecf1f7864707144"), Path.join(root, "4ecf1f7864707144"))
    world_clock = start_supervised!({TestSupport.WorldClock, 0})
    opts = [source: GeneratedStore, root: root, manifest_path: manifest, name: nil,
      clock: {TestSupport.WorldClock, world_clock}, static_l0_retirement: true,
      property_catalog_path: Path.join(@fixtures, "e63744e26fd94896713eb7722901c1e0c92544df9b4d0fb325b75a2c0a042f8c.json"),
      thermal_environment_path: Path.join(@fixtures, "environment.json"), prefab_catalog_path: Path.join(root, "prefabs")]
    world = start_supervised!({World, opts})
    assert {:ok, _} = World.apply_edit(world, {0, 64_000, 0}, 19)
    assert :ok = World.compact(world)
    stop_supervised!(World)
    world = start_supervised!({World, opts})
    assert :ok = World.set_simulation_windows(world, [{{10, 8, -7}, {11, 9, -6}}])
    TestSupport.payload(world, 0, elem(@page, 1))
    assert MapSet.member?(:sys.get_state(world).static_l0.eligible, @page)
    assert :ok = World.set_simulation_windows(world, [])
    refute Pages.resident?(:sys.get_state(world), @page)

    clock = :atomics.new(1, signed: true)
    body_store = start_supervised!({MmoTest.BodyStore, []})
    common = [world_ref: world, clock: {Clock, clock}, sink: Sink,
      body_store: {MmoTest.BodyStore, store: body_store}, scene_epoch: 7]
    source = start_supervised!(Supervisor.child_spec({Scene, [scene_id: 1, config: config(:source)] ++ common}, id: :static_source_scene))
    await(fn -> Scene.observe(source).initialized end)
    {:ok, endpoint} = Scene.neighbour_endpoint(source)
    target = start_supervised!(Supervisor.child_spec({Scene,
      [scene_id: 2, config: config(:target), timeline_origin_us: endpoint.origin_us] ++ common}, id: :static_target_scene))
    await(fn -> Scene.observe(target).initialized end)
    {:ok, next_endpoint} = Scene.neighbour_endpoint(target)
    assert :ok = Scene.connect_neighbour(source, next_endpoint.pid, 0, next_endpoint)
    identity = %Session.Identity{session_epoch: 1, scene_id: 1, scene_epoch: 7}
    # CollisionStream 的生命期跟随 Gate 会话（不是 Player）；用一个转发进程代表 Gate，最后按真实会话结束释放观察。
    gate = spawn_link(fn -> forward_gate(test) end)
    {:ok, player} = Scene.join(source, identity, %{id: 20}, gate)
    tick(source, clock, 1)
    assert_receive {:reliable, ^identity, :control, %Session.SessionStart{} = start}, 30_000
    Player.time_probe(player, identity, %Session.TimeProbe{request_id: 1, client_send_us: 1})
    Player.ready(player, identity, start.baseline_transaction_seq, start.collision_revision)
    tick(source, clock, 3)
    assert_receive {:reliable, ^identity, :control, %Session.InputStart{origin_tick: origin}}, 10_000
    tick(source, clock, origin - 1)
    await(fn -> Player.observe(player).simulation_tick == origin - 1 end)
    crossed = Enum.reduce_while(1..60, false, fn seq, _ ->
      frame = %Movement.InputFrame{input_seq: seq, axis_x: 32767, axis_z: 0, yaw: 0, jump_pressed: 0}
      Player.input(player, identity, %Movement.InputBatch{identity: identity, frames: [frame]})
      tick(source, clock, origin + seq - 1)
      await(fn -> Player.observe(player).processed_input_seq >= seq end)
      receive do
        {:mmo_transfer_request, ^identity, ^player, 2} -> {:halt, true}
      after
        0 -> {:cont, false}
      end
    end)
    assert crossed, "正常移动输入必须实际触发 Scene 边界移交"
    assert {:ok, cut} = Player.seal(player, identity)
    next_identity = %Session.Identity{session_epoch: 2, scene_id: 2, scene_epoch: 7}
    assert {:ok, imported} = Scene.prepare_transfer(target, next_identity, cut, gate)
    stream = cut.stream
    assert is_pid(stream)
    assert :ok = VoxelRegion.CollisionStream.synchronize(stream)
    assert Map.has_key?(:sys.get_state(world).simulation_windows, stream)
    assert {:ok, observer} = Scene.detach_transfer(source, identity, next_identity)
    refute Process.alive?(player)
    assert :ok = Scene.activate_transfer(target, next_identity, observer)
    stop_supervised!(:static_source_scene)
    await(fn -> not Map.has_key?(:sys.get_state(world).canonical_subs, source) end)
    tick(target, clock, cut.published_tick + 1)
    assert Player.observe(imported).identity == next_identity
    assert MapSet.member?(:sys.get_state(world).static_l0.eligible, @page)
    assert World.maintain_residency(world).status == :ready
    assert Pages.resident?(:sys.get_state(world), @page)
    assert Map.has_key?(:sys.get_state(world).simulation_windows, stream)
    assert :ok = Scene.leave(target, next_identity)
    # 离开 Scene 只结束 Player；同一 Gate 会话仍持有 canonical 来源，页必须继续保留。
    assert World.maintain_residency(world).status == :ready
    assert Pages.resident?(:sys.get_state(world), @page)
    stream_monitor = Process.monitor(stream)
    send(gate, :stop)
    assert_receive {:DOWN, ^stream_monitor, :process, ^stream, :normal}, 30_000
    World.maintain_residency(world)
    await(fn -> not Pages.resident?(:sys.get_state(world), @page) end)
    assert :sys.get_state(world).page_generation[@page] >= 2
    TestSupport.StaticL0Check.write_evidence("scene-handoff", %{cv: World.content_version(world), page: @page,
      source_identity: identity, target_identity: next_identity, normal_input_crossed: crossed,
      retained_after_old_owner_exit: true, retired_after_last_window: true})
  end

  defp config(kind) do
    suite = Path.expand("../../../../../../Voxim/Docs/M0/fixtures/suite.json", __DIR__)
    profile = suite |> File.read!() |> Jason.decode!() |> Map.fetch!("profile") |> Map.put("fixed_hz", 60)
    box = if kind == :source, do: @old, else: @future
    {lo, hi, probe} = if kind == :source,
      do: {[700.0, 448.0, -500.0], [778.005, 640.0, -320.0], [778.0, 630.0, -416.0]},
      else: {[778.005, 448.0, -500.0], [1100.0, 640.0, -320.0], [950.0, 630.0, -416.0]}
    %{"schema" => "voxim-m1-demo-v1", "l0_min" => Tuple.to_list(elem(box, 0)),
      "l0_max_exclusive" => Tuple.to_list(elem(box, 1)), "travel_min_m" => lo,
      "travel_max_exclusive_m" => hi, "spawn_probes_m" => [probe], "spawn_min_y_m" => 448.0,
      "profile" => profile, "collision_window_radius_tiles" => 1}
  end

  defp prepare_cache(root, manifest) do
    baseline = Path.join([root, "4ecf1f7864707144", "baseline"])
    File.mkdir_p!(baseline)
    index = Path.join(baseline, "index.etf")
    unless File.exists?(index), do: File.cp!(Path.join([@release, "world", "4ecf1f7864707144", "baseline", "index.etf"]), index)
    {:ok, source} = GeneratedStore.open(root: root, manifest_path: manifest)
    regions = for {{lx, ly, lz}, {hx, hy, hz}} <- [@old, @future], x <- lx..(hx-1), y <- ly..(hy-1), z <- lz..(hz-1), do: {0, {x,y,z}}
    for {level, region} <- Pages.expand(Pages.with_ancestors([@page | regions])), level > 0,
        GeneratedStore.classify(source, level, region) == :mixed do
      target = GeneratedStore.path(source, level, region)
      unless File.exists?(target) do
        original = Path.join([@release, "world", "4ecf1f7864707144", "baseline", "L#{level}", GeneratedStore.file_name(region)])
        if File.exists?(original) do
          File.mkdir_p!(Path.dirname(target))
          File.cp!(original, target)
        else
          assert :ok = GeneratedStore.bake_region(source, level, region)
        end
      end
    end
  end

  # 只测试：代表 Gate 会话，把出站消息原样转给测试进程；收到 :stop 后正常退出，等价于会话结束。
  defp forward_gate(test) do
    receive do
      :stop -> :ok
      message ->
        send(test, message)
        forward_gate(test)
    end
  end

  defp tick(scene, clock, number) do
    :atomics.put(clock, 1, div(number * 1_000_000 + 59, 60))
    send(scene, :tick)
    await(fn -> Scene.observe(scene).tick >= number end)
  end

  defp await(fun, attempts \\ 30_000) do
    unless fun.() do
      assert attempts > 0, "真实 Scene／World 生命周期没有完成"
      Process.sleep(1)
      await(fun, attempts - 1)
    end
  end
end
