defmodule MmoContracts.Envelope.EntityHandoff do
  @moduledoc """
  实体跨 Cell 信封(`entity_handoff`,FROZEN-5 subtype)。

  **实体跨 Cell handoff 与 Cell ownership migration 必须区分**(CELL-9/11):
  - `entity_handoff` 表示**实体**从 Cell A 移动到 Cell B,采用两阶段幂等 transfer 协议
    (`prepare/accept/commit/abort/timeout`,CELL-12)。
  - **本信封不含、也不递增 Cell `owner_epoch`**;消息携带源/目标 Cell 各自当前
    `source_owner_epoch`/`target_owner_epoch` **仅用于 fencing 校验**(CELL-9)。
  - Cell 本身迁移见 `MmoContracts.Envelope.CellMigration`(那里才递增 owner_epoch,CELL-10)。

  幂等(CELL-12):重复 `prepare/accept/commit/abort` 不得复制/丢失/重复结算实体。
  cutover(CELL-15):`visibility_cutover_snapshot_seq` 禁止客户端同一可见 tick 看到实体两个权威副本。
  """
  alias MmoContracts.Envelope

  @transfer_statuses [:prepare, :accept, :commit, :abort, :timeout]

  defstruct [
    :entity_transfer_id,
    :entity_id,
    :source_cell_id,
    :target_cell_id,
    :source_owner_epoch,
    :target_owner_epoch,
    :source_final_tick,
    :target_start_tick,
    :handoff_tick,
    :source_cell_seq,
    :transfer_seq,
    :target_accept_seq,
    :entity_state_ref,
    :entity_state_digest,
    :transfer_payload_version,
    :transfer_status,
    :command_forward_from_seq,
    :visibility_cutover_snapshot_seq,
    :idempotency_key,
    :deadline_tick
  ]

  @type transfer_status :: :prepare | :accept | :commit | :abort | :timeout

  @type t :: %__MODULE__{
          entity_transfer_id: term() | nil,
          entity_id: term() | nil,
          source_cell_id: term() | nil,
          target_cell_id: term() | nil,
          source_owner_epoch: non_neg_integer() | nil,
          target_owner_epoch: non_neg_integer() | nil,
          source_final_tick: non_neg_integer() | nil,
          target_start_tick: non_neg_integer() | nil,
          handoff_tick: non_neg_integer() | nil,
          source_cell_seq: non_neg_integer() | nil,
          transfer_seq: non_neg_integer() | nil,
          target_accept_seq: non_neg_integer() | nil,
          entity_state_ref: term() | nil,
          entity_state_digest: term() | nil,
          transfer_payload_version: non_neg_integer() | nil,
          transfer_status: transfer_status() | nil,
          command_forward_from_seq: non_neg_integer() | nil,
          visibility_cutover_snapshot_seq: non_neg_integer() | nil,
          idempotency_key: term() | nil,
          deadline_tick: non_neg_integer() | nil
        }

  @required [
    :entity_transfer_id,
    :entity_id,
    :source_cell_id,
    :target_cell_id,
    :source_owner_epoch,
    :target_owner_epoch,
    :handoff_tick,
    :transfer_status,
    :transfer_payload_version,
    :idempotency_key,
    :deadline_tick,
    [:source_cell_seq, :transfer_seq],
    [:entity_state_ref, :entity_state_digest]
  ]

  @doc "合法 transfer_status(CELL-12)。"
  @spec transfer_statuses() :: [transfer_status()]
  def transfer_statuses, do: @transfer_statuses

  @doc "必填规格(FROZEN-5 entity_handoff)。"
  @spec required_fields() :: [Envelope.required_spec()]
  def required_fields, do: @required

  @doc "构造并校验(含 transfer_status 合法性)。"
  @spec new(Enumerable.t()) :: {:ok, t()} | {:error, term()}
  def new(fields) do
    with {:ok, env} <- Envelope.cast(__MODULE__, fields, @required),
         :ok <- validate_status(env.transfer_status) do
      {:ok, env}
    end
  end

  @doc "构造并校验,失败 raise。"
  @spec new!(Enumerable.t()) :: t()
  def new!(fields) do
    case new(fields) do
      {:ok, env} -> env
      {:error, reason} -> raise ArgumentError, "EntityHandoff 非法: #{inspect(reason)}"
    end
  end

  defp validate_status(s) when s in @transfer_statuses, do: :ok
  defp validate_status(s), do: {:error, {:invalid_transfer_status, s}}
end
