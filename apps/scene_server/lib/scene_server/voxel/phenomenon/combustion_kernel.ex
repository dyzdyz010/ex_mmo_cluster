defmodule SceneServer.Voxel.Phenomenon.CombustionKernel do
  @moduledoc """
  Field-kernel adapter for the combustion phenomenon.

  The kernel reads the current temperature layer and chunk storage, delegates
  material/state decisions to `SceneServer.Voxel.Phenomenon.Combustion`, then
  returns FieldEffects to the owning chunk authority.
  """

  @behaviour SceneServer.Voxel.Field.Kernel

  alias SceneServer.Voxel.Field.{FieldLayer, FieldRegion, KernelContext}
  alias SceneServer.Voxel.Phenomenon.Combustion
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.Types

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
          Map.put(opts_map(opts), :dt_seconds, max(context.dt_ms, 1) / 1000.0)
        )
      end)
      |> Enum.reject(&(&1 == :ignore))

    combustion_source_points = Enum.flat_map(results, & &1.heat_source_points)

    next_region = %{
      region
      | source_points: non_combustion_source_points(region.source_points) ++ combustion_source_points
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

  defp non_combustion_source_points(source_points) do
    Enum.reject(source_points, fn source_point ->
      field_type(source_point) == :temperature and
        source_kind(source_point) in [:combustion, "combustion"]
    end)
  end

  defp field_type(source_point) do
    Map.get(source_point, :field_type, Map.get(source_point, "field_type"))
  end

  defp source_kind(source_point) do
    Map.get(source_point, :source_kind, Map.get(source_point, "source_kind"))
  end

  defp opts_map(opts) when is_map(opts), do: opts
  defp opts_map(_opts), do: %{}
end
