defmodule MmoContracts.Envelope.AuthEvent do
  @moduledoc """
  权威事件信封(EVENT-2 / FROZEN-5)。

  所有服务端内部事件的统一 event envelope。消费者**必须**按 `event_id` 或
  `(cell_id, owner_epoch, cell_seq)` 支持幂等(EVENT-3)。

  最小字段(EVENT-2):`event_id`、`event_type`、`schema_version`、`cell_id`、`owner_epoch`、
  `cell_seq`、`tick_id`、`causation_id`、`correlation_id`、`actor_id`、`delivery_class`、
  `created_at`、`payload`。

  普通 Cell-local event 中 `cell_id`/`owner_epoch` 表示事件归属 Cell;对 boundary event 见
  `MmoContracts.Envelope.BoundaryEvent`(EVENT 的冻结 subtype/extension)。
  """
  alias MmoContracts.Envelope

  defstruct [
    :event_id,
    :event_type,
    :schema_version,
    :cell_id,
    :owner_epoch,
    :cell_seq,
    :tick_id,
    :causation_id,
    :correlation_id,
    :actor_id,
    :delivery_class,
    :created_at,
    :payload
  ]

  @type t :: %__MODULE__{
          event_id: term() | nil,
          event_type: term() | nil,
          schema_version: non_neg_integer() | nil,
          cell_id: term() | nil,
          owner_epoch: non_neg_integer() | nil,
          cell_seq: non_neg_integer() | nil,
          tick_id: non_neg_integer() | nil,
          causation_id: term() | nil,
          correlation_id: term() | nil,
          actor_id: term() | nil,
          delivery_class: term() | nil,
          created_at: term() | nil,
          payload: term() | nil
        }

  # correlation_id/actor_id 在系统事件中可为空(无外部 actor),故不入硬必填。
  @required [
    :event_id,
    :event_type,
    :schema_version,
    :cell_id,
    :owner_epoch,
    :cell_seq,
    :tick_id,
    :delivery_class
  ]

  @doc "必填规格(EVENT-2)。"
  @spec required_fields() :: [Envelope.required_spec()]
  def required_fields, do: @required

  @doc "构造并校验,返回 `{:ok, t}` 或 `{:error, _}`。"
  @spec new(Enumerable.t()) :: {:ok, t()} | {:error, term()}
  def new(fields), do: Envelope.cast(__MODULE__, fields, @required)

  @doc "构造并校验,失败 raise。"
  @spec new!(Enumerable.t()) :: t()
  def new!(fields), do: Envelope.cast!(__MODULE__, fields, @required)
end
