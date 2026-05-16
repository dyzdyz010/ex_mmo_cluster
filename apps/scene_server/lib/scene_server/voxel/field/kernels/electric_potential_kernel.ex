defmodule SceneServer.Voxel.Field.Kernels.ElectricPotentialKernel do
  @moduledoc """
  Phase 7.A kernel wrapping the electric potential path.

  `:ionization` is declared as a required layer because this kernel updates it.
  """

  @behaviour SceneServer.Voxel.Field.Kernel

  alias SceneServer.Voxel.Field.{ElectricField, FieldRegion, KernelContext}

  @impl true
  def kernel_id, do: :electric_potential

  @impl true
  def required_layers(_opts), do: [:electric_potential, :ionization]

  @impl true
  def tick(%FieldRegion{} = region, %KernelContext{} = context, _opts) do
    {:cont, ElectricField.tick(region, context.storage), []}
  end
end
