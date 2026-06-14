defmodule SceneServer.Voxel.Field.ModelCardRegistry do
  @moduledoc """
  涌现系统模型卡登记处(梯队3 step3.11,EMG-1/3/7)。

  汇总所有 field kernel(涌现系统)的模型卡,作为审计/可观测的单一真相源:
  每个被登记的 kernel 必须实现 `SceneServer.Voxel.Field.Kernel.model_card/0`(behaviour
  强制),登记处只做枚举与聚合查询,不持有任何状态。

  新增涌现 kernel 时必须在 `@kernel_modules` 注册,否则其模型卡不可审计——这是刻意的
  显式纪律,不做自动模块扫描(避免把非涌现 behaviour 实现误纳入)。
  """

  alias SceneServer.Voxel.Field.ModelCard

  alias SceneServer.Voxel.Field.Kernels.{
    CircuitCurrentKernel,
    ConductionPathKernel,
    ElectricDischargeKernel,
    ElectricPotentialKernel,
    ReactionKernel,
    TemperatureDiffusionKernel
  }

  @kernel_modules [
    TemperatureDiffusionKernel,
    ElectricPotentialKernel,
    ConductionPathKernel,
    ElectricDischargeKernel,
    CircuitCurrentKernel,
    # 功能完善 · 反应层 R3:涌现反应驱动 kernel(材料相变等)。
    ReactionKernel
  ]

  @doc "已登记的涌现 kernel 模块列表。"
  @spec kernel_modules() :: [module()]
  def kernel_modules, do: @kernel_modules

  @doc "全部已登记 kernel 的模型卡。"
  @spec cards() :: [ModelCard.t()]
  def cards, do: Enum.map(@kernel_modules, & &1.model_card())

  @doc "以 kernel_id 为键的模型卡映射。"
  @spec by_kernel_id() :: %{atom() => ModelCard.t()}
  def by_kernel_id do
    Map.new(cards(), fn %ModelCard{kernel_id: kernel_id} = card -> {kernel_id, card} end)
  end

  @doc "按 kernel_id 查询单张模型卡。"
  @spec fetch(atom()) :: {:ok, ModelCard.t()} | :error
  def fetch(kernel_id) when is_atom(kernel_id) do
    case Map.fetch(by_kernel_id(), kernel_id) do
      {:ok, card} -> {:ok, card}
      :error -> :error
    end
  end

  @doc "CLI / observe 用的紧凑摘要列表(每张卡 `ModelCard.summary/1`)。"
  @spec summaries() :: [map()]
  def summaries, do: Enum.map(cards(), &ModelCard.summary/1)
end
