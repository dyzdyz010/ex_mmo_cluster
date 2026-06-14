defmodule MmoContracts.Envelope.BoundaryEvent do
  @moduledoc """
  跨 Cell 边界事件信封(`boundary_event`,EVENT 的冻结 subtype/extension,FROZEN-5 / XBOUND-3)。

  跨 Cell 影响范围事件(爆炸、攻击、火势传播、projectile 迁移)**必须**通过 boundary event 传递,
  并携带 **source/target 双 epoch**(XBOUND-3 / TIME-3 / ANTI-37),定义重复/延迟/拒绝策略。

  字段:`source_cell_id`、`target_cell_id`、`source_owner_epoch`、
  `target_owner_epoch` 或 `target_epoch_observed`、`source_cell_tick`、`tick_id`、`source_seq`、
  `event_id`、`idempotency_key`、`delivery_class`、`boundary_payload_version`、`payload`。
  """
  alias MmoContracts.Envelope

  defstruct [
    :source_cell_id,
    :target_cell_id,
    :source_owner_epoch,
    :target_owner_epoch,
    :target_epoch_observed,
    :source_cell_tick,
    :tick_id,
    :source_seq,
    :event_id,
    :idempotency_key,
    :delivery_class,
    :boundary_payload_version,
    :payload
  ]

  @type t :: %__MODULE__{
          source_cell_id: term() | nil,
          target_cell_id: term() | nil,
          source_owner_epoch: non_neg_integer() | nil,
          target_owner_epoch: non_neg_integer() | nil,
          target_epoch_observed: non_neg_integer() | nil,
          source_cell_tick: non_neg_integer() | nil,
          tick_id: non_neg_integer() | nil,
          source_seq: non_neg_integer() | nil,
          event_id: term() | nil,
          idempotency_key: term() | nil,
          delivery_class: term() | nil,
          boundary_payload_version: non_neg_integer() | nil,
          payload: term() | nil
        }

  @required [
    :source_cell_id,
    :target_cell_id,
    :source_owner_epoch,
    [:target_owner_epoch, :target_epoch_observed],
    :source_cell_tick,
    :tick_id,
    :source_seq,
    :event_id,
    :idempotency_key,
    :delivery_class,
    :boundary_payload_version
  ]

  @doc "必填规格(FROZEN-5 boundary_event,含 source/target 双 epoch)。"
  @spec required_fields() :: [Envelope.required_spec()]
  def required_fields, do: @required

  @doc "构造并校验,返回 `{:ok, t}` 或 `{:error, _}`。"
  @spec new(Enumerable.t()) :: {:ok, t()} | {:error, term()}
  def new(fields), do: Envelope.cast(__MODULE__, fields, @required)

  @doc "构造并校验,失败 raise。"
  @spec new!(Enumerable.t()) :: t()
  def new!(fields), do: Envelope.cast!(__MODULE__, fields, @required)
end
