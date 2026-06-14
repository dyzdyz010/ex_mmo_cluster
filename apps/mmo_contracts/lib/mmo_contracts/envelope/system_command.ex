defmodule MmoContracts.Envelope.SystemCommand do
  @moduledoc """
  系统命令信封(AUTH-11 / FROZEN-5)。

  模拟系统(火、机器、生态、电热等)产生的 durable 后果,**必须**以 `system_actor` 命令
  形式进入 AUTH 路径,而非由规则层绕过 AUTH 直写 authoritative 状态(RULE-11 / ANTI-26)。

  在权威命令信封(`MmoContracts.Envelope.AuthCommand`)基础上增加
  `system_actor`、`rule_version`、`candidate_effect_id`、`idempotency_key`、`causation_id`。

  `system_actor` 必须具备 capability scope、经 policy registry 校验(AUTH-16/17);
  `idempotency_key` / `candidate_effect_id` 必须由稳定输入派生(RULE-16),禁止浮点原值/墙钟/进程随机。
  """
  alias MmoContracts.Envelope

  defstruct [
    # —— AuthCommand 基础字段 ——
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
    :payload,
    # —— 系统命令扩展(AUTH-11)——
    :system_actor,
    :rule_version,
    :candidate_effect_id,
    :idempotency_key,
    :causation_id
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
          payload: term() | nil,
          system_actor: term() | nil,
          rule_version: term() | nil,
          candidate_effect_id: term() | nil,
          idempotency_key: term() | nil,
          causation_id: term() | nil
        }

  # 系统命令由服务端模拟系统发起,无 client_seq;以 idempotency_key 做幂等。
  # candidate_effect_id 仅对"derived→authoritative 阈值提交"型 system command 必填,故不入此处硬必填。
  @required [
    :command_id,
    :cell_id,
    :owner_epoch,
    :system_actor,
    :rule_version,
    :idempotency_key,
    :causation_id,
    :payload_type,
    :payload_version,
    [:target_tick, :server_received_tick]
  ]

  @doc "必填规格(AUTH-11)。"
  @spec required_fields() :: [Envelope.required_spec()]
  def required_fields, do: @required

  @doc "构造并校验,返回 `{:ok, t}` 或 `{:error, _}`。"
  @spec new(Enumerable.t()) :: {:ok, t()} | {:error, term()}
  def new(fields), do: Envelope.cast(__MODULE__, fields, @required)

  @doc "构造并校验,失败 raise。"
  @spec new!(Enumerable.t()) :: t()
  def new!(fields), do: Envelope.cast!(__MODULE__, fields, @required)
end
