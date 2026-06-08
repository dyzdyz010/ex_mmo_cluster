defmodule SceneServer.Voxel.Field.Kernels.MoistureDiffusionKernel do
  @moduledoc """
  Field kernel for local moisture and water-vapor diffusion.

  Combustion publishes moisture source points when high heat dries wet
  materials. This kernel owns the continuous moisture layer so released vapor
  can spread and fade through the same sparse scalar-field path as smoke.
  """

  @behaviour SceneServer.Voxel.Field.Kernel

  alias SceneServer.Voxel.Field.{FieldRegion, KernelContext, ScalarField}

  @impl true
  def kernel_id, do: :moisture_diffusion

  @impl true
  def required_layers(_opts), do: [:moisture]

  @impl true
  def tick(%FieldRegion{} = region, %KernelContext{}, opts) do
    opts =
      opts
      |> opts_map()
      |> Map.put_new(:min_value, 0.0)
      |> Map.put_new(:max_value, 1_000.0)

    {:cont, ScalarField.tick(region, :moisture, opts), []}
  end

  defp opts_map(opts) when is_map(opts), do: opts
  defp opts_map(_opts), do: %{}
end
