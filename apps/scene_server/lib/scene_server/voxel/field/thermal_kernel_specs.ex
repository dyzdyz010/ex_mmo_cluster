defmodule SceneServer.Voxel.Field.ThermalKernelSpecs do
  @moduledoc """
  Shared kernel bundle for temperature-driven local phenomena.

  Temperature diffusion, combustion, contained phase change, smoke, oxygen, and
  moisture must move as one lifecycle bundle. `FieldSource` uses this for user
  temperature requests; combustion self-heat and boundary heat handoffs reuse
  it instead of maintaining parallel kernel lists.
  """

  alias SceneServer.Voxel.Field.FieldRegion

  alias SceneServer.Voxel.Field.Kernels.{
    MoistureDiffusionKernel,
    OxygenDiffusionKernel,
    SmokeDiffusionKernel,
    TemperatureDiffusionKernel
  }

  alias SceneServer.Voxel.Phenomenon.{CombustionKernel, PhaseChangeKernel}

  @source_temperature_diffusion_time_scale 20_000.0
  @source_temperature_ambient_loss_per_second 0.08
  @source_temperature_cell_size_meters 1.0
  @smoke_diffusion_alpha 0.18
  @smoke_decay_per_second 0.08
  @oxygen_diffusion_alpha 0.12
  @oxygen_decay_per_second 0.04
  @moisture_diffusion_alpha 0.10
  @moisture_decay_per_second 0.06

  @doc "Returns the canonical thermal kernel chain for a direct temperature source."
  @spec temperature_source_specs(keyword() | map()) :: [map()]
  def temperature_source_specs(opts \\ %{}) do
    opts = opts_map(opts)
    combustion_opts = opts_map(get_opt(opts, :combustion_opts, %{}))

    [
      temperature_spec(%{
        diffusion_time_scale:
          float_opt(
            opts,
            :temperature_diffusion_time_scale,
            @source_temperature_diffusion_time_scale
          ),
        ambient_loss_per_second:
          float_opt(
            opts,
            :temperature_ambient_loss_per_second,
            @source_temperature_ambient_loss_per_second
          ),
        cell_size_meters:
          float_opt(opts, :temperature_cell_size_meters, @source_temperature_cell_size_meters)
      }),
      combustion_spec(get_opt(opts, :combustion_module, CombustionKernel), combustion_opts),
      phase_change_spec(%{}),
      smoke_spec(%{
        diffusion_alpha: float_opt(opts, :smoke_diffusion_alpha, @smoke_diffusion_alpha),
        decay_per_second: float_opt(opts, :smoke_decay_per_second, @smoke_decay_per_second)
      }),
      oxygen_spec(%{
        diffusion_alpha: float_opt(opts, :oxygen_diffusion_alpha, @oxygen_diffusion_alpha),
        decay_per_second: float_opt(opts, :oxygen_decay_per_second, @oxygen_decay_per_second)
      }),
      moisture_spec(%{
        diffusion_alpha: float_opt(opts, :moisture_diffusion_alpha, @moisture_diffusion_alpha),
        decay_per_second: float_opt(opts, :moisture_decay_per_second, @moisture_decay_per_second)
      })
    ]
  end

  @doc """
  Rebuilds a thermal chain from an existing region.

  Diffusion/phase-change specs are inherited from the region when present.
  Combustion opts come from the caller because owner/boundary heat handoffs must
  deliberately strip handoff-only options while preserving gameplay profile
  options.
  """
  @spec inherit_region_specs(FieldRegion.t(), keyword() | map()) :: [map()]
  def inherit_region_specs(%FieldRegion{} = region, opts \\ %{}) do
    opts = opts_map(opts)
    combustion_module = get_opt(opts, :combustion_module, CombustionKernel)
    combustion_opts = opts_map(get_opt(opts, :combustion_opts, %{}))

    [
      existing_spec(region, :temperature_diffusion, TemperatureDiffusionKernel) ||
        temperature_spec(%{
          diffusion_time_scale: 1.0,
          ambient_loss_per_second: 0.0,
          cell_size_meters: 1.0
        }),
      combustion_spec(combustion_module, combustion_opts),
      existing_spec(region, :phase_change, PhaseChangeKernel) || phase_change_spec(%{}),
      existing_spec(region, :smoke_diffusion, SmokeDiffusionKernel) ||
        smoke_spec(%{
          diffusion_alpha: @smoke_diffusion_alpha,
          decay_per_second: @smoke_decay_per_second
        }),
      existing_spec(region, :oxygen_diffusion, OxygenDiffusionKernel) ||
        oxygen_spec(%{
          diffusion_alpha: @oxygen_diffusion_alpha,
          decay_per_second: @oxygen_decay_per_second
        }),
      existing_spec(region, :moisture_diffusion, MoistureDiffusionKernel) ||
        moisture_spec(%{
          diffusion_alpha: @moisture_diffusion_alpha,
          decay_per_second: @moisture_decay_per_second
        })
    ]
  end

  defp temperature_spec(opts) do
    %{
      id: :temperature_diffusion,
      module: TemperatureDiffusionKernel,
      opts: opts
    }
  end

  defp combustion_spec(module, opts) do
    %{
      id: :combustion,
      module: module,
      opts: opts
    }
  end

  defp phase_change_spec(opts) do
    %{
      id: :phase_change,
      module: PhaseChangeKernel,
      opts: opts
    }
  end

  defp smoke_spec(opts) do
    %{
      id: :smoke_diffusion,
      module: SmokeDiffusionKernel,
      opts: opts
    }
  end

  defp oxygen_spec(opts) do
    %{
      id: :oxygen_diffusion,
      module: OxygenDiffusionKernel,
      opts: opts
    }
  end

  defp moisture_spec(opts) do
    %{
      id: :moisture_diffusion,
      module: MoistureDiffusionKernel,
      opts: opts
    }
  end

  defp existing_spec(%FieldRegion{} = region, id, module) do
    Enum.find(region.kernels, fn
      %{id: ^id} -> true
      %{module: ^module} -> true
      _other -> false
    end)
  end

  defp float_opt(opts, key, default) do
    case get_opt(opts, key, default) do
      value when is_integer(value) -> value * 1.0
      value when is_float(value) -> value
      _other -> default
    end
  end

  defp opts_map(opts) when is_map(opts), do: opts
  defp opts_map(opts) when is_list(opts), do: Map.new(opts)
  defp opts_map(_opts), do: %{}

  defp get_opt(opts, key, default) when is_map(opts) do
    cond do
      Map.has_key?(opts, key) -> Map.fetch!(opts, key)
      Map.has_key?(opts, Atom.to_string(key)) -> Map.fetch!(opts, Atom.to_string(key))
      true -> default
    end
  end

  defp get_opt(_opts, _key, default), do: default
end
