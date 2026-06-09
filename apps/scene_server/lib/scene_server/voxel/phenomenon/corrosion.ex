defmodule SceneServer.Voxel.Phenomenon.Corrosion do
  @moduledoc """
  Material-driven corrosion state machine for one macro voxel.

  The rule is pure: it reads authoritative voxel truth and material profiles,
  then returns structured effects. `ChunkProcess` remains the only owner that
  accepts or rejects durable voxel/object writes.
  """

  alias SceneServer.Voxel.MaterialCatalog
  alias SceneServer.Voxel.Phenomenon.{Effect, StructuralIntegrity}
  alias SceneServer.Voxel.Storage

  @fixed32_scale 65_536
  @percent_max 100.0
  @surface_clean 0
  @surface_exposed 1
  @surface_corroding 2
  @surface_weakened 3

  @type result :: %{
          macro_index: non_neg_integer(),
          material_id: non_neg_integer(),
          stage: atom(),
          effects: [Effect.t()],
          corrosion_after_percent: float(),
          electric_conductivity_after_ms_per_m: float()
        }

  @doc "Returns the enum value for a clean surface."
  @spec surface_clean() :: 0
  def surface_clean, do: @surface_clean

  @doc "Returns the enum value for chemically exposed but not yet corroding surfaces."
  @spec surface_exposed() :: 1
  def surface_exposed, do: @surface_exposed

  @doc "Returns the enum value for active corrosion."
  @spec surface_corroding() :: 2
  def surface_corroding, do: @surface_corroding

  @doc "Returns the enum value for a corrosion-weakened surface."
  @spec surface_weakened() :: 3
  def surface_weakened, do: @surface_weakened

  @doc "Names a surface-state enum value."
  @spec surface_name(integer()) :: atom()
  def surface_name(@surface_exposed), do: :exposed
  def surface_name(@surface_corroding), do: :corroding
  def surface_name(@surface_weakened), do: :weakened
  def surface_name(_surface), do: :clean

  @doc """
  Evaluates corrosion for one solid macro cell.

  Returns `:ignore` when the cell is empty, the material has no corrosion
  profile, or the chemical exposure is below the material threshold.
  """
  @spec evaluate(Storage.t() | nil, non_neg_integer(), map() | keyword()) :: result() | :ignore
  def evaluate(storage, macro_index, opts \\ %{})

  def evaluate(%Storage{} = storage, macro_index, opts) when is_integer(macro_index) do
    storage = Storage.ensure_accel(storage)
    opts = opts_map(opts)

    case Storage.normal_block_at(storage, macro_index) do
      nil ->
        :ignore

      block ->
        case MaterialCatalog.corrosion_profile(block.material_id) do
          nil ->
            :ignore

          profile ->
            evaluate_profile(storage, macro_index, block.material_id, profile, opts)
        end
    end
  rescue
    _exception in [ArgumentError, FunctionClauseError] -> :ignore
  end

  def evaluate(_storage, _macro_index, _opts), do: :ignore

  defp evaluate_profile(storage, macro_index, material_id, profile, opts) do
    moisture = read_float(storage, macro_index, "moisture", 0.0)
    chemical = read_float(storage, macro_index, "chemical_concentration", 0.0)
    previous_surface = read_int(storage, macro_index, "surface_state", @surface_clean)

    moisture_threshold =
      positive_float(get_opt(profile, :moisture_threshold_kg_per_m3, 25.0), 25.0)

    chemical_threshold = positive_float(get_opt(profile, :chemical_threshold_percent, 10.0), 10.0)

    cond do
      chemical < chemical_threshold ->
        :ignore

      moisture < moisture_threshold ->
        expose(macro_index, material_id, moisture, chemical, moisture_threshold, previous_surface)

      true ->
        corrode(
          storage,
          macro_index,
          material_id,
          profile,
          opts,
          moisture,
          chemical,
          moisture_threshold,
          chemical_threshold,
          previous_surface
        )
    end
  end

  defp expose(
         macro_index,
         material_id,
         moisture,
         chemical,
         moisture_threshold,
         previous_surface
       ) do
    effects =
      if previous_surface == @surface_exposed do
        []
      else
        [
          Effect.write_voxel_attribute(macro_index, :surface_state, @surface_exposed),
          Effect.emit_observe("voxel_corrosion_exposed", %{
            macro_index: macro_index,
            material_id: material_id,
            stage: :exposed,
            previous_stage: surface_name(previous_surface),
            moisture_kg_per_m3: moisture,
            moisture_threshold_kg_per_m3: moisture_threshold,
            chemical_concentration_percent: chemical
          })
        ]
      end

    if effects == [] do
      :ignore
    else
      %{
        macro_index: macro_index,
        material_id: material_id,
        stage: :exposed,
        effects: effects,
        corrosion_after_percent: 0.0,
        electric_conductivity_after_ms_per_m: 0.0
      }
    end
  end

  defp corrode(
         storage,
         macro_index,
         material_id,
         profile,
         opts,
         moisture,
         chemical,
         moisture_threshold,
         chemical_threshold,
         previous_surface
       ) do
    dt_seconds = positive_float(get_opt(opts, :dt_seconds, 0.1), 0.1)
    resistance = read_float(storage, macro_index, "corrosion_resistance", @percent_max)
    corrosion_before = read_float(storage, macro_index, "corrosion", 0.0)
    integrity_before = read_float(storage, macro_index, "structural_integrity", @percent_max)
    conductivity_before = read_float(storage, macro_index, "electric_conductivity", 0.0)

    requested_corrosion_delta =
      get_opt(profile, :corrosion_rate_percent_per_second, 1.0)
      |> non_negative_float(1.0)
      |> Kernel.*(dt_seconds)
      |> Kernel.*(resistance_factor(resistance))
      |> Kernel.*(exposure_factor(moisture, moisture_threshold))
      |> Kernel.*(exposure_factor(chemical, chemical_threshold))

    corrosion_after = clamp_percent(corrosion_before + requested_corrosion_delta)
    corrosion_delta = max(corrosion_after - corrosion_before, 0.0)

    stage =
      if corrosion_after >= get_opt(profile, :weakened_threshold_percent, 60.0) do
        :weakened
      else
        :corroding
      end

    next_surface =
      case stage do
        :weakened -> @surface_weakened
        :corroding -> @surface_corroding
      end

    integrity_after =
      clamp_percent(
        integrity_before -
          corrosion_delta *
            get_opt(profile, :structural_loss_percent_per_corrosion_percent, 0.25)
      )

    conductivity_after =
      conductivity_before *
        max(
          0.0,
          1.0 -
            corrosion_delta *
              get_opt(profile, :electric_conductivity_loss_percent_per_corrosion_percent, 1.0) /
              100.0
        )

    effects =
      [
        Effect.write_voxel_attribute(macro_index, :corrosion, fixed32(corrosion_after)),
        Effect.write_voxel_attribute(macro_index, :surface_state, next_surface),
        Effect.write_voxel_attribute(
          macro_index,
          :electric_conductivity,
          fixed32(conductivity_after)
        ),
        Effect.upsert_phenomenon_instance(:corrosion, macro_index, %{
          material_id: material_id,
          stage: stage,
          previous_stage: surface_name(previous_surface),
          corrosion_before_percent: corrosion_before,
          corrosion_after_percent: corrosion_after,
          moisture_kg_per_m3: moisture,
          chemical_concentration_percent: chemical
        }),
        Effect.emit_observe("voxel_corrosion_advanced", %{
          macro_index: macro_index,
          material_id: material_id,
          stage: stage,
          previous_stage: surface_name(previous_surface),
          corrosion_before_percent: corrosion_before,
          corrosion_after_percent: corrosion_after,
          corrosion_delta_percent: corrosion_delta,
          moisture_kg_per_m3: moisture,
          chemical_concentration_percent: chemical,
          corrosion_resistance_percent: resistance,
          structural_integrity_before_percent: integrity_before,
          structural_integrity_after_percent: integrity_after,
          electric_conductivity_before_ms_per_m: conductivity_before,
          electric_conductivity_after_ms_per_m: conductivity_after
        })
      ] ++
        StructuralIntegrity.damage_effects(
          macro_index,
          material_id,
          integrity_before,
          integrity_after,
          reason: :corrosion_integrity_loss,
          threshold_percent:
            get_opt(
              profile,
              :structural_failure_threshold_percent,
              StructuralIntegrity.default_failure_threshold_percent()
            ),
          context: %{
            stage: stage,
            corrosion_before_percent: corrosion_before,
            corrosion_after_percent: corrosion_after
          }
        )

    %{
      macro_index: macro_index,
      material_id: material_id,
      stage: stage,
      effects: effects,
      corrosion_after_percent: corrosion_after,
      electric_conductivity_after_ms_per_m: conductivity_after
    }
  end

  defp resistance_factor(resistance_percent) do
    (100.0 - clamp_percent(resistance_percent))
    |> Kernel./(100.0)
    |> clamp(0.05, 1.0)
  end

  defp exposure_factor(value, threshold) do
    value
    |> Kernel./(max(threshold, 0.001))
    |> clamp(1.0, 2.0)
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
