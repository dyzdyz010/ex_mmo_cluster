defmodule SceneServer.Voxel.Phenomenon.PhaseChangeKernel do
  @moduledoc """
  Field-kernel adapter for contained-moisture phase changes.

  The kernel reads the temperature layer, delegates the per-cell decision to
  `SceneServer.Voxel.Phenomenon.PhaseChange`, and keeps released vapor inside
  the field source lifecycle for `MoistureDiffusionKernel`.
  """

  @behaviour SceneServer.Voxel.Field.Kernel

  alias SceneServer.Voxel.Field.{FieldLayer, FieldRegion, KernelContext}
  alias SceneServer.Voxel.Phenomenon.PhaseChange
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.Types

  @impl true
  def kernel_id, do: :phase_change

  @impl true
  def required_layers(_opts), do: [:temperature, :moisture]

  @impl true
  def tick(%FieldRegion{} = region, %KernelContext{storage: %Storage{} = storage} = context, opts) do
    storage = Storage.ensure_accel(storage)
    temperature_layer = FieldRegion.get_layer(region, :temperature)

    results =
      region
      |> candidate_indices(temperature_layer, storage)
      |> Enum.map(fn macro_index ->
        PhaseChange.evaluate(
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

    phase_source_points = Enum.flat_map(results, &phase_field_source_points/1)

    next_region = %{
      region
      | source_points: non_phase_change_source_points(region.source_points) ++ phase_source_points
    }

    effects = Enum.flat_map(results, & &1.effects)

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
          FieldRegion.in_aabb?(region, Types.macro_coord!(macro_index(source_point)))
      end)
      |> Enum.map(&macro_index/1)

    wet_or_phase_indices =
      region.aabb
      |> aabb_indices()
      |> Enum.filter(fn macro_index ->
        Storage.normal_block_at(storage, macro_index) != nil and
          (read_moisture(storage, macro_index) > 0.0 or
             read_phase_state(storage, macro_index) != PhaseChange.phase_stable())
      end)

    (active_temperature_indices ++ source_indices ++ wet_or_phase_indices)
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

  defp phase_field_source_points(%{field_source_points: field_source_points})
       when is_list(field_source_points) do
    field_source_points
  end

  defp phase_field_source_points(_result), do: []

  defp non_phase_change_source_points(source_points) do
    Enum.reject(source_points, fn source_point ->
      source_kind(source_point) in [:phase_change, "phase_change"]
    end)
  end

  defp field_environment(%FieldRegion{} = region, macro_index) do
    case field_value(region, :moisture, macro_index) do
      value when is_number(value) -> %{moisture_kg_per_m3: value}
      _other -> %{}
    end
  end

  defp field_value(%FieldRegion{} = region, field_type, macro_index) do
    if field_type in region.field_types do
      layer = FieldRegion.get_layer(region, field_type)

      if abs(FieldLayer.get_delta(layer, macro_index)) >= layer.threshold do
        FieldLayer.get(layer, macro_index)
      end
    end
  end

  defp read_moisture(storage, macro_index) do
    storage
    |> Storage.effective_attribute_at_normalized(macro_index, "moisture")
    |> Kernel./(65_536)
  rescue
    _exception in [ArgumentError, FunctionClauseError] -> 0.0
  end

  defp read_phase_state(storage, macro_index) do
    Storage.effective_attribute_at_normalized(storage, macro_index, "phase_state")
  rescue
    _exception in [ArgumentError, FunctionClauseError] -> PhaseChange.phase_stable()
  end

  defp field_type(source_point) do
    Map.get(source_point, :field_type, Map.get(source_point, "field_type"))
  end

  defp source_kind(source_point) do
    Map.get(source_point, :source_kind, Map.get(source_point, "source_kind"))
  end

  defp macro_index(source_point) do
    Map.get(source_point, :macro_index, Map.get(source_point, "macro_index"))
  end

  defp opts_map(opts) when is_map(opts), do: opts
  defp opts_map(opts) when is_list(opts), do: Map.new(opts)
  defp opts_map(_opts), do: %{}
end
