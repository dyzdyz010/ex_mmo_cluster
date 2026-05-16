defmodule SceneServer.Voxel.Field.DevFieldCreate do
  @moduledoc """
  Dev-only helper for applying heat-skill voxel attribute writes.

  Called from `AuthServerWeb.IngameController.voxel_dev_heat_voxel/2` via
  WorldServer cross-node dispatch.  The request writes a target temperature to the
  selected voxel; `FieldRuntime` then detects any temperature anomaly from
  authoritative voxel storage before creating a field region.
  """

  alias SceneServer.Voxel.Field.FieldRuntime

  @default_max_ticks 600

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
    base_opts = [
      logical_scene_id: Keyword.get(opts, :logical_scene_id, 1),
      world_macro: Keyword.get(opts, :world_macro, {0, 0, 0}),
      max_ticks: Keyword.get(opts, :max_ticks, @default_max_ticks),
      radius: Keyword.get(opts, :radius, 4)
    ]

    thermal_opts =
      if Keyword.has_key?(opts, :heat_energy_joules) do
        [heat_energy_joules: Keyword.fetch!(opts, :heat_energy_joules)]
      else
        [
          target_temperature_celsius:
            Keyword.get(
              opts,
              :target_temperature_celsius,
              Keyword.get(
                opts,
                :target_temperature,
                FieldRuntime.default_target_temperature_celsius()
              )
            )
        ]
      end

    FieldRuntime.ensure_temperature_anomaly(base_opts ++ thermal_opts)
  end
end
