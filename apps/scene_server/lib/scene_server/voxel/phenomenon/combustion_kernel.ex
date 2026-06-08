defmodule SceneServer.Voxel.Phenomenon.CombustionKernel do
  @moduledoc """
  Field-kernel adapter for the combustion phenomenon.

  The kernel reads the current temperature layer and chunk storage, delegates
  material/state decisions to `SceneServer.Voxel.Phenomenon.Combustion`, then
  returns FieldEffects to the owning chunk authority.
  """

  @behaviour SceneServer.Voxel.Field.Kernel

  alias SceneServer.Voxel.Field.{FieldLayer, FieldRegion, KernelContext}

  alias SceneServer.Voxel.Field.Kernels.{
    MoistureDiffusionKernel,
    OxygenDiffusionKernel,
    SmokeDiffusionKernel,
    TemperatureDiffusionKernel
  }

  alias SceneServer.Voxel.Phenomenon.Combustion
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.Types

  @default_boundary_radius 4
  @default_boundary_max_ticks 60
  @default_owner_radius 4
  @default_owner_max_ticks 30

  @impl true
  def kernel_id, do: :combustion

  @impl true
  def required_layers(_opts), do: [:temperature]

  @impl true
  def tick(%FieldRegion{} = region, %KernelContext{storage: %Storage{} = storage} = context, opts) do
    storage = Storage.ensure_accel(storage)
    temperature_layer = FieldRegion.get_layer(region, :temperature)

    results =
      region
      |> candidate_indices(temperature_layer, storage)
      |> Enum.map(fn macro_index ->
        Combustion.evaluate(
          storage,
          macro_index,
          FieldLayer.get(temperature_layer, macro_index),
          opts
          |> opts_map()
          |> Map.put(:dt_seconds, max(context.dt_ms, 1) / 1000.0)
          |> Map.put(:environment, field_environment(region, macro_index))
        )
      end)
      |> Enum.reject(&(&1 == :ignore))

    combustion_source_points = Enum.flat_map(results, &combustion_field_source_points/1)
    heat_source_points = Enum.filter(combustion_source_points, &(field_type(&1) == :temperature))
    owner_handoff? = owner_handoff_after_tick?(region)

    next_region = %{
      region
      | source_points:
          non_combustion_source_points(region.source_points) ++
            retained_combustion_source_points(
              region.source_points,
              combustion_source_points,
              owner_handoff?
            )
    }

    effects =
      Enum.flat_map(results, & &1.effects) ++
        combustion_owner_effects(
          region,
          heat_source_points,
          context,
          opts_map(opts),
          owner_handoff?
        ) ++
        boundary_heat_effects(region, heat_source_points, context, opts_map(opts))

    {:cont, next_region, effects}
  end

  def tick(%FieldRegion{} = region, %KernelContext{}, _opts), do: {:cont, region, []}

  defp candidate_indices(%FieldRegion{} = region, %FieldLayer{} = temperature_layer, storage) do
    active_temperature_indices =
      temperature_layer
      |> FieldLayer.active_cells(region.aabb, 0)
      |> Enum.map(&elem(&1, 0))

    source_indices =
      region.source_points
      |> Enum.filter(fn source_point ->
        field_type(source_point) == :temperature and
          FieldRegion.in_aabb?(region, Types.macro_coord!(source_point.macro_index))
      end)
      |> Enum.map(& &1.macro_index)

    active_combustion_indices =
      region.aabb
      |> aabb_indices()
      |> Enum.filter(fn macro_index ->
        Storage.normal_block_at(storage, macro_index) != nil and
          read_combustion_stage(storage, macro_index) in [
            Combustion.stage_preheat(),
            Combustion.stage_burning(),
            Combustion.stage_smoldering()
          ]
      end)

    (active_temperature_indices ++ source_indices ++ active_combustion_indices)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp aabb_indices({{min_x, min_y, min_z}, {max_x, max_y, max_z}}) do
    for x <- min_x..max_x,
        y <- min_y..max_y,
        z <- min_z..max_z do
      Types.macro_index!({x, y, z})
    end
  end

  defp read_combustion_stage(storage, macro_index) do
    Storage.effective_attribute_at_normalized(storage, macro_index, "combustion_stage")
  rescue
    _exception in [ArgumentError, FunctionClauseError] -> Combustion.stage_idle()
  end

  defp combustion_field_source_points(%{field_source_points: field_source_points})
       when is_list(field_source_points) do
    field_source_points
  end

  defp combustion_field_source_points(%{heat_source_points: heat_source_points})
       when is_list(heat_source_points) do
    heat_source_points
  end

  defp combustion_field_source_points(_result), do: []

  defp non_combustion_source_points(source_points) do
    Enum.reject(source_points, fn source_point ->
      source_kind(source_point) in [:combustion, "combustion"]
    end)
  end

  defp retained_combustion_source_points(_existing_source_points, next_source_points, false) do
    next_source_points
  end

  defp retained_combustion_source_points(existing_source_points, next_source_points, true) do
    owned_indices =
      existing_source_points
      |> Enum.filter(fn source_point ->
        field_type(source_point) == :temperature and
          source_kind(source_point) in [:combustion, "combustion"]
      end)
      |> Enum.map(& &1.macro_index)
      |> MapSet.new()

    Enum.filter(next_source_points, fn source_point ->
      MapSet.member?(owned_indices, source_point.macro_index)
    end)
  end

  defp boundary_heat_effects(
         %FieldRegion{} = region,
         source_points,
         %KernelContext{} = context,
         opts
       ) do
    source_points
    |> Enum.filter(fn source_point ->
      field_type(source_point) == :temperature and
        source_kind(source_point) in [:combustion, "combustion"]
    end)
    |> Enum.flat_map(fn source_point ->
      source_point.macro_index
      |> Types.macro_coord!()
      |> boundary_targets(region.chunk_coord)
      |> Enum.map(fn {target_chunk_coord, target_local_macro, face} ->
        target_macro_index = Types.macro_index!(target_local_macro)

        {:ensure_field_region,
         %{
           target_chunk_coord: target_chunk_coord,
           aabb: local_aabb_around(target_local_macro, boundary_radius(opts)),
           kernels: boundary_kernel_specs(region, opts),
           source_points: [
             %{
               macro_index: target_macro_index,
               field_type: :temperature,
               source_mode: :persistent,
               source_kind: :combustion_boundary,
               value: source_point.value * 1.0
             }
           ],
           source_points_mode: :replace,
           source_key:
             boundary_source_key(
               context.logical_scene_id,
               region.chunk_coord,
               source_point.macro_index,
               target_chunk_coord,
               target_macro_index
             ),
           max_ticks: boundary_max_ticks(opts),
           reason: :combustion_boundary_heat,
           source_chunk_coord: region.chunk_coord,
           source_macro_index: source_point.macro_index,
           source_world_macro:
             world_macro_coord(region.chunk_coord, Types.macro_coord!(source_point.macro_index)),
           target_macro_index: target_macro_index,
           target_world_macro: world_macro_coord(target_chunk_coord, target_local_macro),
           boundary_face: face,
           source_value: source_point.value * 1.0
         }}
      end)
    end)
  end

  defp combustion_owner_effects(
         %FieldRegion{} = region,
         source_points,
         %KernelContext{} = context,
         opts,
         true
       ) do
    source_points
    |> Enum.filter(fn source_point ->
      field_type(source_point) == :temperature and
        source_kind(source_point) in [:combustion, "combustion"]
    end)
    |> Enum.map(fn source_point ->
      source_macro = Types.macro_coord!(source_point.macro_index)

      {:ensure_field_region,
       %{
         target_chunk_coord: region.chunk_coord,
         aabb: local_aabb_around(source_macro, owner_radius(opts)),
         kernels: owner_kernel_specs(region, opts),
         source_points: [
           %{
             macro_index: source_point.macro_index,
             field_type: :temperature,
             source_mode: :persistent,
             source_kind: :combustion,
             value: source_point.value * 1.0
           }
         ],
         source_points_mode: :replace,
         source_key:
           combustion_owner_source_key(
             context.logical_scene_id,
             region.chunk_coord,
             source_point.macro_index
           ),
         max_ticks: owner_max_ticks(opts),
         reason: :combustion_self_heat,
         source_chunk_coord: region.chunk_coord,
         source_macro_index: source_point.macro_index,
         source_world_macro: world_macro_coord(region.chunk_coord, source_macro),
         source_value: source_point.value * 1.0
       }}
    end)
  end

  defp combustion_owner_effects(
         %FieldRegion{},
         _source_points,
         %KernelContext{},
         _opts,
         false
       ),
       do: []

  defp boundary_targets({x, y, z}, {cx, cy, cz}) do
    max_local = Types.chunk_size_in_macro() - 1

    []
    |> maybe_boundary_target(x == 0, {cx - 1, cy, cz}, {max_local, y, z}, :x_neg)
    |> maybe_boundary_target(x == max_local, {cx + 1, cy, cz}, {0, y, z}, :x_pos)
    |> maybe_boundary_target(y == 0, {cx, cy - 1, cz}, {x, max_local, z}, :y_neg)
    |> maybe_boundary_target(y == max_local, {cx, cy + 1, cz}, {x, 0, z}, :y_pos)
    |> maybe_boundary_target(z == 0, {cx, cy, cz - 1}, {x, y, max_local}, :z_neg)
    |> maybe_boundary_target(z == max_local, {cx, cy, cz + 1}, {x, y, 0}, :z_pos)
  end

  defp maybe_boundary_target(acc, true, target_chunk_coord, target_local_macro, face) do
    [{target_chunk_coord, target_local_macro, face} | acc]
  end

  defp maybe_boundary_target(acc, false, _target_chunk_coord, _target_local_macro, _face),
    do: acc

  defp boundary_kernel_specs(%FieldRegion{} = region, opts) do
    [
      temperature_kernel_spec(region),
      %{
        id: :combustion,
        module: __MODULE__,
        opts:
          Map.drop(opts, [
            :boundary_radius,
            "boundary_radius",
            :boundary_max_ticks,
            "boundary_max_ticks"
          ])
      },
      smoke_kernel_spec(region),
      oxygen_kernel_spec(region),
      moisture_kernel_spec(region)
    ]
  end

  defp owner_kernel_specs(%FieldRegion{} = region, opts) do
    [
      temperature_kernel_spec(region),
      %{
        id: :combustion,
        module: __MODULE__,
        opts:
          Map.drop(opts, [
            :owner_radius,
            "owner_radius",
            :owner_max_ticks,
            "owner_max_ticks"
          ])
      },
      smoke_kernel_spec(region),
      oxygen_kernel_spec(region),
      moisture_kernel_spec(region)
    ]
  end

  defp temperature_kernel_spec(%FieldRegion{} = region) do
    Enum.find(region.kernels, fn
      %{id: :temperature_diffusion} -> true
      %{module: TemperatureDiffusionKernel} -> true
      _other -> false
    end) ||
      %{
        id: :temperature_diffusion,
        module: TemperatureDiffusionKernel,
        opts: %{diffusion_time_scale: 1.0, ambient_loss_per_second: 0.0, cell_size_meters: 1.0}
      }
  end

  defp smoke_kernel_spec(%FieldRegion{} = region) do
    Enum.find(region.kernels, fn
      %{id: :smoke_diffusion} -> true
      %{module: SmokeDiffusionKernel} -> true
      _other -> false
    end) ||
      %{
        id: :smoke_diffusion,
        module: SmokeDiffusionKernel,
        opts: %{diffusion_alpha: 0.18, decay_per_second: 0.08}
      }
  end

  defp oxygen_kernel_spec(%FieldRegion{} = region) do
    Enum.find(region.kernels, fn
      %{id: :oxygen_diffusion} -> true
      %{module: OxygenDiffusionKernel} -> true
      _other -> false
    end) ||
      %{
        id: :oxygen_diffusion,
        module: OxygenDiffusionKernel,
        opts: %{diffusion_alpha: 0.12, decay_per_second: 0.04}
      }
  end

  defp moisture_kernel_spec(%FieldRegion{} = region) do
    Enum.find(region.kernels, fn
      %{id: :moisture_diffusion} -> true
      %{module: MoistureDiffusionKernel} -> true
      _other -> false
    end) ||
      %{
        id: :moisture_diffusion,
        module: MoistureDiffusionKernel,
        opts: %{diffusion_alpha: 0.10, decay_per_second: 0.06}
      }
  end

  defp boundary_source_key(
         logical_scene_id,
         source_chunk_coord,
         source_macro_index,
         target_chunk_coord,
         target_macro_index
       ) do
    {:combustion_boundary_heat, logical_scene_id, source_chunk_coord, source_macro_index,
     target_chunk_coord, target_macro_index}
  end

  defp combustion_owner_source_key(logical_scene_id, chunk_coord, macro_index) do
    {:combustion_instance, logical_scene_id, chunk_coord, macro_index}
  end

  defp local_aabb_around({x, y, z}, radius) do
    {{clamp_macro(x - radius), clamp_macro(y - radius), clamp_macro(z - radius)},
     {clamp_macro(x + radius), clamp_macro(y + radius), clamp_macro(z + radius)}}
  end

  defp clamp_macro(value) when value < 0, do: 0
  defp clamp_macro(value) when value > 15, do: 15
  defp clamp_macro(value), do: value

  defp world_macro_coord({cx, cy, cz}, {x, y, z}) do
    size = Types.chunk_size_in_macro()
    {cx * size + x, cy * size + y, cz * size + z}
  end

  defp boundary_radius(opts) do
    non_negative_int(get_opt(opts, :boundary_radius, @default_boundary_radius))
  end

  defp boundary_max_ticks(opts) do
    non_negative_int(get_opt(opts, :boundary_max_ticks, @default_boundary_max_ticks))
  end

  defp owner_handoff_after_tick?(%FieldRegion{max_ticks: nil}), do: false

  defp owner_handoff_after_tick?(%FieldRegion{tick_count: tick_count, max_ticks: max_ticks}) do
    is_integer(max_ticks) and max_ticks >= 0 and tick_count + 1 >= max_ticks
  end

  defp owner_radius(opts) do
    non_negative_int(get_opt(opts, :owner_radius, @default_owner_radius))
  end

  defp owner_max_ticks(opts) do
    non_negative_int(get_opt(opts, :owner_max_ticks, @default_owner_max_ticks))
  end

  defp field_type(source_point) do
    Map.get(source_point, :field_type, Map.get(source_point, "field_type"))
  end

  defp source_kind(source_point) do
    Map.get(source_point, :source_kind, Map.get(source_point, "source_kind"))
  end

  defp field_environment(%FieldRegion{} = region, macro_index) do
    %{}
    |> maybe_put_field_value(region, :oxygen, macro_index, :oxygen_percent)
    |> maybe_put_field_value(region, :moisture, macro_index, :moisture_kg_per_m3)
  end

  defp maybe_put_field_value(environment, %FieldRegion{} = region, field_type, macro_index, key) do
    if field_type in region.field_types do
      layer = FieldRegion.get_layer(region, field_type)

      if abs(FieldLayer.get_delta(layer, macro_index)) >= layer.threshold do
        Map.put(environment, key, FieldLayer.get(layer, macro_index))
      else
        environment
      end
    else
      environment
    end
  end

  defp opts_map(opts) when is_map(opts), do: opts
  defp opts_map(_opts), do: %{}

  defp get_opt(opts, key, default) do
    cond do
      Map.has_key?(opts, key) -> Map.fetch!(opts, key)
      Map.has_key?(opts, Atom.to_string(key)) -> Map.fetch!(opts, Atom.to_string(key))
      true -> default
    end
  end

  defp non_negative_int(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_int(value) when is_float(value) and value >= 0.0, do: trunc(value)
  defp non_negative_int(_value), do: 0
end
