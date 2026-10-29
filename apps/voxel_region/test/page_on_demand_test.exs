defmodule VoxelRegion.PageOnDemandTest do
  @moduledoc """
  只测试（Test-only）：M2b 按需装页（`docs/10-active/voxel-authority/2026-10-24-world-region-paging/m2b-on-demand-pages.md` §4）。

  世界内容全部经正常入口（作者编辑、作者放置 prefab、液体实验入口）写出并发布；重启后只用正常读写入口触及，判定
  驻留集、正式读取（去头部 seq 的载荷）与格材料。期望值来自手算的格与页坐标（页 = 64³ 宏格，负坐标向负无穷取整）。
  """
  use ExUnit.Case, async: false
  alias VoxelRegion.{OverlayLog, Prefab, World}
  alias VoxelRegion.TestSupport.Source
  alias VoxelRegion.World.Pages
  alias MmoContracts.Voxel.{Codec, Payload}

  @cv 123

  defmodule GateRead do
    @moduledoc """
    只测试：文件后端外加读取闸（故障注入只在装页边界）。`hold(owner, key)`：下一次读到含 key 的页时通知 owner 并等 `:continue`；
    `fail(owner, times)`：此后（至多 times 次）每次读页都通知 owner 并抛错（模拟 PG 不可用），`clear/0` 撤销。
    """
    alias VoxelRegion.OverlayLog.File, as: Log
    defdelegate open(path, cv), to: Log
    defdelegate replay(path), to: Log
    defdelegate append(path, txn), to: Log
    defdelegate checkpoint(path, txn), to: Log
    defdelegate prefix(path), to: Log
    defdelegate clear_unpublished(path, prefix), to: Log
    defdelegate write_pages(path, cut, rows), to: Log
    defdelegate publish(path, cut, rows, globals), to: Log
    defdelegate load(path), to: Log
    defdelegate load_head(path, code), to: Log
    defdelegate locate(path, ids), to: Log
    defdelegate page_keys(path), to: Log
    defdelegate collect(path, prefix, limit), to: Log

    def hold(owner, key), do: :persistent_term.put(__MODULE__, {:hold, owner, key})
    def shared(owner, key), do: :persistent_term.put(__MODULE__, {:shared, owner, key})
    def fail(owner, times \\ :infinity), do: :persistent_term.put(__MODULE__, {:fail, owner, times})
    def clear, do: :persistent_term.erase(__MODULE__)

    def read_pages(path, keys, fragments) do
      case :persistent_term.get(__MODULE__, nil) do
        {:shared, owner, key} ->
          if key in keys do
            send(owner, {:shared_read, self(), key})
            receive do
              :continue -> :ok
            end
          end

        {:hold, owner, key} ->
          if key in keys do
            :persistent_term.erase(__MODULE__)
            send(owner, {:holding_read, self(), key})
            receive do
              :continue -> :ok
            end
          end

        {:fail, owner, times} ->
          if times == 1, do: :persistent_term.erase(__MODULE__)
          if is_integer(times) and times > 1, do: :persistent_term.put(__MODULE__, {:fail, owner, times - 1})
          send(owner, {:read_failed, keys})
          raise "test-only page read failure"

        nil ->
          :ok
      end

      Log.read_pages(path, keys, fragments)
    end
  end

  defmodule GateSource do
    @moduledoc "只测试：仅阻塞 World 外发送进程的真实 source 读取，World 仍能处理生命周期消息。"
    defdelegate open(opts), to: VoxelRegion.TestSupport.Source
    defdelegate content_version(state), to: VoxelRegion.TestSupport.Source
    defdelegate world_dir(state), to: VoxelRegion.TestSupport.Source
    defdelegate generated(state), to: VoxelRegion.TestSupport.Source
    defdelegate ensure(state, level, region), to: VoxelRegion.TestSupport.Source
    def hold(observer, world), do: :persistent_term.put(__MODULE__, {observer, world})
    def clear, do: :persistent_term.erase(__MODULE__)

    def read(state, level, region) do
      case :persistent_term.get(__MODULE__, nil) do
        {observer, world} when world != self() ->
          :persistent_term.erase(__MODULE__)
          send(observer, {:holding_source, self()})
          receive do: (:continue -> :ok)
        _ -> :ok
      end
      VoxelRegion.TestSupport.Source.read(state, level, region)
    end
  end

  setup context do
    root = Path.join(System.tmp_dir!(), "page_on_demand_#{System.pid()}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "prefabs"))
    on_exit(fn -> File.rm_rf!(root) end)

    log =
      if context[:database] do
        MmoTest.Database.start!()
        :ok = DataService.Voxel.OverlayLogStore.reset_world(@cv)
        on_exit(fn -> DataService.Voxel.OverlayLogStore.reset_world(@cv) end)
        OverlayLog.Db
      else
        context[:log] || OverlayLog.File
      end

    on_exit(fn -> GateRead.clear() end)
    on_exit(fn -> GateSource.clear() end)

    opts = [source: Source, root: root, observer: self(), name: nil, log: log, production_materials: [11, 19],
      prefab_catalog_path: Path.join(root, "prefabs")]

    # 液体用例：已发布目录 + 液体步进参数（步长 1 小时，步进由用例手动投递，同 `liquid_world_test`）。
    opts =
      if context[:liquid] do
        catalog = Path.join(root, "catalog.json")
        data = Jason.decode!(File.read!(VoxelRegion.TestSupport.catalog()))
          |> Map.put("liquid", %{"step_seconds" => 3600, "gravity_units_per_step" => 524_288, "side_units_per_step" => 131_072,
            "side_threshold_units" => 0})
        File.write!(catalog, Jason.encode!(data))
        Keyword.merge(opts, property_catalog_path: catalog, production_materials: [19, 21], liquid_bounds: {{62, 0, 1}, {66, 4, 4}})
      else
        opts
      end

    # 热用例：材料 19 带热容 / 导热（同 thermal_radiation_world_test），环境 293.15 K、视线 8 格。
    opts =
      if context[:thermal] do
        catalog = Path.join(root, "thermal-properties.json")
        materials = for id <- 0..23 do
          base = %{material_id: id, max_hp_per_macro: if(id == 0, do: 0.0, else: 100.0), defense: 2.0, tags: [],
            responses: [%{action: "damage", multiplier: 1.0}]}
          if id == 19, do: Map.merge(base, %{heat_capacity_per_macro: 1000.0, thermal_conductivity: 10.0,
            heat_resistance_kelvin: 1.0e5}), else: base
        end
        File.write!(catalog, Jason.encode!(%{schema_version: 1, tags: [%{id: "damage"}], materials: materials, tools: [], definitions: []}))
        environment = Path.join(root, "environment.json")
        File.write!(environment, Jason.encode!(%{ambient_kelvin: 293.15, environment_w_per_m2_k: 10.0, tolerance_kelvin: 1.0,
          emissivity: 0.0, view_range_cells: 8, circuit_min_power_w: 1.0}))
        Keyword.merge(opts, property_catalog_path: catalog, thermal_environment_path: environment, production_materials: [19])
      else
        opts
      end
    world = start_supervised!({World, opts})
    %{root: root, opts: opts, world: world}
  end

  defp restart(c) do
    stop_supervised!(World)
    start_supervised!({World, c.opts})
  end

  defp resident?(w, key), do: Pages.resident?(:sys.get_state(w), key)

  # 读取闸属于持久化依赖替身；内容、并发请求与取消都经过正式 World 入口。
  @tag log: GateRead
  test "同一冷页重叠读取只发一次，两个公共请求都得到完整材料", c do
    assert {:ok, _} = World.apply_edits(c.world, [{{2, 1, 2}, 19}])
    assert :ok = World.compact(c.world)
    w = restart(c)
    key = {0, {0, 0, 0}}
    GateRead.shared(self(), key)
    a = Task.async(fn -> World.material_snapshot(w, [], [{2, 1, 2}]) end)
    assert_receive {:shared_read, reader, ^key}, 5_000
    b = Task.async(fn -> World.material_snapshot(w, [], [{2, 1, 2}]) end)
    refute_receive {:shared_read, _, ^key}, 300
    send(reader, :continue)
    assert [%{material: 19}] = Task.await(a, 5_000).probe_occupancy
    assert [%{material: 19}] = Task.await(b, 5_000).probe_occupancy
    await(fn -> :sys.get_state(w).page_load.tasks == %{} end)
    assert :sys.get_state(w).page_load.pending == %{}
  end

  @tag log: GateRead
  test "共享装页的一个 caller 退出不取消剩余调用，独占 caller 退出释放任务", c do
    assert {:ok, _} = World.apply_edits(c.world, [{{2, 1, 2}, 19}])
    assert :ok = World.compact(c.world)
    w = restart(c)
    key = {0, {0, 0, 0}}
    GateRead.shared(self(), key)
    a = spawn(fn -> World.material_snapshot(w, [], [{2, 1, 2}]) end)
    assert_receive {:shared_read, reader, ^key}, 5_000
    b = Task.async(fn -> World.material_snapshot(w, [], [{2, 1, 2}]) end)
    await(fn -> Enum.sum(for {_, t} <- :sys.get_state(w).page_load.tasks, do: length(t.entries)) == 2 end)
    Process.exit(a, :kill)
    await(fn -> Enum.sum(for {_, t} <- :sys.get_state(w).page_load.tasks, do: length(t.entries)) == 1 end)
    refute_receive {:shared_read, _, ^key}, 100
    send(reader, :continue)
    assert [%{material: 19}] = Task.await(b, 5_000).probe_occupancy

    w = restart(c)
    GateRead.shared(self(), key)
    caller = spawn(fn -> World.apply_edits(w, [{{2, 1, 2}, 11}]) end)
    assert_receive {:shared_read, abandoned, ^key}, 5_000
    monitor = Process.monitor(abandoned)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^abandoned, _}, 5_000
    await(fn -> :sys.get_state(w).page_load.tasks == %{} end)
    assert :sys.get_state(w).page_load.pending == %{}
    assert :sys.get_state(w).page_load.held == %{}
    GateRead.clear()
    assert materials(w, [{2, 1, 2}]) == [19]
  end

  defp materials(w, cells), do: Enum.map(World.material_snapshot(w, [], cells).probe_occupancy, & &1.material)

  @tag log: GateRead
  test "冷世界维护all与普通调用共享读取，完整装齐才接纳且不授予永久驻留", c do
    stop_supervised!(World)
    opts = Keyword.put(c.opts, :property_catalog_path, VoxelRegion.TestSupport.catalog())
    c = %{c | opts: opts, world: start_supervised!({World, opts})}
    assert {:ok, _} = World.apply_edits(c.world, [{{2, 1, 2}, 19}, {{258, 1, 2}, 11}])
    assert :ok = World.compact(c.world)
    w = restart(c)
    refute :sys.get_state(w).resident == :all
    key = {0, {0, 0, 0}}
    GateRead.shared(self(), key)
    ordinary = Task.async(fn -> World.material_snapshot(w, [], [{2, 1, 2}]) end)
    assert_receive {:shared_read, reader, ^key}, 5_000
    maintenance = Task.async(fn -> World.publish_properties(w, VoxelRegion.TestSupport.catalog()) end)
    await(fn -> Enum.sum(for {_, t} <- :sys.get_state(w).page_load.tasks, do: length(t.entries)) == 2 end)
    refute :sys.get_state(w).resident == :all
    refute_receive {:shared_read, _, ^key}, 100
    send(reader, :continue)
    assert [%{material: 19}] = Task.await(ordinary, 5_000).probe_occupancy
    assert :ok = Task.await(maintenance, 5_000)
    GateRead.clear()
    assert World.maintain_residency(w).status == :ready
    assert materials(w, [{2, 1, 2}, {258, 1, 2}]) == [19, 11]
    load = :sys.get_state(w).page_load
    assert load.tasks == %{} and load.pending == %{} and load.callers == %{}
  end

  @tag log: GateRead, liquid: true
  test "公共洪泛在第二次动态defer时活caller超时，取消身份没有在重放中丢失", c do
    stop_supervised!(World)
    opts = Keyword.put(c.opts, :liquid_bounds, {{0, 0, 0}, {384, 1, 1}})
    c = %{c | opts: opts}
    w = start_supervised!({World, opts})
    capacity = 2_097_152
    assert {:ok, _} = World.apply_edits(w, [{{320, 0, 0}, 19}])
    assert {:ok, _} = World.material_supply(w, 1001, "water", %{21 => 384 * capacity})
    send(w, :liquid_commit)
    await(fn -> World.liquid_activity(w).active_cells == 0 end)
    assert :ok = World.compact(w)
    w = restart(c)
    refute resident?(w, {0, {2, 0, 0}})
    refute resident?(w, {0, {5, 0, 0}})
    seq = World.seq(w)
    key = {0, {5, 0, 0}}
    GateRead.shared(self(), key)
    parent = self()
    caller = spawn(fn ->
      result = catch_exit(World.liquid_fill(w, 1001, "timed-fill", 21, {0, 0, 0}, 0, timeout: 1_000))
      send(parent, {:defer_timeout, self(), result})
      receive do: (:stop -> :ok)
    end)
    on_exit(fn -> Process.exit(caller, :kill) end)
    assert_receive {:shared_read, reader, ^key}, 5_000
    assert resident?(w, {0, {2, 0, 0}})
    refute resident?(w, key)
    assert World.seq(w) == seq
    monitor = Process.monitor(reader)
    assert_receive {:defer_timeout, ^caller, {:timeout, _}}, 2_000
    assert Process.alive?(caller)
    assert_receive {:DOWN, ^monitor, :process, ^reader, _}, 2_000
    load = :sys.get_state(w).page_load
    assert load.tasks == %{} and load.pending == %{} and load.callers == %{}
    assert World.seq(w) == seq
    GateRead.clear()
    assert Enum.find(World.material_balances(w, 1001), &(&1.material == 21)).balance == 384 * capacity
    assert materials(w, [{0, 0, 0}, {128, 0, 0}, {320, 0, 0}]) == [0, 0, 19]
    send(caller, :stop)
  end

  @tag log: GateRead
  test "公共canonical快照装页后由真实feed完成，接纳后的caller退出不撤销订阅", c do
    stop_supervised!(World)
    opts = Keyword.put(c.opts, :source, GateSource)
    c = %{c | opts: opts}
    w = start_supervised!({World, opts})
    assert {:ok, _} = World.apply_edits(w, [{{2, 1, 2}, 19}])
    assert :ok = World.compact(w)
    parent = self()

    for mode <- [:reply, :caller_exit] do
      w = restart(c)
      request = make_ref()
      key = {0, {0, 0, 0}}
      GateRead.shared(self(), key)
      subscriber = spawn(fn ->
        receive do
          {:canonical_snapshot, ^request, snapshot} ->
            send(parent, {:received_snapshot, request, snapshot})
            receive do: (:stop -> :ok)
        end
      end)
      caller = spawn(fn ->
        result = World.canonical_snapshot_and_subscribe(w, {{0, 0, 0}, {2, 1, 1}}, subscriber, request, false)
        send(parent, {:snapshot_reply, request, result})
        receive do: (:stop -> :ok)
      end)
      on_exit(fn -> Process.exit(caller, :kill); Process.exit(subscriber, :kill) end)
      assert_receive {:shared_read, reader, ^key}, 5_000
      assert Enum.any?(:sys.get_state(w).page_load.callers, fn {{pid, _}, _} -> pid == caller end)
      # 首页读取闸确保请求尚未接纳；source闸随后只阻塞真正发送进程。
      GateSource.hold(self(), w)
      send(reader, :continue)
      assert_receive {:holding_source, feed}, 5_000
      state = :sys.get_state(w)
      assert state.page_load.tasks == %{} and state.page_load.callers == %{}
      assert map_size(state.canonical_snapshots) == 1
      assert state.canonical_feeds[subscriber] == feed
      if mode == :caller_exit, do: Process.exit(caller, :kill)
      send(feed, :continue)
      assert_receive {:received_snapshot, ^request, snapshot}, 5_000
      assert snapshot.transaction_seq == World.seq(w)
      if mode == :reply do
        assert_receive {:snapshot_reply, ^request, :ok}, 5_000
        Process.exit(caller, :kill)
      end
      await(fn -> :sys.get_state(w).canonical_snapshots == %{} end)
      assert Map.has_key?(:sys.get_state(w).canonical_subs, subscriber)
      assert Process.alive?(feed)
      monitor = Process.monitor(feed)
      send(subscriber, :stop)
      assert_receive {:DOWN, ^monitor, :process, ^feed, _}, 5_000
      await(fn -> :sys.get_state(w).canonical_feeds == %{} end)
      assert :sys.get_state(w).page_load.callers == %{}
    end
  end

  @tag log: GateRead
  test "真实公共call包装超时但caller仍活着：取消独占装页，已接纳事务不撤销", c do
    assert {:ok, _} = World.apply_edits(c.world, [{{2, 1, 2}, 19}])
    assert :ok = World.compact(c.world)
    w = restart(c)
    key = {0, {0, 0, 0}}
    GateRead.shared(self(), key)
    parent = self()
    caller = spawn(fn ->
      # 正常 World 公共入口只缩短本次等待时限；caller 捕获超时后继续存活。
      result = catch_exit(World.simulation_snapshot(w, [], {{0, 0, 0}, {1, 1, 1}}, 150))
      send(parent, {:call_timeout, self(), result})
      receive do: (:stop -> :ok)
    end)
    on_exit(fn -> Process.exit(caller, :kill) end)
    assert_receive {:shared_read, reader, ^key}, 5_000
    monitor = Process.monitor(reader)
    assert_receive {:call_timeout, ^caller, {:timeout, _}}, 5_000
    assert Process.alive?(caller)
    assert_receive {:DOWN, ^monitor, :process, ^reader, _}, 5_000
    await(fn -> :sys.get_state(w).page_load.tasks == %{} end)
    load = :sys.get_state(w).page_load
    assert load.callers == %{} and load.pending == %{} and load.held == %{}
    GateRead.clear()
    assert materials(w, [{2, 1, 2}]) == [19]
    send(caller, :stop)

    accepted = spawn(fn ->
      send(parent, {:accepted_edit, World.apply_edits(w, [{{2, 1, 2}, 11}])})
      receive do: (:stop -> :ok)
    end)
    assert_receive {:accepted_edit, {:ok, _}}, 5_000
    Process.exit(accepted, :kill)
    assert materials(w, [{2, 1, 2}]) == [11]
    assert :sys.get_state(w).page_load.callers == %{}
  end

  @tag log: GateRead, liquid: true
  test "真实液体前沿与caller共享冷页：caller退出后模拟需求仍完成并继续落水", c do
    stop_supervised!(World)
    opts = Keyword.put(c.opts, :liquid_bounds, {{62, 0, 1}, {66, 196, 4}})
    w = start_supervised!({World, opts})
    c = %{c | opts: opts}
    supply = Path.join(c.root, "high-water.json")
    File.write!(supply, Jason.encode!(%{classification: "Test-only", deposits: [%{macro: [64, 193, 2], material: 21}]}))
    assert {:ok, _} = World.liquid_experiment(w, supply)
    assert :ok = World.compact(w)
    w = restart(c)
    key = {0, {1, 1, 0}}
    refute resident?(w, key)
    assert World.simulation_windows(w).source_count == 0
    # 初始活动页Y=3只载入邻页2..4；落水进入Y=2后，模拟自然需要仍冷的Y=1。
    send(w, :liquid_commit)
    _ = World.seq(w)
    GateRead.shared(self(), key)
    caller = spawn(fn -> World.material_snapshot(w, [], [{63, 128, 2}, {64, 128, 2}]) end)
    assert_receive {:shared_read, reader, ^key}, 5_000
    send(w, :liquid_commit)
    await(fn -> Enum.any?(:sys.get_state(w).page_load.tasks, fn {_, task} ->
      Enum.any?(task.entries, &match?({:input, _, {:info, :liquid_commit}}, &1))
    end) end)
    Process.exit(caller, :kill)
    await(fn -> :sys.get_state(w).page_load.callers == %{} end)
    assert Process.alive?(reader)
    refute_receive {:shared_read, _, ^key}, 100
    seq = World.seq(w)
    GateRead.clear()
    send(reader, :continue)
    await(fn -> :sys.get_state(w).page_load.tasks == %{} end)
    # 测试调度正式液体消息，不等待生产1小时间隔；实际内核与提交路径不替换。
    send(w, :liquid_commit)
    assert World.seq(w) > seq
    assert resident?(w, key)
    assert World.liquid_activity(w).active_cells > 0
    assert :sys.get_state(w).page_load.pending == %{}
  end

  defp fetch(w, level, region) do
    request = Codec.encode_request(@cv, [%{level: level, region: region, have_seq: 0, have_hash: 0}]) |> IO.iodata_to_binary()
    {:ok, reply} = World.serve(w, request)
    {:ok, _, [{:payload, ^level, ^region, bytes}]} = Codec.decode_reply(IO.iodata_to_binary(reply))
    {:ok, p} = Payload.decode(bytes)
    %{p | seq: 0}
  end

  # 作者目录里的 prefab（经正式目录发布入口；重启时由同一目录装回）。
  defp define(c, definition) do
    bytes = Prefab.encode(Map.merge(%{cells: [], children: [], attachments: [], macro_cells: []}, definition))
    id = :crypto.hash(:sha256, bytes)
    File.write!(Path.join([c.root, "prefabs", Base.encode16(id) <> ".vxpd"]), bytes)
    :ok = World.publish_prefabs(c.world, Path.join(c.root, "prefabs"))
    id
  end

  test "重启后冷页不驻留；编辑触及即装页并提交，冷页内容按正式读取不冒充 baseline", c do
    # 手算：a 在 L0 页 {0,0,0}；b 的 z = 330 → 页 {0,0,5}，两页相距 5 页，互不在对方的 26 邻页里。
    a = {10, 2, 10}
    b = {10, 2, 330}
    assert {:ok, _} = World.apply_edits(c.world, [{a, 11}, {b, 19}])
    cold = fetch(c.world, 0, {0, 0, 5})
    assert :ok = World.compact(c.world)

    w = restart(c)
    # 后缀为空、无活动页：启动不装任何页（M2a 启动装全部页）。
    assert World.stats(w).resident_pages == 0
    assert :ok = World.set_simulation_windows(w, [{{0, 0, 0}, {1, 1, 1}}])
    assert {:ok, _} = World.apply_edits(w, [{{11, 2, 10}, 19}])
    assert resident?(w, {0, {0, 0, 0}}) and resident?(w, {0, {1, 1, 1}})
    refute resident?(w, {0, {0, 0, 5}})
    assert materials(w, [a, {11, 2, 10}]) == [11, 19]
    # 冷页经正式读取装入：载荷（去 seq）与发布前相同，b 仍是 19 而不是 baseline。
    assert fetch(w, 0, {0, 0, 5}) == cold
    assert materials(w, [b]) == [19]
  end

  test "粗层页只读粗层页与片段：不装 L0 页，L1–L5 载荷（含细化 structure）与发布前相同", c do
    # 一个细化格（微格 prefab）在宏格 {2,1,2}：L1–L5 的 structure 都落在 L0 页 {0,0,0} 的片段里。
    id = define(c, %{cells: [{{0, 0, 0}, 11}, {{1, 0, 0}, 19}]})
    assert {:ok, _} = World.place_prefab(c.world, id, {16, 8, 16}, 0)
    before = for level <- 1..5, do: fetch(c.world, level, {0, 0, 0})
    assert Enum.all?(before, &(map_size(&1.structure) > 0))
    assert :ok = World.compact(c.world)

    w = restart(c)
    {token, _, _, _} = VoxelRegion.World.PageLoad.call(w, {:prepare, for(level <- 1..5, do: {level, {0, 0, 0}})})
    assert (for level <- 1..5, do: fetch(w, level, {0, 0, 0})) == before
    refute resident?(w, {0, {0, 0, 0}})
    assert resident?(w, {5, {0, 0, 0}})
    GenServer.cast(w, {:release_preparation, token, self()})
  end

  for backend <- [:file, :database] do
    @tag database: backend == :database
    test "跨页 prefab 按 id 拆除：定位表 → 根 home 页 → 覆盖页集合装全整棵树（#{backend}）", c do
      # 手算：anchor 微格 (480,16,80) → 宏格 (60,2,10)，home = 页 {0,0,0}；同一定义的两段宏格 x 60..63（页 {0,0,0}）与
      # x 130..133（页 {2,0,0}），中间的页 {1,0,0} 没有它的格。页 {2,0,0} 不在 home 页及其格的 26 邻页里，只能由根记录的覆盖页集合带出。
      offsets = Enum.to_list(0..3) ++ Enum.to_list(70..73)
      cells = for dx <- offsets, do: {60 + dx, 2, 10}
      id = define(c, %{macro_cells: for(dx <- offsets, do: {{dx, 0, 0}, 11})})
      assert {:ok, _} = World.place_prefab(c.world, id, {480, 16, 80}, 0)
      assert materials(c.world, cells) == List.duplicate(11, 8)
      [instance] = Map.keys(:sys.get_state(c.world).instances)
      assert :ok = World.compact(c.world)

      w = restart(c)
      assert World.stats(w).resident_pages == 0
      # 只带 id 的入口：内存里没有这个实例，经定位表找到根 home，再按根记录的覆盖页装入另一页。
      assert {:ok, _} = World.remove_prefab(w, instance)
      assert resident?(w, {0, {0, 0, 0}}) and resident?(w, {0, {2, 0, 0}})
      assert materials(w, cells) == List.duplicate(0, 8)

      w = restart(c)
      assert materials(w, cells) == List.duplicate(0, 8)
      assert :sys.get_state(w).instances == %{}
      assert {:error, :instance_not_found} = World.remove_prefab(w, instance)
    end
  end

  test "只在日志后缀里创建的身份（未发布、无定位行）：重启重放后按 id 拆除", c do
    id = define(c, %{macro_cells: for(dx <- 0..4, do: {{dx, 0, 0}, 11})})
    assert :ok = World.compact(c.world)
    assert {:ok, _} = World.place_prefab(c.world, id, {496, 16, 80}, 0)
    [instance] = Map.keys(:sys.get_state(c.world).instances)

    w = restart(c)
    # 后缀写到的页（及其邻页）启动即装入并重放，身份在内存，拆除不查定位表。
    assert Map.has_key?(:sys.get_state(w).instances, instance)
    assert {:ok, _} = World.remove_prefab(w, instance)
    assert materials(w, for(dx <- 0..4, do: {62 + dx, 2, 10})) == List.duplicate(0, 5)
  end

  test "迟到的装页结果：同页已装入并改写后，旧结果不覆盖", c do
    # 细化格（微格 prefab）在宏格 {2,1,2}，页 {0,0,0}；压实不改 refined 的表示，旧结果里带着它。
    id = define(c, %{cells: [{{0, 0, 0}, 11}]})
    assert {:ok, _} = World.place_prefab(c.world, id, {16, 8, 16}, 0)
    [instance] = Map.keys(:sys.get_state(c.world).instances)
    assert :ok = World.compact(c.world)

    w = restart(c)
    key = {0, {0, 0, 0}}
    %{rows: stale} = OverlayLog.File.read_pages(Path.join(c.root, "overlay.log"), [key], Pages.fragment_codes())
    # 第一个结果正常接纳；之后同页被改写（拆掉细化格）；同一令牌的第二个（迟到）结果到达。
    assert {_, _} = GenServer.call(w, {:page_adopt, [{key, 0}], stale, %{}})
    assert Map.has_key?(:sys.get_state(w).refined, {2, 1, 2})
    assert {:ok, _} = World.remove_prefab(w, instance)
    fields = [:refined, :instances, :macro_owners, :region_bases, :overlay, :damage]
    current = Map.take(:sys.get_state(w), fields)
    refute Map.has_key?(current.refined, {2, 1, 2})
    assert {[], []} = GenServer.call(w, {:page_adopt, [{key, 0}], stale, %{}})
    assert Map.take(:sys.get_state(w), fields) == current
  end

  @tag :liquid
  test "活动索引：液体流动中发布并重启，零窗口且不触碰该区仍继续推进", c do
    # 全空气 baseline 上 y = 3 的一格水：每步下落，至少两步仍在流动。
    supply = Path.join(c.root, "water.json")
    File.write!(supply, Jason.encode!(%{classification: "Test-only", deposits: [%{macro: [64, 3, 2], material: 21}]}))
    assert {:ok, _} = World.liquid_experiment(c.world, supply)
    seq = World.seq(c.world)
    send(c.world, :liquid_commit)
    await(fn -> World.seq(c.world) > seq end)
    assert World.liquid_activity(c.world).active_cells > 0
    assert :ok = World.compact(c.world)

    w = restart(c)
    # 启动只按活动索引装入水所在页（扩 26 邻页），活动集随页恢复；不经任何读写请求。
    assert World.liquid_activity(w).active_cells > 0
    assert resident?(w, {0, {1, 0, 0}})
    assert World.simulation_windows(w).source_count == 0
    seq = World.seq(w)
    send(w, :liquid_commit)
    await(fn -> World.seq(w) > seq end)
  end

  # M2a 遗留（按需装页后冷区更常见）：作者编辑先逐格判液体，曾每格丢掉解码缓存、重读重解码整区 baseline。
  test "作者编辑冷区多格：baseline 整区只读一次", c do
    # 区域 {10,0,0} 的读取由测试数据源通知并等待放行（`TestSupport.Source`）；四格都在该区 core 内。
    cells = for x <- 0..3, do: {650 + x, 2, 10}
    task = Task.async(fn -> World.apply_edits(c.world, Enum.map(cells, &{&1, 11})) end)
    # 改前：逐格判液体各读一次（4）+ 归约再读一次 = 5；改后整笔一次。
    assert reads(task, 0) == 1
  end

  defp reads(task, n) do
    receive do
      {:region_read_started, pid, {10, 0, 0}} ->
        send(pid, :continue_region_read)
        reads(task, n + 1)

      {ref, result} when ref == task.ref ->
        Process.demonitor(ref, [:flush])
        {:ok, _} = result
        n
    end
  end

  # 父稿 P4：有模拟资格但未驻留的页——该步暂停、请求装页、装齐后再推进，不提交部分通量、不当空气、不崩 World。
  @tag :thermal
  # 证明范围（评审 A 测试项）：只覆盖“开提交前”发现缺页的暂停与续行；内核步之间的缺页暂停与同步收尾路径由“热步前装页失败：不紧循环重试”
  # 用例触及，夹具只删驻留标记（邻页内容仍在内存），不制造真实冷页数据缺失。
  test "开热提交前读到未驻留页时暂停，装齐后才推进", c do
    # 手算：热源格 (63,1,10) 在页 {0,0,0} 的 +x 边上，六邻 (64,1,10) 在页 {1,0,0}，同在计算域里。
    assert {:ok, _} = World.apply_edits(c.world, [{{63, 1, 10}, 19}, {{64, 1, 10}, 19}])
    experiment = Path.join(c.root, "thermal.json")
    File.write!(experiment, Jason.encode!(%{classification: "Test-only", source_macro: [63, 1, 10], ambient_kelvin: 293.15,
      environment_w_per_m2_k: 10.0, tolerance_kelvin: 1.0, emissivity: 0.0, view_range_cells: 8, power_w: 20_000.0, energy_j: 1.0e9}))
    :ok = World.thermal_experiment(c.world, experiment)
    assert :ok = World.compact(c.world)

    w = restart(c)
    # 活动索引装入热源页及其 26 邻页；只测试夹具：停掉墙钟节拍，并把邻页 {1,0,0} 记为未驻留（它从未在启动后改过，
    # 重装与内存一致），模拟热域伸进尚未装入的页。
    assert resident?(w, {0, {1, 0, 0}})
    :sys.replace_state(w, fn s ->
      if s.thermal_timer, do: Process.cancel_timer(s.thermal_timer)
      %{s | thermal_timer: nil, resident: MapSet.delete(s.resident, {0, {1, 0, 0}})}
    end)
    elapsed = :sys.get_state(w).thermal.elapsed_s
    seq = World.seq(w)
    send(w, :thermal_tick)
    # 这一拍：未开提交、未推进模拟时间、无新事务，已起装页；World 照常响应。
    s = :sys.get_state(w)
    assert s.thermal_run == nil and s.thermal.elapsed_s == elapsed and World.seq(w) == seq
    assert match?(%{status: :loading}, s.page_load.sim) or Pages.resident?(s, {0, {1, 0, 0}})
    # 装齐后由装页任务唤醒：推进一次 0.5 s。
    await(fn -> :sys.get_state(w).thermal.elapsed_s == elapsed + 0.5 end)
    assert resident?(w, {0, {1, 0, 0}})
  end

  defp await(fun, n \\ 200) do
    cond do
      fun.() -> :ok
      n == 0 -> flunk("condition not reached")
      true -> Process.sleep(25); await(fun, n - 1)
    end
  end

  # ---- 代码评审跟进（review-{astra,fable}-m2b-code.md）

  # 评审 A2 / F1：模拟提交的闭包只装 L0 页时，逐级归约从 baseline 读未驻留粗层页的兄弟格，并把不完整的粗层值写回 PG。
  # 期望独立于分页：同一操作序列在不重启的世界里得到的 L1–L5 载荷（内存即全部真值）。
  @tag :liquid
  test "重启后一步液体提交 → 切点 → 再重启：L1–L5 载荷与不重启的同序操作逐字节相等", c do
    # 水格 (64,3,2) 在页 {1,0,0}；石格 (66,2,2) 与水在同一 L2 父格 (16,0,0)（L1 兄弟 (32,1,1) / (33,1,1)）。
    supply = Path.join(c.root, "water.json")
    File.write!(supply, Jason.encode!(%{classification: "Test-only", deposits: [%{macro: [64, 3, 2], material: 21}]}))

    setup_world = fn w ->
      assert {:ok, _} = World.apply_edits(w, [{{66, 2, 2}, 19}])
      assert {:ok, _} = World.liquid_experiment(w, supply)
      assert :ok = World.compact(w)
    end

    coarse = fn w -> for level <- 1..5, do: fetch(w, level, {0, 0, 0}) end

    setup_world.(c.world)
    w = restart(c)
    :ok = VoxelRegion.TestSupport.activate_simulation(w, c.opts[:liquid_bounds])
    seq = World.seq(w)
    send(w, :liquid_commit)
    assert World.seq(w) > seq
    assert :ok = World.compact(w)
    w = restart(c)
    paged = coarse.(w)

    # 对照：另一个根目录、同一序列、不重启。
    stop_supervised!(World)
    root = c.root <> "_reference"
    File.mkdir_p!(Path.join(root, "prefabs"))
    on_exit(fn -> File.rm_rf!(root) end)
    ref = start_supervised!({World, Keyword.put(c.opts, :root, root)})
    :ok = VoxelRegion.TestSupport.activate_simulation(ref, c.opts[:liquid_bounds])
    setup_world.(ref)
    send(ref, :liquid_commit)
    _ = World.seq(ref)
    assert coarse.(ref) == paged
  end

  # 评审 A2：洪泛没有离 seed 的空间上界；伸进冷页时不能把冷页上的持久墙当空气。期望（手算）：墙在 x = 128，注液止于 x = 127。
  test "注液洪泛伸进冷页：先装页再裁决，冷页上的墙挡住液体", c do
    stop_supervised!(World)
    catalog = Path.join(c.root, "catalog.json")

    data =
      Jason.decode!(File.read!(VoxelRegion.TestSupport.catalog()))
      |> Map.put("liquid", %{"step_seconds" => 3600, "gravity_units_per_step" => 524_288, "side_units_per_step" => 131_072,
        "side_threshold_units" => 0})

    File.write!(catalog, Jason.encode!(data))
    opts = Keyword.merge(c.opts, property_catalog_path: catalog, production_materials: [19, 21], liquid_bounds: {{0, 0, 0}, {192, 1, 1}})
    c = %{c | opts: opts}
    w = start_supervised!({World, opts})
    :ok = VoxelRegion.TestSupport.activate_simulation(w, opts[:liquid_bounds])
    assert {:ok, _} = World.apply_edits(w, [{{128, 0, 0}, 19}])
    assert {:ok, _} = World.material_supply(w, 1001, "water", %{21 => 192 * 2_097_152})
    # 编辑唤醒的液体活动集（墙周围，此时还没有水）走一步即趋静，墙页不会作为活动页在启动时装入。
    send(w, :liquid_commit)
    await(fn -> World.liquid_activity(w).active_cells == 0 end)
    assert :ok = World.compact(w)

    w = restart(c)
    refute resident?(w, {0, {2, 0, 0}})
    assert {:ok, %{cells: 128}} = World.liquid_fill(w, 1001, "fill", 21, {0, 0, 0}, 0)
    assert materials(w, [{127, 0, 0}, {128, 0, 0}, {129, 0, 0}]) == [21, 19, 0]
  end

  # 评审 A1 / F2：整树闭包在装页任务里按 PG 行闭合后一次接纳；中途别处的几何提交看不到“身份已装、格未装”的半棵树，也不会把它当死实例删除。
  @tag log: GateRead
  test "整树闭包未闭合前不驻留：分批暂存途中触及该树的请求挂起到闭合，别处提交不删跨页实例", c do
    offsets = Enum.to_list(0..3) ++ Enum.to_list(70..73)
    cells = for dx <- offsets, do: {60 + dx, 2, 10}
    id = define(c, %{macro_cells: for(dx <- offsets, do: {{dx, 0, 0}, 11})})
    assert {:ok, _} = World.place_prefab(c.world, id, {480, 16, 80}, 0)
    [instance] = Map.keys(:sys.get_state(c.world).instances)
    assert :ok = World.compact(c.world)

    w = restart(c)
    assert :ok = World.set_simulation_windows(w, [{{0, 0, 0}, {1, 1, 1}}])
    # 只触及 home 页 {0,0,0} 的一格（只装本页）；树的另一部分在页 {2,0,0}，读它时卡住。
    GateRead.hold(self(), {0, {2, 0, 0}})
    reader = Task.async(fn -> World.material_snapshot(w, [], [{60, 2, 10}]) end)
    assert_receive {:holding_read, task, {0, {2, 0, 0}}}, 10_000
    # 闭合前：home 页已分批暂存（数据进了 World）但不驻留。
    refute resident?(w, {0, {0, 0, 0}})
    # 分批接纳途中另一请求触及这棵树（按 id 取整树的格）：必须挂起到闭合，不能按半棵树（只有 home 页上的 4 格）回答。
    cells_task = Task.async(fn -> World.instance_cells(w, instance) end)
    assert Task.yield(cells_task, 300) == nil
    # 此时远处一笔正常编辑提交（与这棵树的页、各级粗层祖页都不重叠：x = 8000 在 L5 页 3，暂存的在 L5 页 −1..1）：
    # 不把暂存中的实例当死实例删除。
    assert {:ok, _} = World.apply_edits(w, [{{8000, 2, 10}, 19}])
    send(task, :continue)
    assert [%{material: 11}] = Task.await(reader, 10_000).probe_occupancy
    assert {:ok, tree} = Task.await(cells_task, 10_000)
    assert Enum.sort(tree) == Enum.sort(cells)
    assert Map.has_key?(:sys.get_state(w).instances, instance)
    assert materials(w, cells) == List.duplicate(11, 8)

    w = restart(c)
    assert :ok = World.set_simulation_windows(w, [{{0, 0, 0}, {1, 1, 1}}])
    assert materials(w, cells) == List.duplicate(11, 8)
    assert Map.has_key?(:sys.get_state(w).instances, instance)
  end

  # 统筹第五轮 / 评审 Fable §2.4：粗层祖页与不带树身份 / 引用的 L0 页随批标驻留，不被一次整树装页占住到闭合；
  # 带树身份的页（home 页）仍等整树闭合。
  @tag log: GateRead
  test "整树暂存期间粗层祖页与平凡 L0 页已驻留：同一 L5 区域内与该树无关的编辑不等整树闭合", c do
    offsets = Enum.to_list(0..3) ++ Enum.to_list(70..73)
    cells = for dx <- offsets, do: {60 + dx, 2, 10}
    id = define(c, %{macro_cells: for(dx <- offsets, do: {{dx, 0, 0}, 11})})
    assert {:ok, _} = World.place_prefab(c.world, id, {480, 16, 80}, 0)
    assert :ok = World.compact(c.world)

    w = restart(c)
    # 编辑 A 在树的 home 页 {0,0,0}（带 L1–L5 祖页）：读完首轮页后要补覆盖页 {2,0,0}，读它时卡住（整树未闭合）。
    GateRead.hold(self(), {0, {2, 0, 0}})
    a = Task.async(fn -> World.apply_edits(w, [{{61, 3, 10}, 19}]) end)
    assert_receive {:holding_read, task, {0, {2, 0, 0}}}, 10_000
    # 首轮已暂存：粗层祖页（L5 页 {0,0,0}）与不含树的邻页 {0,1,0} 已驻留；home 页带树身份，未驻留。
    assert resident?(w, {5, {0, 0, 0}}) and resident?(w, {1, {0, 0, 0}}) and resident?(w, {0, {0, 1, 0}})
    refute resident?(w, {0, {0, 0, 0}})
    # 同一 L5 页（{0,0,0}，z = 330 在 L0 页 {0,0,5}）内与该树无关的编辑：共用 L1–L5 祖页，在树仍卡住时就完成。
    started = System.monotonic_time(:millisecond)
    assert {:ok, _} = World.apply_edits(w, [{{10, 2, 330}, 19}])
    elapsed = System.monotonic_time(:millisecond) - started
    refute resident?(w, {0, {0, 0, 0}})
    send(task, :continue)
    assert {:ok, _} = Task.await(a, 10_000)
    assert materials(w, cells ++ [{61, 3, 10}, {10, 2, 330}]) == List.duplicate(11, 8) ++ [19, 19]
    # 量级记录（文件后端，本机）：无关编辑耗时与一次装页批次同量级，不是“等到整树闭合”（树此刻仍卡在读页上，永不自行闭合）。
    assert elapsed < 5_000

    w = restart(c)
    assert materials(w, cells ++ [{61, 3, 10}, {10, 2, 330}]) == List.duplicate(11, 8) ++ [19, 19]
  end

  # P1：失败任务没有最后需求时退休半树；新的正常请求仍从持久locator恢复完整树，不把退休当业务删除。
  @tag log: GateRead
  test "装页失败暂存被退休后，下一正常请求仍通过locator恢复整树", c do
    offsets = Enum.to_list(0..3) ++ Enum.to_list(70..73)
    cells = for dx <- offsets, do: {60 + dx, 2, 10}
    id = define(c, %{macro_cells: for(dx <- offsets, do: {{dx, 0, 0}, 11})})
    assert {:ok, _} = World.place_prefab(c.world, id, {480, 16, 80}, 0)
    [instance] = Map.keys(:sys.get_state(c.world).instances)
    assert :ok = World.compact(c.world)

    w = restart(c)
    # 装页边界的故障注入：任务暂存了 home 页 H={0,0,0}（实例记录进内存）后、读覆盖页 Q={2,0,0} 时被杀——暂存撤销，H 不驻留。
    GateRead.hold(self(), {0, {2, 0, 0}})
    killed = Task.async(fn -> World.instance_cells(w, instance) end)
    assert_receive {:holding_read, task, {0, {2, 0, 0}}}, 10_000
    # 只测试callback运输：合法且仍有原任务需求的半树副本，以attempt1过同一gate；不回填运行authority。
    # 删除gate对“已知但未闭合身份”的定位例外，会错误返回:ready，不能拿退休后的attempt0恢复替代这一合同。
    partial = :sys.get_state(w)
    probe_from = {self(), make_ref()}
    assert {:deferred, probe} = VoxelRegion.World.PageLoad.gate(partial, {:call, {:instance_cells, instance}, probe_from}, 1)
    assert_receive {:"$gen_call", {probe_pid, _} = reply_to, {:page_need, [], [], [^instance], probe_pid}}, 1_000
    probe_ref = Enum.find_value(probe.page_load.tasks, fn {ref, entry} -> entry.pid == probe_pid and ref end)
    GenServer.reply(reply_to, :ready)
    assert_receive {:DOWN, ^probe_ref, :process, ^probe_pid, :normal}, 1_000
    _ = VoxelRegion.World.PageLoad.accepted(probe, probe_from)
    Process.exit(task, :kill)
    assert {:error, {:page_load_failed, :killed}} = Task.await(killed, 10_000)
    state = :sys.get_state(w)
    refute Map.has_key?(state.instances, instance)
    refute Pages.tree_complete?(state, instance)
    refute Pages.resident?(state, {0, {0, 0, 0}})

    assert :ok = World.set_simulation_windows(w, [{{0, 0, 0}, {1, 1, 1}}])
    assert {:ok, tree} = World.instance_cells(w, instance)
    # 手算：整树 8 格（home 页 4 格 + 覆盖页 4 格）；半棵树只有 4 格。
    assert Enum.sort(tree) == Enum.sort(cells)
    assert resident?(w, {0, {0, 0, 0}}) and resident?(w, {0, {2, 0, 0}})
  end

  # 评审 A1 / F2：裁剪只作用于本笔碰过的身份。即使某次接纳只带来树的 home（身份已装、格未装），别处提交也不删它。
  test "别处提交可退休无需求的装入表示，持久实例仍能正常定位", c do
    # 手算：anchor 宏格 (60,2,10) → home 页 {0,0,0}；全部宏格在 x 130..133（页 {2,0,0}），home 页上没有它的格。
    id = define(c, %{macro_cells: for(dx <- 70..73, do: {{dx, 0, 0}, 11})})
    assert {:ok, _} = World.place_prefab(c.world, id, {480, 16, 80}, 0)
    [instance] = Map.keys(:sys.get_state(c.world).instances)
    assert :ok = World.compact(c.world)

    w = restart(c)
    # 只接纳 home 页（直接经 World 的接纳调用，模拟只到一半的闭包）。
    key = {0, {0, 0, 0}}
    %{rows: rows} = OverlayLog.File.read_pages(Path.join(c.root, "overlay.log"), [key], Pages.fragment_codes())
    assert {_, _} = GenServer.call(w, {:page_adopt, [{key, 0}], rows, %{}})
    assert Map.has_key?(:sys.get_state(w).instances, instance)
    assert {:ok, _} = World.apply_edits(w, [{{10, 2, 330}, 19}])
    refute Map.has_key?(:sys.get_state(w).instances, instance)
    assert {:ok, restored} = World.instance_cells(w, instance)
    assert Enum.sort(restored) == for(x <- 130..133, do: {x, 2, 10})
  end

  # 评审 A4：后缀里区域后像带的是实例的网络投影（无 placed_by）；回放不得用它覆盖页里装回的完整记录。
  @tag :liquid
  test "后缀回放不以区域后像覆盖未改动实例的完整记录（placed_by 保留）", c do
    id = define(c, %{cells: [{{0, 0, 0}, 19}]})
    actor = %{cid: 1001, gate: self(), identity: :placer, refresh: &VoxelRegion.TestSupport.Actor.tool_context/2,
      eye: {2.0, 2.0, 2.0}, tick_us: 16_667}
    actor = Map.put(actor, :player, start_supervised!({VoxelRegion.TestSupport.Actor, actor}))
    assert {:ok, _} = World.material_supply(c.world, 1001, "placing", %{19 => 1_000_000})

    place = fn anchor, seq ->
      World.prefab_intent(c.world, actor, :voxel_prefab_place_v1, %{definition_id: id, anchor: anchor, orientation: 0, client_intent_seq: seq})
    end

    assert {:ok, _} = place.({16, 8, 16}, 1)
    [a] = Map.keys(:sys.get_state(c.world).instances)
    assert get_in(:sys.get_state(c.world).instances, [a, :placed_by]) == 1001
    assert :ok = World.compact(c.world)
    # 同一区域再放 B（后缀），A 不变。
    assert {:ok, _} = place.({24, 8, 16}, 2)

    w = restart(c)
    _ = materials(w, [{2, 1, 2}])
    assert get_in(:sys.get_state(w).instances, [a, :placed_by]) == 1001
  end

  # 评审 A3 / F5：装入无关页不得把别处尚未提交的热源差异抹成“已记住”。期望：差异格的热源单元在下一笔提交里判脏。
  @tag :thermal
  test "装页不重置他页未提交的热源差异（热步间判脏）", c do
    assert {:ok, _} = World.apply_edits(c.world, [{{10, 1, 10}, 19}])
    experiment = Path.join(c.root, "thermal.json")
    File.write!(experiment, Jason.encode!(%{classification: "Test-only", source_macro: [10, 1, 10], ambient_kelvin: 293.15,
      environment_w_per_m2_k: 10.0, tolerance_kelvin: 1.0, emissivity: 0.0, view_range_cells: 8, power_w: 20_000.0, energy_j: 1.0e9}))
    :ok = World.thermal_experiment(c.world, experiment)
    assert {:ok, _} = World.apply_edits(c.world, [{{10, 2, 330}, 19}])
    assert :ok = World.compact(c.world)
    w = restart(c)
    :sys.replace_state(w, fn s -> if s.thermal_timer, do: Process.cancel_timer(s.thermal_timer); %{s | thermal_timer: nil} end)
    state = :sys.get_state(w)
    assert Map.has_key?(state.thermal.sources, {10, 1, 10})
    # 热步中途热源耗尽（内核改写 sources，提交尚未结束）：在 World 状态副本上走同一组纯函数（接纳无关页 → 提交收尾的判脏）。
    exhausted = put_in(state.thermal.sources, %{})
    key = {0, {0, 0, 5}}
    %{rows: rows} = OverlayLog.File.read_pages(Path.join(c.root, "overlay.log"), [key], Pages.fragment_codes())
    assert rows != []
    {adopted, _, _} = Pages.adopt(exhausted, [{key, 0}], rows, %{})
    committed = Pages.remember(adopted, %{})
    assert Pages.cell_unit(:sources, {10, 1, 10}) in committed.page_dirty
  end

  @tag :thermal
  test "两页各一个热源：重启后只触及一页，另一页热源仍在且照常结算", c do
    assert {:ok, _} = World.apply_edits(c.world, [{{10, 1, 10}, 19}, {{10, 1, 330}, 19}])

    for {macro, name} <- [{[10, 1, 10], "a"}, {[10, 1, 330], "b"}] do
      experiment = Path.join(c.root, "thermal-#{name}.json")
      File.write!(experiment, Jason.encode!(%{classification: "Test-only", source_macro: macro, ambient_kelvin: 293.15,
        environment_w_per_m2_k: 10.0, tolerance_kelvin: 1.0, emissivity: 0.0, view_range_cells: 8, power_w: 20_000.0, energy_j: 1.0e9}))
      :ok = World.thermal_experiment(c.world, experiment)
    end

    assert :ok = World.compact(c.world)
    w = restart(c)
    _ = materials(w, [{10, 1, 10}])
    assert World.simulation_windows(w).source_count == 0
    send(w, :thermal_commit)
    _ = World.seq(w)
    assert :ok = World.compact(w)
    w = restart(c)
    sources = :sys.get_state(w).thermal.sources
    assert Enum.sort(Map.keys(sources)) == [{10, 1, 10}, {10, 1, 330}]
    assert sources[{10, 1, 330}].remaining_j < 1.0e9
  end

  # 装页失败保持原due；显式修复/恢复后才续步，不再按墙钟无限自动重试。步前读取集缺页时不开run（无部分推进）；
  # 失败期间到达的显式强制步与 `:liquid_commit` 同经输入闸显式拒绝，不另起读取或绕过失败闸。
  @tag :thermal
  @tag log: GateRead
  test "热步前装页失败：原due显式等待，强制步不绕过，一次恢复后继续", c do
    assert {:ok, _} = World.apply_edits(c.world, [{{63, 1, 10}, 19}, {{64, 1, 10}, 19}])
    experiment = Path.join(c.root, "thermal.json")
    File.write!(experiment, Jason.encode!(%{classification: "Test-only", source_macro: [63, 1, 10], ambient_kelvin: 293.15,
      environment_w_per_m2_k: 10.0, tolerance_kelvin: 1.0, emissivity: 0.0, view_range_cells: 8, power_w: 20_000.0, energy_j: 1.0e9}))
    :ok = World.thermal_experiment(c.world, experiment)
    assert :ok = World.compact(c.world)
    w = restart(c)
    :ok = VoxelRegion.TestSupport.activate_simulation(w, {{63, 1, 10}, {65, 2, 11}})
    # 只测试夹具：把热源邻页 {1,0,0} 记为未驻留，并让读页失败；到期自然步在步前读取。
    :sys.replace_state(w, fn s -> %{s | resident: MapSet.delete(s.resident, {0, {1, 0, 0}})} end)
    GateRead.fail(self())
    assert_receive {:read_failed, _}, 1_000
    try do
      await(fn -> World.stats(w).simulation_io.status == :failed end)
      failed = World.stats(w).simulation_progress.thermal
      refute_receive {:read_failed, _}, 600
      assert failed.wait_reason == :page_io_failed
      assert :sys.get_state(w).thermal_run == nil
      assert World.stats(w).simulation_progress.thermal.next_due_ms == failed.next_due_ms
      send(w, :thermal_commit)
      World.seq(w)
      refute_receive {:read_failed, _}, 100
      assert World.stats(w).simulation_progress.thermal.model_elapsed_s == failed.model_elapsed_s
      GateRead.clear()
      assert {:loading, _attempt} = World.retry_simulation_io(w)
      await(fn -> World.stats(w).simulation_progress.thermal.model_elapsed_s > failed.model_elapsed_s end)
    after
      GateRead.clear()
    end
    assert Process.alive?(w)
  end

  # 统筹跟进：窗口预备带上百个粗层页键，逐键查询让首次装页从中位 74 ms 退化到 1.2 s。粗层页按级合并读取：查询数不随页键数增长。
  # 期望（手算）：片段行区域是 L0 坐标，所属粗层页 = 向负无穷整除 2^level；非片段行按区域相等。
  @tag database: true
  test "粗层页按级合并读取：选行与逐页规则相同，查询数 ≤ 级数 + 固定开销", _c do
    alias DataService.Voxel.PageStore
    row = fn level, region, segment -> %{level: level, region: region, segment: segment, chunk: {0, 0, 0}, payload: <<level, segment>>} end
    [structure, canopy] = Pages.fragment_codes()
    rows = [
      row.(1, {1, 0, 0}, structure),   # L1 页 {0,0,0} 的片段（1 >>> 1 = 0）
      row.(1, {5, 0, 0}, structure),   # L1 页 {2,0,0}，不在请求里
      row.(2, {0, 0, 0}, 20),          # L2 页 {0,0,0} 的 base
      row.(3, {-1, 0, 0}, 21),         # L3 页 {-1,0,0} 的稀疏格
      row.(5, {-33, 0, 0}, canopy),    # L5 页 {-2,0,0} 的片段（-33 >>> 5 = -2）
      row.(5, {-2, 0, 0}, 20)          # L5 页 {-2,0,0} 的 base
    ]
    :ok = PageStore.publish(@cv, 1, rows, Pages.globals(%{seq: 1, protection: %{regions: %{}}, thermal: nil}))
    keys = [{1, {0, 0, 0}}, {2, {0, 0, 0}}, {3, {-1, 0, 0}}, {5, {-2, 0, 0}}] ++ for(x <- 0..9, level <- [1, 4], do: {level, {x + 10, 0, 0}})

    me = self()
    handler = "page-read-count-#{System.unique_integer([:positive])}"
    :telemetry.attach(handler, [:data_service, :repo, :query], fn _, _, meta, _ -> if self() == me and String.starts_with?(meta.query, "SELECT DISTINCT ON"), do: send(me, :query) end, nil)
    %{rows: got} = PageStore.read_pages(@cv, keys, Pages.fragment_codes())
    :telemetry.detach(handler)

    assert MapSet.new(got, &{&1.level, &1.region, &1.segment}) ==
             MapSet.new([{1, {1, 0, 0}, structure}, {2, {0, 0, 0}, 20}, {3, {-1, 0, 0}, 21}, {5, {-33, 0, 0}, canopy}, {5, {-2, 0, 0}, 20}])
    # 24 个粗层页键分属 5 级（1–5）：只数本进程（读页调用方）读段的查询——每级一条（无 L0 键时不查 L0）；逐页查询时是 24 条。
    assert count_queries(0) == 5
  end

  defp count_queries(n) do
    receive do
      :query -> count_queries(n + 1)
    after
      0 -> n
    end
  end

  # 统筹跟进：死亡掉落是已确认后果，装页失败时不能只重投一次。保持挂起、每 1 s 重试直到成功；期望：两次读失败后第三次成功，掉落只落一次
  # （余额减少 = 世界格数量 = 1/8 m³，手算同 persist_backlog_test）。
  @tag log: GateRead
  test "死亡掉落装页连续失败两次后第三次成功：掉落只落一次", c do
    stop_supervised!(World)
    sand = 5
    capacity = 2_097_152
    eighth = div(capacity, 8)
    data = Path.expand("fixtures/combustion/7b69b79f1786756e857fb8cc0c855e911ce1d015ca2a5efdb25fc76f2a52b45e.json", __DIR__)
      |> File.read!() |> Jason.decode!() |> put_in(["liquid", "step_seconds"], 3600)
    catalog = Path.join(c.root, "loose.json")
    File.write!(catalog, Jason.encode!(data))
    opts = Keyword.merge(c.opts, property_catalog_path: catalog, production_materials: [sand],
      liquid_bounds: {{0, 0, 0}, {8, 8, 8}}, death_drop_probability: 1.0)
    c = %{c | opts: opts}
    w = start_supervised!({World, opts})
    :ok = VoxelRegion.TestSupport.activate_simulation(w, opts[:liquid_bounds])
    {:ok, _} = World.apply_edits(w, for(x <- 0..7, z <- 0..7, do: {{x, 0, z}, 7}))
    {:ok, _} = World.material_supply(w, 1001, "death-drop", %{sand => 8 * capacity})
    send(w, :liquid_commit)
    assert :ok = World.compact(w)

    w = restart(c)
    refute resident?(w, {0, {0, 0, 0}})
    seq = World.seq(w)
    GateRead.fail(self(), 2)
    send(w, {:body_death, 1001, {3.5, 1.0, 3.5}})
    assert_receive {:read_failed, _}, 5_000
    assert_receive {:read_failed, _}, 5_000
    await(fn -> World.seq(w) == seq + 1 end, 200)
    refute_received {:read_failed, _}
    after_drop = VoxelRegion.TestSupport.observe(w, [1001], {{-9, -1, -9}, {17, 8, 17}})
    assert 8 * capacity - after_drop.material_balances[{1001, sand}] == eighth
    assert after_drop.liquid_units[{3, 1, 3}] == eighth
    # 不再重投：之后没有第二次掉落。
    Process.sleep(1_500)
    assert World.seq(w) == seq + 1
  end

  test "旧日志的整表实例格式不能在分页重放里静默接受" do
    assert_raise RuntimeError, ~r/whole-table instance/, fn ->
      Pages.txn_needs(%{seq: 3, entries: [], coarse: [], prefab_instances: %{}})
    end
    # M2a 可以只改附件归属、不改实例表：整表归属单独出现也要拒绝（评审 A4）。
    assert_raise RuntimeError, ~r/whole-table instance/, fn ->
      Pages.txn_needs(%{seq: 4, entries: [], coarse: [], attachment_owners: %{}})
    end
  end
end
