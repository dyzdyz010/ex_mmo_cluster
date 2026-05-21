defmodule SceneServer.Voxel.Field.NativeBackend.TemperatureDiffusionInput do
  @moduledoc """
  Native DTO encoder for sparse temperature diffusion ticks.

  The Elixir Field layer keeps source lifecycle and layer ownership. This module
  freezes one deterministic compute request for the native temperature diffusion
  kernel: current sparse deltas, candidate cells, AABB, and per-candidate thermal
  material facts.
  """

  alias SceneServer.Voxel.Field.FieldLayer
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.Types

  @default_tc_raw 6_554
  @default_density_raw 65_536
  @default_specific_heat_capacity_raw 65_536_000

  defstruct cells: [],
            candidates: [],
            aabb: {{0, 0, 0}, {0, 0, 0}},
            thermal_properties: [],
            diffusion_seconds: 0.1,
            ambient_dt_seconds: 0.1,
            ambient_loss_per_second: 0.0,
            cell_size_meters: 1.0

  @type cell :: {0..4095, float()}
  @type thermal_properties :: {0..4095, integer(), integer(), integer()}
  @type t :: %__MODULE__{
          cells: [cell()],
          candidates: [0..4095],
          aabb: {{0..15, 0..15, 0..15}, {0..15, 0..15, 0..15}},
          thermal_properties: [thermal_properties()],
          diffusion_seconds: float(),
          ambient_dt_seconds: float(),
          ambient_loss_per_second: float(),
          cell_size_meters: float()
        }

  @spec new(
          FieldLayer.t(),
          {{0..15, 0..15, 0..15}, {0..15, 0..15, 0..15}},
          [0..4095],
          Storage.t() | nil,
          number(),
          number(),
          number(),
          number()
        ) :: t()
  def new(
        %FieldLayer{} = layer,
        aabb,
        candidate_indices,
        storage,
        diffusion_seconds,
        ambient_dt_seconds,
        ambient_loss_per_second,
        cell_size_meters
      ) do
    candidates =
      candidate_indices
      |> Enum.uniq()
      |> Enum.sort()

    %__MODULE__{
      cells: delta_cells(layer, aabb),
      candidates: candidates,
      aabb: aabb,
      thermal_properties: thermal_properties(candidates, storage),
      diffusion_seconds: diffusion_seconds * 1.0,
      ambient_dt_seconds: ambient_dt_seconds * 1.0,
      ambient_loss_per_second: ambient_loss_per_second * 1.0,
      cell_size_meters: cell_size_meters * 1.0
    }
  end

  defp delta_cells(%FieldLayer{} = layer, aabb) do
    layer.values
    |> Enum.filter(fn {macro_index, delta} ->
      in_aabb?(macro_index, aabb) and abs(delta) >= layer.threshold
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {macro_index, delta} -> {macro_index, delta * 1.0} end)
  end

  defp thermal_properties(candidate_indices, storage) do
    Enum.map(candidate_indices, fn macro_index ->
      {
        macro_index,
        read_thermal_conductivity(storage, macro_index),
        read_density(storage, macro_index),
        read_specific_heat_capacity(storage, macro_index)
      }
    end)
  end

  defp in_aabb?(macro_index, {{min_x, min_y, min_z}, {max_x, max_y, max_z}}) do
    {x, y, z} = Types.macro_coord!(macro_index)

    x >= min_x and x <= max_x and y >= min_y and y <= max_y and z >= min_z and z <= max_z
  end

  defp read_thermal_conductivity(nil, _macro_index), do: @default_tc_raw

  defp read_thermal_conductivity(%Storage{} = storage, macro_index) do
    Storage.effective_attribute_at_normalized(storage, macro_index, "thermal_conductivity")
  rescue
    _ -> @default_tc_raw
  end

  defp read_thermal_conductivity(_other, _macro_index), do: @default_tc_raw

  defp read_density(nil, _macro_index), do: @default_density_raw

  defp read_density(%Storage{} = storage, macro_index) do
    Storage.effective_attribute_at_normalized(storage, macro_index, "density")
  rescue
    _ -> @default_density_raw
  end

  defp read_density(_other, _macro_index), do: @default_density_raw

  defp read_specific_heat_capacity(nil, _macro_index), do: @default_specific_heat_capacity_raw

  defp read_specific_heat_capacity(%Storage{} = storage, macro_index) do
    Storage.effective_attribute_at_normalized(storage, macro_index, "specific_heat_capacity")
  rescue
    _ -> @default_specific_heat_capacity_raw
  end

  defp read_specific_heat_capacity(_other, _macro_index), do: @default_specific_heat_capacity_raw
end
