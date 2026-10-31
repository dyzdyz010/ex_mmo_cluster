defmodule VoxelRegion.ClimateWorldTest do
  @moduledoc """
  只测试：真实 GeneratedStore、World 和文件页表的气候身份接纳与冷恢复。

  不烘全世界、不生成地形页、不启动应用或数据库。作者供给只经既有公共入口建立有限相态库存；
  本文件不证明天然活动发现、热传播、雪融化或正式客户端 Ready。
  """
  use ExUnit.Case, async: false
  alias VoxelRegion.{Climate, GeneratedStore, World}
  alias VoxelRegion.Climate.Source

  @config {1337, -200, 326, 586, 4, 381.77066, 1223.743774, 96}
  @parameters %{"cold_kelvin" => 263.15, "warm_kelvin" => 293.15,
    "sample_height_offset_m" => 1, "wind_mps" => 0}
  @box {{0, 7, 0}, {1, 8, 1}}

  @moduletag :tmp_dir
  setup %{tmp_dir: root} do
    # 只测试：启动拒绝会发出链接退出信号，捕获它以断言公开错误返回，不让它终止本例。
    Process.flag(:trap_exit, true)
    manifest = Map.new(Enum.zip(
      ~w(seed min_height sea_level max_height soil_depth lowland_amplitude mountain_amplitude cave_max_depth),
      Tuple.to_list(@config)))
      |> Map.merge(%{"schema" => "voxim-worldgen-v1", "kernel" => "worldgen_density_v3@1",
        "world_half_extent_m" => 8192, "materials" => MmoContracts.VoxelMaterialCatalog.table()})
    manifest_path = Path.join(root, "worldgen.json")
    File.write!(manifest_path, Jason.encode!(manifest))
    environment_path = Path.join(root, "environment.json")
    environment = %{"ambient_kelvin" => 293.15, "environment_w_per_m2_k" => 10.0,
      "tolerance_kelvin" => 1.0, "emissivity" => 0.9, "view_range_cells" => 8,
      "circuit_min_power_w" => 0.001, "generated_climate" => @parameters}
    File.write!(environment_path, Jason.encode!(environment))
    prefabs = Path.join(root, "prefabs")
    File.mkdir_p!(prefabs)
    catalog = Path.expand(
      "../../../../Voxim/Content/Voxel/Properties/Playable/Published/4b2c6abeaec3818e2203a0b95e3ee03f1cf1aed6bf796c5f33ab41001eb641ed.json",
      __DIR__)
    opts = [source: GeneratedStore, root: root, manifest_path: manifest_path,
      log: VoxelRegion.OverlayLog.File, property_catalog_path: catalog,
      thermal_environment_path: environment_path, prefab_catalog_path: prefabs,
      production_materials: [21], name: nil]
    %{opts: opts, root: root, environment: environment, environment_path: environment_path}
  end

  defp snapshot(world), do: World.simulation_snapshot(world, [1001], @box)

  defp rewrite(context, environment),
    do: File.write!(context.environment_path, Jason.encode!(environment))

  @tag :climate_binding
  test "新世界的公开观察携带已绑定的同一生成气候源，观察不生成地形页", context do
    world = start_supervised!({World, context.opts})
    value = snapshot(world)
    assert %Source{} = source = Map.get(value.property_context, :climate_source)
    assert source.content_version == World.content_version(world)
    assert Climate.at(%{"climate_source" => source}, {62, 493, 0}).air_k == 263.15
    assert value.property_context.climate_source_identity == source.identity
    assert World.stats(world).climate_source_identity == source.identity
    assert World.stats(world).generated == 0
    assert value.property_context.ambient_kelvin == 293.15
  end

  test "同身份冷恢复精确保留相态库存与既有热账，不按冷气候重置能量", context do
    world = start_supervised!({World, context.opts})
    assert {:ok, supplied_seq} = World.material_supply(world, 1001, "climate-finite", %{21 => 512})
    before = snapshot(world)
    source = before.property_context.climate_source
    assert before.phase_inventory[{1001, 21}] != {0.0, 0}
    assert :ok = World.compact(world)
    stop_supervised!(World)

    recovered = start_supervised!({World, context.opts})
    after_restart = snapshot(recovered)
    assert after_restart.property_context.climate_source == source
    assert after_restart.phase_inventory == before.phase_inventory
    assert after_restart.thermal_accounting == before.thermal_accounting
    assert after_restart.material_balances == before.material_balances
    assert {:ok, ^supplied_seq} = World.material_supply(recovered, 1001, "climate-finite", %{21 => 512})
    assert snapshot(recovered).phase_inventory == before.phase_inventory
  end

  test "即使旧世界只有seq零的持久前缀，增加新气候仍须显式迁移", context do
    rewrite(context, Map.delete(context.environment, "generated_climate"))
    world = start_supervised!({World, context.opts})
    assert World.seq(world) == 0
    assert :ok = World.compact(world)
    stop_supervised!(World)

    rewrite(context, context.environment)
    assert {:error, :climate_migration_required} = World.start_link(context.opts)
  end

  test "已有气候的参数改变或资产撤下都显式拒绝，原资产仍可恢复", context do
    world = start_supervised!({World, context.opts})
    assert {:ok, _} = World.material_supply(world, 1001, "climate-finite", %{21 => 512})
    before = snapshot(world)
    assert :ok = World.compact(world)
    stop_supervised!(World)

    rewrite(context, put_in(context.environment, ["generated_climate", "cold_kelvin"], 253.15))
    assert {:error, :climate_migration_required} = World.start_link(context.opts)
    rewrite(context, Map.delete(context.environment, "generated_climate"))
    assert {:error, :climate_migration_required} = World.start_link(context.opts)
    assert {:error, :climate_migration_required} =
      World.start_link(Keyword.put(context.opts, :thermal_environment_path, nil))

    rewrite(context, context.environment)
    recovered = start_supervised!({World, context.opts})
    assert snapshot(recovered).phase_inventory == before.phase_inventory
    assert snapshot(recovered).property_context.climate_source == before.property_context.climate_source
  end

  test "生成气候与旧绝热区双来源在World接纳边界明确失败", context do
    zone = %{"min" => [0, 0], "max" => [1, 1], "ambient_kelvin" => 250.0}
    rewrite(context, Map.put(context.environment, "climate_zones", [zone]))
    assert {:error, :conflicting_climate_sources} = World.start_link(context.opts)
  end

  test "默认新世界冷雪preset在材料目录融点处拒绝，低层Source仍支持暖气候", context do
    for cold <- [273.15, 280.0] do
      rewrite(context, put_in(context.environment, ["generated_climate", "cold_kelvin"], cold))
      assert {:error, :invalid_snow_climate_preset} = World.start_link(context.opts)
    end
  end

  @tag :climate_maintenance
  @tag timeout: 300_000
  test "全新生成世界经公开粗层重建后仍可用同资产启动并恢复同一Source", context do
    # 只测试：满足公开维护入口的预烘焙前提；64m有限世界保留原生成参数与真实目录。
    manifest_path = Keyword.fetch!(context.opts, :manifest_path)
    manifest = manifest_path |> File.read!() |> Jason.decode!() |> Map.put("world_half_extent_m", 64)
    File.write!(manifest_path, Jason.encode!(manifest))
    assert {:ok, store} = GeneratedStore.open(context.opts)
    assert {:ok, store, _stats} = VoxelRegion.Bake.run(store)
    assert {:ok, expected_source} = GeneratedStore.climate_source(store, @parameters)

    assert {:ok, report} = World.rebuild_coarse(context.opts)
    assert report.seq == 1
    assert report.canonical_equal
    head = durable_head(context)
    globals = VoxelRegion.World.Pages.decode(head.globals)
    catalog = VoxelRegion.Damage.load(Keyword.fetch!(context.opts, :property_catalog_path))
    # 只测试：保存公开维护的真实持久结果，后续若还有初始化失败，能区分缺源与量子事实。
    IO.puts("CLIMATE_MAINTENANCE_STATE " <> Jason.encode!(%{
      prefix: head.prefix, source_bound: Map.has_key?(globals.thermal.config, "climate_source"),
      stored_material_units: globals.material_units_per_micro,
      catalog_material_units: VoxelRegion.Damage.material_units(catalog)}))
    assert globals.material_units_per_micro == VoxelRegion.Damage.material_units(catalog)
    world = start_supervised!({World, context.opts})
    value = snapshot(world)
    assert value.property_context.climate_source == expected_source
    assert World.stats(world).published_seq == 1
    assert World.stats(world).climate_source_identity == expected_source.identity
  end

  @tag :climate_maintenance
  test "旧seq零前缀不能在粗层维护时偷偷增源并发布", context do
    rewrite(context, Map.delete(context.environment, "generated_climate"))
    world = start_supervised!({World, context.opts})
    assert :ok = World.compact(world)
    assert World.seq(world) == 0
    stop_supervised!(World)
    before = durable_head(context)

    rewrite(context, context.environment)
    assert {:error, :climate_migration_required} = World.rebuild_coarse(context.opts)
    assert durable_head(context) == before

    # 同一持久前缀即使seq仍为零，也不能在在线或维护入口被新目录悄悄改变量子。
    rewrite(context, Map.delete(context.environment, "generated_climate"))
    revised_catalog = Path.join(context.root, "revised-units.json")
    original_catalog = Keyword.fetch!(context.opts, :property_catalog_path)
    asset = original_catalog |> File.read!() |> Jason.decode!()
      |> put_in(["attachments", "material_units_per_micro"], 8192)
    File.write!(revised_catalog, Jason.encode!(asset))
    revised_opts = Keyword.put(context.opts, :property_catalog_path, revised_catalog)
    assert {:error, :material_units_migration_required} = World.rebuild_coarse(revised_opts)
    assert {:error, :material_units_migration_required} = World.start_link(revised_opts)
    assert durable_head(context) == before
  end

  @tag :climate_maintenance
  test "已有Source在粗层维护时换源或撤源均拒绝且不改持久前缀及账", context do
    world = start_supervised!({World, context.opts})
    assert {:ok, _} = World.material_supply(world, 1001, "maintenance-finite", %{21 => 512})
    before_snapshot = snapshot(world)
    assert :ok = World.compact(world)
    stop_supervised!(World)
    before_head = durable_head(context)

    for environment <- [put_in(context.environment, ["generated_climate", "cold_kelvin"], 253.15),
        Map.delete(context.environment, "generated_climate")] do
      rewrite(context, environment)
      assert {:error, :climate_migration_required} = World.rebuild_coarse(context.opts)
      assert durable_head(context) == before_head
    end
    assert {:error, :climate_migration_required} =
      World.rebuild_coarse(Keyword.put(context.opts, :thermal_environment_path, nil))
    assert durable_head(context) == before_head

    rewrite(context, context.environment)
    recovered = start_supervised!({World, context.opts})
    assert snapshot(recovered).phase_inventory == before_snapshot.phase_inventory
    assert snapshot(recovered).thermal_accounting == before_snapshot.thermal_accounting
  end

  @tag :climate_maintenance
  test "非法冷雪preset或双来源在粗层维护发布之前明确失败", context do
    before = durable_head(context)
    zone = %{"min" => [0, 0], "max" => [1, 1], "ambient_kelvin" => 250.0}
    for {environment, reason} <- [
        {put_in(context.environment, ["generated_climate", "cold_kelvin"], 280.0), :invalid_snow_climate_preset},
        {Map.put(context.environment, "climate_zones", [zone]), :conflicting_climate_sources}] do
      rewrite(context, environment)
      assert {:error, ^reason} = World.rebuild_coarse(context.opts)
      assert durable_head(context) == before
    end
  end

  # 只测试：经真实持久化后端的只读接口比较整个已发布头部，不向World回填状态。
  defp durable_head(context) do
    {:ok, store} = GeneratedStore.open(context.opts)
    handle = VoxelRegion.OverlayLog.File.open(store.world_dir, store.content_version)
    VoxelRegion.OverlayLog.File.load_head(handle, VoxelRegion.World.Pages.activity_code())
  end
end
