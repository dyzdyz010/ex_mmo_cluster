defmodule MmoContracts.Envelope.CellTime do
  @moduledoc """
  Cell 时间字段(TIME / FROZEN-5)。

  每个 Cell 维护单调递增 `cell_tick` 与 `sim_time`;所有权变更**禁止**重置 `cell_tick`(TIME-1)。
  time dilation 只改变 `sim_time` 推进速率,**禁止**破坏权威事件全序(TIME-4)。
  复制消息**必须**携带 `snapshot_tick` 或 `snapshot_seq`;客户端**只基于** `snapshot_tick` 做插值/预测/纠错(TIME-5)。

  字段:`cell_tick`、`sim_time`、`dilation_ratio`、`snapshot_tick`、`snapshot_seq`。
  """
  alias MmoContracts.Envelope

  defstruct [
    :cell_tick,
    :sim_time,
    :dilation_ratio,
    :snapshot_tick,
    :snapshot_seq
  ]

  @type t :: %__MODULE__{
          cell_tick: non_neg_integer() | nil,
          sim_time: number() | nil,
          dilation_ratio: number() | nil,
          snapshot_tick: non_neg_integer() | nil,
          snapshot_seq: non_neg_integer() | nil
        }

  @required [:cell_tick, :sim_time]

  @doc "必填规格(TIME-1)。"
  @spec required_fields() :: [Envelope.required_spec()]
  def required_fields, do: @required

  @doc "构造并校验,返回 `{:ok, t}` 或 `{:error, _}`。"
  @spec new(Enumerable.t()) :: {:ok, t()} | {:error, term()}
  def new(fields), do: Envelope.cast(__MODULE__, fields, @required)

  @doc "构造并校验,失败 raise。"
  @spec new!(Enumerable.t()) :: t()
  def new!(fields), do: Envelope.cast!(__MODULE__, fields, @required)
end
