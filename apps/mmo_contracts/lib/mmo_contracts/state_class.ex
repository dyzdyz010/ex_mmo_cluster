defmodule MmoContracts.StateClass do
  @moduledoc """
  PERS-5 状态四分类的**单一来源**。

  规范要求:任何状态进入系统前必须声明为下列四类之一;**未分类禁止进入生产代码**(PERS-5)。

  | 分类 | 含义 | 示例 | 提交/恢复要求 |
  |------|------|------|----------------|
  | `:durable_authoritative` | 持久权威,成功确认前必须可恢复 | 方块变更、机器库存、建筑归属、经济账本、交易 | 走 AUTH-2 提交路径;客户端确认**必须晚于** durable commit(PERS-6) |
  | `:runtime_authoritative` | 运行时权威,服务端裁决为准,不要求每 tick durable commit | 玩家位置/速度/姿态、短时 combat movement、AI 临时状态 | 必须声明 input WAL / ring buffer / checkpoint / snapshot 恢复策略(AUTH-15/PERS-12) |
  | `:derived` | 派生,可重建 | 温湿度微观场、缓存索引、网格化结果 | 重建算法必须版本化;**不**走 durable-commit;触发权威后果须经 system_actor(AUTH-11/PERS-9) |
  | `:ephemeral` | 临时,可丢失 | 视觉粒子、纯表现烟雾、非关键 AI 中间态 | 必须声明可丢失边界;**禁止**影响经济/资产/建筑/任务/战斗最终结算(PERS-8) |

  相关:`AUTH-2`、`AUTH-15`、`PERS-1/5/6/8/9/12`、`PRIN-7`。
  """

  @typedoc "PERS-5 四分类之一"
  @type t :: :durable_authoritative | :runtime_authoritative | :derived | :ephemeral

  @all [:durable_authoritative, :runtime_authoritative, :derived, :ephemeral]

  @doc "全部合法状态分类(PERS-5)。"
  @spec all() :: [t()]
  def all, do: @all

  @doc "是否为合法状态分类。"
  @spec valid?(term()) :: boolean()
  def valid?(class), do: class in @all

  @doc """
  校验并返回 `class`;非法则 raise。

  用于"未分类禁止进入生产代码"(PERS-5)的硬约束点。
  """
  @spec fetch!(term()) :: t()
  def fetch!(class) when class in @all, do: class

  def fetch!(other) do
    raise ArgumentError,
          "invalid state_class: #{inspect(other)};必须是 PERS-5 四分类之一: #{inspect(@all)}"
  end

  @doc """
  该分类的客户端成功确认是否**必须晚于** durable commit(AUTH-2 / PERS-6)。

  仅 `:durable_authoritative` 为 `true`;`:runtime_authoritative` 走 checkpoint/input log(AUTH-15),
  `:derived` / `:ephemeral` 不走 durable-commit 路径。
  """
  @spec durable_commit_required?(t()) :: boolean()
  def durable_commit_required?(:durable_authoritative), do: true
  def durable_commit_required?(class) when class in @all, do: false

  @doc """
  该分类是否**允许**影响经济/资产/建筑/任务/战斗最终结算。

  `:ephemeral` 禁止(PERS-8);其余允许(`:derived` 须经 AUTH-11 system_actor 落地,见 `PERS-9`)。
  """
  @spec may_affect_settlement?(t()) :: boolean()
  def may_affect_settlement?(:ephemeral), do: false
  def may_affect_settlement?(class) when class in @all, do: true

  @doc """
  该分类是否要求声明**恢复策略**。

  `:durable_authoritative`(持久化/WAL 恢复)与 `:runtime_authoritative`(checkpoint/input log,PERS-12)
  必须声明恢复来源;`:derived` 由重建算法恢复(PERS-3/7);`:ephemeral` 可丢失。
  """
  @spec recovery_required?(t()) :: boolean()
  def recovery_required?(class) when class in [:durable_authoritative, :runtime_authoritative],
    do: true

  def recovery_required?(class) when class in @all, do: false
end
