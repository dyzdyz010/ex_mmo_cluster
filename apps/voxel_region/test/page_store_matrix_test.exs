defmodule VoxelRegion.PageStoreMatrixTest do
  @moduledoc """
  只测试：m2a §8 反例矩阵的写回尝试、读者、home 与启动项。真值只经正常入口产生（编辑、供料、放置）；故障只注入在写回 /
  持久边界（测试后端在写完第 k 批或发布前停住写回进程）。页存储用例用本 VM 的测试库，只清固定的内容版本 123，
  另写一个内容版本的行并断言它不受这里的删除影响（不做全表清空）。
  """
  use ExUnit.Case, async: false
  alias VoxelRegion.{OverlayLog, TestSupport, World}
  alias VoxelRegion.World.{Pages, PageWriter}
  alias DataService.Voxel.{OverlayLogStore, PageStore}
  alias MmoContracts.Voxel.{Codec, Payload}

  @cv 123
  @other 0x5EED_0000_0000_0042
  # 80 格分在 80 个 16³ 子块（一个切点两批以上），避开 TestSupport.Source 会停顿的 {10,0,0}/{11,0,0} 区域。
  @spread for a <- 0..3, b <- 0..19, do: {{16 * a, 2, 16 * b}, 11}
  # 原始真值字段（判定器 a）；派生索引、缓存与订阅不比较。地形的基底 + 稀疏格是同一真值的两种表示（发布与回放会换基底），
  # 按区域物化后比较（`truth/1` 的 reads，即判定器 b 的正式读取）。
  @truth [:seq, :refined, :attachments, :attachment_owners, :attachment_serial, :instances,
    :macro_owners, :liquid_units, :liquid_active, :epochs, :placed_by, :damage, :material_balances, :material_supplies,
    :caster_energy, :craft_ledger, :food_ledger, :food_receipts, :phase_inventory, :beacons, :beacon_attunements, :thermal,
    :interaction_history, :interaction_floor]

  defmodule KillAfter do
    @moduledoc "只测试：Db 后端；登记 `{测试进程, k}` 后，写回进程写完第 k 批即报 `{:written, 写回进程, 切点, k}` 并停住，等测试杀掉它。"
    alias VoxelRegion.OverlayLog.Db
    defdelegate open(dir, cv), to: Db
    defdelegate replay(cv), to: Db
    defdelegate append(cv, txn), to: Db
    defdelegate checkpoint(cv, txn), to: Db
    defdelegate prefix(cv), to: Db
    defdelegate clear_unpublished(cv, prefix), to: Db
    defdelegate publish(cv, cut, rows, globals), to: Db
    defdelegate load(cv), to: Db
    defdelegate load_head(cv, code), to: Db
    defdelegate read_pages(cv, keys, fragments), to: Db
    defdelegate locate(cv, ids), to: Db
    defdelegate page_keys(cv), to: Db
    defdelegate collect(cv, prefix, limit), to: Db

    def write_pages(cv, cut, rows) do
      :ok = Db.write_pages(cv, cut, rows)

      case :persistent_term.get({__MODULE__, cv}, nil) do
        {owner, counter, k} ->
          if :atomics.add_get(counter, 1, 1) == k do
            send(owner, {:written, self(), cut, k})
            receive do :never -> :ok end
          end

        nil ->
          :ok
      end

      :ok
    end

    def arm(cv, k) do
      :persistent_term.put({__MODULE__, cv}, {self(), :atomics.new(1, signed: false), k})
      ExUnit.Callbacks.on_exit(fn -> :persistent_term.erase({__MODULE__, cv}) end)
    end
  end

  defmodule HoldFile do
    @moduledoc "只测试：文件后端；登记后，下一次发布前停住写回进程并报 `{:holding_publish, 写回进程, 切点}`。"
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
    defdelegate read_pages(path, keys, fragments), to: Log
    defdelegate locate(path, ids), to: Log
    defdelegate page_keys(path), to: Log
    defdelegate collect(path, prefix, limit), to: Log

    def publish(path, cut, rows, globals) do
      case :persistent_term.get({__MODULE__, path}, nil) do
        owner when is_pid(owner) ->
          :persistent_term.erase({__MODULE__, path})
          send(owner, {:holding_publish, self(), cut})
          receive do :continue -> :ok end

        _ ->
          :ok
      end

      Log.publish(path, cut, rows, globals)
    end
  end

  setup context do
    root = Path.join(System.tmp_dir!(), "page_matrix_#{System.pid()}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "prefabs"))
    on_exit(fn -> File.rm_rf!(root) end)

    if context[:database] do
      MmoTest.Database.start!()
      :ok = OverlayLogStore.reset_world(@cv)
      :ok = OverlayLogStore.reset_world(@other)
      # 另一个世界的已发布页、全局行与日志后缀：本 cv 的清残留、迁移与渐进删除都不得碰它。
      row = Pages.row({:chunk, :overlay, {0, 0, 0}}, %{{1, 2, 3} => {11, MmoContracts.Voxel.Skins.uniform(11)}})
      :ok = PageStore.publish(@other, 7, [row], Pages.globals(%{seq: 7, protection: %{regions: %{}}, thermal: nil}))
      :ok = PageStore.write(@other, 9, [row])
      :ok = OverlayLogStore.append(@other, OverlayLog.rows(%{seq: 8, entries: [], coarse: []}))
    end

    %{root: root, other: other_world()}
  end

  defp opts(c, log, extra \\ []),
    do: [source: TestSupport.Source, root: c.root, observer: self(), name: nil, log: log, production_materials: [11, 19]] ++ extra

  # ---- 写回尝试（§8 第 4 项）

  @tag :database
  test "写回在第 1 批后被杀 → World 随之重启 → 提交无关页 → 再发布 → 再重启，逐字段相等", c do
    w1 = start_supervised!(Supervisor.child_spec({World, opts(c, KillAfter)}, restart: :temporary))
    assert :ok = World.compact(w1)
    assert {:ok, 1} = World.apply_edits(w1, @spread)
    expected = truth(w1)
    KillAfter.arm(@cv, 1)
    compact = Task.async(fn -> catch_exit(World.compact(w1)) end)
    assert_receive {:written, writer, 1, 1}, 5_000
    monitor = Process.monitor(w1)
    Process.exit(writer, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^w1, :killed}, 5_000
    assert {:killed, _} = Task.await(compact, 5_000)
    # 半个切点留在库里、前缀不动。
    assert PageStore.prefix(@cv) == 0
    assert segments(@cv, 1) > 0

    w2 = start_supervised!({World, opts(c, OverlayLog.Db)})
    touch(w2, @spread)
    same!(truth(w2), expected)
    # 提交与被杀切点无关的页，再发布：新尝试先清掉上次的残留。
    assert {:ok, 2} = World.apply_edit(w2, {40, 2, 400}, 19)
    assert :ok = World.compact(w2)
    assert PageStore.prefix(@cv) == 2
    assert segments(@cv, 1) == 0
    published = truth(w2)
    stop_supervised!(World)

    w3 = start_supervised!({World, opts(c, OverlayLog.Db)})
    touch(w3, [{{40, 2, 400}, 19} | @spread])
    same!(truth(w3), published)
    assert other_world() == c.other
  end

  @tag :database
  test "首次迁移半写后被杀 → 重启从头迁移，结果与旧日志全量回放相同", c do
    w0 = start_supervised!({World, opts(c, OverlayLog.Db)})
    assert {:ok, 1} = World.apply_edits(w0, @spread)
    assert {:ok, 2} = World.material_supply(w0, 1001, "legacy", %{19 => 3})
    expected = truth(w0)
    stop_supervised!(World)
    # 只测试夹具：删掉本 cv 的页表行，得到 M2a 之前只有日志的库（日志仍是正常入口写出的）。
    drop_pages(@cv)
    assert PageStore.prefix(@cv) == nil

    KillAfter.arm(@cv, 1)
    w1 = start_supervised!(Supervisor.child_spec({World, opts(c, KillAfter)}, restart: :temporary))
    assert_receive {:written, writer, 2, 1}, 30_000
    monitor = Process.monitor(w1)
    Process.exit(writer, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^w1, :killed}, 5_000
    assert PageStore.prefix(@cv) == nil
    assert segments(@cv, 2) > 0

    w2 = start_supervised!({World, opts(c, OverlayLog.Db)})
    await(fn -> World.stats(w2).published_seq == 2 end)
    same!(truth(w2), expected)
    stop_supervised!(World)
    w3 = start_supervised!({World, opts(c, OverlayLog.Db)})
    touch(w3, @spread)
    same!(truth(w3), expected)
    assert other_world() == c.other
  end

  @tag :database
  test "尝试开始时持久前缀已覆盖切点按已发布收口；影响 0 行的旧发布报错而非成功", c do
    w = start_supervised!({World, opts(c, OverlayLog.Db)})
    assert {:ok, 1} = World.apply_edit(w, {1, 2, 1}, 11)
    assert :ok = World.compact(w)
    assert {:ok, 2} = World.apply_edit(w, {2, 2, 1}, 11)
    assert :ok = World.compact(w)
    stop_supervised!(World)
    before = PageStore.load(@cv)
    assert before.prefix == 2
    old_globals = globals(@cv, 1)

    # 只测试：直接驱动写回进程的尝试状态机（World 已停，本进程扮演它的回信对象）。
    {:ok, writer} = PageWriter.start_link(self(), {OverlayLog.Db, @cv})
    lost = make_ref()
    GenServer.cast(writer, {:begin, lost, 2})
    assert_receive {:page_published, ^lost, 2}, 5_000
    assert PageStore.load(@cv) == before

    stale_rows = segments(@cv, 1)
    stale = make_ref()
    row = {{:chunk, :overlay, {0, 0, 0}}, %{}}
    GenServer.cast(writer, {:publish, stale, 1, [row], Pages.globals(%{seq: 1, protection: %{regions: %{}}, thermal: nil})})
    assert_receive {:page_failed, ^stale, {:prefix, 2}}, 5_000
    refute_received {:page_published, ^stale, _}
    assert PageStore.load(@cv) == before
    assert segments(@cv, 1) == stale_rows
    assert globals(@cv, 1) == old_globals

    # 前缀恰等于切点：上一次发布已提交、确认丢失，重发按已发布收口，不再写。
    again = make_ref()
    GenServer.cast(writer, {:publish, again, 2, [row], Pages.globals(%{seq: 2, protection: %{regions: %{}}, thermal: nil})})
    assert_receive {:page_published, ^again, 2}, 5_000
    assert PageStore.load(@cv) == before
    GenServer.stop(writer)
    assert other_world() == c.other
  end

  # ---- 读者（§8 第 5 项）

  test "读者游标为 P−1 / P / P+1 时 subscribe 与 serve_item 的实际结果", c do
    w = start_supervised!({World, opts(c, OverlayLog.File)})
    r = {0, 0, 0}
    q = {1, 0, 0}
    t = {2, 0, 0}
    # 三个区域都先有提交（载荷头按当时的 seq 盖章）。
    assert {:ok, 1} = World.apply_edits(w, [{{1, 1, 1}, 11}, {{65, 2, 1}, 11}, {{129, 2, 1}, 11}])
    assert {:ok, 2} = World.apply_edit(w, {2, 1, 1}, 11)
    h2 = header(w, r, 0, 0)
    assert h2.seq == 2
    assert {:ok, 3} = World.apply_edit(w, {3, 1, 1}, 11)
    assert :ok = World.compact(w)
    assert World.stats(w).published_seq == 3
    hq3 = header(w, q, 0, 0)
    assert hq3.seq == 3
    assert {:ok, 4} = World.apply_edits(w, [{{4, 1, 1}, 11}, {{66, 1, 1}, 11}])
    ht4 = header(w, t, 0, 0)
    assert ht4.seq == 4
    assert {:ok, 5} = World.apply_edits(w, [{{130, 1, 1}, 11}])

    # P−1：seq 3 对 r 的改动已随发布退休，不能只补 seq 4；整区载荷含全部四格。
    assert [{:payload, 0, ^r, bytes}] = serve(w, r, h2.seq, h2.hash)
    {:ok, p} = Payload.decode(bytes)
    assert Enum.all?(1..4, &(Payload.material(p, Payload.local(r, {&1, 1, 1})) == 11))
    # P：前缀之后的保留历史完整，给增量。
    assert [{:entries, 0, ^q, [%{seq: 4}]}] = serve(w, q, hq3.seq, hq3.hash)
    # P+1：同上，只补其后。
    assert [{:entries, 0, ^t, [%{seq: 5}]}] = serve(w, t, ht4.seq, ht4.hash)

    box = {{-1, -1, -1}, {300, 10, 10}}
    assert {:error, :cursor_expired} = World.subscribe(w, self(), 2, box, 0)
    assert :ok = World.subscribe(w, self(), 3, box, 0)
    assert received_seqs() == [4, 5]
    assert :ok = World.subscribe(w, self(), 4, box, 0)
    assert received_seqs() == [5]
  end

  # ---- 装页：负微格 anchor 的 home（§8 第 3 项）

  test "负微格 anchor 的实例按 floor_div 归入 home 页并随页恢复", c do
    # 只有一个微格的定义（无宏格，可放在任意微格 anchor），经正式目录发布。
    bytes = VoxelRegion.Prefab.encode(%{cells: [{{0, 0, 0}, 11}], children: [], attachments: [], macro_cells: []})
    File.write!(Path.join([c.root, "prefabs", "micro.vxpd"]), bytes)
    id = :crypto.hash(:sha256, bytes)
    extra = [prefab_catalog_path: Path.join(c.root, "prefabs")]
    w = start_supervised!({World, opts(c, OverlayLog.File, extra)})
    # 手算：anchor 微格 x = -3 → 宏格 floor(-3/8) = -1 → L0 区域 -1（按截断除法会落到宏格 0 / 区域 0）。
    assert {:ok, 1} = World.place_prefab(w, id, {-3, 8, 8}, 0)
    assert :ok = World.compact(w)
    instance = Map.fetch!(:sys.get_state(w).instances, {1, 0})
    loaded = OverlayLog.File.load(Path.join(c.root, "overlay.log"))
    homes = for row <- loaded.segments, {{:page, :identity, {0, region}}, value} <- [Pages.unit_value(row)],
      Map.has_key?(value.instances, {1, 0}), do: region
    assert homes == [{-1, 0, 0}]
    stop_supervised!(World)
    w = start_supervised!({World, opts(c, OverlayLog.File, extra)})
    touch(w, [{{-1, 1, 1}, 0}])
    assert Map.fetch!(:sys.get_state(w).instances, {1, 0}) == instance
  end

  # ---- 启动与切点（§8 第 1、6 项）

  test "全新世界首次发布 P = 0；只有供料全局账的提交也开切点并在重启后保留；已覆盖时 compact 立即返回", c do
    path = Path.join(c.root, "overlay.log")
    w = start_supervised!({World, opts(c, HoldFile)})
    await(fn -> World.stats(w).published_seq == 0 end)
    assert OverlayLog.File.prefix(path) == 0
    assert %{prefix: 0, segments: []} = OverlayLog.File.load(path)

    assert {:ok, 1} = World.material_supply(w, 1001, "ledger-only", %{19 => 5})
    assert MapSet.size(:sys.get_state(w).page_dirty) == 0
    assert :ok = World.compact(w)
    assert OverlayLog.File.prefix(path) == 1
    checkpoints = World.stats(w).checkpoints

    # 已覆盖：不再开切点（登记的发布停点不会被触发），立即回复。
    :persistent_term.put({HoldFile, path}, self())
    on_exit(fn -> :persistent_term.erase({HoldFile, path}) end)
    assert :ok = World.compact(w)
    refute_receive {:holding_publish, _, _}, 100
    assert World.stats(w).checkpoints == checkpoints
    :persistent_term.erase({HoldFile, path})
    stop_supervised!(World)

    w = start_supervised!({World, opts(c, OverlayLog.File)})
    assert World.seq(w) == 1
    assert [%{material: 11, balance: 0}, %{material: 19, balance: 5}] =
      Enum.sort_by(World.material_balances(w, 1001), & &1.material) |> Enum.map(&Map.take(&1, [:material, :balance]))
    assert {:ok, 1} = World.material_supply(w, 1001, "ledger-only", %{19 => 5})
  end

  # ---- 新 VM 解码（§8 第 8 项）

  test "页段与全局行在全新 VM 里可解码", c do
    {id, extra} = prefab(c)
    w = start_supervised!({World, opts(c, OverlayLog.File, extra)})
    assert {:ok, _} = World.apply_edit(w, {63, 1, 2}, 16)
    heat = Path.join(c.root, "heat.json")
    File.write!(heat, Jason.encode!(%{classification: "Test-only", source_macro: [63, 1, 2],
      ambient_kelvin: 293.15, environment_w_per_m2_k: 0.01, tolerance_kelvin: 1.0,
      emissivity: 0.0, view_range_cells: 8, power_w: 1.0, energy_j: 100.0}))
    assert :ok = World.thermal_experiment(w, heat)
    # 直接投递一次热提交（同 phase_world_test 的做法），让被加热格出现带温度的属性行。
    send(w, :thermal_commit)
    water = Path.join(c.root, "water.json")
    File.write!(water, Jason.encode!(%{classification: "Test-only", deposits: [%{macro: [40, 40, 40], material: 21}]}))
    assert {:ok, _} = World.liquid_experiment(w, water)
    assert {:ok, _} = World.place_prefab(w, id, {-8, 8, 8}, 0)
    assert {:ok, _} = World.material_supply(w, 1001, "fresh-vm", %{19 => 2})
    assert :ok = World.compact(w)
    loaded = OverlayLog.File.load(Path.join(c.root, "overlay.log"))
    segments = Enum.map(loaded.segments, &elem(Pages.unit_value(&1), 0)) |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    # 样本覆盖实例、热源、液体、属性行、世代与地形各段。
    assert [] == [:identity, :sources, :liquid_units, :liquid_active, :damage, :epochs, :overlay, :refined, :attachments, :macro_owners] -- segments

    path = Path.join(c.root, "pages.etf")
    File.write!(path, :erlang.term_to_binary(%{segments: loaded.segments, globals: loaded.globals}))
    paths = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)])
    # 与冷重启相同：World 已加载，其余模块按需惰性加载；先全部按 :safe 解码，再与不带 :safe 的期望比较。
    code = ~s|{:module, _} = Code.ensure_loaded(VoxelRegion.World); | <>
      ~s|d = :erlang.binary_to_term(File.read!(#{inspect(path)})); | <>
      ~s|safe = {Enum.map(d.segments, &VoxelRegion.World.Pages.unit_value/1), VoxelRegion.OverlayLog.term(d.globals)}; | <>
      ~s|unsafe = {Enum.map(d.segments, &{elem(VoxelRegion.World.Pages.unit_value(&1), 0), :erlang.binary_to_term(&1.payload).value}), | <>
      ~s|:erlang.binary_to_term(d.globals)}; IO.write(inspect(safe == unsafe))|
    assert {"true", 0} = System.cmd("elixir", paths ++ ["-e", code], stderr_to_stdout: true)
  end

  # ---- 辅助

  # 判定器 a（原始真值逐键精确）+ b（正式读取：触及区域的载荷去掉头部 seq 后的内容）。
  # M2b：有前缀的重启只驻留启动装入的页（日志后缀与活动页）。判定前经正常读入口触及内容所在的格，装入它们的读取闭包。
  defp touch(w, edits), do: World.material_snapshot(w, [], Enum.map(edits, &elem(&1, 0)))

  defp truth(w) do
    state = :sys.get_state(w)
    regions = state.overlay |> Map.keys() |> Enum.map(fn {_, cell} -> VoxelRegion.World.Canonical.region_of(cell) end)
    regions = Enum.uniq(regions ++ for({{0, region}, _} <- state.region_bases, do: region))
    reads = Map.new(regions, fn region -> {region, unstamped(fetch(w, 0, region))} end)
    state |> Map.take(@truth) |> Map.put(:reads, reads)
  end

  # 逐键比较，失败时报出不同的字段。
  defp same!(actual, expected) do
    for key <- Enum.uniq(Map.keys(actual) ++ Map.keys(expected)),
        do: assert(Map.get(actual, key) == Map.get(expected, key), "field #{key} differs")
  end

  defp unstamped(bytes) do
    {:ok, p} = Payload.decode(bytes)
    %{p | seq: 0}
  end

  defp fetch(w, level, region) do
    [{:payload, ^level, ^region, bytes}] = serve(w, region, 0, 0, level)
    bytes
  end

  defp serve(w, region, have_seq, have_hash, level \\ 0) do
    req = Codec.encode_request(@cv, [%{level: level, region: region, have_seq: have_seq, have_hash: have_hash}]) |> IO.iodata_to_binary()
    {:ok, reply} = World.serve(w, req)
    {:ok, @cv, items} = Codec.decode_reply(IO.iodata_to_binary(reply))
    items
  end

  defp header(w, region, have_seq, have_hash) do
    [{:payload, 0, ^region, bytes}] = serve(w, region, have_seq, have_hash)
    {:ok, h} = Codec.decode_payload_header(bytes)
    h
  end

  defp received_seqs(acc \\ []) do
    receive do
      {:voxel_log_transaction_payload, bin} ->
        {:ok, txn} = Codec.decode_transaction(bin)
        received_seqs([txn.seq | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  defp prefab(c) do
    # 有限作者定义（同 coarse_rebuild_test）：一个宏格、一微格和宏格顶面的木附件，经正式目录与放置入口。
    bytes = <<"VXPD", 3::32-little, 1::32-little,
      8::signed-little-32, 0::signed-little-32, 0::signed-little-32, 11::16-little,
      0::32-little, 1::32-little, 1::32-little, 0, 1,
      0::signed-little-32, 8::signed-little-32, 0::signed-little-32, 8, 19::16-little,
      1::32-little, 0::signed-little-32, 0::signed-little-32, 0::signed-little-32, 11::16-little>>
    File.write!(Path.join([c.root, "prefabs", "sample.vxpd"]), bytes)
    catalog = Path.join(c.root, "catalog.json")
    data = TestSupport.catalog() |> File.read!() |> Jason.decode!()
      |> Map.put("liquid", %{"step_seconds" => 3600, "gravity_units_per_step" => 524_288,
        "side_units_per_step" => 131_072, "side_threshold_units" => 0})
    File.write!(catalog, Jason.encode!(data))
    {:crypto.hash(:sha256, bytes), [property_catalog_path: catalog, prefab_catalog_path: Path.join(c.root, "prefabs"),
      liquid_bounds: {{39, 39, 39}, {42, 42, 42}}]}
  end

  defp segments(cv, cut_seq),
    do: count("SELECT count(*) FROM voxel_page_segment WHERE content_version = $1 AND cut_seq = $2", [cv, cut_seq])

  defp globals(cv, cut_seq),
    do: count("SELECT count(*) FROM voxel_world_globals WHERE content_version = $1 AND cut_seq = $2", [cv, cut_seq])

  defp count(sql, params), do: hd(hd(Ecto.Adapters.SQL.query!(DataService.Repo, sql, params).rows))

  defp drop_pages(cv) do
    for table <- ~w(voxel_page_segment voxel_world_globals voxel_safe_prefix),
        do: Ecto.Adapters.SQL.query!(DataService.Repo, "DELETE FROM #{table} WHERE content_version = $1", [cv])
  end

  defp other_world do
    if Process.whereis(DataService.Repo) do
      %{pages: PageStore.load(@other), log: OverlayLogStore.read_all(@other),
        unpublished: count("SELECT count(*) FROM voxel_page_segment WHERE content_version = $1 AND cut_seq > 7", [signed(@other)])}
    end
  end

  defp signed(cv) do
    <<value::64-signed>> = <<cv::64>>
    value
  end

  defp await(predicate, attempts \\ 3000) do
    if predicate.() do
      :ok
    else
      assert attempts > 0
      Process.sleep(10)
      await(predicate, attempts - 1)
    end
  end
end
