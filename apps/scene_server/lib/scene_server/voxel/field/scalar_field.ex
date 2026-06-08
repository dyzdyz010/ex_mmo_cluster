defmodule SceneServer.Voxel.Field.ScalarField do
  @moduledoc """
  Sparse scalar-field evolution for non-temperature environmental layers.

  `ScalarField` keeps the same owner boundary as `TemperatureField`: it mutates
  only the `FieldLayer` inside the provided `FieldRegion`, consumes impulse
  source points for the selected field type, and leaves voxel truth writes to
  phenomenon/chunk effects. It is intentionally lightweight; the first use is
  smoke density, oxygen, and moisture without adding per-phenomenon diffusion
  loops.
  """

  alias SceneServer.Voxel.Field.{FieldLayer, FieldRegion}
  alias SceneServer.Voxel.Types

  @default_diffusion_alpha 0.18
  @default_decay_per_second 0.08
  @default_min_value 0.0
  @default_max_value 100.0

  @doc """
  Runs one scalar diffusion tick for `field_type`.

  Options:
    * `:diffusion_alpha` - per-tick explicit 6-neighbor mixing factor.
    * `:decay_per_second` - exponential decay toward the layer baseline.
    * `:min_value` / `:max_value` - clamp absolute field values.
  """
  @spec tick(FieldRegion.t(), FieldRegion.field_type(), keyword() | map()) :: FieldRegion.t()
  def tick(%FieldRegion{} = region, field_type, opts \\ [])
      when field_type in [:smoke_density, :oxygen, :moisture] do
    opts = opts_map(opts)

    diffusion_alpha =
      clamp(
        non_negative_float(get_opt(opts, :diffusion_alpha, @default_diffusion_alpha)),
        0.0,
        1.0
      )

    decay_per_second =
      non_negative_float(get_opt(opts, :decay_per_second, @default_decay_per_second))

    dt_seconds = positive_float(get_opt(opts, :dt_seconds, 0.1), 0.1)
    min_value = float_value(get_opt(opts, :min_value, @default_min_value), @default_min_value)
    max_value = float_value(get_opt(opts, :max_value, @default_max_value), @default_max_value)

    {impulse_sources, persistent_region} = take_impulses(region, field_type)

    persistent_sources = persistent_sources(persistent_region, field_type)

    layer =
      region
      |> FieldRegion.get_layer(field_type)
      |> apply_source_points(region, field_type, impulse_sources, min_value, max_value)
      |> apply_source_points(region, field_type, persistent_sources, min_value, max_value)

    layer =
      layer
      |> candidate_indices(persistent_region, field_type)
      |> diffuse_layer(
        layer,
        persistent_region,
        diffusion_alpha,
        decay_per_second,
        dt_seconds,
        min_value,
        max_value
      )
      |> apply_source_points(
        persistent_region,
        field_type,
        persistent_sources,
        min_value,
        max_value
      )

    FieldRegion.put_layer(persistent_region, field_type, layer)
  end

  defp diffuse_layer(
         candidate_indices,
         %FieldLayer{} = layer,
         %FieldRegion{} = region,
         diffusion_alpha,
         decay_per_second,
         dt_seconds,
         min_value,
         max_value
       ) do
    Enum.reduce(candidate_indices, layer, fn idx, acc ->
      current = FieldLayer.get(layer, idx)
      neighbor_avg = neighbor_average(layer, region, idx)

      current
      |> Kernel.+(diffusion_alpha * (neighbor_avg - current))
      |> apply_decay(layer.baseline, decay_per_second, dt_seconds)
      |> clamp(min_value, max_value)
      |> then(&FieldLayer.put(acc, idx, &1))
    end)
  end

  defp take_impulses(%FieldRegion{} = region, field_type) do
    {impulses, rest} =
      Enum.split_with(region.source_points, fn source_point ->
        field_type(source_point) == field_type and source_mode(source_point) == :impulse
      end)

    {impulses, %{region | source_points: rest}}
  end

  defp persistent_sources(%FieldRegion{} = region, field_type) do
    Enum.filter(region.source_points, fn source_point ->
      field_type(source_point) == field_type and source_mode(source_point) != :impulse
    end)
  end

  defp apply_source_points(
         %FieldLayer{} = layer,
         %FieldRegion{} = region,
         field_type,
         source_points,
         min_value,
         max_value
       ) do
    Enum.reduce(source_points, layer, fn source_point, acc ->
      with ^field_type <- field_type(source_point),
           macro_index when is_integer(macro_index) <- macro_index(source_point),
           coord <- Types.macro_coord!(macro_index),
           true <- FieldRegion.in_aabb?(region, coord),
           value when is_number(value) <- source_value(source_point) do
        FieldLayer.put(acc, macro_index, clamp(value * 1.0, min_value, max_value))
      else
        _other -> acc
      end
    end)
  end

  defp candidate_indices(%FieldLayer{} = layer, %FieldRegion{} = region, field_type) do
    active_indices =
      layer
      |> FieldLayer.active_cells(region.aabb, 0)
      |> Enum.map(&elem(&1, 0))

    source_indices =
      region.source_points
      |> Enum.filter(fn source_point ->
        field_type(source_point) == field_type and
          source_point
          |> macro_index()
          |> in_region?(region)
      end)
      |> Enum.map(&macro_index/1)

    (active_indices ++ source_indices)
    |> Enum.flat_map(fn idx -> [idx | neighbor_indices(region, idx)] end)
    |> Enum.uniq()
  end

  defp neighbor_average(%FieldLayer{} = layer, %FieldRegion{} = region, macro_index) do
    macro_index
    |> Types.macro_coord!()
    |> neighbor_coords()
    |> Enum.map(fn coord ->
      if coord_in_region?(region, coord) do
        coord
        |> Types.macro_index!()
        |> then(&FieldLayer.get(layer, &1))
      else
        layer.baseline
      end
    end)
    |> Enum.sum()
    |> Kernel./(6.0)
  end

  defp neighbor_indices(%FieldRegion{} = region, macro_index) do
    macro_index
    |> Types.macro_coord!()
    |> neighbor_coords()
    |> Enum.filter(&coord_in_region?(region, &1))
    |> Enum.map(&Types.macro_index!/1)
  end

  defp neighbor_coords({x, y, z}) do
    [
      {x - 1, y, z},
      {x + 1, y, z},
      {x, y - 1, z},
      {x, y + 1, z},
      {x, y, z - 1},
      {x, y, z + 1}
    ]
  end

  defp coord_in_region?(region, {x, y, z} = coord) do
    x in 0..15 and y in 0..15 and z in 0..15 and FieldRegion.in_aabb?(region, coord)
  end

  defp in_region?(macro_index, %FieldRegion{} = region) when is_integer(macro_index) do
    macro_index
    |> Types.macro_coord!()
    |> then(&FieldRegion.in_aabb?(region, &1))
  rescue
    _exception in [ArgumentError, FunctionClauseError] -> false
  end

  defp in_region?(_macro_index, _region), do: false

  defp apply_decay(value, _baseline, decay_per_second, _dt_seconds) when decay_per_second <= 0.0,
    do: value

  defp apply_decay(value, baseline, decay_per_second, dt_seconds) do
    baseline + (value - baseline) * :math.exp(-decay_per_second * dt_seconds)
  end

  defp field_type(source_point) do
    Map.get(source_point, :field_type, Map.get(source_point, "field_type"))
  end

  defp source_mode(source_point) do
    case Map.get(source_point, :source_mode, Map.get(source_point, "source_mode", :persistent)) do
      :impulse -> :impulse
      "impulse" -> :impulse
      _other -> :persistent
    end
  end

  defp macro_index(source_point) do
    Map.get(source_point, :macro_index, Map.get(source_point, "macro_index"))
  end

  defp source_value(source_point) do
    Map.get(source_point, :value, Map.get(source_point, "value"))
  end

  defp opts_map(opts) when is_map(opts), do: opts
  defp opts_map(opts) when is_list(opts), do: Map.new(opts)
  defp opts_map(_opts), do: %{}

  defp get_opt(opts, key, default) do
    cond do
      Map.has_key?(opts, key) -> Map.fetch!(opts, key)
      Map.has_key?(opts, Atom.to_string(key)) -> Map.fetch!(opts, Atom.to_string(key))
      true -> default
    end
  end

  defp positive_float(value, _fallback) when is_integer(value) and value > 0, do: value * 1.0
  defp positive_float(value, _fallback) when is_float(value) and value > 0.0, do: value
  defp positive_float(_value, fallback), do: fallback

  defp non_negative_float(value) when is_integer(value) and value >= 0, do: value * 1.0
  defp non_negative_float(value) when is_float(value) and value >= 0.0, do: value
  defp non_negative_float(_value), do: 0.0

  defp float_value(value, _fallback) when is_integer(value), do: value * 1.0
  defp float_value(value, _fallback) when is_float(value), do: value
  defp float_value(_value, fallback), do: fallback

  defp clamp(value, min_value, max_value) do
    value
    |> max(min_value)
    |> min(max_value)
  end
end
