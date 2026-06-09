defmodule SceneServer.Voxel.Phenomenon.CorrosionTest do
  use ExUnit.Case, async: false

  alias SceneServer.Voxel.AttributeCatalog
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.Phenomenon.Corrosion
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.Types

  @fixed32_scale 65_536

  setup do
    case start_supervised({AttributeCatalog, []}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  test "moisture and chemical source corrode iron through structured effects" do
    macro_index = Types.macro_index!({0, 0, 0})

    storage =
      macro_index
      |> storage_with_material(5)
      |> put_attribute(macro_index, "moisture", 120.0)
      |> put_attribute(macro_index, "chemical_concentration", 45.0)

    conductivity_before =
      Storage.effective_attribute_at_normalized(storage, macro_index, "electric_conductivity")

    assert %{
             stage: :corroding,
             effects: effects,
             corrosion_after_percent: corrosion_after,
             electric_conductivity_after_ms_per_m: conductivity_after
           } =
             Corrosion.evaluate(storage, macro_index, dt_seconds: 1.0)

    assert corrosion_after > 0.0
    assert conductivity_after * @fixed32_scale < conductivity_before
    assert write_raw(effects, :corrosion) > 0
    assert write_raw(effects, :surface_state) == Corrosion.surface_corroding()
    assert write_raw(effects, :structural_integrity) < fixed32(100.0)
    assert write_raw(effects, :electric_conductivity) < conductivity_before
    assert observe_event?(effects, "voxel_corrosion_advanced", :corroding)
    assert upsert_instance?(effects, :corrosion, macro_index, :corroding)
  end

  test "chemical exposure without enough moisture only marks exposed surface" do
    macro_index = Types.macro_index!({1, 0, 0})

    storage =
      macro_index
      |> storage_with_material(5)
      |> put_attribute(macro_index, "moisture", 1.0)
      |> put_attribute(macro_index, "chemical_concentration", 45.0)

    assert %{stage: :exposed, effects: effects} =
             Corrosion.evaluate(storage, macro_index, dt_seconds: 1.0)

    assert write_raw(effects, :surface_state) == Corrosion.surface_exposed()
    refute write_raw(effects, :corrosion)
    refute write_raw(effects, :structural_integrity)
    assert observe_event?(effects, "voxel_corrosion_exposed", :exposed)
  end

  test "inert materials without corrosion profile ignore chemical exposure" do
    macro_index = Types.macro_index!({2, 0, 0})

    storage =
      macro_index
      |> storage_with_material(2)
      |> put_attribute(macro_index, "moisture", 120.0)
      |> put_attribute(macro_index, "chemical_concentration", 45.0)

    assert :ignore = Corrosion.evaluate(storage, macro_index, dt_seconds: 1.0)
  end

  defp storage_with_material(macro_index, material_id) do
    Storage.empty(1, {0, 0, 0})
    |> Storage.put_solid_block(macro_index, NormalBlockData.new(material_id))
    |> Storage.ensure_accel()
  end

  defp put_attribute(storage, macro_index, attr_name, value) do
    Storage.put_attribute_for_cell(storage, macro_index, attr_name, fixed32(value))
  end

  defp write_raw(effects, attribute) do
    Enum.find_value(effects, fn
      {:write_voxel_attribute, %{attribute: ^attribute, raw_value: raw_value}} -> raw_value
      _other -> nil
    end)
  end

  defp observe_event?(effects, event, stage) do
    Enum.any?(effects, fn
      {:emit_observe, ^event, %{stage: ^stage}} -> true
      _other -> false
    end)
  end

  defp upsert_instance?(effects, kind, macro_index, stage) do
    Enum.any?(effects, fn
      {:upsert_phenomenon_instance, %{kind: ^kind, macro_index: ^macro_index, stage: ^stage}} ->
        true

      _other ->
        false
    end)
  end

  defp fixed32(value), do: round(value * @fixed32_scale)
end
