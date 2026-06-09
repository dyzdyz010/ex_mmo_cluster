defmodule SceneServer.Voxel.Phenomenon.CombustionProbe do
  @moduledoc """
  Read-only combustion truth probe for one authoritative macro voxel.

  The probe is intentionally observational: it resolves the owning chunk,
  reads the current storage truth, and summarizes material defaults plus
  dynamic combustion attributes without mutating voxel state or creating field
  regions.
  """

  alias SceneServer.Voxel.{
    ChunkDirectory,
    ChunkProcess,
    MacroCellHeader,
    MaterialCatalog,
    MicroLayer,
    NormalBlockData,
    RefinedCellData,
    Storage,
    Types
  }

  alias SceneServer.Voxel.Phenomenon.{Combustion, Instance}

  @default_logical_scene_id 1
  @fixed32_scale 65_536

  @doc """
  Returns a JSON-safe-ish map describing the combustion state of one world
  macro voxel.

  Options:
    * `:logical_scene_id` - defaults to 1.
    * `:world_macro` - `{x, y, z}` world macro coordinate.
    * `:lease` / `:lease_token` - optional source-owner lease forwarded to the
      chunk directory in multi-node dev runs.
  """
  @spec probe(keyword() | map()) :: {:ok, map()} | {:error, term()}
  def probe(opts \\ []) when is_list(opts) or is_map(opts) do
    opts = opts_map(opts)

    logical_scene_id =
      non_negative_int(get_any(opts, [:logical_scene_id], @default_logical_scene_id))

    world_macro = world_macro_coord(opts)
    {chunk_coord, local_macro} = Types.chunk_and_local_macro!(world_macro)
    macro_index = Types.macro_index!(local_macro)

    with {:ok, chunk_pid} <-
           ChunkDirectory.ensure_chunk(%{
             logical_scene_id: logical_scene_id,
             chunk_coord: chunk_coord,
             lease: get_any(opts, [:lease, :lease_token], nil)
           }) do
      debug_state = ChunkProcess.debug_state(chunk_pid)
      %{storage: %Storage{} = storage} = debug_state
      storage = Storage.ensure_accel(storage)
      header = Storage.macro_header_at(storage, macro_index)
      material_id = material_id_at(storage, macro_index)
      profile = MaterialCatalog.combustion_profile(material_id)
      stage_raw = read_int(storage, macro_index, "combustion_stage", Combustion.stage_idle())
      instance = active_instance_summary(debug_state, logical_scene_id, chunk_coord, macro_index)

      {:ok,
       %{
         logical_scene_id: logical_scene_id,
         world_macro: coord_map(world_macro),
         chunk_coord: coord_map(chunk_coord),
         local_macro: coord_map(local_macro),
         macro_index: macro_index,
         cell_mode: cell_mode_name(header),
         material_id: material_id,
         material_name: material_name(material_id, profile),
         combustible: is_map(profile),
         combustion_stage: Combustion.stage_name(stage_raw),
         combustion_stage_raw: stage_raw,
         active_combustion: active_combustion_stage?(stage_raw),
         active_combustion_instance: not is_nil(instance),
         phenomenon_instance: instance,
         attributes: combustion_attributes(storage, macro_index),
         profile: profile_summary(profile)
       }}
    end
  rescue
    error -> {:error, {:combustion_probe_failed, error}}
  catch
    kind, reason -> {:error, {:combustion_probe_failed, kind, reason}}
  end

  defp combustion_attributes(%Storage{} = storage, macro_index) do
    %{
      temperature_celsius: read_float(storage, macro_index, "temperature", 20.0),
      ignition_temperature_celsius:
        read_float(storage, macro_index, "ignition_temperature", 5_000.0),
      moisture_kg_per_m3: read_float(storage, macro_index, "moisture", 0.0),
      fuel_mass_kg_per_m3: read_float(storage, macro_index, "fuel_mass", 0.0),
      oxygen_percent: read_float(storage, macro_index, "oxygen", 100.0),
      combustion_progress_percent: read_float(storage, macro_index, "combustion_progress", 0.0),
      smoke_density_percent: read_float(storage, macro_index, "smoke_density", 0.0),
      carbonization_percent: read_float(storage, macro_index, "carbonization", 0.0),
      structural_integrity_percent:
        read_float(storage, macro_index, "structural_integrity", 100.0)
    }
  end

  defp material_id_at(%Storage{} = storage, macro_index) do
    case Storage.normal_block_at(storage, macro_index) do
      %NormalBlockData{material_id: material_id} when material_id > 0 ->
        material_id

      _other ->
        refined_material_id_at(storage, macro_index)
    end
  end

  defp refined_material_id_at(%Storage{} = storage, macro_index) do
    case Storage.refined_cell_at(storage, macro_index) do
      %RefinedCellData{layers: layers} ->
        Enum.find_value(layers, fn
          %MicroLayer{material_id: material_id} when material_id > 0 -> material_id
          _other -> nil
        end)

      _other ->
        nil
    end
  end

  defp material_name(_material_id, %{material_name: name}), do: name
  defp material_name(material_id, _profile), do: MaterialCatalog.material_name(material_id)

  defp profile_summary(nil), do: nil

  defp profile_summary(profile) when is_map(profile) do
    %{
      material_name: Map.get(profile, :material_name),
      ignition_temperature_celsius: Map.get(profile, :ignition_temperature_celsius),
      preheat_margin_celsius: Map.get(profile, :preheat_margin_celsius),
      max_moisture_kg_per_m3: Map.get(profile, :max_moisture_kg_per_m3),
      min_oxygen_percent: Map.get(profile, :min_oxygen_percent),
      initial_fuel_mass_kg_per_m3: Map.get(profile, :initial_fuel_mass_kg_per_m3),
      burn_rate_kg_per_m3_second: Map.get(profile, :burn_rate_kg_per_m3_second),
      combustion_heat_j_per_kg: Map.get(profile, :combustion_heat_j_per_kg),
      heat_release_efficiency: Map.get(profile, :heat_release_efficiency),
      smolder_heat_release_fraction: Map.get(profile, :smolder_heat_release_fraction),
      smolder_progress_percent: Map.get(profile, :smolder_progress_percent),
      residue: residue_summary(Map.get(profile, :residue)),
      oxygen_limited_residue: residue_summary(Map.get(profile, :oxygen_limited_residue))
    }
  end

  defp residue_summary({:material, material_id}), do: %{type: :material, material_id: material_id}
  defp residue_summary(:clear), do: %{type: :clear}
  defp residue_summary(nil), do: nil
  defp residue_summary(other), do: %{type: :unknown, value: inspect(other)}

  defp cell_mode_name(%MacroCellHeader{mode: mode}) do
    cond do
      mode == MacroCellHeader.cell_mode_solid_block() -> :solid
      mode == MacroCellHeader.cell_mode_refined() -> :refined
      true -> :empty
    end
  end

  defp active_combustion_stage?(stage) do
    stage in [
      Combustion.stage_preheat(),
      Combustion.stage_burning(),
      Combustion.stage_smoldering()
    ]
  end

  defp active_instance_summary(debug_state, logical_scene_id, chunk_coord, macro_index) do
    instances = Map.get(debug_state, :phenomenon_instances, %{})
    id = Instance.key(logical_scene_id, chunk_coord, :combustion, macro_index)
    Map.get(instances, inspect(id))
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

  defp world_macro_coord(opts) do
    cond do
      has_any_key?(opts, [:world_macro]) ->
        Types.normalize_world_micro_coord!(get_any(opts, [:world_macro], nil))

      has_axis_keys?(opts, [:x, :y, :z]) ->
        Types.normalize_world_micro_coord!({
          get_any(opts, [:x], 0),
          get_any(opts, [:y], 0),
          get_any(opts, [:z], 0)
        })

      true ->
        {0, 0, 0}
    end
  end

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
end
