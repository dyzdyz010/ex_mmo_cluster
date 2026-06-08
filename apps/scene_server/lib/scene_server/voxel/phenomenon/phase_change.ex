defmodule SceneServer.Voxel.Phenomenon.PhaseChange do
  @moduledoc """
  Material-contained moisture phase-change rules for one macro voxel.

  The first Phase 8.C slice models water held by a voxel material: low
  temperature freezes it into persistent voxel state, and high temperature
  releases it into the local moisture field as vapor. Material-body melting and
  solidification are intentionally left to a later rule set.
  """

  alias SceneServer.Voxel.Phenomenon.Effect
  alias SceneServer.Voxel.Storage

  @fixed32_scale 65_536
  @phase_stable 0
  @phase_frozen 1
  @phase_boiling 2
  @phase_vapor 3
  @water_freezing_point_celsius 0.0
  @water_boiling_point_celsius 100.0
  @absolute_zero_celsius -273.15
  @default_boiling_rate_kg_per_m3_second 20.0
  @default_freeze_stress_loss_percent 3.0
  @percent_max 100.0

  @type result :: %{
          macro_index: non_neg_integer(),
          material_id: non_neg_integer(),
          stage: atom(),
          effects: [Effect.t()],
          field_source_points: [map()]
        }

  @spec phase_stable() :: 0
  def phase_stable, do: @phase_stable

  @spec phase_frozen() :: 1
  def phase_frozen, do: @phase_frozen

  @spec phase_boiling() :: 2
  def phase_boiling, do: @phase_boiling

  @spec phase_vapor() :: 3
  def phase_vapor, do: @phase_vapor

  @spec phase_name(integer()) :: atom()
  def phase_name(@phase_frozen), do: :frozen
  def phase_name(@phase_boiling), do: :boiling
  def phase_name(@phase_vapor), do: :vapor
  def phase_name(_state), do: :stable

  @doc """
  Evaluates contained-moisture phase change for one solid macro cell.

  Returns `:ignore` when the cell has no contained moisture, has no solid
  material, or remains within its stable thermal band.
  """
  @spec evaluate(Storage.t() | nil, non_neg_integer(), number(), map() | keyword()) ::
          result() | :ignore
  def evaluate(storage, macro_index, temperature_celsius, opts \\ %{})

  def evaluate(%Storage{} = storage, macro_index, temperature_celsius, opts)
      when is_integer(macro_index) and is_number(temperature_celsius) do
    storage = Storage.ensure_accel(storage)
    opts = opts_map(opts)

    case Storage.normal_block_at(storage, macro_index) do
      nil ->
        :ignore

      block ->
        evaluate_cell(storage, macro_index, block.material_id, temperature_celsius * 1.0, opts)
    end
  rescue
    _exception in [ArgumentError, FunctionClauseError] -> :ignore
  end

  def evaluate(_storage, _macro_index, _temperature_celsius, _opts), do: :ignore

  defp evaluate_cell(storage, macro_index, material_id, temperature_celsius, opts) do
    environment = normalize_environment(get_opt(opts, :environment, %{}))
    moisture = moisture_kg_per_m3(storage, macro_index, environment)
    previous_phase = read_int(storage, macro_index, "phase_state", @phase_stable)

    cond do
      moisture <= 0.0 ->
        :ignore

      temperature_celsius <= freezing_point_celsius(storage, macro_index, opts) and
          previous_phase != @phase_frozen ->
        freeze(
          storage,
          macro_index,
          material_id,
          temperature_celsius,
          moisture,
          previous_phase,
          opts
        )

      temperature_celsius >= boiling_point_celsius(storage, macro_index, opts) ->
        boil(
          storage,
          macro_index,
          material_id,
          temperature_celsius,
          moisture,
          previous_phase,
          opts
        )

      previous_phase == @phase_frozen and
          temperature_celsius > freezing_point_celsius(storage, macro_index, opts) ->
        thaw(macro_index, material_id, temperature_celsius, previous_phase, moisture)

      true ->
        :ignore
    end
  end

  defp freeze(
         storage,
         macro_index,
         material_id,
         temperature_celsius,
         moisture,
         previous_phase,
         opts
       ) do
    integrity_before = read_float(storage, macro_index, "structural_integrity", @percent_max)

    stress_loss =
      non_negative_float(
        get_opt(opts, :freeze_stress_loss_percent, @default_freeze_stress_loss_percent),
        @default_freeze_stress_loss_percent
      )

    integrity_after = clamp_percent(integrity_before - stress_loss)

    effects =
      [
        Effect.write_voxel_attribute(macro_index, :phase_state, @phase_frozen),
        Effect.write_voxel_attribute(
          macro_index,
          :structural_integrity,
          fixed32(integrity_after)
        ),
        Effect.upsert_phenomenon_instance(:phase_change, macro_index, %{
          material_id: material_id,
          stage: :frozen,
          previous_stage: phase_name(previous_phase),
          temperature_celsius: temperature_celsius,
          moisture_kg_per_m3: moisture
        }),
        Effect.emit_observe("voxel_phase_change_frozen", %{
          macro_index: macro_index,
          material_id: material_id,
          stage: :frozen,
          previous_stage: phase_name(previous_phase),
          temperature_celsius: temperature_celsius,
          freezing_point_celsius: freezing_point_celsius(storage, macro_index, opts),
          moisture_kg_per_m3: moisture,
          structural_integrity_before_percent: integrity_before,
          structural_integrity_after_percent: integrity_after
        })
      ]

    %{
      macro_index: macro_index,
      material_id: material_id,
      stage: :frozen,
      effects: effects,
      field_source_points: []
    }
  end

  defp boil(
         storage,
         macro_index,
         material_id,
         temperature_celsius,
         moisture_before,
         previous_phase,
         opts
       ) do
    dt_seconds = positive_float(get_opt(opts, :dt_seconds, 0.1), 0.1)

    boiling_rate =
      non_negative_float(
        get_opt(opts, :boiling_rate_kg_per_m3_second, @default_boiling_rate_kg_per_m3_second),
        @default_boiling_rate_kg_per_m3_second
      )

    boiling_point = boiling_point_celsius(storage, macro_index, opts)
    heat_factor = max(1.0, (temperature_celsius - boiling_point) / 100.0)
    released = min(moisture_before, boiling_rate * dt_seconds * heat_factor)
    moisture_after = max(moisture_before - released, 0.0)
    next_phase = if moisture_after <= 0.0, do: @phase_vapor, else: @phase_boiling
    next_stage = phase_name(next_phase)

    source_points = moisture_source_points(macro_index, moisture_before, moisture_after, released)

    effects =
      [
        Effect.write_voxel_attribute(macro_index, :moisture, fixed32(moisture_after)),
        Effect.write_voxel_attribute(macro_index, :phase_state, next_phase),
        Effect.upsert_phenomenon_instance(:phase_change, macro_index, %{
          material_id: material_id,
          stage: next_stage,
          previous_stage: phase_name(previous_phase),
          temperature_celsius: temperature_celsius,
          moisture_before_kg_per_m3: moisture_before,
          moisture_after_kg_per_m3: moisture_after,
          moisture_released_kg_per_m3: released
        }),
        Effect.emit_observe("voxel_phase_change_boiling", %{
          macro_index: macro_index,
          material_id: material_id,
          stage: next_stage,
          previous_stage: phase_name(previous_phase),
          temperature_celsius: temperature_celsius,
          boiling_point_celsius: boiling_point,
          moisture_before_kg_per_m3: moisture_before,
          moisture_after_kg_per_m3: moisture_after,
          moisture_released_kg_per_m3: released
        })
      ] ++ maybe_complete_vaporized(macro_index, material_id, moisture_after, released)

    %{
      macro_index: macro_index,
      material_id: material_id,
      stage: next_stage,
      effects: effects,
      field_source_points: source_points
    }
  end

  defp thaw(macro_index, material_id, temperature_celsius, previous_phase, moisture) do
    effects = [
      Effect.write_voxel_attribute(macro_index, :phase_state, @phase_stable),
      Effect.complete_phenomenon_instance(:phase_change, macro_index, %{
        material_id: material_id,
        stage: :stable,
        previous_stage: phase_name(previous_phase),
        reason: :temperature_above_freezing,
        temperature_celsius: temperature_celsius,
        moisture_kg_per_m3: moisture
      }),
      Effect.emit_observe("voxel_phase_change_thawed", %{
        macro_index: macro_index,
        material_id: material_id,
        stage: :stable,
        previous_stage: phase_name(previous_phase),
        temperature_celsius: temperature_celsius,
        moisture_kg_per_m3: moisture
      })
    ]

    %{
      macro_index: macro_index,
      material_id: material_id,
      stage: :stable,
      effects: effects,
      field_source_points: []
    }
  end

  defp maybe_complete_vaporized(_macro_index, _material_id, moisture_after, _released)
       when moisture_after > 0.0,
       do: []

  defp maybe_complete_vaporized(macro_index, material_id, _moisture_after, released) do
    [
      Effect.complete_phenomenon_instance(:phase_change, macro_index, %{
        material_id: material_id,
        stage: :vapor,
        reason: :moisture_depleted,
        moisture_released_kg_per_m3: released
      })
    ]
  end

  defp moisture_source_points(_macro_index, _before, _after, released) when released <= 0.0,
    do: []

  defp moisture_source_points(macro_index, moisture_before, moisture_after, released) do
    [
      %{
        macro_index: macro_index,
        field_type: :moisture,
        source_mode: :impulse,
        source_kind: :phase_change,
        value: released,
        moisture_before_kg_per_m3: moisture_before,
        moisture_after_kg_per_m3: moisture_after,
        moisture_released_kg_per_m3: released
      }
    ]
  end

  defp moisture_kg_per_m3(storage, macro_index, environment) do
    storage_moisture = read_float(storage, macro_index, "moisture", 0.0)
    environment_moisture = get_opt(environment, :moisture_kg_per_m3, nil)

    cond do
      storage_moisture > 0.0 -> storage_moisture
      is_number(environment_moisture) -> environment_moisture * 1.0
      true -> 0.0
    end
  end

  defp freezing_point_celsius(storage, macro_index, opts) do
    explicit = get_opt(opts, :freezing_point_celsius, nil)

    cond do
      is_number(explicit) ->
        explicit * 1.0

      true ->
        storage
        |> read_float(macro_index, "freezing_point", @water_freezing_point_celsius)
        |> contained_water_freezing_point()
    end
  end

  defp boiling_point_celsius(storage, macro_index, opts) do
    explicit = get_opt(opts, :boiling_point_celsius, nil)

    cond do
      is_number(explicit) ->
        explicit * 1.0

      true ->
        storage
        |> read_float(macro_index, "boiling_point", @water_boiling_point_celsius)
        |> contained_water_boiling_point()
    end
  end

  defp contained_water_freezing_point(value)
       when value <= @absolute_zero_celsius or value > @water_freezing_point_celsius,
       do: @water_freezing_point_celsius

  defp contained_water_freezing_point(value), do: value

  defp contained_water_boiling_point(value)
       when value <= @absolute_zero_celsius or value > @water_boiling_point_celsius,
       do: @water_boiling_point_celsius

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

  defp fixed32(value), do: round(value * @fixed32_scale)
  defp clamp_percent(value), do: clamp(value, 0.0, @percent_max)

  defp clamp(value, min_value, max_value) do
    value
    |> max(min_value)
    |> min(max_value)
  end

  defp opts_map(opts) when is_map(opts), do: opts
  defp opts_map(opts) when is_list(opts), do: Map.new(opts)
  defp opts_map(_opts), do: %{}

  defp normalize_environment(environment) when is_map(environment), do: environment
  defp normalize_environment(_environment), do: %{}

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

  defp positive_float(value, _fallback) when is_integer(value) and value > 0, do: value * 1.0
  defp positive_float(value, _fallback) when is_float(value) and value > 0.0, do: value
  defp positive_float(_value, fallback), do: fallback

  defp non_negative_float(value, _fallback) when is_integer(value) and value >= 0,
    do: value * 1.0

  defp non_negative_float(value, _fallback) when is_float(value) and value >= 0.0, do: value
  defp non_negative_float(_value, fallback), do: fallback
end
