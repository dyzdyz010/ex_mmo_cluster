defmodule SceneServer.Voxel.Field.Kernels.OxygenDiffusionKernel do
  @moduledoc """
  Field kernel for local oxygen availability.

  Combustion publishes low-oxygen source points as it consumes air. This kernel
  diffuses that oxygen deficit through the same sparse scalar-field path used by
  smoke while decaying deficits back toward the 100% ambient baseline.
  """

  @behaviour SceneServer.Voxel.Field.Kernel

  alias SceneServer.Voxel.Field.{FieldRegion, KernelContext, ScalarField}

  @impl true
  def kernel_id, do: :oxygen_diffusion

  @impl true
  def required_layers(_opts), do: [:oxygen]

  @impl true
  def tick(%FieldRegion{} = region, %KernelContext{} = context, opts) do
    opts =
      opts
      |> opts_map()
      |> Map.put(:dt_seconds, max(context.dt_ms, 1) / 1000.0)
      |> Map.put_new(:min_value, 0.0)
      |> Map.put_new(:max_value, 100.0)

    {:cont, ScalarField.tick(region, :oxygen, opts), []}
  end

  defp opts_map(opts) when is_map(opts), do: opts
  defp opts_map(_opts), do: %{}
end
