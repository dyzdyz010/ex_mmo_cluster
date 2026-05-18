defmodule SceneServer.Voxel.Field.FieldSource do
  @moduledoc """
  Minimal Phase 7.D2 runtime source descriptor for local field creation.

  `FieldSource` is not persistent world truth. It is the normalized runtime
  record that explains why `FieldRuntime` should create or refresh a local
  field worker.
  """

  alias SceneServer.Voxel.Types
  alias SceneServer.Voxel.Field.Kernels.TemperatureDiffusionKernel

  @type t :: %__MODULE__{
          source_id: term(),
          source_key: term(),
          source_kind: atom(),
          source_mode: atom(),
          owner_ref: term(),
          location: term(),
          target_value: term(),
          source_value: term(),
          kernel_specs: [map()],
          decay_policy: map() | nil,
          lease_token: term(),
          created_tick: non_neg_integer() | nil,
          updated_tick: non_neg_integer() | nil
        }

  defstruct source_id: nil,
            source_key: nil,
            source_kind: nil,
            source_mode: :impulse,
            owner_ref: nil,
            location: nil,
            target_value: nil,
            source_value: nil,
            kernel_specs: [],
            decay_policy: nil,
            lease_token: nil,
            created_tick: nil,
            updated_tick: nil

  @default_max_ticks 600
  @default_radius 4
  # SetTemperature writes authoritative voxel temperature first. The local
  # FieldRegion is a gameplay/observe projection, so this profile compresses
  # physical diffusion into a browser-visible time window without changing the
  # voxel truth stored on the chunk.
  @temperature_diffusion_time_scale 20_000.0
  @temperature_ambient_loss_per_second 0.08
  @temperature_cell_size_meters 1.0

  @doc """
  Normalizes a runtime field source.

  The current minimal slice specializes the default path for temperature voxel
  sources while still accepting the full Phase 7.D2 field set.
  """
  @spec normalize(keyword() | map()) :: t()
  def normalize(attrs) when is_list(attrs) or is_map(attrs) do
    attrs = opts_map(attrs)

    case normalize_source_kind(fetch_any(attrs, [:source_kind], :temperature)) do
      :temperature -> normalize_temperature_source(attrs)
      source_kind -> normalize_generic_source(attrs, source_kind)
    end
  end

  @doc "Returns the summary map exposed by `FieldRuntime` responses."
  @spec to_summary(t()) :: map()
  def to_summary(%__MODULE__{} = source), do: Map.from_struct(source)

  @doc """
  Derives the existing `FieldRuntime.ensure_temperature_anomaly/1` attrs from a
  normalized temperature source without introducing new request semantics.
  """
  @spec temperature_runtime_attrs(t()) :: map()
  def temperature_runtime_attrs(%__MODULE__{source_kind: :temperature} = source) do
    %{
      logical_scene_id: fetch_any(source.owner_ref, [:logical_scene_id], 1),
      world_macro: coord_tuple(fetch_any(source.location, [:world_macro], %{x: 0, y: 0, z: 0})),
      radius: fetch_any(source.decay_policy, [:field_radius], @default_radius),
      max_ticks: fetch_any(source.decay_policy, [:max_ticks], @default_max_ticks),
      source_key: source.source_key,
      target_temperature_celsius: source.target_value,
      field_source: source
    }
  end

  def temperature_runtime_attrs(%__MODULE__{} = source) do
    raise ArgumentError,
          "FieldSource.temperature_runtime_attrs/1 only supports :temperature sources, got #{inspect(source.source_kind)}"
  end

  defp normalize_temperature_source(attrs) do
    logical_scene_id = non_negative_int(fetch_any(attrs, [:logical_scene_id], 1))
    world_macro = world_macro_coord(attrs)
    {chunk_coord, local_macro} = Types.chunk_and_local_macro!(world_macro)
    macro_index = Types.macro_index!(local_macro)

    target_value =
      temperature_float(
        fetch_any(attrs, [:target_temperature, :target_temperature_celsius], nil),
        800.0
      )

    source_value =
      temperature_float(fetch_any(attrs, [:source_value], target_value), target_value)

    radius = non_negative_int(fetch_any(attrs, [:radius], @default_radius))
    max_ticks = non_negative_int(fetch_any(attrs, [:max_ticks], @default_max_ticks))

    %__MODULE__{
      source_id: fetch_any(attrs, [:source_id], {:temperature, logical_scene_id, world_macro}),
      source_key: fetch_any(attrs, [:source_key], {:temperature, macro_index}),
      source_kind: :temperature,
      source_mode: normalize_source_mode(fetch_any(attrs, [:source_mode], :impulse)),
      owner_ref:
        fetch_any(attrs, [:owner_ref], %{
          kind: :voxel,
          logical_scene_id: logical_scene_id,
          world_macro: coord_map(world_macro)
        }),
      location:
        fetch_any(attrs, [:location], %{
          world_macro: coord_map(world_macro),
          chunk_coord: coord_map(chunk_coord),
          local_macro: coord_map(local_macro),
          macro_index: macro_index
        }),
      target_value: target_value,
      source_value: source_value,
      kernel_specs: fetch_any(attrs, [:kernel_specs], [temperature_kernel_spec()]),
      decay_policy:
        fetch_any(attrs, [:decay_policy], %{
          field_radius: radius,
          max_ticks: max_ticks
        }),
      lease_token: fetch_any(attrs, [:lease_token], nil),
      created_tick: normalize_optional_non_negative_int(fetch_any(attrs, [:created_tick], nil)),
      updated_tick: normalize_optional_non_negative_int(fetch_any(attrs, [:updated_tick], nil))
    }
  end

  defp normalize_generic_source(attrs, source_kind) do
    %__MODULE__{
      source_id: fetch_any(attrs, [:source_id], nil),
      source_key: fetch_any(attrs, [:source_key], nil),
      source_kind: source_kind,
      source_mode: normalize_source_mode(fetch_any(attrs, [:source_mode], :persistent)),
      owner_ref: fetch_any(attrs, [:owner_ref], nil),
      location: fetch_any(attrs, [:location], nil),
      target_value: fetch_any(attrs, [:target_value], nil),
      source_value: fetch_any(attrs, [:source_value], nil),
      kernel_specs: fetch_any(attrs, [:kernel_specs], []),
      decay_policy: fetch_any(attrs, [:decay_policy], nil),
      lease_token: fetch_any(attrs, [:lease_token], nil),
      created_tick: normalize_optional_non_negative_int(fetch_any(attrs, [:created_tick], nil)),
      updated_tick: normalize_optional_non_negative_int(fetch_any(attrs, [:updated_tick], nil))
    }
  end

  defp temperature_kernel_spec do
    %{
      id: :temperature_diffusion,
      module: TemperatureDiffusionKernel,
      opts: %{
        diffusion_time_scale: @temperature_diffusion_time_scale,
        ambient_loss_per_second: @temperature_ambient_loss_per_second,
        cell_size_meters: @temperature_cell_size_meters
      }
    }
  end

  defp normalize_source_kind(value) when is_atom(value), do: value

  defp normalize_source_kind(value) when is_binary(value) do
    normalized =
      value
      |> String.trim()
      |> String.downcase()

    case normalized do
      "temperature" -> :temperature
      "electric" -> :electric
      "combustion" -> :combustion
      "weather" -> :weather
      "magic" -> :magic
      "device" -> :device
      _other -> :temperature
    end
  end

  defp normalize_source_kind(_value), do: :temperature

  defp normalize_source_mode(value) when value in [:impulse, :persistent], do: value

  defp normalize_source_mode(value) when is_binary(value) do
    case String.trim(String.downcase(value)) do
      "impulse" -> :impulse
      "persistent" -> :persistent
      _other -> :impulse
    end
  end

  defp normalize_source_mode(_value), do: :impulse

  defp world_macro_coord(attrs) do
    cond do
      has_any_key?(attrs, [:world_macro]) ->
        Types.normalize_world_micro_coord!(fetch_any(attrs, [:world_macro], {0, 0, 0}))

      has_axis_keys?(attrs, [:x, :y, :z]) ->
        Types.normalize_world_micro_coord!(
          {fetch_any(attrs, [:x], 0), fetch_any(attrs, [:y], 0), fetch_any(attrs, [:z], 0)}
        )

      has_any_key?(attrs, [:location]) ->
        attrs
        |> fetch_any([:location], %{})
        |> fetch_any([:world_macro], {0, 0, 0})
        |> coord_tuple()
        |> Types.normalize_world_micro_coord!()

      true ->
        {0, 0, 0}
    end
  end

  defp coord_map({x, y, z}), do: %{x: x, y: y, z: z}

  defp coord_tuple(%{x: x, y: y, z: z}), do: {x, y, z}
  defp coord_tuple(%{"x" => x, "y" => y, "z" => z}), do: {x, y, z}
  defp coord_tuple({x, y, z}), do: {x, y, z}

  defp opts_map(attrs) when is_list(attrs), do: Map.new(attrs)
  defp opts_map(attrs) when is_map(attrs), do: attrs

  defp fetch_any(map, keys, default) when is_map(map) do
    Enum.find_value(keys, fn key ->
      cond do
        Map.has_key?(map, key) ->
          {:found, Map.fetch!(map, key)}

        is_atom(key) and Map.has_key?(map, Atom.to_string(key)) ->
          {:found, Map.fetch!(map, Atom.to_string(key))}

        true ->
          nil
      end
    end)
    |> case do
      {:found, value} -> value
      nil -> default
    end
  end

  defp fetch_any(_other, _keys, default), do: default

  defp has_any_key?(map, keys) when is_map(map) do
    Enum.any?(keys, fn key ->
      Map.has_key?(map, key) or (is_atom(key) and Map.has_key?(map, Atom.to_string(key)))
    end)
  end

  defp has_any_key?(_map, _keys), do: false

  defp has_axis_keys?(map, keys) when is_map(map) do
    Enum.all?(keys, fn key ->
      Map.has_key?(map, key) or (is_atom(key) and Map.has_key?(map, Atom.to_string(key)))
    end)
  end

  defp has_axis_keys?(_map, _keys), do: false

  defp non_negative_int(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_int(value) when is_float(value) and value >= 0, do: trunc(value)

  defp non_negative_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _other -> 0
    end
  end

  defp non_negative_int(_value), do: 0

  defp normalize_optional_non_negative_int(nil), do: nil
  defp normalize_optional_non_negative_int(value), do: non_negative_int(value)

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
