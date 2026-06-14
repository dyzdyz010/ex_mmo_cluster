defmodule SceneServer.Voxel.Field.NativeBackend.TemperatureDiffusionInput do
  @moduledoc """
  Native DTO encoder for sparse temperature diffusion ticks.

  **梯队2 step2.7c(BND-1)**:场层本体已迁入 Rust `ResourceArc<FieldLayerSim>`,扩散 NIF
  (`diffuse_temperature_sim`)直读句柄的 active 缓冲,故本 DTO **不再序列化 layer cells**——只冻结
  candidate cells、AABB、per-candidate 热材料事实(来自 storage)与时间参数。
  """

  alias SceneServer.Voxel.Storage

  @default_tc_raw 6_554
  @default_density_raw 65_536
  @default_specific_heat_capacity_raw 65_536_000

  defstruct candidates: [],
            aabb: {{0, 0, 0}, {0, 0, 0}},
            thermal_properties: [],
            diffusion_seconds: 0.1,
            ambient_dt_seconds: 0.1,
            ambient_loss_per_second: 0.0,
            cell_size_meters: 1.0

  @type thermal_properties :: {0..4095, integer(), integer(), integer()}
  @type t :: %__MODULE__{
          candidates: [0..4095],
          aabb: {{0..15, 0..15, 0..15}, {0..15, 0..15, 0..15}},
          thermal_properties: [thermal_properties()],
          diffusion_seconds: float(),
          ambient_dt_seconds: float(),
          ambient_loss_per_second: float(),
          cell_size_meters: float()
        }

  @spec new(
          {{0..15, 0..15, 0..15}, {0..15, 0..15, 0..15}},
          [0..4095],
          Storage.t() | nil,
          number(),
          number(),
          number(),
          number()
        ) :: t()
  def new(
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
      candidates: candidates,
      aabb: aabb,
      thermal_properties: thermal_properties(candidates, storage),
      diffusion_seconds: diffusion_seconds * 1.0,
      ambient_dt_seconds: ambient_dt_seconds * 1.0,
      ambient_loss_per_second: ambient_loss_per_second * 1.0,
      cell_size_meters: cell_size_meters * 1.0
    }
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
