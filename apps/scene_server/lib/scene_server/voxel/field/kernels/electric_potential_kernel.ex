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
  def tick(%FieldRegion{} = region, %KernelContext{} = context, opts) do
    {:cont, ElectricField.tick(region, context.storage, electric_backend: backend_opt(opts)), []}
  end

  defp backend_opt(%{} = opts) do
    Map.get(opts, :electric_backend, Map.get(opts, "electric_backend", :native))
  end

  defp backend_opt(_opts), do: :native
end
