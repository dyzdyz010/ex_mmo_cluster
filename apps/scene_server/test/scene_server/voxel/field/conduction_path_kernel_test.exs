defmodule SceneServer.Voxel.Field.ConductionPathKernelTest do
  # Phase 7.B: conduction must be driven by electric material attributes,
  # not by the older density-based ElectricField approximation.
  use ExUnit.Case, async: false

  alias SceneServer.Voxel.{AttributeCatalog, NormalBlockData, Storage, Types}
  alias SceneServer.Voxel.Field.{FieldLayer, FieldRegion, KernelContext}
  alias SceneServer.Voxel.Field.Kernels.ConductionPathKernel

  @dirt 1
  @stone 2
  @wood 3
  @iron 5

  setup do
    case start_supervised({AttributeCatalog, []}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  test "declares conduction identity and output layers" do
    assert ConductionPathKernel.kernel_id() == :conduction_path
    assert ConductionPathKernel.required_layers(%{}) == [:electric_potential, :ionization]
  end

  test "chooses conductive material path without emitting authoritative side effects" do
    {storage, region, target} = conduction_fixture()
    context = KernelContext.new(region, 7, storage, dt_ms: 100)

    assert {:cont, updated, []} =
             ConductionPathKernel.tick(region, context, %{target_macro_index: target})

    potential_layer = FieldRegion.get_layer(updated, :electric_potential)
    ionization_layer = FieldRegion.get_layer(updated, :ionization)

    conductive_path = [
      {0, 1, 0},
      {0, 0, 0},
      {1, 0, 0},
      {2, 0, 0},
      {3, 0, 0},
      {3, 1, 0}
    ]

    for coord <- conductive_path do
      macro_index = Types.macro_index!(coord)
      assert FieldLayer.get(potential_layer, macro_index) > 0.0
      assert FieldLayer.get(ionization_layer, macro_index) > 0.0
    end

    for coord <- [{1, 1, 0}, {2, 1, 0}] do
      macro_index = Types.macro_index!(coord)
      assert FieldLayer.get(potential_layer, macro_index) == 0.0
      assert FieldLayer.get(ionization_layer, macro_index) == 0.0
    end

    assert FieldLayer.get(potential_layer, Types.macro_index!({0, 1, 0})) >
             FieldLayer.get(potential_layer, Types.macro_index!({3, 1, 0}))
  end

  test "produces deterministic channel cells for identical input" do
    {storage, region, target} = conduction_fixture()
    context = KernelContext.new(region, 7, storage, dt_ms: 100)
    opts = %{target_macro_index: target}

    assert {:cont, first, []} = ConductionPathKernel.tick(region, context, opts)
    assert {:cont, second, []} = ConductionPathKernel.tick(region, context, opts)

    assert active_cells(first, :electric_potential) == active_cells(second, :electric_potential)
    assert active_cells(first, :ionization) == active_cells(second, :ionization)
  end

  test "native and elixir path backends produce the same channel cells" do
    {storage, region, target} = conduction_fixture()

    assert_backend_equivalence(storage, region, target)
  end

  test "native and elixir path backends agree on refined contact boundaries" do
    source = Types.macro_index!({0, 0, 0})
    target = Types.macro_index!({3, 0, 0})

    connected_storage =
      Storage.new(7, {0, 0, 0})
      |> put_solid({0, 0, 0}, @iron)
      |> put_refined_x_conductor({1, 0, 0}, 3, 3)
      |> put_refined_x_conductor({2, 0, 0}, 3, 3)
      |> put_solid({3, 0, 0}, @iron)

    connected_region =
      conduction_region(26, source, {{0, 0, 0}, {3, 0, 0}})

    assert_backend_equivalence(connected_storage, connected_region, target)

    misaligned_storage =
      Storage.new(7, {0, 0, 0})
      |> put_solid({0, 0, 0}, @iron)
      |> put_refined_x_conductor({1, 0, 0}, 1, 1)
      |> put_refined_x_conductor({2, 0, 0}, 6, 6)
      |> put_solid({3, 0, 0}, @iron)

    misaligned_region =
      conduction_region(27, source, {{0, 0, 0}, {3, 0, 0}})

    assert_backend_equivalence(misaligned_storage, misaligned_region, target)
  end

  test "emits Joule heat effects for a powered thermal coupling path" do
    {storage, region, target} = conduction_fixture()
    context = KernelContext.new(region, 7, storage, dt_ms: 100)

    assert {:cont, _updated, effects} =
             ConductionPathKernel.tick(region, context, %{
               target_macro_index: target,
               power_source: %{
                 output_mode: :dc,
                 voltage: 120.0,
                 current_limit_amps: 10.0,
                 load_current_amps: 6.0
               },
               thermal_coupling: %{enabled: true}
             })

    assert length(effects) == 6

    heat_cells =
      Enum.map(effects, fn
        {:write_voxel_attribute,
         %{
           attribute: :temperature,
           macro_index: macro_index,
           heat_energy_joules: heat_energy_joules
         }} ->
          assert heat_energy_joules > 0.0
          macro_index
      end)

    assert heat_cells == [
             Types.macro_index!({0, 1, 0}),
             Types.macro_index!({0, 0, 0}),
             Types.macro_index!({1, 0, 0}),
             Types.macro_index!({2, 0, 0}),
             Types.macro_index!({3, 0, 0}),
             Types.macro_index!({3, 1, 0})
           ]

    assert Enum.all?(effects, fn
             {:write_voxel_attribute, %{source: :electric_conduction}} -> true
             _other -> false
           end)
  end

  test "attaches prefab object part targets to Joule heat effects" do
    source = Types.macro_index!({0, 0, 0})
    refined_bridge = Types.macro_index!({1, 0, 0})
    target = Types.macro_index!({2, 0, 0})

    storage =
      Storage.new(7, {0, 0, 0})
      |> put_solid({0, 0, 0}, @iron)
      |> put_connected_refined_conductor({1, 0, 0})
      |> put_solid({2, 0, 0}, @iron)

    region =
      FieldRegion.new(%{
        region_id: 22,
        chunk_coord: {0, 0, 0},
        aabb: {{0, 0, 0}, {2, 0, 0}},
        kernels: [%{id: :conduction_path, module: ConductionPathKernel}],
        source_points: [%{macro_index: source, field_type: :electric_potential, value: 120.0}]
      })

    context = KernelContext.new(region, 7, storage, dt_ms: 100)

    assert {:cont, _updated, effects} =
             ConductionPathKernel.tick(region, context, %{
               target_macro_index: target,
               power_source: %{
                 output_mode: :dc,
                 voltage: 120.0,
                 current_limit_amps: 10.0,
                 load_current_amps: 6.0
               },
               thermal_coupling: %{enabled: true}
             })

    assert {:write_voxel_attribute,
            %{
              macro_index: ^refined_bridge,
              object_part_targets: [%{owner_object_id: 42, owner_part_id: 3}]
            }} =
             Enum.find(effects, fn
               {:write_voxel_attribute, %{macro_index: ^refined_bridge}} -> true
               _other -> false
             end)
  end

  test "uses target_local_macro option" do
    {storage, region, _target} = conduction_fixture()
    context = KernelContext.new(region, 7, storage, dt_ms: 100)

    assert {:cont, updated, []} =
             ConductionPathKernel.tick(region, context, %{"target_local_macro" => {3, 1, 0}})

    assert FieldLayer.get(
             FieldRegion.get_layer(updated, :electric_potential),
             Types.macro_index!({3, 1, 0})
           ) > 0.0
  end

  test "clears stale channel when source or target is missing or invalid" do
    {storage, region, target} = conduction_fixture()
    context = KernelContext.new(region, 7, storage, dt_ms: 100)
    region = put_stale_channel(region)

    assert {:cont, missing_target, []} = ConductionPathKernel.tick(region, context, %{})
    assert active_cells(missing_target, :electric_potential) == []
    assert active_cells(missing_target, :ionization) == []

    assert {:cont, invalid_target, []} =
             ConductionPathKernel.tick(region, context, %{target_macro_index: 99_999})

    assert active_cells(invalid_target, :electric_potential) == []
    assert active_cells(invalid_target, :ionization) == []

    no_source_region = put_stale_channel(%{region | source_points: []})
    no_source_context = KernelContext.new(no_source_region, 7, storage, dt_ms: 100)

    assert {:cont, no_source, []} =
             ConductionPathKernel.tick(no_source_region, no_source_context, %{
               target_macro_index: target
             })

    assert active_cells(no_source, :electric_potential) == []
    assert active_cells(no_source, :ionization) == []
  end

  test "returns no channel when frontier budget is exhausted" do
    {storage, region, target} = conduction_fixture()
    context = KernelContext.new(region, 7, storage, dt_ms: 100)
    region = put_stale_channel(region)

    assert {:cont, updated, []} =
             ConductionPathKernel.tick(region, context, %{
               target_macro_index: target,
               max_frontier: 1
             })

    assert active_cells(updated, :electric_potential) == []
    assert active_cells(updated, :ionization) == []
  end

  test "does not let density advantage override electrical properties" do
    {storage, region, target} = density_independent_fixture()
    context = KernelContext.new(region, 7, storage, dt_ms: 100)

    assert {:cont, updated, []} =
             ConductionPathKernel.tick(region, context, %{target_macro_index: target})

    potential_layer = FieldRegion.get_layer(updated, :electric_potential)

    for coord <- [{0, 1, 0}, {0, 0, 0}, {1, 0, 0}, {2, 0, 0}, {3, 0, 0}, {3, 1, 0}] do
      assert FieldLayer.get(potential_layer, Types.macro_index!(coord)) > 0.0
    end

    for coord <- [{1, 1, 0}, {2, 1, 0}] do
      assert FieldLayer.get(potential_layer, Types.macro_index!(coord)) == 0.0
    end
  end

  test "does not route through empty or low-conductivity ground cells" do
    source = Types.macro_index!({0, 1, 0})
    target = Types.macro_index!({3, 1, 0})

    storage =
      Storage.new(7, {0, 0, 0})
      |> put_solid({0, 1, 0}, @iron)
      |> put_solid({3, 1, 0}, @iron)
      |> put_solid({1, 1, 0}, @dirt)
      |> put_solid({2, 1, 0}, @dirt)

    region =
      FieldRegion.new(%{
        region_id: 19,
        chunk_coord: {0, 0, 0},
        aabb: {{0, 1, 0}, {3, 1, 0}},
        kernels: [%{id: :conduction_path, module: ConductionPathKernel}],
        source_points: [%{macro_index: source, field_type: :electric_potential, value: 120.0}]
      })

    context = KernelContext.new(region, 7, storage, dt_ms: 100)

    assert {:cont, updated, []} =
             ConductionPathKernel.tick(region, context, %{target_macro_index: target})

    assert active_cells(updated, :electric_potential) == []
    assert active_cells(updated, :ionization) == []
  end

  test "does not treat a broken refined prefab conductor as a whole conductive macro" do
    source = Types.macro_index!({0, 0, 0})
    target = Types.macro_index!({2, 0, 0})

    storage =
      Storage.new(7, {0, 0, 0})
      |> put_solid({0, 0, 0}, @iron)
      |> put_broken_refined_conductor({1, 0, 0})
      |> put_solid({2, 0, 0}, @iron)

    region =
      FieldRegion.new(%{
        region_id: 20,
        chunk_coord: {0, 0, 0},
        aabb: {{0, 0, 0}, {2, 0, 0}},
        kernels: [%{id: :conduction_path, module: ConductionPathKernel}],
        source_points: [%{macro_index: source, field_type: :electric_potential, value: 120.0}]
      })

    context = KernelContext.new(region, 7, storage, dt_ms: 100)

    assert {:cont, updated, []} =
             ConductionPathKernel.tick(region, context, %{target_macro_index: target})

    assert active_cells(updated, :electric_potential) == []
    assert active_cells(updated, :ionization) == []
  end

  test "routes through a connected refined prefab conductor bridge" do
    source = Types.macro_index!({0, 0, 0})
    target = Types.macro_index!({2, 0, 0})

    storage =
      Storage.new(7, {0, 0, 0})
      |> put_solid({0, 0, 0}, @iron)
      |> put_connected_refined_conductor({1, 0, 0})
      |> put_solid({2, 0, 0}, @iron)

    region =
      FieldRegion.new(%{
        region_id: 21,
        chunk_coord: {0, 0, 0},
        aabb: {{0, 0, 0}, {2, 0, 0}},
        kernels: [%{id: :conduction_path, module: ConductionPathKernel}],
        source_points: [%{macro_index: source, field_type: :electric_potential, value: 120.0}]
      })

    context = KernelContext.new(region, 7, storage, dt_ms: 100)

    assert {:cont, updated, []} =
             ConductionPathKernel.tick(region, context, %{target_macro_index: target})

    assert active_cells(updated, :electric_potential) == [
             {source, 120.0},
             {Types.macro_index!({1, 0, 0}), 80.0},
             {target, 40.0}
           ]
  end

  test "does not connect refined prefab conductors when shared face contacts are misaligned" do
    source = Types.macro_index!({0, 0, 0})
    target = Types.macro_index!({3, 0, 0})

    storage =
      Storage.new(7, {0, 0, 0})
      |> put_solid({0, 0, 0}, @iron)
      |> put_refined_x_conductor({1, 0, 0}, 1, 1)
      |> put_refined_x_conductor({2, 0, 0}, 6, 6)
      |> put_solid({3, 0, 0}, @iron)

    region =
      FieldRegion.new(%{
        region_id: 23,
        chunk_coord: {0, 0, 0},
        aabb: {{0, 0, 0}, {3, 0, 0}},
        kernels: [%{id: :conduction_path, module: ConductionPathKernel}],
        source_points: [%{macro_index: source, field_type: :electric_potential, value: 120.0}]
      })

    context = KernelContext.new(region, 7, storage, dt_ms: 100)

    assert {:cont, updated, []} =
             ConductionPathKernel.tick(region, context, %{target_macro_index: target})

    assert active_cells(updated, :electric_potential) == []
    assert active_cells(updated, :ionization) == []
  end

  test "connects refined prefab conductors when shared face contacts overlap" do
    source = Types.macro_index!({0, 0, 0})
    target = Types.macro_index!({3, 0, 0})

    storage =
      Storage.new(7, {0, 0, 0})
      |> put_solid({0, 0, 0}, @iron)
      |> put_refined_x_conductor({1, 0, 0}, 3, 3)
      |> put_refined_x_conductor({2, 0, 0}, 3, 3)
      |> put_solid({3, 0, 0}, @iron)

    region =
      FieldRegion.new(%{
        region_id: 24,
        chunk_coord: {0, 0, 0},
        aabb: {{0, 0, 0}, {3, 0, 0}},
        kernels: [%{id: :conduction_path, module: ConductionPathKernel}],
        source_points: [%{macro_index: source, field_type: :electric_potential, value: 120.0}]
      })

    context = KernelContext.new(region, 7, storage, dt_ms: 100)

    assert {:cont, updated, []} =
             ConductionPathKernel.tick(region, context, %{target_macro_index: target})

    assert active_cells(updated, :electric_potential) == [
             {source, 120.0},
             {Types.macro_index!({1, 0, 0}), 90.0},
             {Types.macro_index!({2, 0, 0}), 60.0},
             {target, 30.0}
           ]
  end

  defp conduction_fixture do
    source = Types.macro_index!({0, 1, 0})
    target = Types.macro_index!({3, 1, 0})

    storage =
      Storage.new(7, {0, 0, 0})
      |> put_solid({0, 1, 0}, @iron)
      |> put_solid({3, 1, 0}, @iron)
      |> put_solid({1, 1, 0}, @wood)
      |> put_solid({2, 1, 0}, @wood)
      |> put_solid({0, 0, 0}, @iron)
      |> put_solid({1, 0, 0}, @iron)
      |> put_solid({2, 0, 0}, @iron)
      |> put_solid({3, 0, 0}, @iron)
      |> put_solid({1, 0, 1}, @dirt)

    region =
      FieldRegion.new(%{
        region_id: 17,
        chunk_coord: {0, 0, 0},
        aabb: {{0, 0, 0}, {3, 1, 0}},
        kernels: [%{id: :conduction_path, module: ConductionPathKernel}],
        source_points: [%{macro_index: source, field_type: :electric_potential, value: 120.0}]
      })

    {storage, region, target}
  end

  defp density_independent_fixture do
    source = Types.macro_index!({0, 1, 0})
    target = Types.macro_index!({3, 1, 0})

    storage =
      Storage.new(7, {0, 0, 0})
      |> put_solid({0, 1, 0}, @iron)
      |> put_solid({3, 1, 0}, @iron)
      |> put_solid({1, 1, 0}, @stone)
      |> put_solid({2, 1, 0}, @stone)
      |> put_solid({0, 0, 0}, @iron)
      |> put_solid({1, 0, 0}, @iron)
      |> put_solid({2, 0, 0}, @iron)
      |> put_solid({3, 0, 0}, @iron)

    region =
      FieldRegion.new(%{
        region_id: 18,
        chunk_coord: {0, 0, 0},
        aabb: {{0, 0, 0}, {3, 1, 0}},
        kernels: [%{id: :conduction_path, module: ConductionPathKernel}],
        source_points: [%{macro_index: source, field_type: :electric_potential, value: 120.0}]
      })

    {storage, region, target}
  end

  defp conduction_region(region_id, source, aabb) do
    FieldRegion.new(%{
      region_id: region_id,
      chunk_coord: {0, 0, 0},
      aabb: aabb,
      kernels: [%{id: :conduction_path, module: ConductionPathKernel}],
      source_points: [%{macro_index: source, field_type: :electric_potential, value: 120.0}]
    })
  end

  defp assert_backend_equivalence(storage, region, target) do
    context = KernelContext.new(region, 7, storage, dt_ms: 100)

    assert {:cont, native_region, native_effects} =
             ConductionPathKernel.tick(region, context, %{
               target_macro_index: target,
               path_backend: :native
             })

    assert {:cont, elixir_region, elixir_effects} =
             ConductionPathKernel.tick(region, context, %{
               target_macro_index: target,
               path_backend: :elixir
             })

    assert active_cells(native_region, :electric_potential) ==
             active_cells(elixir_region, :electric_potential)

    assert active_cells(native_region, :ionization) == active_cells(elixir_region, :ionization)
    assert native_effects == elixir_effects
  end

  defp put_stale_channel(region) do
    stale_index = Types.macro_index!({1, 1, 0})

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

  defp put_solid(storage, coord, material_id) do
    Storage.put_solid_block(storage, coord, NormalBlockData.new(material_id))
  end

  defp put_broken_refined_conductor(storage, coord) do
    face_slots = [
      Types.micro_index!({0, 3, 3}),
      Types.micro_index!({7, 3, 3})
    ]

    Storage.put_micro_blocks(
      storage,
      coord,
      Enum.map(face_slots, fn slot ->
        {slot,
         %{
           material_id: @iron,
           health: 100,
           owner_object_id: 42,
           owner_part_id: 3
         }}
      end)
    )
  end

  defp put_connected_refined_conductor(storage, coord) do
    put_refined_x_conductor(storage, coord, 3, 3)
  end

  defp put_refined_x_conductor(storage, coord, y, z) do
    slots = Enum.map(0..7, &Types.micro_index!({&1, y, z}))

    Storage.put_micro_blocks(
      storage,
      coord,
      Enum.map(slots, fn slot ->
        {slot,
         %{
           material_id: @iron,
           health: 100,
           owner_object_id: 42,
           owner_part_id: 3
         }}
      end)
    )
  end

  defp active_cells(region, field_type) do
    region
    |> FieldRegion.get_layer(field_type)
    |> FieldLayer.active_cells(region.aabb)
  end
end
