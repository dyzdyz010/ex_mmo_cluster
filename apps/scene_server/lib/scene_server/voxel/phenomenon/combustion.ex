defmodule SceneServer.Voxel.Phenomenon.Combustion do
  @moduledoc """
  Material-driven combustion state machine for one macro voxel.

  This module is deliberately pure: it reads voxel truth and material defaults,
  then returns phenomenon effects. It does not own processes, mutate storage, or
  create field regions directly.
  """

  alias SceneServer.Voxel.MaterialCatalog
  alias SceneServer.Voxel.Phenomenon.{Effect, StructuralIntegrity}
  alias SceneServer.Voxel.Storage

  @fixed32_scale 65_536
  @percent_max 100.0
  @stage_idle 0
  @stage_preheat 1
  @stage_burning 2
  @stage_smoldering 3
  @stage_extinguished 4
  @voxel_volume_cubic_meter 1.0
  @min_heat_capacity_j_per_k 0.001

  @typedoc "Combustion evaluation result for one macro cell."
  @type result :: %{
          macro_index: non_neg_integer(),
          material_id: non_neg_integer(),
          stage: atom(),
          effects: [Effect.t()],
          heat_source_points: [map()],
          field_source_points: [map()]
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

  Runtime `:profile` values only override an existing material combustion
  profile; they cannot make inert materials combustible. Use
  `:profile_overrides` keyed by material id when a test or scripted field
  region needs material-specific tuning without erasing per-material residue
  policy.
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
        environment = normalize_environment(get_opt(opts, :environment, %{}))

        profile =
          block.material_id
          |> resolve_profile(opts)
          |> merge_runtime_profile_opts(opts)

        if is_nil(profile) do
          :ignore
        else
          evaluate_profile(
            storage,
            macro_index,
            block.material_id,
            temperature_celsius * 1.0,
            profile,
            environment
          )
        end
    end
  rescue
    _exception in [ArgumentError, FunctionClauseError] -> :ignore
  end

  def evaluate(_storage, _macro_index, _temperature_celsius, _opts), do: :ignore

  defp evaluate_profile(
         storage,
         macro_index,
         material_id,
         temperature_celsius,
         profile,
         environment
       ) do
    ignition_temperature =
      read_float(
        storage,
        macro_index,
        "ignition_temperature",
        get_opt(profile, :ignition_temperature_celsius, 5_000.0)
      )

    moisture =
      read_environment_float(environment, :moisture_kg_per_m3, fn ->
        read_float(storage, macro_index, "moisture", 0.0)
      end)

    oxygen =
      read_environment_float(environment, :oxygen_percent, fn ->
        read_float(storage, macro_index, "oxygen", @percent_max)
      end)

    previous_stage = read_int(storage, macro_index, "combustion_stage", @stage_idle)

    preheat_temperature =
      ignition_temperature - get_opt(profile, :preheat_margin_celsius, 40.0)

    cond do
      temperature_celsius >= ignition_temperature and can_sustain?(moisture, oxygen, profile) ->
        burn(
          storage,
          macro_index,
          material_id,
          temperature_celsius,
          profile,
          previous_stage,
          %{moisture_kg_per_m3: moisture, oxygen_percent: oxygen}
        )

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

    moisture_source_points = moisture_source_points(macro_index, moisture_before, moisture_after)

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
      heat_source_points: [],
      field_source_points: moisture_source_points
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
        heat_source_points: [],
        field_source_points: []
      }
    end
  end

  defp preheat_stage_effects(macro_index, previous_stage)
       when previous_stage in [@stage_idle, @stage_extinguished] do
    [Effect.write_voxel_attribute(macro_index, :combustion_stage, @stage_preheat)]
  end

  defp preheat_stage_effects(_macro_index, _previous_stage), do: []

  defp burn(
         storage,
         macro_index,
         material_id,
         temperature_celsius,
         profile,
         previous_stage,
         environment
       ) do
    dt_seconds = get_opt(profile, :dt_seconds, 0.1)
    initial_fuel = get_opt(profile, :initial_fuel_mass_kg_per_m3, 1.0)

    fuel_before =
      storage
      |> read_float(macro_index, "fuel_mass", 0.0)
      |> initial_fuel_if_needed(previous_stage, initial_fuel)

    oxygen_before =
      read_environment_float(environment, :oxygen_percent, fn ->
        read_float(storage, macro_index, "oxygen", @percent_max)
      end)

    smoke_before = read_float(storage, macro_index, "smoke_density", 0.0)
    carbon_before = read_float(storage, macro_index, "carbonization", 0.0)
    integrity_before = read_float(storage, macro_index, "structural_integrity", @percent_max)

    moisture =
      read_environment_float(environment, :moisture_kg_per_m3, fn ->
        read_float(storage, macro_index, "moisture", 0.0)
      end)

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

    heat_output =
      heat_source_output(
        storage,
        macro_index,
        temperature_celsius,
        burned_fuel,
        next_stage,
        profile
      )

    heat_source_points = heat_source_points(macro_index, next_stage, profile, heat_output)
    smoke_source_points = smoke_source_points(macro_index, smoke_before, smoke_after, burned_fuel)
    oxygen_source_points = oxygen_source_points(macro_index, oxygen_before, oxygen_after)

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
        Effect.emit_observe(observe_event(next_stage, previous_stage), %{
          macro_index: macro_index,
          material_id: material_id,
          stage: stage_name(next_stage),
          previous_stage: stage_name(previous_stage),
          temperature_celsius: temperature_celsius,
          fuel_before_kg_per_m3: fuel_before,
          fuel_after_kg_per_m3: fuel_after,
          burned_fuel_kg_per_m3: burned_fuel,
          progress_percent: progress_percent,
          combustion_heat_j_per_kg: combustion_heat_j_per_kg(profile),
          heat_release_efficiency: heat_release_efficiency(next_stage, profile),
          released_heat_energy_joules: heat_output.released_heat_energy_joules,
          heat_source_celsius: heat_output.source_temperature_celsius,
          oxygen_before_percent: oxygen_before,
          oxygen_after_percent: oxygen_after,
          oxygen_consumed_percent: max(oxygen_before - oxygen_after, 0.0),
          smoke_before_percent: smoke_before,
          smoke_after_percent: smoke_after,
          smoke_delta_percent: max(smoke_after - smoke_before, 0.0)
        })
      ] ++
        structural_damage_effects(
          macro_index,
          material_id,
          integrity_before,
          integrity_after,
          profile,
          :combustion_integrity_loss,
          %{stage: stage_name(next_stage)}
        ) ++
        combustion_instance_effects(
          macro_index,
          material_id,
          next_stage,
          previous_stage,
          progress_percent,
          heat_output
        ) ++
        residue_effects(macro_index, profile, next_stage)

    %{
      macro_index: macro_index,
      material_id: material_id,
      stage: stage_name(next_stage),
      effects: effects,
      heat_source_points: heat_source_points,
      field_source_points: heat_source_points ++ smoke_source_points ++ oxygen_source_points
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
        structural_damage_effects(
          macro_index,
          material_id,
          integrity_before,
          integrity_after,
          profile,
          :oxygen_limited_carbonization,
          %{stage: :preheat}
        ) ++ oxygen_limited_residue_effects(macro_index, profile, carbon_before, carbon_after)

    %{
      macro_index: macro_index,
      material_id: material_id,
      stage: :preheat,
      effects: effects,
      heat_source_points: [],
      field_source_points: []
    }
  end

  defp extinguish(macro_index, material_id, reason) do
    %{
      macro_index: macro_index,
      material_id: material_id,
      stage: :extinguished,
      effects: [
        Effect.write_voxel_attribute(macro_index, :combustion_stage, @stage_extinguished),
        Effect.complete_phenomenon_instance(:combustion, macro_index, %{
          material_id: material_id,
          stage: :extinguished,
          reason: reason
        }),
        Effect.emit_observe("voxel_combustion_extinguished", %{
          macro_index: macro_index,
          material_id: material_id,
          reason: reason,
          stage: :extinguished
        })
      ],
      heat_source_points: [],
      field_source_points: []
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

  defp combustion_instance_effects(
         macro_index,
         material_id,
         @stage_extinguished,
         previous_stage,
         progress_percent,
         heat_output
       ) do
    maybe_start_effects =
      if previous_stage in [@stage_idle, @stage_preheat] do
        [
          Effect.upsert_phenomenon_instance(:combustion, macro_index, %{
            material_id: material_id,
            stage: :burning,
            previous_stage: stage_name(previous_stage),
            progress_percent: progress_percent,
            released_heat_energy_joules: heat_output.released_heat_energy_joules
          })
        ]
      else
        []
      end

    maybe_start_effects ++
      [
        Effect.complete_phenomenon_instance(:combustion, macro_index, %{
          material_id: material_id,
          stage: :extinguished,
          previous_stage: stage_name(previous_stage),
          reason: :fuel_exhausted,
          progress_percent: progress_percent,
          released_heat_energy_joules: heat_output.released_heat_energy_joules
        })
      ]
  end

  defp combustion_instance_effects(
         macro_index,
         material_id,
         next_stage,
         previous_stage,
         progress_percent,
         heat_output
       ) do
    [
      Effect.upsert_phenomenon_instance(:combustion, macro_index, %{
        material_id: material_id,
        stage: stage_name(next_stage),
        previous_stage: stage_name(previous_stage),
        progress_percent: progress_percent,
        heat_source_celsius: heat_output.source_temperature_celsius,
        released_heat_energy_joules: heat_output.released_heat_energy_joules
      })
    ]
  end

  defp heat_source_points(_macro_index, @stage_extinguished, _profile, _heat_output), do: []

  defp heat_source_points(macro_index, @stage_smoldering, profile, heat_output) do
    [
      %{
        macro_index: macro_index,
        field_type: :temperature,
        source_mode: :persistent,
        source_kind: :combustion,
        value: heat_output.source_temperature_celsius,
        heat_source_delta_celsius: heat_output.heat_source_delta_celsius,
        released_heat_energy_joules: heat_output.released_heat_energy_joules,
        combustion_heat_j_per_kg: combustion_heat_j_per_kg(profile),
        heat_release_efficiency: heat_release_efficiency(@stage_smoldering, profile)
      }
    ]
  end

  defp heat_source_points(macro_index, _stage, profile, heat_output) do
    [
      %{
        macro_index: macro_index,
        field_type: :temperature,
        source_mode: :persistent,
        source_kind: :combustion,
        value: heat_output.source_temperature_celsius,
        heat_source_delta_celsius: heat_output.heat_source_delta_celsius,
        released_heat_energy_joules: heat_output.released_heat_energy_joules,
        combustion_heat_j_per_kg: combustion_heat_j_per_kg(profile),
        heat_release_efficiency: heat_release_efficiency(:burning, profile)
      }
    ]
  end

  defp smoke_source_points(_macro_index, smoke_before, smoke_after, _burned_fuel)
       when smoke_after <= smoke_before do
    []
  end

  defp smoke_source_points(macro_index, smoke_before, smoke_after, burned_fuel) do
    [
      %{
        macro_index: macro_index,
        field_type: :smoke_density,
        source_mode: :impulse,
        source_kind: :combustion,
        value: smoke_after,
        smoke_density_percent: smoke_after,
        smoke_delta_percent: smoke_after - smoke_before,
        burned_fuel_kg_per_m3: burned_fuel
      }
    ]
  end

  defp oxygen_source_points(_macro_index, oxygen_before, oxygen_after)
       when oxygen_after >= oxygen_before do
    []
  end

  defp oxygen_source_points(macro_index, oxygen_before, oxygen_after) do
    [
      %{
        macro_index: macro_index,
        field_type: :oxygen,
        source_mode: :impulse,
        source_kind: :combustion,
        value: oxygen_after,
        oxygen_before_percent: oxygen_before,
        oxygen_after_percent: oxygen_after,
        oxygen_consumed_percent: oxygen_before - oxygen_after
      }
    ]
  end

  defp moisture_source_points(_macro_index, moisture_before, moisture_after)
       when moisture_after >= moisture_before do
    []
  end

  defp moisture_source_points(macro_index, moisture_before, moisture_after) do
    moisture_released = moisture_before - moisture_after

    [
      %{
        macro_index: macro_index,
        field_type: :moisture,
        source_mode: :impulse,
        source_kind: :combustion,
        value: moisture_released,
        moisture_before_kg_per_m3: moisture_before,
        moisture_after_kg_per_m3: moisture_after,
        moisture_released_kg_per_m3: moisture_released
      }
    ]
  end

  defp heat_source_output(
         _storage,
         _macro_index,
         _temperature_celsius,
         burned_fuel_kg_per_m3,
         @stage_extinguished,
         profile
       ) do
    %{
      released_heat_energy_joules:
        released_heat_energy_joules(burned_fuel_kg_per_m3, @stage_extinguished, profile),
      source_temperature_celsius: nil,
      heat_source_delta_celsius: nil
    }
  end

  defp heat_source_output(
         storage,
         macro_index,
         temperature_celsius,
         burned_fuel_kg_per_m3,
         next_stage,
         profile
       ) do
    released_heat_energy_joules =
      released_heat_energy_joules(burned_fuel_kg_per_m3, next_stage, profile)

    heat_capacity_j_per_k = heat_capacity_j_per_k(storage, macro_index, profile)

    uncapped_temperature =
      temperature_celsius + released_heat_energy_joules / heat_capacity_j_per_k

    source_temperature_celsius =
      uncapped_temperature
      |> min(heat_source_cap_celsius(next_stage, profile))

    %{
      released_heat_energy_joules: released_heat_energy_joules,
      source_temperature_celsius: source_temperature_celsius,
      heat_source_delta_celsius: source_temperature_celsius - temperature_celsius
    }
  end

  defp released_heat_energy_joules(burned_fuel_kg_per_m3, next_stage, profile) do
    burned_fuel_kg_per_m3 *
      @voxel_volume_cubic_meter *
      combustion_heat_j_per_kg(profile) *
      heat_release_efficiency(next_stage, profile)
  end

  defp heat_source_cap_celsius(@stage_smoldering, profile) do
    get_opt(profile, :smolder_heat_source_celsius, 350.0)
  end

  defp heat_source_cap_celsius(_stage, profile) do
    get_opt(profile, :heat_source_celsius, 650.0)
  end

  defp combustion_heat_j_per_kg(profile) do
    profile
    |> get_opt(:combustion_heat_j_per_kg, 16_000_000.0)
    |> non_negative_float(16_000_000.0)
  end

  defp heat_release_efficiency(@stage_smoldering, profile) do
    heat_release_efficiency(:burning, profile) *
      non_negative_float(get_opt(profile, :smolder_heat_release_fraction, 0.35), 0.35)
  end

  defp heat_release_efficiency(_stage, profile) do
    profile
    |> get_opt(:heat_release_efficiency, 1.0)
    |> non_negative_float(1.0)
  end

  defp heat_capacity_j_per_k(storage, macro_index, profile) do
    density =
      storage
      |> read_float(macro_index, "density", get_opt(profile, :density_kg_per_m3, 1.0))
      |> max(0.001)

    specific_heat_capacity =
      storage
      |> read_float(
        macro_index,
        "specific_heat_capacity",
        get_opt(profile, :specific_heat_capacity_j_per_kg_k, 1.0)
      )
      |> max(0.001)

    max(density * specific_heat_capacity * @voxel_volume_cubic_meter, @min_heat_capacity_j_per_k)
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

  defp structural_damage_effects(
         macro_index,
         material_id,
         integrity_before,
         integrity_after,
         profile,
         reason,
         context
       ) do
    StructuralIntegrity.damage_effects(
      macro_index,
      material_id,
      integrity_before,
      integrity_after,
      reason: reason,
      threshold_percent:
        get_opt(
          profile,
          :structural_failure_threshold_percent,
          StructuralIntegrity.default_failure_threshold_percent()
        ),
      context: context
    )
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

  defp non_negative_float(value, _fallback) when is_integer(value) and value >= 0 do
    value * 1.0
  end

  defp non_negative_float(value, _fallback) when is_float(value) and value >= 0.0, do: value
  defp non_negative_float(_value, fallback), do: fallback

  defp clamp(value, min_value, max_value) do
    value
    |> max(min_value)
    |> min(max_value)
  end

  defp resolve_profile(material_id, opts) do
    material_id
    |> MaterialCatalog.combustion_profile()
    |> merge_profile_override(get_opt(opts, :profile, nil))
    |> merge_profile_override(material_profile_override(opts, material_id))
  end

  defp merge_profile_override(nil, _override), do: nil

  defp merge_profile_override(profile, override) when is_map(profile) and is_map(override) do
    Map.merge(profile, override)
  end

  defp merge_profile_override(profile, _override), do: profile

  defp material_profile_override(opts, material_id) do
    opts
    |> get_opt(:profile_overrides, %{})
    |> opts_map()
    |> find_material_profile_override(material_id)
  end

  defp find_material_profile_override(overrides, material_id) when is_map(overrides) do
    string_material_id = to_string(material_id)

    cond do
      Map.has_key?(overrides, material_id) ->
        Map.fetch!(overrides, material_id)

      Map.has_key?(overrides, string_material_id) ->
        Map.fetch!(overrides, string_material_id)

      true ->
        nil
    end
  end

  defp find_material_profile_override(_overrides, _material_id), do: nil

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

  defp normalize_environment(environment) when is_map(environment), do: environment
  defp normalize_environment(_environment), do: %{}

  defp read_environment_float(environment, key, fallback_fun) when is_function(fallback_fun, 0) do
    case get_opt(environment, key, nil) do
      value when is_number(value) -> value * 1.0
      _other -> fallback_fun.()
    end
  end

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
