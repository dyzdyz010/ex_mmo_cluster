defmodule MmoContracts.Envelope.CellMigration do
  @moduledoc """
  Cell 迁移信封(`cell_migration`,FROZEN-5 subtype)。

  **只有当某个 Cell 本身迁移到新的 CellServer/节点时**,才递增该 Cell 的 `owner_epoch`(CELL-10)。
  **`owner_epoch` 仅在此处递增**(CELL-11);实体跨界见 `MmoContracts.Envelope.EntityHandoff`(不递增)。

  旧 owner 在 `migration_tick` 之后**禁止**再产生该 Cell 的权威事件或写入(CELL-10 / CELL-20 / TIME-6)。

  字段:`cell_id`、`old_owner_epoch`、`new_owner_epoch`、`migration_tick`、`snapshot_ref`、`commit_watermark`。
  """
  alias MmoContracts.Envelope

  defstruct [
    :cell_id,
    :old_owner_epoch,
    :new_owner_epoch,
    :migration_tick,
    :snapshot_ref,
    :commit_watermark
  ]

  @type t :: %__MODULE__{
          cell_id: term() | nil,
          old_owner_epoch: non_neg_integer() | nil,
          new_owner_epoch: non_neg_integer() | nil,
          migration_tick: non_neg_integer() | nil,
          snapshot_ref: term() | nil,
          commit_watermark: non_neg_integer() | nil
        }

  @required [:cell_id, :old_owner_epoch, :new_owner_epoch, :migration_tick]

  @doc "必填规格(FROZEN-5 cell_migration)。"
  @spec required_fields() :: [Envelope.required_spec()]
  def required_fields, do: @required

  @doc """
  构造并校验。强制 `new_owner_epoch > old_owner_epoch`(CELL-10/18 单调递增)。
  """
  @spec new(Enumerable.t()) :: {:ok, t()} | {:error, term()}
  def new(fields) do
    with {:ok, mig} <- Envelope.cast(__MODULE__, fields, @required),
         :ok <- validate_monotonic(mig) do
      {:ok, mig}
    end
  end

  @doc "构造并校验,失败 raise。"
  @spec new!(Enumerable.t()) :: t()
  def new!(fields) do
    case new(fields) do
      {:ok, mig} -> mig
      {:error, reason} -> raise ArgumentError, "CellMigration 非法: #{inspect(reason)}"
    end
  end

  defp validate_monotonic(%__MODULE__{old_owner_epoch: old, new_owner_epoch: new})
       when is_integer(old) and is_integer(new) and new > old,
       do: :ok

  defp validate_monotonic(%__MODULE__{old_owner_epoch: old, new_owner_epoch: new}),
    do: {:error, {:owner_epoch_not_monotonic, %{old: old, new: new}}}
end
