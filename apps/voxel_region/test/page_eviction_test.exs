defmodule VoxelRegion.PageEvictionTest do
  @moduledoc """
  只测试：P1 单 World 驻留生命周期。通过作者编辑、窗口、真实文件切点和正常读取建立前提；
  只读 state 核对表示退休，不向运行中的 authority 注入内容。此文件不证明天然活动初始化、PG 或客户端。
  删除退休动作会让已释放且已持久的页继续驻留；漏掉未发布切点或准备需求会让对应保留断言失败。
  """
  use ExUnit.Case, async: false
  alias VoxelRegion.{OverlayLog, World}
  alias VoxelRegion.TestSupport.Source
  alias VoxelRegion.World.Pages

  defmodule HeldEnsure do
    @moduledoc "只测试：在调用方的真实source预备边界等待，不拦World、不更换载荷值。"
    defdelegate open(opts), to: VoxelRegion.TestSupport.Source
    defdelegate content_version(state), to: VoxelRegion.TestSupport.Source
    defdelegate world_dir(state), to: VoxelRegion.TestSupport.Source
    defdelegate generated(state), to: VoxelRegion.TestSupport.Source
    defdelegate read(state, level, region), to: VoxelRegion.TestSupport.Source
    def ensure(state, level, region) do
      if owner = :persistent_term.get({__MODULE__, state.root}, nil) do
        :persistent_term.erase({__MODULE__, state.root})
        send(owner, {:ensure_held, self()})
        receive do: (:ensure_continue -> :ok)
      end
      VoxelRegion.TestSupport.Source.ensure(state, level, region)
    end
  end

  defmodule HeldFeedSource do
    @moduledoc "只测试：仅在独立发送进程的source读取边界等待，World继续接纳换窗。"
    defdelegate open(opts), to: VoxelRegion.TestSupport.Source
    defdelegate content_version(state), to: VoxelRegion.TestSupport.Source
    defdelegate world_dir(state), to: VoxelRegion.TestSupport.Source
    defdelegate generated(state), to: VoxelRegion.TestSupport.Source
    defdelegate ensure(state, level, region), to: VoxelRegion.TestSupport.Source
    def read(state, level, region) do
      case :persistent_term.get({__MODULE__, state.root}, nil) do
        {owner, world} when world != self() ->
          :persistent_term.erase({__MODULE__, state.root})
          send(owner, {:feed_source_held, self()})
          receive do: (:feed_source_continue -> :ok)
        _ -> :ok
      end
      VoxelRegion.TestSupport.Source.read(state, level, region)
    end
  end

  defmodule HeldPublish do
    @moduledoc "只测试：真实文件后端仅在publish调用边界等待；不替换已写行、prefix或canonical值。"
    alias VoxelRegion.OverlayLog.File, as: Log
    defdelegate open(path, cv), to: Log
    defdelegate replay(path), to: Log
    defdelegate append(path, txn), to: Log
    defdelegate checkpoint(path, txn), to: Log
    defdelegate prefix(path), to: Log
    defdelegate clear_unpublished(path, prefix), to: Log
    defdelegate write_pages(path, cut, rows), to: Log
    defdelegate load(path), to: Log
    defdelegate load_head(path, code), to: Log
    defdelegate locate(path, ids), to: Log
    defdelegate page_keys(path), to: Log
    defdelegate collect(path, prefix, limit), to: Log

    def read_pages(path, keys, fragments) do
      case :persistent_term.get({__MODULE__, :read, path}, nil) do
        {owner, key} ->
          if key in keys do
            :persistent_term.erase({__MODULE__, :read, path})
            send(owner, {:read_held, self()})
            receive do: (:read_continue -> :ok)
          end
        nil -> :ok
      end
      Log.read_pages(path, keys, fragments)
    end

    def publish(path, cut, rows, globals) do
      if owner = :persistent_term.get({__MODULE__, path}, nil) do
        :persistent_term.erase({__MODULE__, path})
        send(owner, {:publish_held, self(), cut})
        receive do: (:publish_continue -> :ok)
      end
      Log.publish(path, cut, rows, globals)
    end
  end

  setup context do
    root = Path.join(System.tmp_dir!(), "page_eviction_#{System.pid()}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "prefabs"))
    on_exit(fn -> File.rm_rf!(root) end)
    opts = [source: context[:source] || Source, root: root, observer: self(), name: nil,
      prefab_catalog_path: Path.join(root, "prefabs"), production_materials: [11, 19],
      log: context[:log] || OverlayLog.File]
    opts = if context[:properties], do: Keyword.put(opts, :property_catalog_path, VoxelRegion.TestSupport.catalog()), else: opts
    opts = if context[:thermal] do
      materials = for id <- 0..23 do
        material = %{material_id: id, max_hp_per_macro: if(id == 0, do: 0.0, else: 100.0), defense: 2.0,
          tags: [], responses: [%{action: "damage", multiplier: 1.0}]}
        if id == 19, do: Map.merge(material, %{heat_capacity_per_macro: 1000.0, thermal_conductivity: 10.0,
          heat_resistance_kelvin: 1.0e5}), else: material
      end
      catalog = Path.join(root, "thermal-properties.json")
      File.write!(catalog, Jason.encode!(%{schema_version: 1, tags: [%{id: "damage"}], materials: materials, tools: [], definitions: []}))
      environment = Path.join(root, "environment.json")
      File.write!(environment, Jason.encode!(%{ambient_kelvin: 293.15, environment_w_per_m2_k: 10.0,
        tolerance_kelvin: 1.0, emissivity: 0.0, view_range_cells: 8, circuit_min_power_w: 1.0}))
      Keyword.merge(opts, property_catalog_path: catalog, thermal_environment_path: environment)
    else
      opts
    end
    opts = if context[:liquid] do
      catalog = Path.join(root, "liquid-properties.json")
      data = Jason.decode!(File.read!(VoxelRegion.TestSupport.catalog())) |> Map.put("liquid", %{
        "step_seconds" => 3600, "gravity_units_per_step" => 524_288, "side_units_per_step" => 131_072, "side_threshold_units" => 0})
      File.write!(catalog, Jason.encode!(data))
      Keyword.merge(opts, property_catalog_path: catalog, production_materials: [19, 21], liquid_bounds: {{0, 0, 0}, {4, 4, 4}})
    else
      opts
    end
    world = start_supervised!({World, opts})
    %{world: world, root: root, opts: opts}
  end

  test "两个有限 XYZ 观察范围：已持久页在最后观察释放后退休，正常重入恢复同一材料与完整载荷", c do
    a = {2, 1, 2}
    b = {1282, 129, -127}
    a_key = {0, {0, 0, 0}}
    b_key = {0, {20, 2, -2}}
    a_box = {{0, 0, 0}, {1, 1, 1}}
    b_box = {{20, 2, -2}, {21, 3, -1}}
    assert :ok = World.set_simulation_windows(c.world, [a_box, b_box])
    assert {:ok, _} = World.apply_edits(c.world, [{a, 19}, {b, 11}])
    assert :ok = World.compact(c.world)
    before = VoxelRegion.TestSupport.payload(c.world, 0, {0, 0, 0})
    collision_reader = spawn(fn -> receive do: (:stop -> :ok) end)
    assert {:ok, collision_before} = World.replica_snapshot_and_subscribe(c.world, a_box, collision_reader)
    Process.exit(collision_reader, :kill)
    await(fn -> :sys.get_state(c.world).replica_subs == %{} end)
    old_generation = Map.get(:sys.get_state(c.world).page_generation, a_key, 0)
    assert Pages.resident?(:sys.get_state(c.world), a_key)
    assert Pages.resident?(:sys.get_state(c.world), b_key)

    assert :ok = World.set_simulation_windows(c.world, [b_box])
    retired = :sys.get_state(c.world)
    refute Pages.resident?(retired, a_key)
    assert Pages.resident?(retired, b_key)
    refute Map.has_key?(retired.region_bases, a_key)
    refute Map.has_key?(retired.decoded, a_key)
    refute Map.has_key?(retired.served_headers, a_key)
    refute MapSet.member?(retired.snapshots, a_key)
    refute Map.has_key?(retired.liquid_adopted, elem(a_key, 1))
    assert Map.get(retired.page_generation, a_key, 0) > 0

    # 接纳信任边界反例：真实已发布行携带退休前token，不得使旧页重新驻留。
    %{rows: old_rows} = OverlayLog.File.read_pages(Path.join(c.root, "overlay.log"), [a_key], Pages.fragment_codes())
    assert {_, _} = GenServer.call(c.world, {:page_adopt, [{a_key, old_generation}], old_rows, %{}})
    refute Pages.resident?(:sys.get_state(c.world), a_key)
    refute Map.has_key?(:sys.get_state(c.world).region_bases, a_key)

    assert :ok = World.set_simulation_windows(c.world, [a_box, b_box])
    assert [%{material: 19}, %{material: 11}] = World.material_snapshot(c.world, [], [a, b]).probe_occupancy
    assert VoxelRegion.TestSupport.payload(c.world, 0, {0, 0, 0}) == before
    collision_reader = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> Process.exit(collision_reader, :kill) end)
    assert {:ok, collision_after} = World.replica_snapshot_and_subscribe(c.world, a_box, collision_reader)
    assert collision_after.chunks == collision_before.chunks
    assert OverlayLog.File.prefix(Path.join(c.root, "overlay.log")) == World.seq(c.world)
  end

  @tag log: HeldPublish
  test "dirty已清空但cut尚未published时不退休，确认真实prefix后才释放", c do
    key = {0, {0, 0, 0}}
    assert :ok = World.set_simulation_windows(c.world, [{{0, 0, 0}, {1, 1, 1}}])
    assert {:ok, _} = World.apply_edits(c.world, [{{2, 1, 2}, 19}])
    path = Path.join(c.root, "overlay.log")
    :persistent_term.put({HeldPublish, path}, self())
    on_exit(fn -> :persistent_term.erase({HeldPublish, path}) end)
    compact = Task.async(fn -> World.compact(c.world) end)
    assert_receive {:publish_held, writer, 1}, 10_000
    state = :sys.get_state(c.world)
    assert MapSet.size(state.page_dirty) == 0
    assert state.page_store.cut != nil
    assert state.page_store.published != 1
    assert :ok = World.set_simulation_windows(c.world, [])
    assert Pages.resident?(:sys.get_state(c.world), key)
    send(writer, :publish_continue)
    assert :ok = Task.await(compact, 10_000)
    refute Pages.resident?(:sys.get_state(c.world), key)
    assert OverlayLog.File.prefix(path) == 1
  end

  test "seq0只读来源页释放观察即可退休，不要求先做作者编辑", c do
    key = {0, {0, 0, 0}}
    assert :ok = World.set_simulation_windows(c.world, [{{0, 0, 0}, {1, 1, 1}}])
    assert [%{material: 0}] = World.material_snapshot(c.world, [], [{2, 1, 2}]).probe_occupancy
    assert World.seq(c.world) == 0
    assert Pages.resident?(:sys.get_state(c.world), key)
    assert :ok = World.set_simulation_windows(c.world, [{{20, 2, -2}, {21, 3, -1}}])
    refute Pages.resident?(:sys.get_state(c.world), key)
    assert World.seq(c.world) == 0
    assert World.residency_status(c.world).status == :ready
  end

  @tag source: HeldEnsure
  test "公共serve预备完成到真实使用之间有owner，外部ensure不让窗口释放退休其页", c do
    key = {0, {3, 0, 0}}
    :persistent_term.put({HeldEnsure, c.root}, self())
    on_exit(fn -> :persistent_term.erase({HeldEnsure, c.root}) end)
    read = Task.async(fn -> VoxelRegion.TestSupport.payload(c.world, 0, {3, 0, 0}) end)
    assert_receive {:ensure_held, worker}, 10_000
    assert :ok = World.set_simulation_windows(c.world, [])
    assert World.maintain_residency(c.world).preparations == 1
    assert Pages.resident?(:sys.get_state(c.world), key)
    send(worker, :ensure_continue)
    assert %{region: {3, 0, 0}} = Task.await(read, 10_000)
    # 公共作用域的释放cast在同一caller完成；显式维护也走同一required资格。
    await(fn -> World.residency_status(c.world).preparations == 0 end)
    assert World.maintain_residency(c.world).status == :ready
    refute Pages.resident?(:sys.get_state(c.world), key)
    assert World.stats(c.world).shared_cache.namespaces.payload.entries > 0
  end

  @tag properties: true
  test "观察跨页树的一端保留整树，最后需求释放后身份及几何索引一起退休", c do
    definition = VoxelRegion.Prefab.encode(%{cells: [{{0, 0, 0}, 11}, {{560, 0, 0}, 11}],
      children: [], attachments: [], macro_cells: []})
    id = :crypto.hash(:sha256, definition)
    File.write!(Path.join([c.root, "prefabs", Base.encode16(id) <> ".vxpd"]), definition)
    assert :ok = World.publish_prefabs(c.world, Path.join(c.root, "prefabs"))
    assert :ok = World.set_simulation_windows(c.world, [{{2, 0, 0}, {3, 1, 1}}])
    assert {:ok, _} = World.place_prefab(c.world, id, {480, 16, 80}, 0)
    [instance] = Map.keys(:sys.get_state(c.world).instances)
    assert :ok = World.compact(c.world)
    _ = World.simulation_snapshot(c.world, [], {{2, 0, 0}, {3, 1, 1}})
    state = :sys.get_state(c.world)
    assert Pages.resident?(state, {0, {0, 0, 0}})
    assert Pages.resident?(state, {0, {2, 0, 0}})
    assert Map.has_key?(state.component_cache, instance)
    assert :ok = World.set_simulation_windows(c.world, [])
    state = :sys.get_state(c.world)
    refute Map.has_key?(state.instances, instance)
    refute Map.has_key?(state.refined_owners, instance)
    refute Map.has_key?(state.component_cache, instance)
    assert state.refined == %{}
    assert state.refined_regions == %{}
    refute Map.has_key?(state, :refined_encoded)
    assert state.pages.instance_home == %{}
    assert state.pages.home_instances == %{}
    assert state.pages.covers == %{}
    assert {:ok, [{60, 2, 10}, {130, 2, 10}]} = World.instance_cells(c.world, instance)
    assert World.seq(c.world) == 1
  end

  @tag properties: true
  @tag log: HeldPublish
  test "唯一caller取消后，未闭合树的暂存canonical及页索引一并退休", c do
    definition = VoxelRegion.Prefab.encode(%{cells: [{{0, 0, 0}, 11}, {{560, 0, 0}, 11}],
      children: [], attachments: [], macro_cells: []})
    id = :crypto.hash(:sha256, definition)
    File.write!(Path.join([c.root, "prefabs", Base.encode16(id) <> ".vxpd"]), definition)
    assert :ok = World.publish_prefabs(c.world, Path.join(c.root, "prefabs"))
    assert {:ok, _} = World.place_prefab(c.world, id, {480, 16, 80}, 0)
    [instance] = Map.keys(:sys.get_state(c.world).instances)
    assert :ok = World.compact(c.world)
    stop_supervised!(World)
    world = start_supervised!({World, c.opts})
    path = Path.join(c.root, "overlay.log")
    :persistent_term.put({HeldPublish, :read, path}, {self(), {0, {2, 0, 0}}})
    on_exit(fn -> :persistent_term.erase({HeldPublish, :read, path}) end)
    read = Task.async(fn -> World.instance_cells(world, instance) end)
    assert_receive {:read_held, _worker}, 10_000
    partial = :sys.get_state(world)
    assert Map.has_key?(partial.instances, instance)
    assert map_size(partial.refined) > 0
    refute Pages.resident?(partial, {0, {0, 0, 0}})
    assert MapSet.size(partial.page_load.staged) > 0
    Task.shutdown(read, :brutal_kill)
    await(fn -> World.stats(world).page_loads == 0 end)
    retired = :sys.get_state(world)
    assert retired.instances == %{}
    assert retired.refined == %{}
    assert retired.refined_owners == %{}
    assert retired.refined_regions == %{}
    assert retired.pages.instance_home == %{}
    assert MapSet.size(retired.page_load.staged) == 0
    assert Map.get(retired.page_generation, {0, {0, 0, 0}}, 0) > 0
    assert {:ok, [{60, 2, 10}, {130, 2, 10}]} = World.instance_cells(world, instance)
  end

  test "prepare初始回复超时且caller继续存活时，原request取消精确释放准备owner", c do
    parent = self()
    hook = fn debug, event, _ ->
      case event do
        {:in, {:"$gen_call", _, {:page_request, _, {:prepare, _}}}} ->
          unless Process.get(:residency_prepare_held, false) do
            Process.put(:residency_prepare_held, true)
            send(parent, :prepare_reply_held)
            receive do: (:prepare_reply_continue -> :ok)
          end
        _ -> :ok
      end
      debug
    end
    assert :ok = :sys.install(c.world, {hook, nil})
    caller = spawn(fn ->
      try do
        VoxelRegion.World.PageLoad.call(c.world, {:prepare, [{0, {3, 0, 0}}]}, 20)
      catch
        :exit, {:timeout, _} -> send(parent, {:prepare_timed_out, self()})
      end
      receive do: (:stop -> :ok)
    end)
    on_exit(fn -> send(c.world, :prepare_reply_continue); Process.exit(caller, :kill) end)
    assert_receive :prepare_reply_held, 1_000
    assert_receive {:prepare_timed_out, ^caller}, 1_000
    assert Process.alive?(caller)
    send(c.world, :prepare_reply_continue)
    await(fn -> World.residency_status(c.world).preparations == 0 end)
    assert World.maintain_residency(c.world).preparations == 0
    refute Pages.resident?(:sys.get_state(c.world), {0, {3, 0, 0}})
    send(caller, :stop)
  end

  @tag properties: true
  @tag source: HeldFeedSource
  test "同seq换窗退休后，冻结旧window的迟到geometry和payload不回灌当前页", c do
    definition = VoxelRegion.Prefab.encode(%{cells: [{{0, 0, 0}, 11}], children: [], attachments: [], macro_cells: []})
    id = :crypto.hash(:sha256, definition)
    File.write!(Path.join([c.root, "prefabs", Base.encode16(id) <> ".vxpd"]), definition)
    assert :ok = World.publish_prefabs(c.world, Path.join(c.root, "prefabs"))
    a_box = {{0, 0, 0}, {5, 1, 1}}
    b_box = {{20, 2, -2}, {21, 3, -1}}
    assert :ok = World.set_simulation_windows(c.world, [a_box])
    assert {:ok, _} = World.place_prefab(c.world, id, {16, 8, 16}, 0)
    [instance] = Map.keys(:sys.get_state(c.world).instances)
    assert :ok = World.compact(c.world)
    assert :miss = VoxelRegion.World.Cache.peek(:sys.get_state(c.world).cache, {:payload, {0, {0, 0, 0}}})
    parent = self()
    subscriber = spawn(fn -> relay(parent) end)
    on_exit(fn -> Process.exit(subscriber, :kill) end)
    :persistent_term.put({HeldFeedSource, c.root}, {self(), c.world})
    on_exit(fn -> :persistent_term.erase({HeldFeedSource, c.root}) end)
    first = Task.async(fn -> World.canonical_snapshot_and_subscribe(c.world, a_box, subscriber, :old, false) end)
    assert_receive {:feed_source_held, feed}, 10_000
    assert World.residency_status(c.world).preparations == 0
    second = Task.async(fn -> World.canonical_snapshot_and_subscribe(c.world, b_box, subscriber, :new, false) end)
    await(fn -> :sys.get_state(c.world).canonical_subs[subscriber] == b_box end)
    assert :ok = World.set_simulation_windows(c.world, [])
    retired = :sys.get_state(c.world)
    refute Pages.resident?(retired, {0, {0, 0, 0}})
    refute Map.has_key?(retired.instances, instance)
    assert map_size(retired.canonical_snapshots) == 2
    send(feed, :feed_source_continue)
    assert_receive {:canonical_snapshot, :old, old}, 10_000
    assert_receive {:canonical_snapshot, :new, new}, 10_000
    assert Task.await(first, 10_000) == :ok
    assert Task.await(second, 10_000) == :ok
    assert old.transaction_seq == new.transaction_seq
    state = :sys.get_state(c.world)
    refute Map.has_key?(state.component_cache, instance)
    refute Pages.resident?(state, {0, {0, 0, 0}})
    assert :miss = VoxelRegion.World.Cache.peek(state.cache, {:payload, {0, {0, 0, 0}}})
  end

  @tag :thermal
  test "无人有限热源在持久发布后仍拥有页，释放观察不抹热源或未来due", c do
    assert {:ok, _} = World.apply_edits(c.world, [{{2, 1, 2}, 19}])
    experiment = Path.join(c.root, "thermal.json")
    File.write!(experiment, Jason.encode!(%{classification: "Test-only", source_macro: [2, 1, 2],
      ambient_kelvin: 293.15, environment_w_per_m2_k: 10.0, tolerance_kelvin: 1.0,
      emissivity: 0.0, view_range_cells: 8, power_w: 20_000.0, energy_j: 1.0e9}))
    assert :ok = World.thermal_experiment(c.world, experiment)
    assert :ok = World.compact(c.world)
    due = :sys.get_state(c.world).thermal_due
    assert :ok = World.set_simulation_windows(c.world, [])
    assert World.maintain_residency(c.world).reasons.thermal > 0
    state = :sys.get_state(c.world)
    assert Pages.resident?(state, {0, {0, 0, 0}})
    assert Map.has_key?(state.thermal.sources, {2, 1, 2})
    assert state.thermal_due == due
  end

  @tag :liquid
  test "无人活动液体在持久发布后仍拥有下一步页，释放观察不抹活动或due", c do
    assert {:ok, _} = World.material_supply(c.world, 1001, "water", %{21 => 128 * 2_097_152})
    assert {:ok, _} = World.liquid_fill(c.world, 1001, "fill", 21, {1, 1, 1}, 1)
    assert :ok = World.compact(c.world)
    before = :sys.get_state(c.world)
    assert MapSet.size(before.liquid_active) > 0
    assert :ok = World.set_simulation_windows(c.world, [])
    assert World.maintain_residency(c.world).reasons.liquid > 0
    state = :sys.get_state(c.world)
    assert Pages.resident?(state, {0, {0, 0, 0}})
    assert state.liquid_active == before.liquid_active
    assert state.liquid_due == before.liquid_due
  end

  @tag properties: true
  test "粗层fragment由L0和L1共享，最后一个驻留owner释放才删除", c do
    definition = VoxelRegion.Prefab.encode(%{cells: [{{0, 0, 0}, 11}], children: [], attachments: [], macro_cells: []})
    id = :crypto.hash(:sha256, definition)
    File.write!(Path.join([c.root, "prefabs", Base.encode16(id) <> ".vxpd"]), definition)
    assert :ok = World.publish_prefabs(c.world, Path.join(c.root, "prefabs"))
    assert :ok = World.set_simulation_windows(c.world, [{{0, 0, 0}, {1, 1, 1}}])
    assert {:ok, _} = World.place_prefab(c.world, id, {16, 8, 16}, 0)
    assert :ok = World.compact(c.world)
    fragment = {1, {0, 0, 0}}
    assert Map.has_key?(:sys.get_state(c.world).structure_pages, fragment)
    assert {token, _, _, _} = VoxelRegion.World.PageLoad.call(c.world, {:prepare, [{1, {0, 0, 0}}]})
    before = VoxelRegion.TestSupport.payload(c.world, 1, {0, 0, 0})
    assert :ok = World.set_simulation_windows(c.world, [])
    state = :sys.get_state(c.world)
    refute Pages.resident?(state, {0, {0, 0, 0}})
    assert Pages.resident?(state, {1, {0, 0, 0}})
    assert Map.has_key?(state.structure_pages, fragment)
    assert VoxelRegion.TestSupport.payload(c.world, 1, {0, 0, 0}) == before
    GenServer.cast(c.world, {:release_preparation, token, self()})
    assert World.maintain_residency(c.world).preparations == 0
    state = :sys.get_state(c.world)
    refute Pages.resident?(state, {1, {0, 0, 0}})
    refute Map.has_key?(state.structure_pages, fragment)
    assert state.structure == %{}
  end

  defp relay(parent) do
    receive do
      message -> send(parent, message); relay(parent)
    end
  end

  defp await(condition, remaining \\ 200)
  defp await(condition, remaining) when remaining > 0 do
    if condition.(), do: :ok, else: (Process.sleep(5); await(condition, remaining - 1))
  end
  defp await(_condition, 0), do: flunk("驻留生命周期未在限定时间内完成")
end
