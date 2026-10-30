defmodule VoxelRegion.StaticL0PgTest do
  @moduledoc "只测试：独立 PG 中真实无段、空段、发布前缀与 World 冷恢复；存储适配器用合法行，运行中 World 只经公共作者入口产生真值。"
  use ExUnit.Case, async: false
  @moduletag :static_l0_pg
  alias VoxelRegion.{World, GeneratedStore, OverlayLog, TestSupport}
  alias VoxelRegion.World.Pages
  alias VoxelRegion.TestSupport.StaticL0Check
  @page {0, {-20, 1000, -20}}
  @box {{-20, 1000, -20}, {-19, 1001, -19}}

  test "PG 同一发布快照区分无行和空记录，原生页退休重装，修改页冷恢复不再发证" do
    database = DataService.Repo.config()[:database]
    assert String.starts_with?(database, ["static_l0_", "mmo_test_"]), "只允许本次独立测试库"
    MmoTest.Database.start!()
    root = Path.join(System.tmp_dir!(), "static_l0_pg_#{System.pid()}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "prefabs"))
    on_exit(fn ->
      assert Path.dirname(Path.expand(root)) == Path.expand(System.tmp_dir!())
      File.rm_rf!(root)
    end)
    manifest = Path.join(root, "worldgen.json")
    data = Path.join(__DIR__, "fixtures/static_l0/worldgen.json") |> File.read!() |> Jason.decode!() |> Map.put("seed", 20261030)
    File.write!(manifest, Jason.encode!(data))
    clock = start_supervised!({VoxelRegion.TestSupport.WorldClock, 0})
    opts = [root: root, source: GeneratedStore, manifest_path: manifest, name: nil, log: OverlayLog.Db,
      clock: {VoxelRegion.TestSupport.WorldClock, clock}, static_l0_retirement: true,
      property_catalog_path: TestSupport.catalog(),
      thermal_environment_path: Path.join(__DIR__, "fixtures/static_l0/environment.json"),
      prefab_catalog_path: Path.join(root, "prefabs")]
    {:ok, source} = GeneratedStore.open(opts)
    cv = source.content_version
    assert OverlayLog.Db.prefix(cv) == nil
    world = start_supervised!({World, opts})
    assert {:ok, first} = World.apply_edit(world, {0, 64_000, 0}, 19)
    assert :ok = World.compact(world)
    stop_supervised!(World)
    world = start_supervised!({World, opts})
    assert %{prefix: ^first, rows: []} = OverlayLog.Db.read_pages(cv, [@page], Pages.fragment_codes())
    assert :ok = World.set_simulation_windows(world, [@box])
    before = TestSupport.payload(world, 0, elem(@page, 1))
    assert MapSet.member?(:sys.get_state(world).static_l0.eligible, @page)
    assert :ok = World.set_simulation_windows(world, [])
    refute Pages.resident?(:sys.get_state(world), @page)
    assert TestSupport.payload(world, 0, elem(@page, 1)) == before
    cell = {-1280, 64_000, -1280}
    assert {:ok, _} = World.apply_edit(world, cell, 19)
    assert {:ok, last} = World.apply_edit(world, cell, 0)
    assert :ok = World.compact(world)
    %{prefix: prefix, rows: rows} = OverlayLog.Db.read_pages(cv, [@page], Pages.fragment_codes())
    assert prefix == last
    units = Enum.map(rows, &Pages.unit_value/1)
    assert {{:chunk, :overlay, {-80, 4000, -80}}, %{}} in units
    assert MapSet.member?(Pages.recorded_keys(units), @page)
    assert Pages.resident?(:sys.get_state(world), @page)
    stop_supervised!(World)
    world = start_supervised!({World, opts})
    assert [%{material: 0}] = World.material_snapshot(world, [], [cell]).probe_occupancy
    assert :sys.get_state(world).static_l0.cores[@page].core == :recorded_page
    assert World.maintain_residency(world).status == :ready
    assert Pages.resident?(:sys.get_state(world), @page)
    assert OverlayLog.Db.prefix(cv) == last
    StaticL0Check.write_evidence("pg-prefix", %{database: database, cv: cv, source_identity: source.identity,
      initial_prefix: first, final_prefix: last, no_row_before: true, empty_overlay_after: true,
      recovered_core: :sys.get_state(world).static_l0.cores[@page]})
  end

  test "独立存储适配器前缀隐藏未发布行，只有 false 的页段也必须返回" do
    alias DataService.Voxel.PageStore
    database = DataService.Repo.config()[:database]
    assert String.starts_with?(database, ["static_l0_", "mmo_test_"])
    MmoTest.Database.start!()
    # 此 CV 只属于持久适配器测试，不启动 World，也不向任何运行中的 authority 注入记录。
    cv = 0x535441544943
    assert PageStore.prefix(cv) == nil
    assert :ok = PageStore.publish(cv, 0, [], "test-only adapter globals")
    assert %{prefix: 0, rows: []} = PageStore.read_pages(cv, [@page], Pages.fragment_codes())
    row = Pages.row({:page, :activity, @page}, false)
    assert :ok = PageStore.write(cv, 1, [row])
    assert %{prefix: 0, rows: []} = PageStore.read_pages(cv, [@page], Pages.fragment_codes())
    assert :ok = PageStore.publish(cv, 1, [], "test-only adapter globals")
    assert %{prefix: 1, rows: [visible]} = PageStore.read_pages(cv, [@page], Pages.fragment_codes())
    assert {{:page, :activity, @page}, false} = Pages.unit_value(visible)
    assert :ok = PageStore.write(cv, 2, [Pages.row({:page, :activity, @page}, true)])
    assert %{prefix: 1, rows: [still_old]} = PageStore.read_pages(cv, [@page], Pages.fragment_codes())
    assert Pages.unit_value(still_old) == Pages.unit_value(visible)
    assert :ok = PageStore.publish(cv, 2, [], "test-only adapter globals")
    assert %{prefix: 2, rows: [published]} = PageStore.read_pages(cv, [@page], Pages.fragment_codes())
    assert {{:page, :activity, @page}, true} = Pages.unit_value(published)
    StaticL0Check.write_evidence("pg-empty-only", %{database: database, cv: cv, isolated_false_row: visible, final_prefix: 2})
  end
end
