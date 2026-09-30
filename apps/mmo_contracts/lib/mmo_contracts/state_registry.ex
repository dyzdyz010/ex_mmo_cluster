defmodule MmoContracts.StateRegistry do
  @moduledoc """
  PERS-5 状态分类**清单的单一来源**(manifest-as-data)。

  登记主要状态持有者及其 `state_class`,作为"每个状态都已分类"的可审计依据(PERS-5:
  未分类禁止进入生产代码)。`holder` 以模块名(atom)登记,**不**产生对那些 app 的编译依赖
  (仅是 atom 字面量),故本契约库保持零 sibling 依赖。

  与 `MmoContracts.StateClassed` 配套:各持有者模块用 `use MmoContracts.StateClassed, class: ...`
  做**编译期**自声明;本清单做**集中登记**;迁移测试断言二者一致(梯队 0 step 0.5)。

  > 本清单随迁移推进**增量补全**。
  """
  alias MmoContracts.StateClass

  @type entry :: %{
          holder: module(),
          state_class: StateClass.t(),
          app: atom(),
          spec: String.t(),
          note: String.t()
        }

  @entries [
    # —— durable_authoritative:成功确认前必须可恢复(AUTH-2/PERS-6)——
    %{
      holder: DataService.Voxel.OverlayLogStore,
      state_class: :durable_authoritative,
      app: :data_service,
      spec: "Voxim R6 决策稿 §9 第 1 项",
      note: "Voxim region 世界的权威 overlay 日志（VoxelRegion.World 事务按条目落行，压实 = 替换为检查点）"
    },
    %{
      holder: DataService.Schema.Account,
      state_class: :durable_authoritative,
      app: :data_service,
      spec: "PERS-5",
      note: "账户"
    },
    %{
      holder: DataService.Schema.Character,
      state_class: :durable_authoritative,
      app: :data_service,
      spec: "PERS-5",
      note: "角色"
    }
  ]

  @doc "全部登记条目。"
  @spec entries() :: [entry()]
  def entries, do: @entries

  @doc "按 state_class 过滤。"
  @spec by_class(StateClass.t()) :: [entry()]
  def by_class(class), do: Enum.filter(@entries, &(&1.state_class == class))

  @doc "登记的持有者模块列表。"
  @spec holders() :: [module()]
  def holders, do: Enum.map(@entries, & &1.holder)

  @doc "条目数。"
  @spec count() :: non_neg_integer()
  def count, do: length(@entries)

  @doc """
  校验清单完整性:每条 `state_class` 合法(PERS-5)、`holder` 无重复。失败 raise。
  """
  @spec validate!() :: :ok
  def validate! do
    Enum.each(@entries, fn e -> StateClass.fetch!(e.state_class) end)

    holders = holders()
    dups = holders -- Enum.uniq(holders)

    if dups != [] do
      raise ArgumentError, "StateRegistry 重复登记 holder: #{inspect(Enum.uniq(dups))}"
    end

    :ok
  end
end
