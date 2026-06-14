defmodule MmoContracts.Envelope.ReplicationOut do
  @moduledoc """
  复制层输出契约(REPL / FROZEN-5)。

  所有客户端可见状态**必须经 per-observer Replicator**(REPL-2)。Replicator **禁止**向客户端
  发布高于对应 `visibility_watermark` 的 authoritative 结果(AUTH-8)。

  字段:`observer_id`、`cell_id`、`snapshot_seq`、`delta_base`、`budget_class`、`priority_score`、
  `reliability_class`、`visibility_watermark`、`payload`。

  v2.0.2 分级:强制出口预算仅对**高频连续流**(移动/快照);低频离散事件可走全量/affected-chunk
  扇出 + AOI 裁剪(REPL-2 [v2.0.2])。`reliability_class` ∈
  reliable-ordered / reliable-unordered / unreliable-snapshot / bulk-stream(REPL-4 / NET-1)。
  """
  alias MmoContracts.Envelope

  defstruct [
    :observer_id,
    :cell_id,
    :snapshot_seq,
    :delta_base,
    :budget_class,
    :priority_score,
    :reliability_class,
    :visibility_watermark,
    :payload
  ]

  @type reliability_class ::
          :reliable_ordered | :reliable_unordered | :unreliable_snapshot | :bulk_stream

  @type t :: %__MODULE__{
          observer_id: term() | nil,
          cell_id: term() | nil,
          snapshot_seq: non_neg_integer() | nil,
          delta_base: non_neg_integer() | nil,
          budget_class: term() | nil,
          priority_score: number() | nil,
          reliability_class: reliability_class() | nil,
          visibility_watermark: non_neg_integer() | nil,
          payload: term() | nil
        }

  @reliability_classes [
    :reliable_ordered,
    :reliable_unordered,
    :unreliable_snapshot,
    :bulk_stream
  ]

  @required [:observer_id, :cell_id, :snapshot_seq, :reliability_class]

  @doc "合法可靠性类别(REPL-4 / NET-1)。"
  @spec reliability_classes() :: [reliability_class()]
  def reliability_classes, do: @reliability_classes

  @doc "必填规格(REPL / FROZEN-5)。"
  @spec required_fields() :: [Envelope.required_spec()]
  def required_fields, do: @required

  @doc "构造并校验(含 reliability_class 合法性),返回 `{:ok, t}` 或 `{:error, _}`。"
  @spec new(Enumerable.t()) :: {:ok, t()} | {:error, term()}
  def new(fields) do
    with {:ok, env} <- Envelope.cast(__MODULE__, fields, @required),
         :ok <- validate_reliability(env.reliability_class) do
      {:ok, env}
    end
  end

  @doc "构造并校验,失败 raise。"
  @spec new!(Enumerable.t()) :: t()
  def new!(fields) do
    case new(fields) do
      {:ok, env} -> env
      {:error, reason} -> raise ArgumentError, "ReplicationOut 非法: #{inspect(reason)}"
    end
  end

  defp validate_reliability(rc) when rc in @reliability_classes, do: :ok
  defp validate_reliability(rc), do: {:error, {:invalid_reliability_class, rc}}
end
