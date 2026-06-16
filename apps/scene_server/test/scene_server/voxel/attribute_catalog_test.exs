defmodule SceneServer.Voxel.AttributeCatalogTest do
  # Phase 5.C: AttributeCatalog GenServer + private ETS。每个测试用 unique name
  # 启 ad-hoc 进程，避免与 production singleton 冲突；async: false 因为 ETS
  # named table 在同名注册时会冲突（即便用 unique server name，每个进程也只
  # 一个 lookup_by_id / lookup_by_name 表）。
  use ExUnit.Case, async: false

  alias SceneServer.Voxel.AttributeCatalog
  alias SceneServer.Voxel.AttributeCatalogSnapshot
  alias SceneServer.Voxel.AttributeDefinition

  @absolute_zero_raw -17_904_824
  @fixed32_scale 65_536

  setup do
    name = :"attribute_catalog_#{System.unique_integer([:positive])}"
    pid = start_supervised!({AttributeCatalog, name: name})
    %{server: name, pid: pid}
  end

  describe "seed loading" do
    test "loads all 14 attributes from priv/catalogs/attribute_catalog_v1.exs", %{server: server} do
      snapshot = AttributeCatalog.current_snapshot(server)
      assert %AttributeCatalogSnapshot{} = snapshot
      assert snapshot.catalog_version == 4
      assert length(snapshot.definitions) == 14
    end

    test "catalog_version returns 4", %{server: server} do
      assert AttributeCatalog.catalog_version(server) == 4
    end

    test "definitions are sorted by id ascending", %{server: server} do
      snapshot = AttributeCatalog.current_snapshot(server)
      ids = Enum.map(snapshot.definitions, & &1.id)
      assert ids == Enum.sort(ids)
      assert ids == Enum.to_list(1..14)
    end
  end

  describe "lookup_by_id" do
    test "returns {:ok, defn} for id 1 (temperature)", %{server: server} do
      assert {:ok, defn} = AttributeCatalog.lookup_by_id(server, 1)
      assert %AttributeDefinition{} = defn
      assert defn.id == 1
      assert defn.name == "temperature"
      assert defn.unit == "°C"
      # 0x03 fixed32
      assert defn.value_type == 0x03
      # 20.0 °C in Q16.16
      assert defn.default_value == 1_310_720
      # 0x02 add_delta
      assert defn.merge_rule == 0x02
      assert defn.dynamic == true
    end

    test "returns {:ok, defn} for id 4 (density, material_default static)", %{server: server} do
      assert {:ok, defn} = AttributeCatalog.lookup_by_id(server, 4)
      assert defn.name == "density"
      # 0x05 material_default
      assert defn.merge_rule == 0x05
      assert defn.dynamic == false
      assert defn.value_type == 0x03
    end

    test "returns {:ok, defn} for id 5 (thermal_conductivity)", %{server: server} do
      assert {:ok, defn} = AttributeCatalog.lookup_by_id(server, 5)
      assert defn.name == "thermal_conductivity"
      assert defn.unit == "W/(m·K)"
      # 0.1 in Q16.16
      assert defn.default_value == 6_554
    end

    test "returns {:ok, defn} for id 6 (specific_heat_capacity)", %{server: server} do
      assert {:ok, defn} = AttributeCatalog.lookup_by_id(server, 6)
      assert defn.name == "specific_heat_capacity"
      assert defn.unit == "J/(kg·K)"
      # 1000.0 in Q16.16
      assert defn.default_value == 65_536_000
      assert defn.merge_rule == 0x05
      assert defn.dynamic == false
    end

    test "returns Phase 7.E material threshold and electrical definitions", %{server: server} do
      expectations = [
        {7, "ignition_temperature", "°C", fixed32(5_000.0), @absolute_zero_raw, fixed32(5_000.0)},
        {8, "melting_point", "°C", fixed32(5_000.0), @absolute_zero_raw, fixed32(5_000.0)},
        {9, "freezing_point", "°C", @absolute_zero_raw, @absolute_zero_raw, fixed32(5_000.0)},
        {10, "boiling_point", "°C", fixed32(5_000.0), @absolute_zero_raw, fixed32(5_000.0)},
        {11, "electric_conductivity", "MS/m", 0, 0, fixed32(100.0)},
        {12, "dielectric_strength", "MV/m", fixed32(3.0), 0, fixed32(100.0)},
        {14, "electric_resistance", "Ω", 0, 0, fixed32(10_000.0)}
      ]

      for {id, name, unit, default_value, min_value, max_value} <- expectations do
        assert {:ok, defn} = AttributeCatalog.lookup_by_id(server, id)
        assert defn.name == name
        assert defn.unit == unit
        assert defn.value_type == 0x03
        assert defn.default_value == default_value
        assert defn.min_value == min_value
        assert defn.max_value == max_value
        assert defn.merge_rule == 0x05
        assert defn.dynamic == false
      end
    end

    test "returns {:error, :not_found} for id 999", %{server: server} do
      assert {:error, :not_found} = AttributeCatalog.lookup_by_id(server, 999)
    end

    test "returns {:error, :not_found} for id 0", %{server: server} do
      assert {:error, :not_found} = AttributeCatalog.lookup_by_id(server, 0)
    end
  end

  describe "lookup_by_name" do
    test "returns {:ok, 2, defn} for humidity", %{server: server} do
      assert {:ok, 2, defn} = AttributeCatalog.lookup_by_name(server, "humidity")
      assert defn.name == "humidity"
      assert defn.unit == "%"
      # 50.0%
      assert defn.default_value == 3_276_800
      # 100.0% max
      assert defn.max_value == 6_553_600
    end

    test "returns {:ok, 3, defn} for moisture", %{server: server} do
      assert {:ok, 3, defn} = AttributeCatalog.lookup_by_name(server, "moisture")
      assert defn.name == "moisture"
      assert defn.unit == "kg/m³"
      assert defn.default_value == 0
    end

    test "returns {:error, :not_found} for unknown name", %{server: server} do
      assert {:error, :not_found} = AttributeCatalog.lookup_by_name(server, "nonexistent")
    end

    test "returns {:error, :not_found} for empty string", %{server: server} do
      assert {:error, :not_found} = AttributeCatalog.lookup_by_name(server, "")
    end

    test "is case-sensitive", %{server: server} do
      assert {:error, :not_found} = AttributeCatalog.lookup_by_name(server, "Temperature")
      assert {:error, :not_found} = AttributeCatalog.lookup_by_name(server, "TEMPERATURE")
      assert {:ok, 1, _} = AttributeCatalog.lookup_by_name(server, "temperature")
    end
  end

  describe "current_snapshot byte-stable encoding" do
    test "matches AttributeCatalogSnapshot.normalize! invariants", %{server: server} do
      snapshot = AttributeCatalog.current_snapshot(server)

      # snapshot 必须可以直接 encode/decode roundtrip
      wire = AttributeCatalogSnapshot.encode_for_wire(snapshot)
      decoded = AttributeCatalogSnapshot.decode_for_wire(wire)

      assert decoded.catalog_version == 4
      assert length(decoded.definitions) == 14

      # 重复 encode 应 byte-stable
      assert wire == AttributeCatalogSnapshot.encode_for_wire(decoded)
    end
  end

  describe "reload!" do
    test "reloading default seed yields identical snapshot", %{server: server} do
      before = AttributeCatalog.current_snapshot(server)
      assert :ok = AttributeCatalog.reload!(server)
      after_reload = AttributeCatalog.current_snapshot(server)
      assert before == after_reload
    end
  end

  defp fixed32(value), do: round(value * @fixed32_scale)
end
