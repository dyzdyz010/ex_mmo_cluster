defmodule SceneServer.Voxel.Field.NativeBackend.DischargePathInput do
  @moduledoc """
  Native DTO encoder for dielectric-breakdown discharge path search.

  Discharge can traverse empty dielectric cells, so unlike conductive routing
  this DTO freezes every macro cell in the requested AABB with only the two
  electric attributes needed by the read-only native solver.
  """

  alias SceneServer.Voxel.Field.FieldLayer
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.Types

  @fixed32_scale 65_536.0

  defstruct cells: [],
            aabb: {{0, 0, 0}, {0, 0, 0}},
            source_macro_index: 0,
            target_macro_index: 0,
            source_value: 0.0,
            ionization_cells: [],
            max_frontier: 1

  @type cell :: {0..4095, float(), float()}
  @type aabb :: {{0..15, 0..15, 0..15}, {0..15, 0..15, 0..15}}
  @type t :: %__MODULE__{
          cells: [cell()],
          aabb: aabb(),
          source_macro_index: 0..4095,
          target_macro_index: 0..4095,
          source_value: float(),
          ionization_cells: [{0..4095, float()}],
          max_frontier: pos_integer()
        }

  @spec new(Storage.t(), aabb(), 0..4095, 0..4095, number(), FieldLayer.t(), pos_integer()) ::
          t()
  def new(
        %Storage{} = storage,
        aabb,
        source_macro_index,
        target_macro_index,
        source_value,
        %FieldLayer{} = ionization_layer,
        max_frontier
      ) do
    storage = Storage.normalize!(storage)

    %__MODULE__{
      cells: electric_cells(storage, aabb),
      aabb: aabb,
      source_macro_index: source_macro_index,
      target_macro_index: target_macro_index,
      source_value: source_value * 1.0,
      ionization_cells: ionization_cells(ionization_layer, aabb),
      max_frontier: max(max_frontier, 1)
    }
  end

  defp electric_cells(%Storage{} = storage, {{min_x, min_y, min_z}, {max_x, max_y, max_z}}) do
    for x <- min_x..max_x, y <- min_y..max_y, z <- min_z..max_z do
      macro_index = Types.macro_index!({x, y, z})

      {
        macro_index,
        electric_attribute(storage, macro_index, "electric_conductivity"),
        electric_attribute(storage, macro_index, "dielectric_strength")
      }
    end
  end

  defp electric_attribute(%Storage{} = storage, macro_index, attr_name) do
    storage
    |> Storage.effective_attribute_at_normalized(macro_index, attr_name)
    |> Kernel./(@fixed32_scale)
  end

  defp ionization_cells(%FieldLayer{} = ionization_layer, aabb) do
    ionization_layer
    |> FieldLayer.active_cells(aabb, 0)
    |> Enum.map(fn {macro_index, value} -> {macro_index, value * 1.0} end)
  end
end
