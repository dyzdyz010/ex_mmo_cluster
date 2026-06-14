defmodule SceneServer.Voxel.Field.Kernels.ElectricPotentialKernel do
  @moduledoc """
  Phase 7.A kernel wrapping the electric potential path.

  `:ionization` is declared as a required layer because this kernel updates it.
  """

  @behaviour SceneServer.Voxel.Field.Kernel

  alias SceneServer.Voxel.Field.{ElectricField, FieldRegion, KernelContext, ModelCard}

  @impl true
  def kernel_id, do: :electric_potential

  @impl true
  def required_layers(_opts), do: [:electric_potential, :ionization]

  @impl true
  def model_card do
    ModelCard.new!(
      kernel_id: :electric_potential,
      fidelity_class: :semi_quantitative,
      model_version: 1,
      safety_valve: %{type: :aabb_bound, note: "chunk-local AABB 内 Dijkstra 电势传播,逐 tick 重算"},
      description: "导体图上的耦合坡印亭流电势传播 + 离子化(读旧 ionization 写新)",
      assumptions: ["macro-cell 电导图近似", "chunk-local AABB 边界", "击穿/离子化阈值简化"]
    )
  end

  @impl true
  def tick(%FieldRegion{} = region, %KernelContext{} = context, opts) do
    {:cont, ElectricField.tick(region, context.storage, electric_backend: backend_opt(opts)), []}
  end

  defp backend_opt(%{} = opts) do
    Map.get(opts, :electric_backend, Map.get(opts, "electric_backend", :native))
  end

  defp backend_opt(_opts), do: :native
end
