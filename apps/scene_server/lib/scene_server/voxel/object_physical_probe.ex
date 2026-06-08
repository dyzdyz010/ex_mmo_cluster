defmodule SceneServer.Voxel.ObjectPhysicalProbe do
  @moduledoc """
  Read-only physical object truth probe for one scene object.

  The probe observes `ObjectRegistry` state on the scene node selected by the
  world-side route coordinate. It does not evaluate phenomena, mutate object
  state, start chunks, or apply damage; it only serializes the current object
  and part health truth for dev/browser diagnostics.
  """

  alias SceneServer.Voxel.{ObjectRegistry, PartState, Types}

  @default_logical_scene_id 1

  @doc """
  Returns a JSON-safe-ish map describing the current physical state of one
  object.

  Options:

    * `:logical_scene_id` - defaults to 1.
    * `:object_id` - object id to read.
    * `:world_macro` or `:x/:y/:z` - route coordinate used by WorldServer to
      select the scene node; echoed for diagnostics.
    * `:object_registry` - optional registry target for tests.
  """
  @spec probe(keyword() | map()) :: {:ok, map()} | {:error, term()}
  def probe(opts \\ []) when is_list(opts) or is_map(opts) do
    opts = opts_map(opts)

    logical_scene_id =
      opts
      |> get_any([:logical_scene_id], @default_logical_scene_id)
      |> non_negative_int(@default_logical_scene_id)

    object_id =
      opts
      |> get_any([:object_id], 0)
      |> non_negative_int(0)

    world_macro = world_macro_coord(opts)
    {chunk_coord, local_macro} = Types.chunk_and_local_macro!(world_macro)
    registry = get_any(opts, [:object_registry], ObjectRegistry)

    route_summary = %{
      logical_scene_id: logical_scene_id,
      object_id: object_id,
      route_world_macro: coord_map(world_macro),
      route_chunk_coord: coord_map(chunk_coord),
      route_local_macro: coord_map(local_macro)
    }

    case ObjectRegistry.lookup_object(registry, logical_scene_id, object_id) do
      nil ->
        {:ok, Map.put(route_summary, :object_found, false)}

      instance ->
        {:ok,
         route_summary
         |> Map.put(:object_found, true)
         |> Map.merge(object_summary(instance))}
    end
  rescue
    error -> {:error, {:object_physical_probe_failed, error}}
  catch
    kind, reason -> {:error, {:object_physical_probe_failed, kind, reason}}
  end

  defp object_summary(instance) do
    part_states =
      instance
      |> Map.get(:part_states, [])
      |> Enum.map(&part_summary/1)
      |> Enum.sort_by(& &1.part_id)

    %{
      object_id: Map.fetch!(instance, :object_id),
      blueprint_id: Map.get(instance, :blueprint_id),
      blueprint_version: Map.get(instance, :blueprint_version),
      object_version: Map.get(instance, :object_version),
      state_flags: Map.get(instance, :state_flags, 0),
      owner_actor_id: Map.get(instance, :owner_actor_id),
      owner_region_id: Map.get(instance, :owner_region_id),
      owner_lease_id: Map.get(instance, :owner_lease_id),
      anchor_world_micro: coord_map(Map.get(instance, :anchor_world_micro, {0, 0, 0})),
      covered_chunks: Enum.map(Map.get(instance, :covered_chunks, []), &coord_map/1),
      part_states: part_states,
      damaged_part_count: Enum.count(part_states, & &1.damaged),
      destroyed_part_count: Enum.count(part_states, & &1.destroyed)
    }
  end

  defp part_summary(%PartState{} = part) do
    %{
      part_id: part.part_id,
      health: part.health,
      state_flags: part.state_flags,
      damaged: PartState.damaged?(part),
      destroyed: PartState.destroyed?(part)
    }
  end

  defp part_summary(part) when is_map(part), do: part |> PartState.normalize!() |> part_summary()

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
    Enum.any?(keys, fn key -> Map.has_key?(map, key) or Map.has_key?(map, Atom.to_string(key)) end)
  end

  defp has_axis_keys?(map, keys), do: Enum.all?(keys, &has_any_key?(map, [&1]))

  defp non_negative_int(value, _default) when is_integer(value) and value >= 0, do: value

  defp non_negative_int(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _other -> default
    end
  end

  defp non_negative_int(_value, default), do: default

  defp coord_map({x, y, z}), do: %{x: x, y: y, z: z}
  defp coord_map([x, y, z]), do: %{x: x, y: y, z: z}
  defp coord_map(%{x: _x, y: _y, z: _z} = coord), do: coord
  defp coord_map(%{"x" => x, "y" => y, "z" => z}), do: %{x: x, y: y, z: z}
  defp coord_map(_other), do: %{x: 0, y: 0, z: 0}
end
