defmodule VoxelRegion.ClimateSourceTest do
  @moduledoc "只测试：新世界不可变气候descriptor与原生XYZ取样；不启动World或数据库。"
  use ExUnit.Case, async: false
  alias VoxelRegion.{Climate, GeneratedStore, Native}
  alias VoxelRegion.Climate.Source

  @config {1337, -200, 326, 586, 4, 381.77066, 1223.743774, 96}
  @parameters %{"cold_kelvin" => 263.15, "warm_kelvin" => 293.15,
    "sample_height_offset_m" => 1, "wind_mps" => 0}

  defp descriptor do
    kernel = Native.kernel_identity()
    %{content_version: GeneratedStore.content_version(kernel, @config), kernel_identity: kernel, config: @config}
  end

  @tag :tmp_dir
  test "独占新世界manifest只构造新descriptor与source，不读取生成页或覆盖旧CV", %{tmp_dir: root} do
    manifest = Map.new(Enum.zip(
      ~w(seed min_height sea_level max_height soil_depth lowland_amplitude mountain_amplitude cave_max_depth),
      Tuple.to_list(@config)))
      |> Map.merge(%{"schema" => "voxim-worldgen-v1", "kernel" => "worldgen_density_v3@1",
        "world_half_extent_m" => 8192, "materials" => MmoContracts.VoxelMaterialCatalog.table()})
    path = Path.join(root, "new-worldgen.json")
    bytes = Jason.encode!(manifest)
    File.write!(path, bytes)
    assert {:ok, store} = GeneratedStore.open(root: root, manifest_path: path)
    assert store.content_version == GeneratedStore.content_version(Native.kernel_identity(), @config)
    refute GeneratedStore.hex(store.content_version) == "4ecf1f7864707144"
    assert {:ok, source} = GeneratedStore.climate_source(store, @parameters)
    assert source.content_version == store.content_version
    assert source.kernel_identity == Native.kernel_identity()
    assert GeneratedStore.generated(store) == 0
    assert File.read!(path) == bytes
    refute File.exists?(Path.join(root, "4ecf1f7864707144"))
  end

  test "新descriptor冻结source身份，XYZ按同序取样且冷热温差不构成绝热墙" do
    descriptor = descriptor()
    assert {:ok, source} = Source.new(descriptor, @parameters)
    assert source.content_version == descriptor.content_version
    assert {:ok, ^source} = Source.new(descriptor, @parameters)
    assert {:ok, config} = Climate.bind(%{"ambient_kelvin" => 293.15}, source)
    cells = [{62, 493, 0}, {62, 278, 0}, {62, -200, 0}, {62, 493, 0}]
    assert [cold, transition, warm, repeated] = Climate.at_many(config, cells)
    assert repeated == cold
    assert cold == %{air_k: 263.15, wind_mps: 0.0}
    assert warm == %{air_k: 293.15, wind_mps: 0.0}
    assert_in_delta transition.air_k, 278.21551838090727, 1.0e-12
    assert Climate.at(config, Enum.at(cells, 1)) == transition
    assert Enum.map(cells, &Climate.region(config, &1)) == [nil, nil, nil, nil]
    refute Climate.zoned?(config)
    assert Climate.valid?(config)
    assert Climate.at_many(config, []) == []
  end

  test "错kernel、缺显式参数、气候双来源显式拒绝，作者Kelvin改变source摘要" do
    descriptor = descriptor()
    assert {:error, :climate_kernel_mismatch} = Source.new(%{descriptor | kernel_identity: "wrong"}, @parameters)
    assert {:error, :invalid_climate_parameters} = Source.new(descriptor, Map.delete(@parameters, "cold_kelvin"))
    assert {:error, :invalid_climate_parameters} = Source.new(descriptor, %{@parameters | "sample_height_offset_m" => 0})
    assert {:ok, source} = Source.new(descriptor, @parameters)
    assert {:ok, revised} = Source.new(descriptor, %{@parameters | "cold_kelvin" => 253.15})
    refute revised.identity == source.identity
    zone = %{"min" => [0, 0], "max" => [1, 1], "ambient_kelvin" => 250.0}
    assert {:error, :conflicting_climate_sources} = Climate.bind(%{"climate_zones" => [zone]}, source)
    refute Climate.valid?(%{"climate_source" => %{}})
  end

  test "不可表示的作者整数在唯一构造边界返回显式错误" do
    descriptor = descriptor()
    huge = Integer.pow(10, 1000)
    for parameters <- [%{@parameters | "cold_kelvin" => huge, "warm_kelvin" => huge + 1},
        %{@parameters | "warm_kelvin" => huge}, %{@parameters | "wind_mps" => huge}] do
      assert {:error, :invalid_climate_parameters} = Source.new(descriptor, parameters)
    end
  end

  test "bind同身份幂等，不同身份拒绝；数值合法的暖气候源不冒充初态接纳" do
    descriptor = descriptor()
    assert {:ok, source} = Source.new(descriptor, @parameters)
    assert {:ok, config} = Climate.bind(%{"ambient_kelvin" => 293.15}, source)
    assert {:ok, ^config} = Climate.bind(config, source)
    assert {:ok, warmer} = Source.new(descriptor, %{@parameters | "cold_kelvin" => 280.0, "warm_kelvin" => 300.0})
    assert {:error, :climate_source_identity_conflict} = Climate.bind(config, warmer)
    assert Climate.at(config, {62, 493, 0}).air_k == 263.15
    assert {:ok, independent} = Climate.bind(%{"ambient_kelvin" => 293.15}, warmer)
    assert Climate.at(independent, {62, 493, 0}).air_k == 280.0
  end
end
