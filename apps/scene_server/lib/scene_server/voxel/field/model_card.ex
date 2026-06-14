defmodule SceneServer.Voxel.Field.ModelCard do
  @moduledoc """
  涌现系统模型卡(梯队3 step3.11,EMG-1/3/7)。

  每个 field kernel(涌现系统)**必须**自描述一张模型卡,使其保真度与安全边界可审计:

    * `fidelity_class`(EMG-1):模型保真档——`:qualitative`(定性,如图/Dijkstra 路径)/
      `:semi_quantitative`(半定量,如 SI-ish stencil 弛豫,未严格守恒)/`:quantitative`(定量守恒)。
    * `safety_valve`(EMG-7):安全阀/熔断——声明该系统的预算上限 / 熔断机制(如 `max_frontier`
      搜索预算、活跃集上限),防失控涌现。
    * `assumptions`:模型成立的前提(如 1m voxel / 10Hz / 无 flux 守恒),透明记录已知局限。

  模型卡由 `kernel.model_card/0` 返回;`SceneServer.Voxel.Field.ModelCardRegistry` 汇总查询。
  """

  @fidelity_classes [:qualitative, :semi_quantitative, :quantitative]

  @enforce_keys [:kernel_id, :fidelity_class]
  defstruct [
    :kernel_id,
    :fidelity_class,
    model_version: 1,
    safety_valve: %{},
    description: "",
    assumptions: []
  ]

  @type fidelity_class :: :qualitative | :semi_quantitative | :quantitative
  @type t :: %__MODULE__{
          kernel_id: atom(),
          fidelity_class: fidelity_class(),
          model_version: non_neg_integer(),
          safety_valve: map(),
          description: String.t(),
          assumptions: [String.t()]
        }

  @doc "合法 fidelity_class 档位(EMG-1)。"
  @spec fidelity_classes() :: [fidelity_class()]
  def fidelity_classes, do: @fidelity_classes

  @doc "构造并校验模型卡(fidelity_class 合法 + safety_valve 为 map)。"
  @spec new!(Enumerable.t()) :: t()
  def new!(attrs) do
    attrs = Map.new(attrs)
    kernel_id = Map.fetch!(attrs, :kernel_id)
    fidelity_class = Map.fetch!(attrs, :fidelity_class)
    safety_valve = Map.get(attrs, :safety_valve, %{})

    unless is_atom(kernel_id) do
      raise ArgumentError, "ModelCard: kernel_id 必须是 atom,得 #{inspect(kernel_id)}"
    end

    unless fidelity_class in @fidelity_classes do
      raise ArgumentError,
            "ModelCard: 非法 fidelity_class #{inspect(fidelity_class)};合法 #{inspect(@fidelity_classes)}"
    end

    unless is_map(safety_valve) do
      raise ArgumentError, "ModelCard: safety_valve 必须是 map,得 #{inspect(safety_valve)}"
    end

    %__MODULE__{
      kernel_id: kernel_id,
      fidelity_class: fidelity_class,
      model_version: Map.get(attrs, :model_version, 1),
      safety_valve: safety_valve,
      description: Map.get(attrs, :description, ""),
      assumptions: Map.get(attrs, :assumptions, [])
    }
  end

  @doc "CLI / observe 紧凑摘要。"
  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = card) do
    %{
      kernel_id: card.kernel_id,
      fidelity_class: card.fidelity_class,
      model_version: card.model_version,
      safety_valve: card.safety_valve,
      assumption_count: length(card.assumptions)
    }
  end
end
