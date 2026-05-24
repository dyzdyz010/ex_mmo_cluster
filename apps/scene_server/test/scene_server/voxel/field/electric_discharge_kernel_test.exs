defmodule SceneServer.Voxel.Field.ElectricDischargeKernelTest do
  use ExUnit.Case, async: false

  alias SceneServer.Voxel.{AttributeCatalog, NormalBlockData, Storage, Types}
  alias SceneServer.Voxel.Field.{FieldLayer, FieldRegion, KernelContext}
  alias SceneServer.Voxel.Field.Kernels.ElectricDischargeKernel

  @iron 5
  @power_block 6

  setup do
    case start_supervised({AttributeCatalog, []}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  test "declares discharge identity and output layers" do
    assert ElectricDischargeKernel.kernel_id() == :electric_discharge
    assert ElectricDischargeKernel.required_layers(%{}) == [:electric_potential, :ionization]
  end

  test "high electric potential breaks down empty medium into an ionized discharge path" do
    source = Types.macro_index!({0, 0, 0})
    target = Types.macro_index!({3, 0, 0})

    storage =
      Storage.new(7, {0, 0, 0})
      |> put_solid({0, 0, 0}, @power_block)
      |> put_solid({3, 0, 0}, @iron)

    region =
      discharge_region(
        source,
        {{0, 0, 0}, {3, 0, 0}},
        120.0
      )

    context = KernelContext.new(region, 7, storage, dt_ms: 100)

    assert {:cont, updated, effects} =
             ElectricDischargeKernel.tick(region, context, %{
               target_macro_index: target,
               max_frontier: 32,
               power_source: %{voltage: 120.0, load_current_amps: 8.0},
               thermal_coupling: %{enabled: true, joule_scale: 10_000.0}
             })

    assert active_cells(updated, :electric_potential) == [
             {source, 120.0},
             {Types.macro_index!({1, 0, 0}), 90.0},
             {Types.macro_index!({2, 0, 0}), 60.0},
             {target, 30.0}
           ]

    ionization_layer = FieldRegion.get_layer(updated, :ionization)

    for coord <- [{0, 0, 0}, {1, 0, 0}, {2, 0, 0}, {3, 0, 0}] do
      assert FieldLayer.get(ionization_layer, Types.macro_index!(coord)) > 0.0
    end

    assert length(effects) == 4

    assert Enum.all?(effects, fn
             {:write_voxel_attribute, %{attribute: :temperature, source: :electric_discharge}} ->
               true

             _other ->
               false
           end)
  end

  test "low electric potential does not fake a discharge through intact dielectric medium" do
    source = Types.macro_index!({0, 0, 0})
    target = Types.macro_index!({3, 0, 0})

    storage =
      Storage.new(7, {0, 0, 0})
      |> put_solid({0, 0, 0}, @power_block)
      |> put_solid({3, 0, 0}, @iron)

    region =
      discharge_region(
        source,
        {{0, 0, 0}, {3, 0, 0}},
        2.0
      )
      |> put_stale_channel()

    context = KernelContext.new(region, 7, storage, dt_ms: 100)

    assert {:cont, updated, []} =
             ElectricDischargeKernel.tick(region, context, %{
               target_macro_index: target,
               max_frontier: 32,
               power_source: %{voltage: 2.0, load_current_amps: 1.0},
               thermal_coupling: %{enabled: true}
             })

    assert active_cells(updated, :electric_potential) == []
    assert active_cells(updated, :ionization) == []
  end

  defp discharge_region(source, aabb, source_value) do
    FieldRegion.new(%{
      region_id: 71,
      chunk_coord: {0, 0, 0},
      aabb: aabb,
      kernels: [%{id: :electric_discharge, module: ElectricDischargeKernel}],
      source_points: [
        %{macro_index: source, field_type: :electric_potential, value: source_value}
      ]
    })
  end

  defp put_solid(storage, coord, material_id) do
    Storage.put_solid_block(storage, coord, NormalBlockData.new(material_id))
  end

  defp put_stale_channel(region) do
    stale_index = Types.macro_index!({1, 0, 0})

    region
    |> FieldRegion.put_layer(
      :electric_potential,
      region |> FieldRegion.get_layer(:electric_potential) |> FieldLayer.put(stale_index, 42.0)
    )
    |> FieldRegion.put_layer(
      :ionization,
      region |> FieldRegion.get_layer(:ionization) |> FieldLayer.put(stale_index, 42.0)
    )
  end

  defp active_cells(region, field_type) do
    region
    |> FieldRegion.get_layer(field_type)
    |> FieldLayer.active_cells(region.aabb)
  end
end
