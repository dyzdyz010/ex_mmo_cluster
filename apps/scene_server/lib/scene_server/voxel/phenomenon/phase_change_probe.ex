defmodule SceneServer.Voxel.Phenomenon.PhaseChangeProbe do
  @moduledoc """
  Read-only contained-moisture phase-change truth probe for one macro voxel.

  The probe resolves the owning chunk and reports the current material,
  `phase_state`, moisture, temperature, and active chunk-local phase-change
  instance. It is observational only: it never evaluates phase-change rules,
  mutates voxel truth, or creates field regions.
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

  alias SceneServer.Voxel.Phenomenon.{Instance, PhaseChange}

  @default_logical_scene_id 1
  @fixed32_scale 65_536

  @doc """
  Returns a JSON-safe-ish map describing contained-water phase state for one
  authoritative world macro voxel.

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
      phase_raw = read_int(storage, macro_index, "phase_state", PhaseChange.phase_stable())
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
         material_name: material_name(material_id),
         phase_state: PhaseChange.phase_name(phase_raw),
         phase_state_raw: phase_raw,
         active_phase_change: active_phase_change?(phase_raw, instance),
         active_phase_change_instance: not is_nil(instance),
         phenomenon_instance: instance,
         attributes: phase_attributes(storage, macro_index),
         thresholds: phase_thresholds(storage, macro_index)
       }}
    end
  rescue
    error -> {:error, {:phase_change_probe_failed, error}}
  catch
    kind, reason -> {:error, {:phase_change_probe_failed, kind, reason}}
  end

  defp phase_attributes(%Storage{} = storage, macro_index) do
    %{
      temperature_celsius: read_float(storage, macro_index, "temperature", 20.0),
      moisture_kg_per_m3: read_float(storage, macro_index, "moisture", 0.0),
      structural_integrity_percent:
        read_float(storage, macro_index, "structural_integrity", 100.0)
    }
  end

  defp phase_thresholds(%Storage{} = storage, macro_index) do
    %{
      contained_water_freezing_point_celsius:
        storage
        |> read_float(macro_index, "freezing_point", 0.0)
        |> contained_water_freezing_point(),
      contained_water_boiling_point_celsius:
        storage
        |> read_float(macro_index, "boiling_point", 100.0)
        |> contained_water_boiling_point()
    }
  end

  defp active_phase_change?(phase_raw, instance) do
    phase_raw in [
      PhaseChange.phase_frozen(),
      PhaseChange.phase_boiling(),
      PhaseChange.phase_vapor()
    ] or not is_nil(instance)
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

  defp material_name(nil), do: nil

  defp material_name(material_id) do
    case MaterialCatalog.combustion_profile(material_id) do
      %{material_name: name} -> name
      _other -> known_material_name(material_id)
    end
  end

  defp known_material_name(1), do: :dirt
  defp known_material_name(2), do: :stone
  defp known_material_name(3), do: :wood
  defp known_material_name(4), do: :ice
  defp known_material_name(5), do: :iron
  defp known_material_name(6), do: :power_block
  defp known_material_name(7), do: :electric_load
  defp known_material_name(8), do: :ash
  defp known_material_name(9), do: :charcoal
  defp known_material_name(10), do: :dry_grass
  defp known_material_name(11), do: :cloth
  defp known_material_name(_material_id), do: nil

  defp cell_mode_name(%MacroCellHeader{mode: mode}) do
    cond do
      mode == MacroCellHeader.cell_mode_solid_block() -> :solid
      mode == MacroCellHeader.cell_mode_refined() -> :refined
      true -> :empty
    end
  end

  defp active_instance_summary(debug_state, logical_scene_id, chunk_coord, macro_index) do
    instances = Map.get(debug_state, :phenomenon_instances, %{})
    id = Instance.key(logical_scene_id, chunk_coord, :phase_change, macro_index)
    Map.get(instances, inspect(id))
  end

  defp contained_water_freezing_point(value) when value <= -273.15 or value > 0.0, do: 0.0
  defp contained_water_freezing_point(value), do: value

  defp contained_water_boiling_point(value) when value <= -273.15 or value > 100.0, do: 100.0
  defp contained_water_boiling_point(value), do: value

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
