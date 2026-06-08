defmodule SceneServer.Voxel.Field.Kernels.SmokeDiffusionKernel do
  @moduledoc """
  Field kernel for authoritative smoke-density diffusion.

  Combustion decides when smoke is produced and publishes smoke source points;
  this kernel owns the continuous smoke field layer that clients observe through
  the normal `FieldRegionSnapshot` path.
  """

  @behaviour SceneServer.Voxel.Field.Kernel

  alias SceneServer.Voxel.Field.{FieldRegion, KernelContext, ScalarField}

  @impl true
  def kernel_id, do: :smoke_diffusion

  @impl true
  def required_layers(_opts), do: [:smoke_density]

  @impl true
  def tick(%FieldRegion{} = region, %KernelContext{} = context, opts) do
    opts =
      opts
      |> opts_map()
      |> Map.put(:dt_seconds, max(context.dt_ms, 1) / 1000.0)

    {:cont, ScalarField.tick(region, :smoke_density, opts), []}
  end

  defp opts_map(opts) when is_map(opts), do: opts
  defp opts_map(_opts), do: %{}
end
