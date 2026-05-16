defmodule SceneServer.Voxel.Field.FieldRuntime do
  @moduledoc """
  Runtime entrypoint for turning abnormal voxel attributes into local fields.

  Normal environment values stay on voxel storage and do not allocate a
  `FieldRegion`.  A skill/request may mutate the authoritative voxel
  attribute, but anomaly detection always reads the post-write voxel truth
  before creating any local field.
  """

  alias SceneServer.Voxel.{ChunkDirectory, ChunkProcess, Storage, Types}
  alias SceneServer.Voxel.Field.Kernels.TemperatureDiffusionKernel
  alias SceneServer.Voxel.Field.TemperatureField

  @default_logical_scene_id 1
  @default_max_ticks 600
  @default_radius 4
  @default_target_temperature_celsius 800.0
  @temperature_diffusion_time_scale 1.0
  @temperature_ambient_loss_per_second 0.0
  @temperature_cell_size_meters 1.0
  @temperature_threshold 1.0
  @fixed32_scale 65_536

  @doc """
  Injects the requested heat skill into voxel attributes, then creates a local
  temperature `FieldRegion` only if the voxel's effective temperature is
  abnormal relative to the environment baseline.
  """
  @spec ensure_temperature_anomaly(keyword() | map()) :: {:ok, map()} | {:error, term()}
  def ensure_temperature_anomaly(opts \\ []) do
    opts = opts_map(opts)

    logical_scene_id =
      non_negative_int(get_any(opts, [:logical_scene_id], @default_logical_scene_id))

    world_macro = world_macro_coord(opts)
    {chunk_coord, local_macro} = Types.chunk_and_local_macro!(world_macro)

    heat_request = heat_request(opts)

    with {:ok, chunk_pid} <-
           ChunkDirectory.ensure_chunk(%{
             logical_scene_id: logical_scene_id,
             chunk_coord: chunk_coord
           }),
         {:ok, %{storage: %Storage{} = storage} = write_summary} <-
           write_temperature_request(chunk_pid, local_macro, heat_request) do
      anomaly_opts =
        opts
        |> Map.put(:logical_scene_id, logical_scene_id)
        |> Map.put(:world_macro, world_macro)
        |> Map.put(:storage, storage)

      case build_temperature_anomaly(anomaly_opts) do
        {:ignore, summary} ->
          {:ok, Map.put(summary, :attribute_write, summarize_attribute_write(write_summary))}

        {:ok, plan} ->
          region_attrs = Map.put(plan.region_attrs, :source_key, plan.source_key)

          with {:ok, field_region} <- ChunkProcess.ensure_field_region(chunk_pid, region_attrs) do
            {:ok,
             plan.summary
             |> Map.put(:region_id, field_region.region_id)
             |> Map.put(:field_region_created, field_region.created?)
             |> Map.put(:attribute_write, summarize_attribute_write(write_summary))}
          end
      end
    end
  rescue
    error -> {:error, {:temperature_anomaly_failed, error}}
  catch
    kind, reason -> {:error, {:temperature_anomaly_failed, kind, reason}}
  end

  @doc """
  Builds the deterministic field plan from authoritative voxel storage without
  touching the process registry.  This is the pure, testable half of the
  runtime.
  """
  @spec build_temperature_anomaly(keyword() | map()) :: {:ok, map()} | {:ignore, map()}
  def build_temperature_anomaly(opts \\ []) do
    opts = opts_map(opts)

    logical_scene_id =
      non_negative_int(get_any(opts, [:logical_scene_id], @default_logical_scene_id))

    baseline_temperature = TemperatureField.env_temperature() * 1.0
    storage = storage!(get_any(opts, [:storage], nil))
    world_macro = world_macro_coord(opts)
    {chunk_coord, local_macro} = Types.chunk_and_local_macro!(world_macro)
    source_index = Types.macro_index!(local_macro)
    target_temperature = voxel_temperature(storage, source_index)
    anomaly_delta = target_temperature - baseline_temperature

    summary =
      base_summary(
        logical_scene_id,
        world_macro,
        chunk_coord,
        local_macro,
        baseline_temperature,
        target_temperature,
        anomaly_delta
      )

    if abs(anomaly_delta) < @temperature_threshold do
      {:ignore,
       summary
       |> Map.put(:created, false)
       |> Map.put(:reason, :temperature_within_environment_threshold)}
    else
      max_ticks = non_negative_int(get_any(opts, [:max_ticks], @default_max_ticks))
      radius = non_negative_int(get_any(opts, [:radius], @default_radius))
      aabb = local_aabb_around(local_macro, radius)

      region_attrs = %{
        chunk_coord: chunk_coord,
        aabb: aabb,
        kernels: [
          %{
            id: :temperature_diffusion,
            module: TemperatureDiffusionKernel,
            opts: physical_temperature_kernel_opts()
          }
        ],
        source_points: [
          %{
            macro_index: source_index,
            field_type: :temperature,
            source_mode: :impulse,
            value: target_temperature
          }
        ],
        max_ticks: max_ticks
      }

      {:ok,
       %{
         logical_scene_id: logical_scene_id,
         chunk_coord: chunk_coord,
         local_macro: local_macro,
         source_index: source_index,
         source_key: {:temperature, source_index},
         region_attrs: region_attrs,
         summary:
           summary
           |> Map.put(:created, true)
           |> Map.put(:field_types, ["temperature"])
           |> Map.put(:radius, radius)
           |> Map.put(:max_ticks, max_ticks)
       }}
    end
  end

  @doc "Returns the default heat-skill target temperature in Celsius."
  @spec default_target_temperature_celsius() :: float()
  def default_target_temperature_celsius, do: @default_target_temperature_celsius

  @doc "Converts a Celsius value into the storage catalog Q16.16 raw value."
  @spec celsius_to_raw(number()) :: integer()
  def celsius_to_raw(value) when is_integer(value) or is_float(value) do
    round(value * @fixed32_scale)
  end

  @doc "Converts a storage catalog Q16.16 raw value into Celsius."
  @spec raw_to_celsius(integer()) :: float()
  def raw_to_celsius(value) when is_integer(value), do: value / @fixed32_scale

  defp physical_temperature_kernel_opts do
    %{
      diffusion_time_scale: @temperature_diffusion_time_scale,
      ambient_loss_per_second: @temperature_ambient_loss_per_second,
      cell_size_meters: @temperature_cell_size_meters
    }
  end

  defp base_summary(
         logical_scene_id,
         world_macro,
         chunk_coord,
         local_macro,
         baseline_temperature,
         target_temperature,
         anomaly_delta
       ) do
    %{
      created: true,
      logical_scene_id: logical_scene_id,
      world_macro: coord_map(world_macro),
      chunk_coord: coord_map(chunk_coord),
      local_macro: coord_map(local_macro),
      baseline_temperature: baseline_temperature,
      target_temperature: target_temperature,
      anomaly_delta: anomaly_delta
    }
  end

  defp world_macro_coord(opts) do
    cond do
      has_any_key?(opts, [:world_macro]) ->
        Types.normalize_world_micro_coord!(get_any(opts, [:world_macro], nil))

      has_axis_keys?(opts, [:x, :y, :z]) ->
        Types.normalize_world_micro_coord!(
          {get_any(opts, [:x], 0), get_any(opts, [:y], 0), get_any(opts, [:z], 0)}
        )

      has_any_key?(opts, [:chunk_coord]) ->
        world_macro_from_chunk(get_any(opts, [:chunk_coord], {0, 0, 0}))

      true ->
        {0, 0, 0}
    end
  end

  defp world_macro_from_chunk(chunk_coord) do
    {cx, cy, cz} = Types.normalize_chunk_coord!(chunk_coord)
    size = Types.chunk_size_in_macro()
    centre = div(size, 2) - 1
    {cx * size + centre, cy * size + centre, cz * size + centre}
  end

  defp storage!(%Storage{} = storage), do: Storage.normalize!(storage)

  defp storage!(nil) do
    raise ArgumentError,
          "build_temperature_anomaly requires :storage; anomaly detection must read voxel truth"
  end

  defp storage!(storage) when is_map(storage), do: Storage.normalize!(storage)

  defp voxel_temperature(%Storage{} = storage, source_index) do
    storage
    |> Storage.effective_attribute_at(source_index, "temperature")
    |> raw_to_celsius()
  end

  defp heat_request(opts) do
    cond do
      has_any_key?(opts, [:target_temperature, :target_temperature_celsius]) ->
        {:target_temperature,
         temperature_float(
           get_any(opts, [:target_temperature, :target_temperature_celsius], nil),
           @default_target_temperature_celsius
         )}

      has_any_key?(opts, [:heat_energy_joules]) ->
        {:heat_energy_joules, non_negative_float(get_any(opts, [:heat_energy_joules], 0.0))}

      true ->
        {:target_temperature, @default_target_temperature_celsius}
    end
  end

  defp write_temperature_request(
         chunk_pid,
         local_macro,
         {:target_temperature, target_temperature}
       ) do
    ChunkProcess.write_temperature_attribute(chunk_pid, %{
      macro: local_macro,
      target_temperature: target_temperature
    })
  end

  defp write_temperature_request(
         chunk_pid,
         local_macro,
         {:heat_energy_joules, heat_energy_joules}
       ) do
    ChunkProcess.add_heat_energy_attribute(chunk_pid, %{
      macro: local_macro,
      heat_energy_joules: heat_energy_joules
    })
  end

  defp summarize_attribute_write(summary) when is_map(summary) do
    Map.take(summary, [
      :changed?,
      :macro_index,
      :heat_energy_joules,
      :density,
      :specific_heat_capacity,
      :heat_capacity_j_per_k,
      :previous_temperature,
      :temperature_delta,
      :target_temperature,
      :target_temperature_raw,
      :attribute_delta_raw,
      :effective_temperature,
      :effective_temperature_raw,
      :chunk_version
    ])
  end

  defp local_aabb_around({x, y, z}, radius) do
    {{clamp_macro(x - radius), clamp_macro(y - radius), clamp_macro(z - radius)},
     {clamp_macro(x + radius), clamp_macro(y + radius), clamp_macro(z + radius)}}
  end

  defp clamp_macro(value) when value < 0, do: 0
  defp clamp_macro(value) when value > 15, do: 15
  defp clamp_macro(value), do: value

  defp opts_map(opts) when is_list(opts), do: Map.new(opts)
  defp opts_map(opts) when is_map(opts), do: opts

  defp get_any(map, keys, default) do
    Enum.find_value(keys, fn key ->
      cond do
        Map.has_key?(map, key) -> {:found, Map.fetch!(map, key)}
        Map.has_key?(map, Atom.to_string(key)) -> {:found, Map.fetch!(map, Atom.to_string(key))}
        true -> nil
      end
    end)
    |> case do
      {:found, value} -> value
      nil -> default
    end
  end

  defp has_any_key?(map, keys) do
    Enum.any?(keys, fn key ->
      Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))
    end)
  end

  defp has_axis_keys?(map, keys) do
    Enum.all?(keys, fn key ->
      Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key))
    end)
  end

  defp coord_map({x, y, z}), do: %{x: x, y: y, z: z}

  defp non_negative_int(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_int(value) when is_float(value) and value >= 0, do: trunc(value)

  defp non_negative_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _other -> 0
    end
  end

  defp non_negative_int(_value), do: 0

  defp non_negative_float(value) when is_integer(value) and value >= 0, do: value * 1.0
  defp non_negative_float(value) when is_float(value) and value >= 0, do: value

  defp non_negative_float(value) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _other -> 0.0
    end
  end

  defp non_negative_float(_value), do: 0.0

  defp temperature_float(value, _fallback) when is_integer(value), do: value * 1.0
  defp temperature_float(value, _fallback) when is_float(value), do: value

  defp temperature_float(value, fallback) when is_binary(value) do
    case Float.parse(value) do
      {parsed, ""} -> parsed
      _other -> fallback
    end
  end

  defp temperature_float(_value, fallback), do: fallback
end
