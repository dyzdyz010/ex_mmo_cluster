defmodule SceneServer.Voxel.Phenomenon.CorrosionKernel do
  @moduledoc """
  Field-kernel adapter for material corrosion.

  Corrosion is currently driven by voxel truth (`moisture` and
  `chemical_concentration`) instead of a transported chemical field. The kernel
  scans its AABB, delegates per-cell state changes to `Corrosion`, and returns
  structured effects to the chunk authority.
  """

  @behaviour SceneServer.Voxel.Field.Kernel

  alias SceneServer.Voxel.Field.{FieldRegion, KernelContext}
  alias SceneServer.Voxel.MaterialCatalog
  alias SceneServer.Voxel.Phenomenon.Corrosion
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.Types

  @fixed32_scale 65_536

  @impl true
  def kernel_id, do: :corrosion

  @impl true
  def required_layers(_opts), do: []

  @impl true
  def tick(%FieldRegion{} = region, %KernelContext{storage: %Storage{} = storage} = context, opts) do
    storage = Storage.ensure_accel(storage)

    results =
      region
      |> candidate_indices(storage)
      |> Enum.map(fn macro_index ->
        Corrosion.evaluate(
          storage,
          macro_index,
          opts
          |> opts_map()
          |> Map.put(:dt_seconds, max(context.dt_ms, 1) / 1000.0)
        )
      end)
      |> Enum.reject(&(&1 == :ignore))

    {:cont, region, Enum.flat_map(results, & &1.effects)}
  end

  def tick(%FieldRegion{} = region, %KernelContext{}, _opts), do: {:cont, region, []}

  defp candidate_indices(%FieldRegion{} = region, storage) do
    region.aabb
    |> aabb_indices()
    |> Enum.filter(fn macro_index ->
      case Storage.normal_block_at(storage, macro_index) do
        nil ->
          false

        block ->
          MaterialCatalog.corrosion_profile(block.material_id) != nil and
            (read_float(storage, macro_index, "chemical_concentration", 0.0) > 0.0 or
               read_float(storage, macro_index, "corrosion", 0.0) > 0.0 or
               read_int(storage, macro_index, "surface_state", Corrosion.surface_clean()) !=
                 Corrosion.surface_clean())
      end
    end)
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

  defp read_float(storage, macro_index, attr_name, fallback) do
    storage
    |> Storage.effective_attribute_at_normalized(macro_index, attr_name)
    |> Kernel./(@fixed32_scale)
  rescue
    _exception in [ArgumentError, FunctionClauseError] -> fallback
  end

  defp read_int(storage, macro_index, attr_name, fallback) do
    Storage.effective_attribute_at_normalized(storage, macro_index, attr_name)
  rescue
    _exception in [ArgumentError, FunctionClauseError] -> fallback
  end

  defp opts_map(opts) when is_map(opts), do: opts
  defp opts_map(opts) when is_list(opts), do: Map.new(opts)
  defp opts_map(_opts), do: %{}
end
