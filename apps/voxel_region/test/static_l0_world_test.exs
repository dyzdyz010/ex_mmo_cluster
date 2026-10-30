defmodule VoxelRegion.StaticL0WorldTest do
  @moduledoc "只测试：真实 GeneratedStore、World、File 页发布与冷恢复；通过公共编辑和观察建立前提。"
  use ExUnit.Case, async: false
  alias VoxelRegion.{GeneratedStore, World}
  alias VoxelRegion.World.Pages
  alias VoxelRegion.TestSupport
  alias VoxelRegion.TestSupport.{WorldClock, SimulationIoLog}
  alias VoxelRegion.TestSupport.StaticL0Log, as: HeldLog

  @manifest %{
    "schema" => "voxim-worldgen-v1",
    "kernel" => "worldgen_density_v3@1",
    "materials" => MmoContracts.VoxelMaterialCatalog.table(),
    "world_half_extent_m" => 64,
    "seed" => 1337,
    "min_height" => -200,
    "sea_level" => 326,
    "max_height" => 586,
    "soil_depth" => 4,
    "lowland_amplitude" => 381.77066,
    "mountain_amplitude" => 1223.743774,
    "cave_max_depth" => 96
  }
  @key {0, {-20, 1000, -20}}
  @box {{-20, 1000, -20}, {-19, 1001, -19}}

  setup context do
    root =
      Path.join(
        System.tmp_dir!(),
        "static_l0_#{System.pid()}_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(Path.join(root, "prefabs"))
    on_exit(fn -> File.rm_rf!(root) end)
    manifest = Path.join(root, "worldgen.json")
    environment = Path.join(root, "environment.json")
    File.write!(manifest, Jason.encode!(@manifest))

    File.write!(
      environment,
      Jason.encode!(%{
        ambient_kelvin: 293.15,
        environment_w_per_m2_k: 10.0,
        tolerance_kelvin: 1.0,
        emissivity: 0.9,
        view_range_cells: 8,
        circuit_min_power_w: 1.0
      })
    )

    opts = [
      source: GeneratedStore,
      root: root,
      manifest_path: manifest,
      name: nil,
      log: Map.get(context, :log, VoxelRegion.OverlayLog.File),
      production_materials: [19],
      prefab_catalog_path: Path.join(root, "prefabs"),
      property_catalog_path: TestSupport.catalog(),
      thermal_environment_path: environment,
      static_l0_retirement: Map.get(context, :enabled, true)
    ]

    opts = if context[:fixed_clock], do: Keyword.put(opts, :clock, {WorldClock, start_supervised!({WorldClock, 0})}), else: opts

    opts =
      if context[:flow] do
        clock = start_supervised!({WorldClock, 0})
        catalog = flow_catalog(root)

        Keyword.merge(opts,
          property_catalog_path: catalog,
          log: SimulationIoLog,
          clock: {WorldClock, clock},
          liquid_bounds: {{-1279, 63_997, -1279}, {-1278, 64_200, -1278}}
        )
      else
        opts
      end

    world = start_supervised!({World, opts})

    # 与目标相隔多页的正常作者提交产生非零首 cut；目标及 halo 保持完整天然状态。
    assert {:ok, _} = World.apply_edit(world, {0, 64_000, 0}, 19)
    assert :ok = World.compact(world)
    stop_supervised!(World)
    world = start_supervised!({World, opts})
    assert :ok = World.set_simulation_windows(world, [@box])
    TestSupport.payload(world, 0, elem(@key, 1))
    assert Pages.resident?(:sys.get_state(world), @key)
    %{world: world, opts: opts, root: root}
  end

  test "真实天然 L0 离窗退休、粗层保留，公开返回同 body 和身份", c do
    assert :ok = World.set_simulation_windows(c.world, [@box])
    {before, body} = payload_body(c.world)
    collision = collision_chunks(c.world)
    state = :sys.get_state(c.world)
    assert MapSet.member?(state.static_l0.eligible, @key)
    assert Pages.resident?(state, @key)
    coarse = MapSet.reject(state.resident, &match?({0, _}, &1))
    assert :ok = World.set_simulation_windows(c.world, [])
    status = World.maintain_residency(c.world)
    retired = :sys.get_state(c.world)
    refute Pages.resident?(retired, @key)
    refute Map.has_key?(retired.static_l0.cores, @key)
    assert MapSet.subset?(coarse, retired.resident)
    assert status.retired_pages > 0
    {after_payload, after_body} = payload_body(c.world)
    assert body == after_body
    assert collision_chunks(c.world) == collision

    assert {before.level, before.region, before.content_version} ==
             {after_payload.level, after_payload.region, after_payload.content_version}
  end

  defp payload_body(world) do
    alias MmoContracts.Voxel.Codec

    request =
      Codec.encode_request(0, [%{level: 0, region: elem(@key, 1), have_seq: 0, have_hash: 0}])
      |> IO.iodata_to_binary()

    assert {:ok, reply} = World.serve(world, request)
    assert {:ok, _, [{:payload, 0, _, bytes}]} = Codec.decode_reply(IO.iodata_to_binary(reply))
    assert {:ok, header, body} = Codec.decode_payload_body(bytes)
    {header, body}
  end

  defp collision_chunks(world) do
    {reader, monitor} = spawn_monitor(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> if Process.alive?(reader), do: Process.exit(reader, :kill) end)
    assert {:ok, snapshot} = World.replica_snapshot_and_subscribe(world, @box, reader)
    send(reader, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^reader, :normal}
    await_replica_release(world, reader, 200)
    snapshot.chunks
  end

  defp await_replica_release(world, reader, attempts) do
    if Map.has_key?(:sys.get_state(world).replica_subs, reader) do
      assert attempts > 0
      Process.sleep(1)
      await_replica_release(world, reader, attempts - 1)
    end
  end

  @tag enabled: false
  test "默认关闭保持 GeneratedStore 原全局阻退", c do
    assert :ok = World.set_simulation_windows(c.world, [@box])
    assert :ok = World.set_simulation_windows(c.world, [])
    status = World.maintain_residency(c.world)
    assert status.status == :blocked
    assert status.reason =~ "natural_activity_unregistered"
    assert Pages.resident?(:sys.get_state(c.world), @key)
    assert :sys.get_state(c.world).static_l0.cores == %{}
  end

  test "退休目标正常写入再改回空气，发布与冷恢复后仍有记录而拒绝", c do
    assert :ok = World.set_simulation_windows(c.world, [@box])
    assert :ok = World.set_simulation_windows(c.world, [])
    refute Pages.resident?(:sys.get_state(c.world), @key)
    cell = {-1280, 64_000, -1280}
    assert {:ok, _} = World.apply_edit(c.world, cell, 19)
    assert {:ok, _} = World.apply_edit(c.world, cell, 0)
    assert :ok = World.compact(c.world)
    assert :sys.get_state(c.world).static_l0.cores[@key].core == :recorded_page
    stop_supervised!(World)
    world = start_supervised!({World, c.opts})
    assert :ok = World.set_simulation_windows(world, [@box])
    TestSupport.payload(world, 0, elem(@key, 1))
    assert :sys.get_state(world).static_l0.cores[@key].core == :recorded_page
    assert :ok = World.set_simulation_windows(world, [])
    assert Pages.resident?(:sys.get_state(world), @key)
    assert [%{material: 0}] = World.material_snapshot(world, [], [cell]).probe_occupancy
  end

  test "不兼容环境在装页、热写回和账变更之前拒绝", c do
    assert :ok = World.set_simulation_windows(c.world, [@box])
    assert :ok = World.set_simulation_windows(c.world, [])
    before = :sys.get_state(c.world)
    path = Path.join(c.root, "changed-environment.json")

    File.write!(
      path,
      Jason.encode!(%{
        classification: "Test-only",
        ambient_kelvin: 300.0,
        source_macro: [0, 64_000, 0],
        power_w: 1.0,
        energy_j: 1.0
      })
    )

    assert {:error, :static_l0_environment_change_requires_maintenance} =
             World.thermal_experiment(c.world, path)

    after_state = :sys.get_state(c.world)
    assert after_state.thermal == before.thermal
    assert after_state.seq == before.seq
    assert after_state.resident == before.resident
    assert after_state.page_generation == before.page_generation
  end

  test "同环境有限供热仍可提交，维护读取不会永久困在全量哨兵", c do
    path = Path.join(c.root, "finite-source.json")

    File.write!(
      path,
      Jason.encode!(%{
        classification: "Test-only",
        source_macro: [0, 64_000, 0],
        power_w: 1.0,
        energy_j: 1.0
      })
    )

    seq = World.seq(c.world)
    task = Task.async(fn -> World.thermal_experiment(c.world, path) end)
    assert :ok = Task.await(task, 10_000)
    assert World.seq(c.world) == seq + 1
    state = :sys.get_state(c.world)
    assert state.thermal.sources[{0, 64_000, 0}].remaining_j == 1.0
    assert state.thermal.config["ambient_kelvin"] == 293.15
    assert World.maintain_residency(c.world).status == :ready
    assert :sys.get_state(c.world).resident != :all
  end

  @tag :static_start_failure
  test "不支持的环境通过真实 World 启动入口显式失败", c do
    stop_supervised!(World)
    path = c.opts[:thermal_environment_path]
    data = Jason.decode!(File.read!(path)) |> Map.put("view_range_cells", 65)
    File.write!(path, Jason.encode!(data))
    assert {:error, {{:static_l0_start_failed, :static_l0_read_footprint_exceeds_halo}, _child}} = start_supervised({World, c.opts})
  end

  @tag log: HeldLog, continuation: true
  test "启用态共享装页取消一个 caller 后继续分类，最后释放无孤儿证明", c do
    path = elem(:sys.get_state(c.world).log, 1)
    on_exit(fn -> HeldLog.clear(path) end)
    assert :ok = World.set_simulation_windows(c.world, [])
    refute Pages.resident?(:sys.get_state(c.world), @key)
    HeldLog.hold_read(path, @key, self())
    first = Task.async(fn -> TestSupport.payload(c.world, 0, elem(@key, 1)) end)
    assert_receive {:static_read_held, reader, @key}, 10_000
    second = Task.async(fn -> TestSupport.payload(c.world, 0, elem(@key, 1)) end)
    await_condition(fn -> World.stats(c.world).page_waiters == 2 end)
    Task.shutdown(first, :brutal_kill)
    await_condition(fn -> World.stats(c.world).page_waiters == 1 end)
    assert Process.alive?(reader)
    assert World.maintain_residency(c.world).status == :ready
    send(reader, :continue)
    assert %{region: {-20, 1000, -20}} = Task.await(second, 20_000)
    await_condition(fn -> World.stats(c.world).page_loads == 0 end)
    World.maintain_residency(c.world)
    state = :sys.get_state(c.world)
    assert state.page_load.pending == %{}
    refute Map.has_key?(state.static_l0.cores, @key)
    refute Pages.resident?(state, @key)
  end

  @tag log: HeldLog, continuation: true
  test "唯一 caller 在源分类前取消，真实读取任务结束且不留下摘要", c do
    path = elem(:sys.get_state(c.world).log, 1)
    on_exit(fn -> HeldLog.clear(path) end)
    assert :ok = World.set_simulation_windows(c.world, [])
    before_count = :sys.get_state(c.world).static_l0.metrics.classified
    HeldLog.hold_read(path, @key, self())
    caller = Task.async(fn -> TestSupport.payload(c.world, 0, elem(@key, 1)) end)
    assert_receive {:static_read_held, reader, @key}, 10_000
    Task.shutdown(caller, :brutal_kill)
    await_condition(fn -> not Process.alive?(reader) and World.stats(c.world).page_loads == 0 end)
    state = :sys.get_state(c.world)
    assert state.static_l0.metrics.classified == before_count
    assert state.page_load.pending == %{}
    refute Map.has_key?(state.static_l0.cores, @key)
    assert MapSet.size(state.page_load.staged) == 0
  end

  @tag log: HeldLog, continuation: true
  test "启用态 dirty 移入 frozen cut 后仍保留，旧发布不抹掉 cut 期间的新写", c do
    path = elem(:sys.get_state(c.world).log, 1)
    on_exit(fn -> HeldLog.clear(path) end)
    cell = {-1280, 64_000, -1280}
    assert {:ok, first_seq} = World.apply_edit(c.world, cell, 19)
    HeldLog.hold_publish(path, self(), 2)
    first_cut = Task.async(fn -> World.compact(c.world) end)
    assert_receive {:static_publish_held, writer, ^first_seq}, 10_000
    state = :sys.get_state(c.world)
    assert MapSet.size(state.page_dirty) == 0
    assert @key in Pages.units_pages(state.page_store.cut.frozen, state.page_store.cut.units)
    assert :ok = World.set_simulation_windows(c.world, [])
    assert World.maintain_residency(c.world).persistent_blocked_pages > 0
    assert Pages.resident?(:sys.get_state(c.world), @key)
    assert {:ok, second_seq} = World.apply_edit(c.world, cell, 0)
    assert @key in Pages.units_pages(:sys.get_state(c.world), :sys.get_state(c.world).page_dirty)
    second_cut = Task.async(fn -> World.compact(c.world) end)
    send(writer, {:continue, first_seq})
    assert_receive {:static_publish_held, next_writer, ^second_seq}, 10_000
    state = :sys.get_state(c.world)
    assert state.page_store.published == first_seq
    assert @key in Pages.units_pages(state.page_store.cut.frozen, state.page_store.cut.units)
    send(next_writer, {:continue, second_seq})
    assert :ok = Task.await(first_cut, 10_000)
    assert :ok = Task.await(second_cut, 10_000)
    assert World.maintain_residency(c.world).persistent_blocked_pages == 0
    assert Pages.resident?(:sys.get_state(c.world), @key)
    assert :sys.get_state(c.world).static_l0.cores[@key].core == :recorded_page
    stop_supervised!(World)
    world = start_supervised!({World, c.opts})
    assert [%{material: 0}] = World.material_snapshot(world, [], [cell]).probe_occupancy
    assert :sys.get_state(world).static_l0.cores[@key].core == :recorded_page
  end

  @tag log: HeldLog, continuation: true
  test "真实混合源分类失败显式返回且不自动重试，修复自有缓存后重新接纳", c do
    key = {0, {10, 7, -5}}
    log_path = elem(:sys.get_state(c.world).log, 1)
    on_exit(fn -> HeldLog.clear(log_path) end)
    HeldLog.watch_reads(log_path, key, self())
    {:ok, source} = GeneratedStore.open(c.opts)
    assert {:ok, _, _} = GeneratedStore.read(source, 0, elem(key, 1))
    path = GeneratedStore.path(source, 0, elem(key, 1))
    File.write!(path, <<0>>)
    assert {:error, {:page_load_failed, {:static_l0_source_read_failed, ^key, :invalid_cache}}} =
      World.material_snapshot(c.world, [], [{640, 448, -320}])
    assert_receive {:static_read_seen, _, ^key}
    state = :sys.get_state(c.world)
    assert state.page_load.tasks == %{}
    refute Map.has_key?(state.static_l0.cores, key)
    for _ <- 1..3, do: World.maintain_residency(c.world)
    refute_receive {:static_read_seen, _, ^key}, 100
    assert GeneratedStore.generated(source) == 1
    # 修复仅删除本例生成的坏缓存；真实源重新生成，不能用替身 payload 填入 authority。
    File.rm!(path)
    assert %{probe_occupancy: [_]} = World.material_snapshot(c.world, [], [{640, 448, -320}])
    assert Map.has_key?(:sys.get_state(c.world).static_l0.cores, key)
  end

  @tag log: HeldLog, continuation: true, fixed_clock: true
  test "退休页付费意图取消不扣账且保留共享读者，重试仅一次提交扣料，重复与拒绝不再扣", c do
    alias VoxelRegion.TestSupport.Actor
    assert :ok = TestSupport.mine_authored(c.world, 1001, {0, 64_000, 0})
    assert wood_balance(c.world) == capacity()
    target = {-1280, 64_000, -1280}
    actor = %{cid: 1001, gate: self(), identity: make_ref(), refresh: &Actor.tool_context/2,
      eye: {-1279.5, 64_000.5, -1281.5}, tick_us: 16_667}
    player = start_supervised!({Actor, actor})
    actor = Map.put(actor, :player, player)
    request = %{request_id: 10, client_intent_seq: 10, logical_scene_id: 1,
      action: 1, coord: target, tool_id: 1, material: 19}
    assert :ok = World.set_simulation_windows(c.world, [])
    refute Pages.resident?(:sys.get_state(c.world), @key)
    seq = World.seq(c.world)
    path = elem(:sys.get_state(c.world).log, 1)
    on_exit(fn -> HeldLog.clear(path) end)
    HeldLog.hold_read(path, @key, self())
    build = Task.async(fn -> World.production_intent(c.world, actor, request) end)
    assert_receive {:static_read_held, reader, @key}, 10_000
    observer = Task.async(fn -> TestSupport.payload(c.world, 0, elem(@key, 1)) end)
    await_condition(fn -> World.stats(c.world).page_waiters == 2 end)
    Task.shutdown(build, :brutal_kill)
    await_condition(fn -> World.stats(c.world).page_waiters == 1 end)
    assert Process.alive?(reader)
    assert wood_balance(c.world) == capacity()
    send(reader, :continue)
    assert %{region: {-20, 1000, -20}} = Task.await(observer, 20_000)
    assert World.seq(c.world) == seq
    assert {:ok, committed} = World.production_intent(c.world, actor, request)
    assert committed == seq + 1
    assert wood_balance(c.world) == 0
    assert {:ok, ^committed} = World.production_intent(c.world, actor, request)
    assert {:error, :insufficient_material} =
      World.production_intent(c.world, actor, %{request | request_id: 11, client_intent_seq: 11, coord: {-1279, 64_000, -1280}})
    assert World.seq(c.world) == committed
    assert wood_balance(c.world) == 0
    assert [%{material: 19}] = World.material_snapshot(c.world, [1001], [target]).probe_occupancy
    assert :sys.get_state(c.world).static_l0.cores[@key].core == :recorded_page
  end

  defp await_condition(fun, attempts \\ 2_000) do
    if not fun.() do
      assert attempts > 0, "等待条件没有完成"
      Process.sleep(1)
      await_condition(fun, attempts - 1)
    end
  end

  defp wood_balance(world) do
    World.material_balances(world, 1001) |> Enum.find(&(&1.material == 19)) |> Map.fetch!(:balance)
  end

  @tag :read_order
  test "真实 canonical 读取严格在退休后的重新接纳之后，漏接纳轨迹会被离线判定拒绝", c do
    alias VoxelRegion.TestSupport.{StaticL0Audit, StaticL0Check}
    {_, events} = StaticL0Audit.capture(c.world, [@key], fn ->
      assert :ok = World.set_simulation_windows(c.world, [])
      refute Pages.resident?(:sys.get_state(c.world), @key)
      assert [%{material: 0}] = World.material_snapshot(c.world, [], [{-1280, 64_000, -1280}]).probe_occupancy
    end)
    assert :ok = StaticL0Check.verify_reads(events, [@key])
    assert Enum.any?(events, &(&1.action == :retire))
    StaticL0Check.write_evidence("read-order", %{initially_loaded: [@key], events: events})
    assert {:error, {:read_before_load, @key, _}} =
      StaticL0Check.verify_reads(Enum.reject(events, &(&1.action == :resident)), [@key])
  end

  @tag :late_classification
  test "取消在真实分类完成之前接纳，已排队的源摘要不得回填或遗留 staged", c do
    assert :ok = World.set_simulation_windows(c.world, [])
    before_count = :sys.get_state(c.world).static_l0.metrics.classified
    parent = self()
    gate = make_ref()
    # 只控制真实消息处理顺序：先排 caller DOWN，再允许源任务算完并排入摘要；不改 authority state。
    hook = fn
      nil, {:in, {:"$gen_call", _, {:page_stage, worker, _, _, _}}}, _ ->
        send(parent, {:initial_stage_held, worker})
        receive do: ({:resume_static_stage, caller} -> %{caller: caller, worker: worker})
      %{caller: caller, worker: worker}, {:in, {:DOWN, _, :process, caller, _}}, _ ->
        send(parent, {:cancel_held, worker})
        receive do: (:resume_static_cancel -> :finished)
      debug, _, _ -> debug
    end
    :ok = :sys.install(c.world, {hook, nil})
    caller = Task.async(fn -> TestSupport.payload(c.world, 0, elem(@key, 1)) end)
    try do
      assert_receive {:initial_stage_held, worker}, 10_000
      Process.put(gate, {:stage, caller.pid})
      Task.shutdown(caller, :brutal_kill)
      await_message(c.world, fn
        {:DOWN, _, :process, pid, _} -> pid == caller.pid
        _ -> false
      end)
      send(c.world, {:resume_static_stage, caller.pid})
      assert_receive {:cancel_held, ^worker}, 10_000
      Process.put(gate, :cancel)
      await_message(c.world, fn
        {:"$gen_call", _, {:page_stage, ^worker, _, _, _, facts}} ->
          Enum.any?(facts, fn {key, _, fact} -> key == @key and is_map(fact) end)
        _ -> false
      end)
      send(c.world, :resume_static_cancel)
      Process.delete(gate)
      await_condition(fn -> World.stats(c.world).page_loads == 0 and not Process.alive?(worker) end)
      state = :sys.get_state(c.world)
      refute Map.has_key?(state.static_l0.cores, @key)
      assert state.static_l0.metrics.classified == before_count
      assert state.page_load.pending == %{}
      assert MapSet.size(state.page_load.staged) == 0
    after
      case Process.delete(gate) do
        {:stage, pid} -> send(c.world, {:resume_static_stage, pid})
        :cancel -> send(c.world, :resume_static_cancel)
        _ -> :ok
      end
      :sys.remove(c.world, hook)
    end
  end

  defp await_message(world, predicate) do
    await_condition(fn ->
      {:messages, messages} = Process.info(world, :messages)
      Enum.any?(messages, predicate)
    end)
  end

  @tag flow: true, timeout: 180_000
  test "有限水从 halo 外向负坐标的 Y 通道跨四页，退休页读取受阻不丢 due 或数量焓", c do
    assert_flow_pair(c, 21)
  end

  for {name, material} <- [{"冰", 20}, {"雪", 4}] do
    @tag flow: true, continuation_phase: true, timeout: 180_000
    test "halo 外已记录#{name}经有限供热融化，融水跨四页且 off/on 数量能量与模型进度一致", c do
      assert_flow_pair(c, unquote(material))
    end
  end

  defp assert_flow_pair(c, material) do
    on_exit(&SimulationIoLog.clear/0)
    {WorldClock, clock} = c.opts[:clock]
    assert :ok = World.set_simulation_windows(c.world, [])
    refute Pages.resident?(:sys.get_state(c.world), @key)
    SimulationIoLog.mode(:hold, self(), @key)
    sample = Path.join(c.root, "finite-water.json")

    File.write!(
      sample,
      Jason.encode!(%{
        classification: "Test-only",
        deposits: [%{macro: [-1279, 64_192, -1279], material: material}]
      })
    )

    on_steps = flow(c.world, clock, true, sample, material)
    stop_supervised!(World)
    SimulationIoLog.clear()

    off_root = Path.join(c.root, "off")
    off_clock = start_supervised!(Supervisor.child_spec({WorldClock, 0}, id: :off_clock))

    opts =
      Keyword.merge(c.opts,
        root: off_root,
        static_l0_retirement: false,
        clock: {WorldClock, off_clock}
      )

    world = start_supervised!({World, opts})
    assert {:ok, _} = World.apply_edit(world, {0, 64_000, 0}, 19)
    assert :ok = World.compact(world)
    stop_supervised!(World)
    world = start_supervised!({World, opts})
    assert :ok = World.set_simulation_windows(world, [@box])
    TestSupport.payload(world, 0, elem(@key, 1))
    assert :ok = World.set_simulation_windows(world, [])
    off_steps = flow(world, off_clock, false, sample, material)
    # 每个自然步都比较，不以最后有水或单个计数为成功。
    assert :ok = VoxelRegion.TestSupport.StaticL0Check.compare_steps(on_steps, off_steps)

    assert List.last(on_steps).quantities ==
             Map.new(63_998..64_001, &{{-1279, &1, -1279}, div(capacity(), 4)})
  end

  defp flow(world, clock, held?, sample, material) do
    alias VoxelRegion.TestSupport.{StaticL0Audit, StaticL0Check}
    {steps, events} = StaticL0Audit.capture(world, [@key], fn ->
    assert :sys.get_state(world).material_units_per_micro == 4096
    assert {:ok, _} = World.liquid_experiment(world, sample)
    if material != 21 do
      heat = Path.join(Path.dirname(sample), "melt-#{material}-#{held?}.json")
      File.write!(heat, Jason.encode!(%{classification: "Test-only", source_macro: [-1279, 64_192, -1279],
        power_w: 1_000_000_000.0, energy_j: 400_000_000.0}))
      assert :ok = World.thermal_experiment(world, heat)
      send(world, :thermal_commit)
      World.seq(world)
      await_condition(fn -> TestSupport.simulation_settled?(world) end, 20_000)
      assert [%{material: 21}] = World.material_snapshot(world, [], [{-1279, 64_192, -1279}]).probe_occupancy
      if held?, do: refute(Pages.resident?(:sys.get_state(world), @key))
    end

    {steps, held} =
      Enum.map_reduce(1..194, false, fn step, held ->
        before = World.stats(world).simulation_progress.liquid
        WorldClock.advance(clock, 100)
        held = await_flow(world, clock, before.next_due_ms, held)
        state = :sys.get_state(world)
        assert state.liquid_due == (step + 1) * 100
        quantities = state.liquid_units

        assert Enum.sum(Map.values(quantities)) == capacity(),
               "数量不符，step=#{step} quantities=#{inspect(quantities)} capacity=#{capacity()}"

        phase =
          for {key, row} <- state.damage,
              Map.has_key?(row, :phase_energy_j),
              into: %{},
              do:
                {key,
                 Map.take(row, [:material, :phase_energy_j, :temperature_kelvin, :hp, :max_hp])}

        # 广延量来自作者初态、有限源与环境交换唯一账；冰雪融化不能凭空恢复数量或焓。
        energy = state.thermal.phase_authored_energy_j + state.thermal.supplied_j + state.thermal.environment_j
        assert_in_delta Enum.sum(for {_, row} <- phase, do: row.phase_energy_j),
                        energy,
                        0.01
        if material == 21 do
          assert_in_delta Enum.sum(for {_, row} <- phase, do: row.phase_energy_j), 417_600_000.0, 1.0e-6
        end

        if held?, do: assert(Map.get(state.page_generation, @key) == 1, "活动前沿不能反复退休重装")
        {%{quantities: quantities, phase: phase, due: state.liquid_due, seq: state.seq,
           thermal_elapsed: state.thermal.elapsed_s, supplied_j: state.thermal.supplied_j,
           environment_j: state.thermal.environment_j}, held}
      end)

    assert held == held?
    assert Pages.resident?(:sys.get_state(world), @key)
    if held?, do: assert(:sys.get_state(world).static_l0.cores[@key].core == :recorded_page)
    steps
    end)
    initial = if held?, do: [], else: [@key]
    assert :ok = StaticL0Check.verify_reads(events, initial)
    StaticL0Check.write_evidence("flow-#{material}-#{held?}", %{identity: %{cv: World.content_version(world), page: @key},
      steps: steps, initially_loaded: initial, events: events, time_unit: :nanosecond})
    steps
  end

  defp await_flow(world, clock, due, held, attempts \\ 2_000) do
    receive do
      {:simulation_io_read, reader, @key} ->
        waiting = World.stats(world).simulation_progress.liquid
        assert waiting.next_due_ms == due
        refute Pages.resident?(:sys.get_state(world), @key)
        assert Enum.sum(Map.values(:sys.get_state(world).liquid_units)) == capacity()
        assert Enum.all?(:sys.get_state(world).liquid_units, fn {{_, y, _}, _} -> y >= 64_064 end)

        # IO 等待期间钟前进半步，专门使 due=now 的坏实现可被证伪；不增加已到期自然步数。
        WorldClock.advance(clock, 50)
        assert World.stats(world).simulation_progress.liquid.next_due_ms == due
        SimulationIoLog.clear()
        send(reader, :continue)
        await_flow(world, clock, due, true, attempts)
    after
      0 ->
        state = :sys.get_state(world)

        if state.liquid_due != due and state.page_load.tasks == %{} and state.thermal_run == nil do
          held
        else
          assert attempts > 0, "液体自然步没有完成 due=#{inspect(due)}"
          Process.sleep(1)
          await_flow(world, clock, due, held, attempts - 1)
        end
    end
  end

  # 冻结 schema 2 样本每微格 4096 单位；启动后另核对真实接纳精度。
  defp capacity, do: 4096 * Integer.pow(VoxelRegion.Spatial.micro_resolution(), 3)

  defp flow_catalog(root) do
    data = Jason.decode!(File.read!(TestSupport.catalog()))
    production = Path.join([__DIR__, "fixtures", "static_l0", "e63744e26fd94896713eb7722901c1e0c92544df9b4d0fb325b75a2c0a042f8c.json"])
      |> File.read!() |> Jason.decode!() |> Map.fetch!("materials") |> Map.new(&{&1["material_id"], &1})

    materials =
      Enum.map(data["materials"], fn m ->
        if m["material_id"] in [4, 20, 21] do
          fields = ~w(phase_peer_material_id phase_transition_kelvin latent_heat_per_macro_j heat_capacity_per_macro thermal_conductivity heat_resistance_kelvin)
          Map.merge(m, Map.take(production[m["material_id"]], fields))
        else
          m
        end
      end)

    data =
      data
      |> Map.put("materials", materials)
      |> Map.put("liquid", %{
        "step_seconds" => 0.1,
        "gravity_units_per_step" => div(capacity(), 4),
        "side_units_per_step" => div(capacity(), 16),
        "side_threshold_units" => div(capacity(), 8)
      })

    path = Path.join(root, "flow-catalog.json")
    File.write!(path, Jason.encode!(data))
    path
  end
end
