defmodule MmoContracts.Envelope.CandidateEffect do
  @moduledoc """
  候选效果信封(`candidate_effect`,`derived→authoritative` 阈值提交的冻结 subtype,FROZEN-5)。

  局部规则可产生 `candidate_effect`(如"温度超过燃点,木块可燃");但只要该结果会改变
  authoritative 状态,就**必须**经 `AUTH-11` 的 system_actor 命令提交(RULE-11),进入 AUTH 前
  **必须**满足阈值锁存(RULE-15)与稳定幂等键(RULE-16)。

  `candidate_effect_id` **必须**由稳定输入派生(`cell_id + rule_id + rule_version +
  affected_object_id + quantized_condition_bucket + source_seq/tick_range`),
  **禁止**使用浮点原值/进程随机/墙钟(RULE-16)。

  字段:`candidate_effect_id`、`rule_id`、`rule_version`、`affected_object_id`、
  `quantized_condition_bucket`、`source_seq` 或 `tick_range`、`threshold_profile`、`latch_status`、
  `causation_id`、`state_class`、`payload_version`、`payload`。
  """
  alias MmoContracts.{Envelope, StateClass}

  defstruct [
    :candidate_effect_id,
    :rule_id,
    :rule_version,
    :affected_object_id,
    :quantized_condition_bucket,
    :source_seq,
    :tick_range,
    :threshold_profile,
    :latch_status,
    :causation_id,
    :state_class,
    :payload_version,
    :payload
  ]

  @type t :: %__MODULE__{
          candidate_effect_id: term() | nil,
          rule_id: term() | nil,
          rule_version: term() | nil,
          affected_object_id: term() | nil,
          quantized_condition_bucket: term() | nil,
          source_seq: non_neg_integer() | nil,
          tick_range: term() | nil,
          threshold_profile: term() | nil,
          latch_status: term() | nil,
          causation_id: term() | nil,
          state_class: StateClass.t() | nil,
          payload_version: non_neg_integer() | nil,
          payload: term() | nil
        }

  @required [
    :candidate_effect_id,
    :rule_id,
    :rule_version,
    :affected_object_id,
    :quantized_condition_bucket,
    :latch_status,
    :state_class,
    :payload_version,
    [:source_seq, :tick_range]
  ]

  @doc "必填规格(FROZEN-5 candidate_effect)。"
  @spec required_fields() :: [Envelope.required_spec()]
  def required_fields, do: @required

  @doc "构造并校验(含 state_class 合法性,RULE-12 派生分类)。"
  @spec new(Enumerable.t()) :: {:ok, t()} | {:error, term()}
  def new(fields) do
    with {:ok, eff} <- Envelope.cast(__MODULE__, fields, @required),
         :ok <- validate_state_class(eff.state_class) do
      {:ok, eff}
    end
  end

  @doc "构造并校验,失败 raise。"
  @spec new!(Enumerable.t()) :: t()
  def new!(fields) do
    case new(fields) do
      {:ok, eff} -> eff
      {:error, reason} -> raise ArgumentError, "CandidateEffect 非法: #{inspect(reason)}"
    end
  end

  defp validate_state_class(class) do
    if StateClass.valid?(class), do: :ok, else: {:error, {:invalid_state_class, class}}
  end
end
