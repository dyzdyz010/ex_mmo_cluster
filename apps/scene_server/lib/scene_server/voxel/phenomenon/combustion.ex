defmodule SceneServer.Voxel.Phenomenon.Combustion do
  @moduledoc """
  Material-driven combustion state machine for one macro voxel.

  This module is deliberately pure: it reads voxel truth and material defaults,
  then returns phenomenon effects. It does not own processes, mutate storage, or
  create field regions directly.
  """

  alias SceneServer.Voxel.MaterialCatalog
  alias SceneServer.Voxel.Phenomenon.Effect
  alias SceneServer.Voxel.Storage

  @fixed32_scale 65_536
  @percent_max 100.0
  @stage_idle 0
  @stage_preheat 1
  @stage_burning 2
  @stage_smoldering 3
  @stage_extinguished 4

  @typedoc "Combustion evaluation result for one macro cell."
  @type result :: %{
          macro_index: non_neg_integer(),
          material_id: non_neg_integer(),
          stage: atom(),
          effects: [Effect.t()],
          heat_source_points: [map()]
        }

  @doc "Returns the enum value for the idle/non-combusting stage."
  @spec stage_idle() :: 0
  def stage_idle, do: @stage_idle

  @doc "Returns the enum value for the preheat stage."
  @spec stage_preheat() :: 1
  def stage_preheat, do: @stage_preheat

  @doc "Returns the enum value for the active flame stage."
  @spec stage_burning() :: 2
  def stage_burning, do: @stage_burning

  @doc "Returns the enum value for low-fuel smoldering."
  @spec stage_smoldering() :: 3
  def stage_smoldering, do: @stage_smoldering

  @doc "Returns the enum value for completed combustion."
  @spec stage_extinguished() :: 4
  def stage_extinguished, do: @stage_extinguished

  @doc "Names a combustion stage enum value."
  @spec stage_name(integer()) :: atom()
  def stage_name(@stage_preheat), do: :preheat
  def stage_name(@stage_burning), do: :burning
  def stage_name(@stage_smoldering), do: :smoldering
  def stage_name(@stage_extinguished), do: :extinguished
  def stage_name(_stage), do: :idle

  @doc """
  Evaluates combustion for one solid macro cell at the current field
  temperature. Returns `:ignore` when the cell is inert or unchanged.
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
        profile =
          opts
          |> get_opt(:profile, nil)
          |> normalize_profile(MaterialCatalog.combustion_profile(block.material_id))
          |> merge_runtime_profile_opts(opts)

        if is_nil(profile) do
          :ignore
        else
          evaluate_profile(
            storage,
            macro_index,
            block.material_id,
            temperature_celsius * 1.0,
            profile
          )
        end
    end
  rescue
    _exception in [ArgumentError, FunctionClauseError] -> :ignore
  end

  def evaluate(_storage, _macro_index, _temperature_celsius, _opts), do: :ignore

  defp evaluate_profile(storage, macro_index, material_id, temperature_celsius, profile) do
    ignition_temperature =
      read_float(
        storage,
        macro_index,
        "ignition_temperature",
        get_opt(profile, :ignition_temperature_celsius, 5_000.0)
      )

    moisture = read_float(storage, macro_index, "moisture", 0.0)
    oxygen = read_float(storage, macro_index, "oxygen", @percent_max)
    previous_stage = read_int(storage, macro_index, "combustion_stage", @stage_idle)

    preheat_temperature =
      ignition_temperature - get_opt(profile, :preheat_margin_celsius, 40.0)

    cond do
      temperature_celsius >= ignition_temperature and can_sustain?(moisture, oxygen, profile) ->
        burn(storage, macro_index, material_id, temperature_celsius, profile, previous_stage)

      temperature_celsius >= carbonization_temperature(ignition_temperature, profile) and
        moisture <= get_opt(profile, :max_moisture_kg_per_m3, 150.0) and
        oxygen < get_opt(profile, :min_oxygen_percent, 8.0) and
          previous_stage in [@stage_idle, @stage_preheat, @stage_extinguished] ->
        carbonize(
          storage,
          macro_index,
          material_id,
          temperature_celsius,
          oxygen,
          profile,
          previous_stage
        )

      temperature_celsius >= drying_temperature(ignition_temperature, profile) and
        moisture > get_opt(profile, :max_moisture_kg_per_m3, 150.0) and
          previous_stage in [@stage_idle, @stage_preheat, @stage_extinguished] ->
        dry(
          macro_index,
          material_id,
          temperature_celsius,
          ignition_temperature,
          moisture,
          profile,
          previous_stage
        )

      temperature_celsius >= preheat_temperature and
          previous_stage in [@stage_idle, @stage_preheat] ->
        preheat(
          macro_index,
          material_id,
          temperature_celsius,
          ignition_temperature,
          previous_stage
        )

      previous_stage in [@stage_burning, @stage_smoldering] ->
        extinguish(macro_index, material_id, :temperature_or_environment_dropped)

      true ->
        :ignore
    end
  end

  defp dry(
         macro_index,
         material_id,
         temperature_celsius,
         ignition_temperature,
         moisture_before,
         profile,
         previous_stage
       ) do
    dt_seconds = get_opt(profile, :dt_seconds, 0.1)
    drying_temperature = drying_temperature(ignition_temperature, profile)
    drying_rate = get_opt(profile, :drying_rate_kg_per_m3_second, 25.0)

    heat_factor =
      clamp(
        (temperature_celsius - drying_temperature) /
          max(ignition_temperature - drying_temperature, 1.0),
        0.25,
        2.0
      )

    moisture_after =
      moisture_before
      |> Kernel.-(drying_rate * dt_seconds * heat_factor)
      |> max(0.0)

    effects =
      [
        Effect.write_voxel_attribute(macro_index, :moisture, fixed32(moisture_after)),
        Effect.emit_observe("voxel_combustion_dried", %{
          macro_index: macro_index,
          material_id: material_id,
          stage: :preheat,
          previous_stage: stage_name(previous_stage),
          temperature_celsius: temperature_celsius,
          drying_temperature_celsius: drying_temperature,
          ignition_temperature_celsius: ignition_temperature,
          moisture_before_kg_per_m3: moisture_before,
          moisture_after_kg_per_m3: moisture_after
        })
      ] ++ preheat_stage_effects(macro_index, previous_stage)

    %{
      macro_index: macro_index,
      material_id: material_id,
      stage: :preheat,
      effects: effects,
      heat_source_points: []
    }
  end

  defp preheat(
         macro_index,
         material_id,
         temperature_celsius,
         ignition_temperature,
         previous_stage
       ) do
    effects =
      if previous_stage == @stage_preheat do
        []
      else
        [
          Effect.write_voxel_attribute(macro_index, :combustion_stage, @stage_preheat),
          Effect.emit_observe("voxel_combustion_preheated", %{
            macro_index: macro_index,
            material_id: material_id,
            temperature_celsius: temperature_celsius,
            ignition_temperature_celsius: ignition_temperature,
            stage: :preheat
          })
        ]
      end

    if effects == [] do
      :ignore
    else
      %{
        macro_index: macro_index,
        material_id: material_id,
        stage: :preheat,
        effects: effects,
        heat_source_points: []
      }
    end
  end

  defp preheat_stage_effects(macro_index, previous_stage)
       when previous_stage in [@stage_idle, @stage_extinguished] do
    [Effect.write_voxel_attribute(macro_index, :combustion_stage, @stage_preheat)]
  end

  defp preheat_stage_effects(_macro_index, _previous_stage), do: []

  defp burn(storage, macro_index, material_id, temperature_celsius, profile, previous_stage) do
    dt_seconds = get_opt(profile, :dt_seconds, 0.1)
    initial_fuel = get_opt(profile, :initial_fuel_mass_kg_per_m3, 1.0)

    fuel_before =
      storage
      |> read_float(macro_index, "fuel_mass", 0.0)
      |> initial_fuel_if_needed(previous_stage, initial_fuel)

    oxygen_before = read_float(storage, macro_index, "oxygen", @percent_max)
    smoke_before = read_float(storage, macro_index, "smoke_density", 0.0)
    carbon_before = read_float(storage, macro_index, "carbonization", 0.0)
    integrity_before = read_float(storage, macro_index, "structural_integrity", @percent_max)
    moisture = read_float(storage, macro_index, "moisture", 0.0)

    burned_fuel =
      fuel_before
      |> min(
        burn_rate(profile) * dt_seconds *
          burn_severity(temperature_celsius, moisture, oxygen_before, profile)
      )
      |> max(0.0)

    fuel_after = max(fuel_before - burned_fuel, 0.0)
    progress_percent = burn_progress_percent(fuel_after, initial_fuel)

    oxygen_after =
      clamp_percent(
        oxygen_before -
          burned_fuel * get_opt(profile, :oxygen_consumption_percent_per_kg, 0.2)
      )

    smoke_after =
      clamp_percent(
        smoke_before + burned_fuel * get_opt(profile, :smoke_yield_percent_per_kg, 0.6)
      )

    carbon_after =
      clamp_percent(
        carbon_before +
          burned_fuel * get_opt(profile, :carbonization_yield_percent_per_kg, 1.0)
      )

    integrity_after =
      clamp_percent(
        integrity_before -
          burned_fuel * get_opt(profile, :structural_loss_percent_per_kg, 1.0)
      )

    next_stage =
      cond do
        fuel_after <= 0.001 or progress_percent >= 99.9 -> @stage_extinguished
        progress_percent >= get_opt(profile, :smolder_progress_percent, 70.0) -> @stage_smoldering
        true -> @stage_burning
      end

    effects =
      [
        Effect.write_voxel_attribute(macro_index, :fuel_mass, fixed32(fuel_after)),
        Effect.write_voxel_attribute(
          macro_index,
          :oxygen,
          fixed32(oxygen_after)
        ),
        Effect.write_voxel_attribute(macro_index, :combustion_stage, next_stage),
        Effect.write_voxel_attribute(
          macro_index,
          :combustion_progress,
          fixed32(progress_percent)
        ),
        Effect.write_voxel_attribute(
          macro_index,
          :smoke_density,
          fixed32(smoke_after)
        ),
        Effect.write_voxel_attribute(
          macro_index,
          :carbonization,
          fixed32(carbon_after)
        ),
        Effect.write_voxel_attribute(
          macro_index,
          :structural_integrity,
          fixed32(integrity_after)
        ),
        Effect.emit_observe(observe_event(next_stage, previous_stage), %{
          macro_index: macro_index,
          material_id: material_id,
          stage: stage_name(next_stage),
          previous_stage: stage_name(previous_stage),
          temperature_celsius: temperature_celsius,
          fuel_before_kg_per_m3: fuel_before,
          fuel_after_kg_per_m3: fuel_after,
          progress_percent: progress_percent
        })
      ] ++
        structural_failure_effects(
          macro_index,
          material_id,
          integrity_before,
          integrity_after,
          profile
        ) ++ residue_effects(macro_index, profile, next_stage)

    %{
      macro_index: macro_index,
      material_id: material_id,
      stage: stage_name(next_stage),
      effects: effects,
      heat_source_points: heat_source_points(macro_index, next_stage, profile)
    }
  end

  defp carbonize(
         storage,
         macro_index,
         material_id,
         temperature_celsius,
         oxygen,
         profile,
         previous_stage
       ) do
    dt_seconds = get_opt(profile, :dt_seconds, 0.1)
    ignition_temperature = get_opt(profile, :ignition_temperature_celsius, 300.0)
    carbonization_temperature = carbonization_temperature(ignition_temperature, profile)
    oxygen_min = get_opt(profile, :min_oxygen_percent, 8.0)
    carbon_before = read_float(storage, macro_index, "carbonization", 0.0)
    integrity_before = read_float(storage, macro_index, "structural_integrity", @percent_max)

    heat_factor =
      clamp(
        (temperature_celsius - carbonization_temperature) /
          max(ignition_temperature - carbonization_temperature, 1.0),
        0.25,
        2.0
      )

    oxygen_deficit_factor = clamp((oxygen_min - oxygen) / max(oxygen_min, 1.0), 0.25, 1.0)

    carbon_after =
      clamp_percent(
        carbon_before +
          get_opt(profile, :oxygen_limited_carbonization_percent_per_second, 8.0) *
            dt_seconds * heat_factor * oxygen_deficit_factor
      )

    integrity_after =
      clamp_percent(
        integrity_before -
          get_opt(profile, :oxygen_limited_structural_loss_percent_per_second, 4.0) *
            dt_seconds * heat_factor
      )

    effects =
      [
        Effect.write_voxel_attribute(macro_index, :carbonization, fixed32(carbon_after)),
        Effect.write_voxel_attribute(
          macro_index,
          :structural_integrity,
          fixed32(integrity_after)
        ),
        Effect.emit_observe("voxel_combustion_carbonized", %{
          macro_index: macro_index,
          material_id: material_id,
          stage: :preheat,
          previous_stage: stage_name(previous_stage),
          temperature_celsius: temperature_celsius,
          oxygen_percent: oxygen,
          min_oxygen_percent: oxygen_min,
          carbonization_temperature_celsius: carbonization_temperature,
          carbonization_before_percent: carbon_before,
          carbonization_after_percent: carbon_after,
          structural_integrity_before_percent: integrity_before,
          structural_integrity_after_percent: integrity_after
        })
      ] ++
        preheat_stage_effects(macro_index, previous_stage) ++
        structural_failure_effects(
          macro_index,
          material_id,
          integrity_before,
          integrity_after,
          profile
        ) ++ oxygen_limited_residue_effects(macro_index, profile, carbon_before, carbon_after)

    %{
      macro_index: macro_index,
      material_id: material_id,
      stage: :preheat,
      effects: effects,
      heat_source_points: []
    }
  end

  defp extinguish(macro_index, material_id, reason) do
    %{
      macro_index: macro_index,
      material_id: material_id,
      stage: :extinguished,
      effects: [
        Effect.write_voxel_attribute(macro_index, :combustion_stage, @stage_extinguished),
        Effect.emit_observe("voxel_combustion_extinguished", %{
          macro_index: macro_index,
          material_id: material_id,
          reason: reason,
          stage: :extinguished
        })
      ],
      heat_source_points: []
    }
  end

  defp can_sustain?(moisture, oxygen, profile) do
    moisture <= get_opt(profile, :max_moisture_kg_per_m3, 150.0) and
      oxygen >= get_opt(profile, :min_oxygen_percent, 8.0)
  end

  defp drying_temperature(ignition_temperature, profile) do
    get_opt(
      profile,
      :drying_temperature_celsius,
      max(60.0, ignition_temperature - get_opt(profile, :preheat_margin_celsius, 40.0) * 2.0)
    )
  end

  defp carbonization_temperature(ignition_temperature, profile) do
    get_opt(
      profile,
      :oxygen_limited_carbonization_temperature_celsius,
      max(80.0, ignition_temperature - get_opt(profile, :preheat_margin_celsius, 40.0))
    )
  end

  defp burn_severity(temperature_celsius, moisture, oxygen, profile) do
    ignition = get_opt(profile, :ignition_temperature_celsius, 300.0)

    heat_factor =
      clamp((temperature_celsius - ignition) / max(ignition * 0.35, 100.0), 0.25, 2.0)

    oxygen_min = get_opt(profile, :min_oxygen_percent, 8.0)
    oxygen_factor = clamp((oxygen - oxygen_min) / max(@percent_max - oxygen_min, 1.0), 0.1, 1.0)

    moisture_max = get_opt(profile, :max_moisture_kg_per_m3, 150.0)
    moisture_factor = clamp(1.0 - moisture / max(moisture_max, 1.0), 0.05, 1.0)

    heat_factor * oxygen_factor * moisture_factor
  end

  defp burn_rate(profile), do: get_opt(profile, :burn_rate_kg_per_m3_second, 1.0)

  defp initial_fuel_if_needed(fuel_before, previous_stage, initial_fuel)
       when fuel_before <= 0.0 and previous_stage in [@stage_idle, @stage_preheat] do
    initial_fuel
  end

  defp initial_fuel_if_needed(fuel_before, _previous_stage, _initial_fuel), do: fuel_before

  defp burn_progress_percent(fuel_after, initial_fuel) when initial_fuel > 0.0 do
    clamp_percent((1.0 - fuel_after / initial_fuel) * 100.0)
  end

  defp burn_progress_percent(_fuel_after, _initial_fuel), do: 100.0

  defp heat_source_points(_macro_index, @stage_extinguished, _profile), do: []

  defp heat_source_points(macro_index, @stage_smoldering, profile) do
    [
      %{
        macro_index: macro_index,
        field_type: :temperature,
        source_mode: :persistent,
        source_kind: :combustion,
        value: get_opt(profile, :smolder_heat_source_celsius, 350.0)
      }
    ]
  end

  defp heat_source_points(macro_index, _stage, profile) do
    [
      %{
        macro_index: macro_index,
        field_type: :temperature,
        source_mode: :persistent,
        source_kind: :combustion,
        value: get_opt(profile, :heat_source_celsius, 650.0)
      }
    ]
  end

  defp residue_effects(macro_index, profile, @stage_extinguished) do
    case get_opt(profile, :residue, nil) do
      {:material, material_id} when is_integer(material_id) and material_id > 0 ->
        [
          Effect.transform_voxel_material(macro_index, material_id, %{
            reason: :combustion_exhausted,
            reset_attributes?: true
          })
        ]

      :clear ->
        [Effect.clear_voxel_cell(macro_index, %{reason: :combustion_exhausted})]

      _other ->
        []
    end
  end

  defp residue_effects(_macro_index, _profile, _stage), do: []

  defp oxygen_limited_residue_effects(macro_index, profile, carbon_before, carbon_after) do
    threshold = get_opt(profile, :oxygen_limited_residue_threshold_percent, 85.0)

    if carbon_before < threshold and carbon_after >= threshold do
      case get_opt(profile, :oxygen_limited_residue, nil) do
        {:material, material_id} when is_integer(material_id) and material_id > 0 ->
          [
            Effect.transform_voxel_material(macro_index, material_id, %{
              reason: :oxygen_limited_carbonization,
              reset_attributes?: true
            })
          ]

        :clear ->
          [Effect.clear_voxel_cell(macro_index, %{reason: :oxygen_limited_carbonization})]

        _other ->
          []
      end
    else
      []
    end
  end

  defp structural_failure_effects(
         macro_index,
         material_id,
         integrity_before,
         integrity_after,
         profile
       ) do
    threshold = get_opt(profile, :structural_failure_threshold_percent, 15.0)

    if integrity_before > threshold and integrity_after <= threshold do
      [
        Effect.emit_observe("voxel_structural_collapse_candidate", %{
          macro_index: macro_index,
          material_id: material_id,
          reason: :combustion_integrity_loss,
          structural_integrity_before_percent: integrity_before,
          structural_integrity_after_percent: integrity_after,
          structural_failure_threshold_percent: threshold
        })
      ]
    else
      []
    end
  end

  defp observe_event(@stage_extinguished, _previous_stage), do: "voxel_combustion_extinguished"

  defp observe_event(_next_stage, previous_stage)
       when previous_stage in [@stage_idle, @stage_preheat] do
    "voxel_combustion_ignited"
  end

  defp observe_event(@stage_smoldering, previous_stage)
       when previous_stage != @stage_smoldering do
    "voxel_combustion_smoldering"
  end

  defp observe_event(_next_stage, _previous_stage), do: "voxel_combustion_burning"

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

  defp normalize_profile(nil, fallback), do: fallback
  defp normalize_profile(profile, nil) when is_map(profile), do: profile
  defp normalize_profile(profile, fallback) when is_map(profile), do: Map.merge(fallback, profile)
  defp normalize_profile(_profile, fallback), do: fallback

  defp merge_runtime_profile_opts(nil, _opts), do: nil

  defp merge_runtime_profile_opts(profile, opts) do
    Map.merge(profile, runtime_profile_opts(opts))
  end

  defp runtime_profile_opts(opts) do
    opts
    |> get_opt(:dt_seconds, nil)
    |> case do
      value when is_number(value) and value > 0.0 -> %{dt_seconds: value}
      _other -> %{}
    end
  end

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
