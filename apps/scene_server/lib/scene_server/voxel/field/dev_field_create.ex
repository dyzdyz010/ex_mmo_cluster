defmodule SceneServer.Voxel.Field.DevFieldCreate do
  @moduledoc """
  Dev-only helper for applying target-temperature voxel attribute writes.

  Called from `AuthServerWeb.IngameController.voxel_set_temperature/2` and the
  legacy heat alias via WorldServer cross-node dispatch. The request writes a
  target temperature to the selected voxel; `FieldRuntime` then detects any
  temperature anomaly from authoritative voxel storage before creating a field
  region.
  """

  alias SceneServer.Voxel.Field.FieldRuntime
  alias SceneServer.Voxel.Phenomenon.CombustionProbe

  @default_max_ticks 600
  @default_conduction_max_ticks 120

  @doc """
  Applies a skill-like heat action at an exact world-macro voxel.

  Options:
    * `:logical_scene_id` (default 1)
    * `:world_macro`      `{x, y, z}`
    * `:target_temperature_celsius` (default 800 °C), converted to the heat
      budget through voxel material density/specific heat in the write summary
    * `:max_ticks`        (default 600 = 60 s at 10 Hz)
    * `:radius`           local FieldRegion radius around the source voxel
  """
  @spec heat_voxel(keyword()) :: {:ok, map()} | {:error, term()}
  def heat_voxel(opts \\ []) do
    if Keyword.has_key?(opts, :heat_energy_joules) do
      legacy_heat_voxel(opts)
    else
      set_temperature(opts)
    end
  end

  @doc """
  Sets an exact world-macro voxel to a target Celsius value.

  Options match `heat_voxel/1`, but cooling and ambient restore must be
  expressed through `:target_temperature_celsius` / `:restore_ambient`, not
  negative heat energy.
  """
  @spec set_temperature(keyword()) :: {:ok, map()} | {:error, term()}
  def set_temperature(opts \\ []) do
    base_opts =
      [
        logical_scene_id: Keyword.get(opts, :logical_scene_id, 1),
        world_macro: Keyword.get(opts, :world_macro, {0, 0, 0}),
        max_ticks: Keyword.get(opts, :max_ticks, @default_max_ticks),
        radius: Keyword.get(opts, :radius, 4)
      ]
      |> maybe_put(:lease, Keyword.get(opts, :lease))
      |> maybe_put(:lease_token, Keyword.get(opts, :lease_token))

    thermal_opts = [
      target_temperature_celsius:
        Keyword.get(
          opts,
          :target_temperature_celsius,
          Keyword.get(
            opts,
            :target_temperature,
            FieldRuntime.default_target_temperature_celsius()
          )
        ),
      restore_ambient: Keyword.get(opts, :restore_ambient, false)
    ]

    FieldRuntime.ensure_set_temperature(base_opts ++ thermal_opts)
  end

  @doc """
  Creates a chunk-local electric conduction field from a source world-macro
  voxel to a target world-macro voxel.

  Unlike `set_temperature/1`, this helper does not mutate voxel attributes. It
  only asks `FieldRuntime` to create the selected electric kernel region so the
  normal field snapshot pipeline can expose the electric/ionization layers to
  the browser field overlay. Optional `:conduction_mode` selects material
  conduction (`:conductive`) or dielectric breakdown (`:discharge`) without
  changing the source lifecycle. Optional `:owner_ref`, `:source_mode`,
  `:ttl_ticks`, `:output_mode`, `:voltage`, `:current_limit_amps`,
  `:load_current_amps`, `:frequency_hz`, and `:energy_budget_joules` are forwarded into the normalized
  electric `FieldSource` so dev/browser requests exercise the same lifecycle
  and power-source boundary as future gameplay sources.
  """
  @spec conduct_path(keyword()) :: {:ok, map()} | {:error, term()}
  def conduct_path(opts \\ []) do
    [
      logical_scene_id: Keyword.get(opts, :logical_scene_id, 1),
      source_world_macro: Keyword.get(opts, :source_world_macro, {0, 0, 0}),
      target_world_macro: Keyword.get(opts, :target_world_macro, {0, 0, 0}),
      source_potential: Keyword.get(opts, :source_potential, 120.0),
      max_ticks: Keyword.get(opts, :max_ticks, @default_conduction_max_ticks),
      radius: Keyword.get(opts, :radius, 1),
      max_frontier: Keyword.get(opts, :max_frontier, 512)
    ]
    |> maybe_put(:ttl_ticks, Keyword.get(opts, :ttl_ticks))
    |> maybe_put(:conduction_mode, Keyword.get(opts, :conduction_mode))
    |> maybe_put(:source_mode, Keyword.get(opts, :source_mode))
    |> maybe_put(:owner_ref, Keyword.get(opts, :owner_ref))
    |> maybe_put(:output_mode, Keyword.get(opts, :output_mode))
    |> maybe_put(:voltage, Keyword.get(opts, :voltage))
    |> maybe_put(:current_limit_amps, Keyword.get(opts, :current_limit_amps))
    |> maybe_put(:load_current_amps, Keyword.get(opts, :load_current_amps))
    |> maybe_put(:frequency_hz, Keyword.get(opts, :frequency_hz))
    |> maybe_put(:energy_budget_joules, Keyword.get(opts, :energy_budget_joules))
    |> FieldRuntime.ensure_conduction_path()
  end

  @doc """
  Creates or refreshes a chunk-local automatic circuit field around a world
  macro. This is target-free: the kernel reads power/load/conductor topology
  every tick and emits current only when a valid source-load component exists.
  """
  @spec auto_circuit(keyword()) :: {:ok, map()} | {:error, term()}
  def auto_circuit(opts \\ []) do
    [
      logical_scene_id: Keyword.get(opts, :logical_scene_id, 1),
      world_macro: Keyword.get(opts, :world_macro, {0, 0, 0}),
      max_ticks: Keyword.get(opts, :max_ticks, @default_max_ticks)
    ]
    |> maybe_put(:voltage, Keyword.get(opts, :voltage))
    |> maybe_put(:current_limit_amps, Keyword.get(opts, :current_limit_amps))
    |> maybe_put(:lease, Keyword.get(opts, :lease))
    |> FieldRuntime.ensure_auto_circuit()
  end

  @doc """
  Reads the authoritative combustion state of one world-macro voxel.

  This is a pure observation helper for browser/dev CLI diagnostics. It does
  not create a field region or mutate voxel truth.
  """
  @spec combustion_probe(keyword()) :: {:ok, map()} | {:error, term()}
  def combustion_probe(opts \\ []) do
    CombustionProbe.probe(opts)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp legacy_heat_voxel(opts) do
    base_opts =
      [
        logical_scene_id: Keyword.get(opts, :logical_scene_id, 1),
        world_macro: Keyword.get(opts, :world_macro, {0, 0, 0}),
        max_ticks: Keyword.get(opts, :max_ticks, @default_max_ticks),
        radius: Keyword.get(opts, :radius, 4)
      ]
      |> maybe_put(:lease, Keyword.get(opts, :lease))
      |> maybe_put(:lease_token, Keyword.get(opts, :lease_token))

    thermal_opts = [heat_energy_joules: Keyword.fetch!(opts, :heat_energy_joules)]

    FieldRuntime.ensure_temperature_anomaly(base_opts ++ thermal_opts)
  end
end
