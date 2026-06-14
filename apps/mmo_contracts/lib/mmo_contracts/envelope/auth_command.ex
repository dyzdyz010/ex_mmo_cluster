defmodule MmoContracts.Envelope.AuthCommand do
  @moduledoc """
  权威命令信封(AUTH-1 / FROZEN-5)。

  所有改变**权威**世界状态的命令的统一信封。客户端只发意图(PRIN-8 / SEC-1),
  权限/规则/前置条件由 CellServer 或 Domain Module 裁决(BND-3 / SEC-3)。

  字段:`command_id`(全局唯一)、`actor_id`、`cell_id`、`owner_epoch`、`client_seq`、
  `target_tick` 或 `server_received_tick`、`precondition`、`payload_type`、`payload_version`、`payload`。
  """
  alias MmoContracts.Envelope

  @enforce_keys []
  defstruct [
    :command_id,
    :actor_id,
    :cell_id,
    :owner_epoch,
    :client_seq,
    :target_tick,
    :server_received_tick,
    :precondition,
    :payload_type,
    :payload_version,
    :payload
  ]

  @type t :: %__MODULE__{
          command_id: term() | nil,
          actor_id: term() | nil,
          cell_id: term() | nil,
          owner_epoch: non_neg_integer() | nil,
          client_seq: non_neg_integer() | nil,
          target_tick: non_neg_integer() | nil,
          server_received_tick: non_neg_integer() | nil,
          precondition: term() | nil,
          payload_type: term() | nil,
          payload_version: non_neg_integer() | nil,
          payload: term() | nil
        }

  @required [
    :command_id,
    :actor_id,
    :cell_id,
    :owner_epoch,
    :client_seq,
    :payload_type,
    :payload_version,
    [:target_tick, :server_received_tick]
  ]

  @doc "必填规格(AUTH-1)。"
  @spec required_fields() :: [Envelope.required_spec()]
  def required_fields, do: @required

  @doc "构造并校验,返回 `{:ok, t}` 或 `{:error, _}`。"
  @spec new(Enumerable.t()) :: {:ok, t()} | {:error, term()}
  def new(fields), do: Envelope.cast(__MODULE__, fields, @required)

  @doc "构造并校验,失败 raise。"
  @spec new!(Enumerable.t()) :: t()
  def new!(fields), do: Envelope.cast!(__MODULE__, fields, @required)
end
