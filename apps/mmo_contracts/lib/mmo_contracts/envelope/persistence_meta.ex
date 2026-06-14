defmodule MmoContracts.Envelope.PersistenceMeta do
  @moduledoc """
  持久化分类标记(PERS / FROZEN-5)。

  任何状态进入系统前**必须**声明 `state_class`(PERS-5,见 `MmoContracts.StateClass`)。
  `derived` 重建算法**必须**版本化(`rebuild_algorithm_version`,PERS-7);`commit_watermark` /
  `visibility_watermark` 服务于 durable outbox 与复制可见性闸门(AUTH-8/9/10)。

  字段:`state_class`、`schema_version`、`commit_watermark`、`visibility_watermark`、
  `replay_source`、`rebuild_algorithm_version`。
  """
  alias MmoContracts.{Envelope, StateClass}

  defstruct [
    :state_class,
    :schema_version,
    :commit_watermark,
    :visibility_watermark,
    :replay_source,
    :rebuild_algorithm_version
  ]

  @type t :: %__MODULE__{
          state_class: StateClass.t() | nil,
          schema_version: non_neg_integer() | nil,
          commit_watermark: non_neg_integer() | nil,
          visibility_watermark: non_neg_integer() | nil,
          replay_source: term() | nil,
          rebuild_algorithm_version: term() | nil
        }

  @required [:state_class, :schema_version]

  @doc "必填规格(PERS-5)。"
  @spec required_fields() :: [Envelope.required_spec()]
  def required_fields, do: @required

  @doc """
  构造并校验。`state_class` 必须是 PERS-5 四分类之一(否则 `{:error, _}`);
  若 `state_class == :derived` 则 `rebuild_algorithm_version` 必填(PERS-7)。
  """
  @spec new(Enumerable.t()) :: {:ok, t()} | {:error, term()}
  def new(fields) do
    with {:ok, meta} <- Envelope.cast(__MODULE__, fields, @required),
         :ok <- validate_state_class(meta.state_class),
         :ok <- validate_derived_versioned(meta) do
      {:ok, meta}
    end
  end

  @doc "构造并校验,失败 raise。"
  @spec new!(Enumerable.t()) :: t()
  def new!(fields) do
    case new(fields) do
      {:ok, meta} -> meta
      {:error, reason} -> raise ArgumentError, "PersistenceMeta 非法: #{inspect(reason)}"
    end
  end

  defp validate_state_class(class) do
    if StateClass.valid?(class), do: :ok, else: {:error, {:invalid_state_class, class}}
  end

  defp validate_derived_versioned(%__MODULE__{
         state_class: :derived,
         rebuild_algorithm_version: nil
       }) do
    {:error, :derived_requires_rebuild_algorithm_version}
  end

  defp validate_derived_versioned(_meta), do: :ok
end
