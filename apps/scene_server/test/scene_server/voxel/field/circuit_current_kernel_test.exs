defmodule SceneServer.Voxel.Field.CircuitCurrentKernelTest do
  use ExUnit.Case, async: false

  alias SceneServer.Voxel.{
    AttributeCatalog,
    BlueprintCatalog,
    NormalBlockData,
    PrefabRaster,
    Storage,
    Types
  }

  alias SceneServer.Voxel.Field.{FieldLayer, FieldRegion, KernelContext}
  alias SceneServer.Voxel.Field.Kernels.CircuitCurrentKernel

  @iron 5
  @power_block 6
  @load_block 7

  setup do
    case start_supervised({AttributeCatalog, []}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  test "declares automatic circuit identity and current output layer" do
    assert CircuitCurrentKernel.kernel_id() == :circuit_current

    assert CircuitCurrentKernel.required_layers(%{}) == [
             :electric_potential,
             :ionization,
             :electric_current
           ]
  end

  test "open conductive wire from a power block does not create current" do
    source = Types.macro_index!({0, 0, 0})

    storage =
      Storage.new(7, {0, 0, 0})
      |> put_solid({0, 0, 0}, @power_block)
      |> put_solid({1, 0, 0}, @iron)
      |> put_solid({2, 0, 0}, @iron)

    region = circuit_region(source)
    context = KernelContext.new(region, 7, storage, dt_ms: 100)

    assert {:cont, updated, []} = CircuitCurrentKernel.tick(region, context, %{})

    assert active_cells(updated, :electric_current) == []
  end

  test "source and load in the same open conductive component do not produce current" do
    source = Types.macro_index!({0, 0, 0})

    storage =
      Storage.new(7, {0, 0, 0})
      |> put_solid({0, 0, 0}, @power_block)
      |> put_solid({1, 0, 0}, @iron)
      |> put_solid({2, 0, 0}, @load_block)

    region = circuit_region(source)
    context = KernelContext.new(region, 7, storage, dt_ms: 100)

    assert {:cont, updated, []} = CircuitCurrentKernel.tick(region, context, %{})

    assert active_cells(updated, :electric_current) == []
  end

  test "source and load on a closed conductive loop produce current automatically" do
    source = Types.macro_index!({0, 0, 0})

    storage =
      Storage.new(7, {0, 0, 0})
      |> put_loop()

    region = loop_region(source)
    context = KernelContext.new(region, 7, storage, dt_ms: 100)

    assert {:cont, updated, []} = CircuitCurrentKernel.tick(region, context, %{})

    current_cells = active_cells(updated, :electric_current)

    assert Enum.map(current_cells, &elem(&1, 0)) == loop_macro_indices()

    assert Enum.all?(current_cells, fn {_macro_index, amps} -> amps > 0.0 end)
    assert active_cells(updated, :electric_potential) != []
    assert active_cells(updated, :ionization) != []
  end

  test "breaking a loop conductor clears previously energized current layers" do
    source = Types.macro_index!({0, 0, 0})

    region = loop_region(source)

    closed_storage =
      Storage.new(7, {0, 0, 0})
      |> put_loop()

    assert {:cont, energized, []} =
             CircuitCurrentKernel.tick(region, KernelContext.new(region, 7, closed_storage), %{})

    assert active_cells(energized, :electric_current) != []

    open_storage = Storage.clear_macro_cell(closed_storage, {2, 1, 0})

    assert {:cont, cleared, []} =
             CircuitCurrentKernel.tick(
               energized,
               KernelContext.new(energized, 7, open_storage),
               %{}
             )

    assert active_cells(cleared, :electric_current) == []
    assert active_cells(cleared, :electric_potential) == []
    assert active_cells(cleared, :ionization) == []
  end

  test "independent loops in one region energize independently when one loop breaks" do
    source_a = Types.macro_index!({0, 0, 0})
    source_b = Types.macro_index!({6, 0, 4})

    region =
      FieldRegion.new(%{
        region_id: 505,
        chunk_coord: {0, 0, 0},
        aabb: {{0, 0, 0}, {8, 2, 4}},
        kernels: [%{id: :circuit_current, module: CircuitCurrentKernel}],
        source_points: [
          %{macro_index: source_a, field_type: :electric_potential, value: 120.0},
          %{macro_index: source_b, field_type: :electric_potential, value: 120.0}
        ]
      })

    closed_storage =
      Storage.new(7, {0, 0, 0})
      |> put_loop()
      |> put_second_loop()

    assert {:cont, energized, []} =
             CircuitCurrentKernel.tick(region, KernelContext.new(region, 7, closed_storage), %{})

    assert energized |> active_cells(:electric_current) |> active_macro_indices() ==
             (loop_macro_indices() ++ second_loop_macro_indices()) |> Enum.sort()

    open_storage = Storage.clear_macro_cell(closed_storage, {2, 1, 0})

    assert {:cont, remaining, []} =
             CircuitCurrentKernel.tick(
               energized,
               KernelContext.new(energized, 7, open_storage),
               %{}
             )

    assert remaining |> active_cells(:electric_current) |> active_macro_indices() ==
             second_loop_macro_indices()
  end

  test "source and load on a rotated prefab loop produce current automatically" do
    source = Types.macro_index!({1, 0, 0})

    storage =
      Storage.new(7, {0, 0, 0})
      |> put_prefab_loop()

    region = prefab_loop_region(source)

    context = KernelContext.new(region, 7, storage, dt_ms: 100)

    assert {:cont, updated, []} = CircuitCurrentKernel.tick(region, context, %{})

    current_cells = active_cells(updated, :electric_current)

    assert current_cells != []
    assert Types.macro_index!({1, 0, 0}) in Enum.map(current_cells, &elem(&1, 0))
    assert Types.macro_index!({3, 0, 0}) in Enum.map(current_cells, &elem(&1, 0))
  end

  test "breaking a rotated prefab loop conductor clears prefab current layers" do
    source = Types.macro_index!({1, 0, 0})
    region = prefab_loop_region(source)

    closed_storage =
      Storage.new(7, {0, 0, 0})
      |> put_prefab_loop()

    assert {:cont, energized, []} =
             CircuitCurrentKernel.tick(region, KernelContext.new(region, 7, closed_storage), %{})

    assert active_cells(energized, :electric_current) != []

    open_storage = Storage.clear_macro_cell(closed_storage, {4, 0, 1})

    assert {:cont, cleared, []} =
             CircuitCurrentKernel.tick(
               energized,
               KernelContext.new(energized, 7, open_storage),
               %{}
             )

    assert active_cells(cleared, :electric_current) == []
    assert active_cells(cleared, :electric_potential) == []
    assert active_cells(cleared, :ionization) == []
  end

  test "disconnected source and load micro components inside one macro do not produce current" do
    source = Types.macro_index!({0, 0, 0})

    storage =
      Storage.new(7, {0, 0, 0})
      |> Storage.put_micro_blocks({0, 0, 0}, [
        {Types.micro_index!({0, 1, 1}), %{material_id: @power_block, health: 100}},
        {Types.micro_index!({7, 6, 6}), %{material_id: @load_block, health: 100}}
      ])

    region =
      FieldRegion.new(%{
        region_id: 502,
        chunk_coord: {0, 0, 0},
        aabb: {{0, 0, 0}, {0, 0, 0}},
        kernels: [%{id: :circuit_current, module: CircuitCurrentKernel}],
        source_points: [%{macro_index: source, field_type: :electric_potential, value: 120.0}]
      })

    context = KernelContext.new(region, 7, storage, dt_ms: 100)

    assert {:cont, updated, []} = CircuitCurrentKernel.tick(region, context, %{})

    assert active_cells(updated, :electric_current) == []
  end

  defp circuit_region(source_index) do
    FieldRegion.new(%{
      region_id: 501,
      chunk_coord: {0, 0, 0},
      aabb: {{0, 0, 0}, {2, 0, 0}},
      kernels: [%{id: :circuit_current, module: CircuitCurrentKernel}],
      source_points: [%{macro_index: source_index, field_type: :electric_potential, value: 120.0}]
    })
  end

  defp loop_region(source_index) do
    FieldRegion.new(%{
      region_id: 503,
      chunk_coord: {0, 0, 0},
      aabb: {{0, 0, 0}, {2, 2, 0}},
      kernels: [%{id: :circuit_current, module: CircuitCurrentKernel}],
      source_points: [%{macro_index: source_index, field_type: :electric_potential, value: 120.0}]
    })
  end

  defp prefab_loop_region(source_index) do
    FieldRegion.new(%{
      region_id: 504,
      chunk_coord: {0, 0, 0},
      aabb: {{0, 0, 0}, {4, 0, 2}},
      kernels: [%{id: :circuit_current, module: CircuitCurrentKernel}],
      source_points: [%{macro_index: source_index, field_type: :electric_potential, value: 120.0}]
    })
  end

  defp put_loop(storage) do
    Enum.reduce(
      loop_blocks(),
      storage,
      fn {coord, material_id}, acc -> put_solid(acc, coord, material_id) end
    )
  end

  defp loop_macro_indices do
    loop_blocks()
    |> Enum.map(fn {coord, _material_id} -> Types.macro_index!(coord) end)
    |> Enum.sort()
  end

  defp loop_blocks do
    [
      {{0, 0, 0}, @power_block},
      {{1, 0, 0}, @iron},
      {{2, 0, 0}, @load_block},
      {{2, 1, 0}, @iron},
      {{2, 2, 0}, @iron},
      {{1, 2, 0}, @iron},
      {{0, 2, 0}, @iron},
      {{0, 1, 0}, @iron}
    ]
  end

  defp put_second_loop(storage) do
    Enum.reduce(
      second_loop_blocks(),
      storage,
      fn {coord, material_id}, acc -> put_solid(acc, coord, material_id) end
    )
  end

  defp second_loop_macro_indices do
    second_loop_blocks()
    |> Enum.map(fn {coord, _material_id} -> Types.macro_index!(coord) end)
    |> Enum.sort()
  end

  defp second_loop_blocks do
    [
      {{6, 0, 4}, @power_block},
      {{7, 0, 4}, @iron},
      {{8, 0, 4}, @load_block},
      {{8, 1, 4}, @iron},
      {{8, 2, 4}, @iron},
      {{7, 2, 4}, @iron},
      {{6, 2, 4}, @iron},
      {{6, 1, 4}, @iron}
    ]
  end

  defp put_solid(storage, coord, material_id) do
    Storage.put_solid_block(storage, coord, NormalBlockData.new(material_id))
  end

  defp put_prefab_loop(storage) do
    [
      {{0, 0, 0}, 5, 0},
      {{1, 0, 0}, 6, 0},
      {{2, 0, 0}, 4, 0},
      {{3, 0, 0}, 7, 0},
      {{4, 0, 0}, 5, 0},
      {{4, 0, 1}, 4, 1},
      {{4, 0, 2}, 5, 0},
      {{3, 0, 2}, 4, 0},
      {{2, 0, 2}, 4, 0},
      {{1, 0, 2}, 4, 0},
      {{0, 0, 2}, 5, 0},
      {{0, 0, 1}, 4, 1}
    ]
    |> Enum.reduce(storage, fn {macro, blueprint_id, rotation}, acc ->
      put_prefab(acc, macro, blueprint_id, rotation)
    end)
  end

  defp put_prefab(storage, macro, blueprint_id, rotation) do
    anchor =
      macro |> Tuple.to_list() |> Enum.map(&(&1 * Types.micro_resolution())) |> List.to_tuple()

    assert {:ok, cells} =
             PrefabRaster.rasterize(
               blueprint_id,
               BlueprintCatalog.blueprint_version(),
               anchor,
               rotation
             )

    cells
    |> Enum.group_by(& &1.local_macro)
    |> Enum.reduce(storage, fn {local_macro, macro_cells}, acc ->
      pairs = Enum.map(macro_cells, &{&1.micro_slot, &1.layer_attrs})
      Storage.put_micro_blocks(acc, local_macro, pairs)
    end)
  end

  defp active_cells(region, field_type) do
    region
    |> FieldRegion.get_layer(field_type)
    |> FieldLayer.active_cells(region.aabb, 0)
  end

  defp active_macro_indices(cells) do
    cells
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end
end
