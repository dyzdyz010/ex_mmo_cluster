Code.require_file("../bench/paging_m0/equiv.ex", __DIR__)

defmodule VoxelRegion.PagingEquivCaptureTest do
  @moduledoc "只测试：有限页采集的真实 File/World 读取、退休和诊断钩子生命周期；不证明完整迁移或性能。"
  use ExUnit.Case, async: false
  alias VoxelRegion.{OverlayLog, Prefab, World}
  alias VoxelRegion.Bench.PagingEquiv
  alias VoxelRegion.TestSupport.Source

  defmodule HeldSource do
    @moduledoc "只测试：在调用方 source ensure 等待一次，World 保持正常接纳。"
    defdelegate open(opts), to: Source
    defdelegate content_version(state), to: Source
    defdelegate world_dir(state), to: Source
    defdelegate generated(state), to: Source
    defdelegate read(state, level, region), to: Source
    def ensure(state, level, region) do
      if parent = :persistent_term.get({__MODULE__, state.root}, nil) do
        :persistent_term.erase({__MODULE__, state.root})
        send(parent, {:ensure_held, self()})
        receive do: (:continue -> :ok)
      end
      Source.ensure(state, level, region)
    end
  end

  defmodule InvalidWorld do
    @moduledoc "只测试：诊断投影失败的独立 GenServer；没有真实 World 权威状态。"
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def init(_), do: {:ok, %{seq: 7, sentinel: :do_not_transport_state}}
    def handle_call({:page_request, _, :seq}, _, state), do: {:reply, 7, state}
  end

  setup context do
    root = Path.join(System.tmp_dir!(), "paging_capture_#{System.pid()}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "prefabs"))
    bytes = Prefab.encode(%{cells: [{{-1, 0, 0}, 11}, {{0, 0, 0}, 19}],
      macro_cells: [], children: [], attachments: []})
    File.write!(Path.join(root, "prefabs/sample.vxpd"), bytes)
    opts = [source: HeldSource, root: root, observer: self(), name: nil,
      prefab_catalog_path: Path.join(root, "prefabs"), property_catalog_path: VoxelRegion.TestSupport.catalog(),
      production_materials: [11, 19], log: OverlayLog.File]
    world = unless context[:full_audit] do
      world = start_supervised!({World, opts})
      assert {:ok, _} = World.apply_edits(world, [{{1, 2, 3}, 19}, {{1281, 130, -125}, 11}])
      assert :ok = World.compact(world)
      stop_supervised!(World)
      start_supervised!({World, opts})
    end
    on_exit(fn ->
      :persistent_term.erase({HeldSource, root})
      File.rm_rf!(root)
    end)
    %{world: world, opts: opts, root: root, path: Path.join(root, "capture.json"), prefab_id: :crypto.hash(:sha256, bytes)}
  end

  @tag :full_audit
  test "完整目录在首次发布前采A，真实File发布冷恢复采B，跨页身份只计一次", c do
    {world, opts, path} = first_publication_world(c)
    alias VoxelRegion.Bench.FirstPublication, as: Gate
    assert %{content_version: 123, seq: 2} = Gate.await_held(5_000)
    assert OverlayLog.File.prefix(path) == nil
    # 写回闸不阻塞 World，也不停止接纳；错误切点不能释放正在等待的 publish。
    assert World.seq(world) == 2
    assert_raise RuntimeError, ~r/wrong_publication_identity/, fn -> Gate.release(123, 3) end
    a_path = Path.join(c.root, "A.json")
    PagingEquiv.capture_full(a_path, world, "A")
    a = Jason.decode!(File.read!(a_path))
    assert map_size(a["digests"]) == 29
    assert a["coverage"]["first_publication_cut"] == 2
    assert [%{"granularity" => 2, "owner" => [1, 0]}] = a["coverage"]["expected_identities"]
    assert length(a["q5"]["properties"]) == 1
    assert "0,20,2,-2" in a["coverage"]["expected_regions"]
    assert %{"published_seq" => 2, "seq" => 2} = PagingEquiv.await_published(2, 5, world) |> Jason.decode!()
    stop_supervised!(World)
    stop_supervised!(Gate)
    cold = start_supervised!({World, Keyword.put(opts, :log, OverlayLog.File)})
    assert World.stats(cold).resident_pages == 0
    b_path = Path.join(c.root, "B.json")
    PagingEquiv.capture_full(b_path, cold, "B")
    b = Jason.decode!(File.read!(b_path))
    assert b["digests"] == a["digests"]
    assert b["reads"] == a["reads"]
    assert b["q5"] == a["q5"]
    assert b["coverage"]["expected_identities"] == a["coverage"]["expected_identities"]
    assert b["coverage"]["expected_regions"] == a["coverage"]["expected_regions"]
    assert b["coverage"]["published_start"] == b["coverage"]["published_end"]
  end

  @tag :full_audit
  test "首切点期间真实编辑推进seq时采集失败且finally解除发布闸", c do
    {world, _opts, path} = first_publication_world(c)
    alias VoxelRegion.Bench.FirstPublication, as: Gate
    assert %{seq: 2} = Gate.await_held(5_000)
    assert {:ok, 3} = World.apply_edit(world, {3, 2, 3}, 11)
    assert_raise RuntimeError, ~r/audit_hook_projection_failed/, fn ->
      PagingEquiv.capture_full(c.path, world, "A")
    end
    refute File.exists?(c.path)
    assert %{"published_seq" => prefix} = PagingEquiv.await_published(2, 5, world) |> Jason.decode!()
    assert prefix >= 2
    assert OverlayLog.File.prefix(path) >= 2
  end

  @tag :full_audit
  test "首次发布闸到期显式失败，不把没有release的写回伪装成功" do
    alias VoxelRegion.Bench.FirstPublication, as: Gate
    gate = start_supervised!(Supervisor.child_spec({Gate, timeout_ms: 20}, restart: :temporary))
    monitor = Process.monitor(gate)
    publisher = Task.async(fn ->
      assert_raise RuntimeError, ~r/publication_timeout/, fn -> Gate.hold(123, 2) end
    end)
    assert_receive {:DOWN, ^monitor, :process, ^gate, :publication_timeout}, 5_000
    Task.await(publisher, 5_000)
  end

  @tag :full_audit
  @tag :static_cut
  test "真实初始化tick从C0推进X后只选一次正常compact切点并完整冷恢复", c do
    alias VoxelRegion.TestSupport.WorldClock
    clock = start_supervised!({WorldClock, 0})
    catalog = Path.join(c.root, "static-liquid.json")
    data = VoxelRegion.TestSupport.catalog() |> File.read!() |> Jason.decode!()
      |> Map.put("liquid", %{"step_seconds" => 0.2, "gravity_units_per_step" => 524_288,
        "side_units_per_step" => 131_072, "side_threshold_units" => 0})
    File.write!(catalog, Jason.encode!(data))
    opts = Keyword.merge(c.opts, property_catalog_path: catalog, clock: {WorldClock, clock},
      liquid_bounds: {{0, 0, 0}, {3, 3, 3}})
    source = start_supervised!({World, opts})
    assert :ok = World.compact(source)
    # 普通编辑会唤醒液体候选；没有水的候选在正常到期步里清空，仍是真实持久提交。
    assert {:ok, 1} = World.apply_edit(source, {1, 1, 1}, 19)
    assert World.liquid_activity(source).active_cells > 0
    original_log = Path.join(c.root, "overlay.log")
    assert OverlayLog.File.prefix(original_log) == 0
    stop_supervised!(World)
    :ok = WorldClock.cancel_all(clock)
    migrated_root = Path.join(c.root, "static-cut")
    File.mkdir!(migrated_root)
    File.cp!(original_log, Path.join(migrated_root, "overlay.log"))
    start_supervised!({VoxelRegion.Bench.FirstPublication, backend: OverlayLog.File, timeout_ms: 30_000})
    opts = Keyword.merge(opts, root: migrated_root, log: VoxelRegion.Bench.FirstPublicationLog)
    world = start_supervised!({World, opts})
    assert %{seq: 1} = VoxelRegion.Bench.FirstPublication.await_held(5_000)
    assert World.liquid_activity(world).active_cells > 0
    a_path = Path.join(c.root, "static-A.json")
    # 采集者自己持有待发布请求，不能再创建会提前独立超时的linked caller。
    compact_hook = make_ref()
    hook = fn parent, event, _name ->
      case event do
        {:in, {:"$gen_call", {caller, _}, :compact}} -> send(parent, {:compact_caller, caller})
        {:in, {:"$gen_call", {caller, _}, {:page_request, _, :compact}}} -> send(parent, {:compact_caller, caller})
        _ -> :ok
      end
      parent
    end
    :ok = :sys.install(world, {compact_hook, hook, self()})
    capture = Task.async(fn -> PagingEquiv.capture_static(a_path, world, "A") end)
    try do
      assert WorldClock.advance(clock, 200) == 200
      Task.await(capture, 15_000)
      assert_receive {:compact_caller, caller}
      assert caller == capture.pid
    after
      :sys.remove(world, compact_hook)
    end
    a = Jason.decode!(File.read!(a_path))
    assert a["seq"] == 2
    assert a["coverage"]["published_start"] == 1
    assert %{"complete" => true, "initial_cut" => 1, "selected_cut" => 2,
      "readiness" => %{"complete" => true, "liquid_active_cells" => 0, "liquid_due_ms" => nil}} =
      a["coverage"]["initialization"]
    assert OverlayLog.File.prefix(Path.join(migrated_root, "overlay.log")) == 2
    stop_supervised!(World)
    stop_supervised!(VoxelRegion.Bench.FirstPublication)
    cold = start_supervised!({World, Keyword.put(opts, :log, OverlayLog.File)})
    b_path = Path.join(c.root, "static-B.json")
    PagingEquiv.capture_static(b_path, cold, "B")
    b = Jason.decode!(File.read!(b_path))
    assert b["seq"] == 2
    assert b["digests"] == a["digests"]
    assert b["reads"] == a["reads"]
    assert b["q5"] == a["q5"]
  end

  # 由正常公开动作生成日志后停止，再只复制真实日志帧到无页表的新根；不回传或改写 World 状态。
  defp first_publication_world(c) do
    source = start_supervised!({World, c.opts})
    assert :ok = World.compact(source)
    assert {:ok, 1} = World.place_prefab(source, c.prefab_id, {512, 8, 8}, 0)
    assert {:ok, 2} = World.apply_edits(source, [{{1, 2, 3}, 19}, {{1281, 130, -125}, 11}])
    original_log = Path.join(c.root, "overlay.log")
    assert OverlayLog.File.prefix(original_log) == 0
    stop_supervised!(World)
    migrated_root = Path.join(c.root, "first-cut")
    File.mkdir!(migrated_root)
    path = Path.join(migrated_root, "overlay.log")
    File.cp!(original_log, path)
    start_supervised!({VoxelRegion.Bench.FirstPublication, backend: OverlayLog.File, timeout_ms: 30_000})
    opts = Keyword.merge(c.opts, root: migrated_root, log: VoxelRegion.Bench.FirstPublicationLog)
    {start_supervised!({World, opts}), opts, path}
  end

  test "旧无目录全世界入口明确拒绝，不再把quiet当完整迁移资格", c do
    assert_raise ArgumentError, ~r/full_world_q5_capture_unavailable/, fn ->
      PagingEquiv.capture(c.path, 30)
    end
    refute File.exists?(c.path)
  end

  test "相离两页逐页捕获，释放后可退休，摘要不漏页也不重复驻留邻页", c do
    regions = [{0, {0, 0, 0}}, {0, {20, 2, -2}}]
    summary = PagingEquiv.capture_regions(c.path, c.world, regions) |> Jason.decode!()
    result = Jason.decode!(File.read!(c.path))
    assert summary["schema"] == "paging-region-audit-v1"
    assert result["coverage"]["expected_regions"] == ["0,0,0,0", "0,20,2,-2"]
    assert Map.keys(result["pages"]) |> Enum.sort() == result["coverage"]["expected_regions"]
    assert result["coverage"]["start_seq"] == result["coverage"]["end_seq"]
    assert map_size(result["global_digests"]) == 16
    for page <- Map.values(result["pages"]) do
      assert map_size(page["digests"]) == 13
      assert page["digests"]["region_bases"] =~ ~r/^1:/
      assert page["digests"]["epochs"] =~ ~r/^1:/
      assert page["seq"] == result["coverage"]["start_seq"]
      assert page["payload_seq"] <= page["seq"]
    end
    assert World.stats(c.world).resident_pages == 0
    assert World.residency_status(c.world).retired_pages > 0
    refute Map.has_key?(result, "coverage_complete_world")
  end

  test "自己的钩子完成和清理后，预先安装的另一钩子继续工作", c do
    parent = self()
    other = make_ref()
    hook = fn state, event, _ ->
      if match?({:out, _, _, _}, event), do: send(parent, :other_hook)
      state
    end
    :ok = :sys.install(c.world, {other, hook, nil})
    try do
      PagingEquiv.capture_regions(c.path, c.world, [{0, {0, 0, 0}}])
      drain_other()
      World.seq(c.world)
      assert_receive :other_hook
    after
      :sys.remove(c.world, other)
    end
  end

  test "hook投影异常显式失败且不输出状态或成功文件", c do
    world = start_supervised!({InvalidWorld, []})
    assert_raise RuntimeError, ~r/audit_hook_projection_failed: Elixir.KeyError/, fn ->
      PagingEquiv.capture_regions(c.path, world, [{0, {0, 0, 0}}])
    end
    assert GenServer.call(world, {:page_request, make_ref(), :seq}) == 7
    refute File.exists?(c.path)
  end

  test "正常prepare期间另笔公开编辑使seq变化，本轮明确失败", c do
    :persistent_term.put({HeldSource, c.root}, self())
    capture = Task.async(fn ->
      try do
        PagingEquiv.capture_regions(c.path, c.world, [{0, {30, 3, -3}}])
      rescue
        error -> Exception.message(error)
      end
    end)
    assert_receive {:ensure_held, source}, 5_000
    assert {:ok, _} = World.apply_edits(c.world, [{{1282, 130, -125}, 19}])
    send(source, :continue)
    assert Task.await(capture, 10_000) =~ "audit_sequence_changed"
    refute File.exists?(c.path)
  end

  test "重复声明同一页在读取前失败，不用去重掩盖重复归属", c do
    assert_raise ArgumentError, ~r/duplicate_audit_region/, fn ->
      PagingEquiv.capture_regions(c.path, c.world, [{0, {0, 0, 0}}, {0, {0, 0, 0}}])
    end
    refute File.exists?(c.path)
  end

  @tag :representative_semantics
  test "跨页同一部件仅在home页报告一次，微格摘要仍按各页归属", c do
    assert {:ok, _} = World.place_prefab(c.world, c.prefab_id, {512, 8, 8}, 0)
    assert :ok = World.compact(c.world)
    PagingEquiv.capture_regions(c.path, c.world, [{0, {0, 0, 0}}, {0, {1, 0, 0}}])
    pages = Jason.decode!(File.read!(c.path))["pages"]
    assert pages["0,0,0,0"]["digests"]["refined"] =~ ~r/^1:/
    assert pages["0,1,0,0"]["digests"]["refined"] =~ ~r/^1:/
    assert pages["0,0,0,0"]["q5"]["properties"] == []
    assert [%{"identity" => %{"granularity" => 2, "owner" => owner}, "property" => property,
      "representative_witness" => witness}] =
      pages["0,1,0,0"]["q5"]["properties"]
    assert length(property["observation_cells"]) == 2
    # 两格位置和材料来自setup手算样本，见证必须来自真实占用而非复制观察行。
    assert %{"schema" => "canonical_g2_point_v1", "content_version" => 123,
      "target" => %{"granularity" => 2, "owner" => ^owner}} = witness
    expected_material = Map.fetch!(%{[511, 8, 8] => 11, [512, 8, 8] => 19}, property["micro"])
    assert witness["target"]["micro"] == property["micro"]
    assert witness["target"]["material"] == expected_material
    assert property["material"] == expected_material
    catalog = VoxelRegion.TestSupport.catalog() |> VoxelRegion.Damage.load()
    assert witness["catalog_defense"] == catalog.materials[expected_material]["defense"]
    assert property["defense"] == witness["catalog_defense"]
    assert property["digest"] == witness["property_digest"]
    assert property["seq"] == witness["seq"]
  end

  @tag :representative_semantics
  test "真实File冷页base摘要采用规范载荷而非内部struct字段", c do
    alias MmoContracts.Voxel.Payload
    key = {0, {0, 0, 0}}
    # 该独立页只有setup的单个宏格编辑，compact后的base与公共完整地形相同。
    payload = VoxelRegion.TestSupport.payload(c.world, 0, {0, 0, 0})
    bytes = Payload.encode(payload, %{}, 0, 123)
    <<hash::128>> = :crypto.hash(:md5, :erlang.term_to_binary({key, bytes}, [:deterministic]))
    PagingEquiv.capture_regions(c.path, c.world, [key])
    page = Jason.decode!(File.read!(c.path))["pages"]["0,0,0,0"]
    assert page["digests"]["region_bases"] == "1:#{Integer.to_string(hash, 16)}"
    changed = Payload.encode(payload, %{{1, 2, 3} => {11, MmoContracts.Voxel.Skins.uniform(11)}}, 0, 123)
    refute changed == bytes
  end

  test "实际hook输出固定小摘要，错From不捕获且State不会成为消息或debug状态" do
    id = make_ref()
    from = {self(), make_ref()}
    debug = %{id: id, caller: self(), mode: :fence, from: nil}
    armed = PagingEquiv.audit_hook(debug, {:in, {:"$gen_call", from, {:page_request, make_ref(), :seq}}}, :fixture)
    state = Map.new([:material_balances, :caster_energy, :material_supplies, :craft_ledger,
      :food_ledger, :food_receipts, :beacons, :beacon_attunements, :phase_inventory], &{&1, %{}})
      |> Map.merge(%{seq: 7, cv: 123, page_store: %{published: 7}, thermal: nil,
        thermal_run: nil, protection: %{regions: %{}}, attachment_serial: 0,
        material_units_per_micro: 1, interaction_history: [], interaction_floor: 0,
        sentinel: List.duplicate(:never_send_state, 10_000)})
    assert PagingEquiv.audit_hook(armed, {:out, 7, {self(), make_ref()}, state}, :fixture) == armed
    refute_receive {^id, _}, 0
    assert :done = PagingEquiv.audit_hook(armed, {:out, 7, from, state}, :fixture)
    assert_receive {^id, {:ok, summary}}
    assert Map.keys(summary) |> Enum.sort() == [:content_version, :global_digests, :published, :seq]
    assert :erlang.external_size(summary) < 1_000
    refute Map.has_key?(armed, :state)
  end

  defp drain_other do
    receive do
      :other_hook -> drain_other()
    after
      0 -> :ok
    end
  end
end
