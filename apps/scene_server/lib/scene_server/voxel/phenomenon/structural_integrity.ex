defmodule SceneServer.Voxel.Phenomenon.StructuralIntegrity do
  @moduledoc """
  Shared structural-integrity effect boundary for physical phenomena.

  Combustion, freezing, corrosion, pressure, and later object damage can all
  reduce the same `structural_integrity` voxel truth. This module owns the
  common percent clamping, authority writeback effect, object-boundary damage
  effect, and collapse-candidate observe event so individual phenomenon rules
  do not each invent their own failure threshold semantics.
  """

  alias SceneServer.Voxel.Phenomenon.Effect

  @fixed32_scale 65_536
  @percent_min 0.0
  @percent_max 100.0
  @default_failure_threshold_percent 15.0

  @doc "Returns the default voxel structural-failure threshold in percent."
  @spec default_failure_threshold_percent() :: float()
  def default_failure_threshold_percent, do: @default_failure_threshold_percent

  @doc """
  Builds effects for a structural-integrity change.

  The returned effects always include an authoritative `structural_integrity`
  attribute write. A `voxel_structural_collapse_candidate` observe effect is
  added only when the value crosses from above the configured threshold to at
  or below it. The same threshold crossing also emits an
  `:apply_structural_damage` effect, which the owning `ChunkProcess` may route
  to prefab/object part health through the normal object authority boundary.
  Already-failed cells therefore do not repeatedly emit collapse candidates on
  every tick.

  Options:
    * `:reason` - source reason atom/string, defaults to `:structural_integrity_loss`.
    * `:threshold_percent` or `:structural_failure_threshold_percent` - failure threshold.
    * `:context` - extra JSON-safe fields merged into the observe payload.
  """
  @spec damage_effects(
          non_neg_integer(),
          non_neg_integer() | nil,
          number(),
          number(),
          keyword() | map()
        ) :: [Effect.t()]
  def damage_effects(macro_index, material_id, integrity_before, integrity_after, opts \\ [])
      when is_integer(macro_index) and is_number(integrity_before) and
             is_number(integrity_after) do
    opts = opts_map(opts)
    before_percent = clamp_percent(integrity_before * 1.0)
    after_percent = clamp_percent(integrity_after * 1.0)
    threshold = failure_threshold_percent(opts)

    [
      Effect.write_voxel_attribute(macro_index, :structural_integrity, fixed32(after_percent))
    ] ++
      maybe_collapse_candidate(
        macro_index,
        material_id,
        before_percent,
        after_percent,
        threshold,
        opts
      )
  end

  defp maybe_collapse_candidate(
         macro_index,
         material_id,
         integrity_before,
         integrity_after,
         threshold,
         opts
       ) do
    if integrity_before > threshold and integrity_after <= threshold do
      context = context_map(get_opt(opts, :context, %{}))

      fields =
        %{
          macro_index: macro_index,
          material_id: material_id,
          reason: get_opt(opts, :reason, :structural_integrity_loss),
          structural_integrity_before_percent: integrity_before,
          structural_integrity_after_percent: integrity_after,
          structural_failure_threshold_percent: threshold
        }
        |> Map.merge(context)

      [
        Effect.emit_observe("voxel_structural_collapse_candidate", fields),
        Effect.apply_structural_damage(macro_index, fields)
      ]
    else
      []
    end
  end

  defp failure_threshold_percent(opts) do
    opts
    |> get_opt(
      :threshold_percent,
      get_opt(opts, :structural_failure_threshold_percent, @default_failure_threshold_percent)
    )
    |> number_or(@default_failure_threshold_percent)
    |> clamp_percent()
  end

  defp context_map(context) when is_map(context), do: context
  defp context_map(_context), do: %{}

  defp fixed32(value), do: round(value * @fixed32_scale)

  defp clamp_percent(value), do: clamp(number_or(value, @percent_min), @percent_min, @percent_max)

  defp clamp(value, min_value, max_value) do
    value
    |> max(min_value)
    |> min(max_value)
  end

  defp number_or(value, _fallback) when is_integer(value), do: value * 1.0
  defp number_or(value, _fallback) when is_float(value), do: value
  defp number_or(_value, fallback), do: fallback

  defp opts_map(opts) when is_map(opts), do: opts
  defp opts_map(opts) when is_list(opts), do: Map.new(opts)
  defp opts_map(_opts), do: %{}

  defp get_opt(map, key, default) when is_map(map) do
    cond do
      Map.has_key?(map, key) ->
        Map.fetch!(map, key)

      is_atom(key) and Map.has_key?(map, Atom.to_string(key)) ->
        Map.fetch!(map, Atom.to_string(key))

      true ->
        default
    end
  end

  defp get_opt(_map, _key, default), do: default
end
