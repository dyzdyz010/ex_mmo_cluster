defmodule WorldServer.Entity.HandoffPlan do
  @moduledoc """
  实体跨 Cell 的两阶段幂等 transfer 控制面状态机(**entity_handoff**,梯队1 step1.6b)。

  规范 CELL-9~15 / FROZEN-5:实体(玩家 / NPC)从 source Cell 移动到 target Cell,采用幂等
  `prepare → accept → commit`(成功)/ `abort` / `timeout`(失败终态)协议。与 **cell_migration**
  (`WorldServer.Voxel.MigrationPlan`,Cell 本身迁移、递增 owner_epoch)严格区分:

  - **本协议绝不递增、也不修改 `owner_epoch`**(CELL-11)。`source_owner_epoch` / `target_owner_epoch`
    随消息携带,**仅用于 fencing 校验**(CELL-9):accept 时校验 target 当前 owner_epoch 与期望一致,
    防止"target Cell 已迁移给他人"导致幽灵实体。
  - **幂等**(CELL-12):重复 `prepare/accept/commit/abort/timeout` 不复制 / 不丢失 / 不重复结算实体——
    重复转移到当前 status 返回 `{:ok, plan}` no-op;非法顺序返回 `{:error, reason}`。

  纯 struct + 转移函数(mirror `MigrationPlan` 风格,非 GenServer),控制面 location-agnostic。
  可经 `entity_handoff_envelope/1` 构 `MmoContracts.Envelope.EntityHandoff`(FROZEN-5)。

  **范围**(梯队1):本模块只提供协议状态机基元。边界检测(`EntityBoundaryMonitor`)、真实
  PlayerCharacter 状态 snapshot/apply、跨 scene_node 搬迁、连接重定向**推迟到多 scene_node tier**
  (那时由 boundary monitor 驱动本基元)。
  """

  alias MmoContracts.Envelope.EntityHandoff

  @statuses [:prepare, :accept, :commit, :abort, :timeout]
  @entity_kinds [:player, :npc]

  @enforce_keys [
    :entity_transfer_id,
    :entity_id,
    :source_cell_id,
    :target_cell_id,
    :source_owner_epoch,
    :target_owner_epoch,
    :handoff_tick,
    :transfer_seq,
    :transfer_payload_version,
    :idempotency_key,
    :deadline_tick
  ]
  defstruct [
    :entity_transfer_id,
    :entity_id,
    :entity_kind,
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
    :command_forward_from_seq,
    :visibility_cutover_snapshot_seq,
    :idempotency_key,
    :deadline_tick,
    :abort_reason,
    transfer_status: :prepare
  ]

  @type status :: :prepare | :accept | :commit | :abort | :timeout
  @type entity_kind :: :player | :npc

  @type t :: %__MODULE__{
          entity_transfer_id: term(),
          entity_id: term(),
          entity_kind: entity_kind() | nil,
          source_cell_id: term(),
          target_cell_id: term(),
          source_owner_epoch: non_neg_integer(),
          target_owner_epoch: non_neg_integer(),
          source_final_tick: non_neg_integer() | nil,
          target_start_tick: non_neg_integer() | nil,
          handoff_tick: non_neg_integer(),
          source_cell_seq: non_neg_integer() | nil,
          transfer_seq: non_neg_integer(),
          target_accept_seq: non_neg_integer() | nil,
          entity_state_ref: term() | nil,
          entity_state_digest: term() | nil,
          transfer_payload_version: non_neg_integer(),
          command_forward_from_seq: non_neg_integer() | nil,
          visibility_cutover_snapshot_seq: non_neg_integer() | nil,
          idempotency_key: term(),
          deadline_tick: non_neg_integer(),
          abort_reason: term() | nil,
          transfer_status: status()
        }

  @doc "合法 transfer_status。"
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc """
  起一笔 entity_handoff(status `:prepare`)。

  source 已 snapshot 实体、标记其"迁出中"(禁移动 / 禁输入 tick),把权威态摘要
  (`entity_state_ref` / `entity_state_digest`)交给本计划。`source_final_tick` 默认取 `handoff_tick`
  (实体在 source 的最后权威 tick)。返回 `{:ok, plan}` 或 `{:error, {:missing, key}}`。
  """
  @spec new(Enumerable.t()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    attrs = Map.new(attrs)

    with :ok <- require_keys(attrs, @enforce_keys),
         :ok <- validate_entity_kind(Map.get(attrs, :entity_kind)),
         :ok <- validate_state_ref(attrs) do
      plan = %__MODULE__{
        entity_transfer_id: Map.fetch!(attrs, :entity_transfer_id),
        entity_id: Map.fetch!(attrs, :entity_id),
        entity_kind: Map.get(attrs, :entity_kind),
        source_cell_id: Map.fetch!(attrs, :source_cell_id),
        target_cell_id: Map.fetch!(attrs, :target_cell_id),
        source_owner_epoch: Map.fetch!(attrs, :source_owner_epoch),
        target_owner_epoch: Map.fetch!(attrs, :target_owner_epoch),
        handoff_tick: Map.fetch!(attrs, :handoff_tick),
        source_final_tick: Map.get(attrs, :source_final_tick, Map.fetch!(attrs, :handoff_tick)),
        source_cell_seq: Map.get(attrs, :source_cell_seq),
        transfer_seq: Map.fetch!(attrs, :transfer_seq),
        entity_state_ref: Map.get(attrs, :entity_state_ref),
        entity_state_digest: Map.get(attrs, :entity_state_digest),
        transfer_payload_version: Map.fetch!(attrs, :transfer_payload_version),
        idempotency_key: Map.fetch!(attrs, :idempotency_key),
        deadline_tick: Map.fetch!(attrs, :deadline_tick),
        transfer_status: :prepare
      }

      {:ok, plan}
    end
  end

  @doc "同 `new/1`,失败 raise。"
  @spec new!(Enumerable.t()) :: t()
  def new!(attrs) do
    case new(attrs) do
      {:ok, plan} -> plan
      {:error, reason} -> raise ArgumentError, "HandoffPlan 非法: #{inspect(reason)}"
    end
  end

  @doc """
  target accept(status `:prepare` → `:accept`)。

  **fencing**(CELL-9):`attrs.observed_target_owner_epoch` 必须等于 `plan.target_owner_epoch`,
  否则 `{:error, :target_epoch_mismatch}`(target Cell 已迁移给他人,拒绝以免幽灵实体)。
  记录 `target_accept_seq` / `target_start_tick` / `command_forward_from_seq` /
  `visibility_cutover_snapshot_seq`。**幂等**:已 `:accept` 返回 `{:ok, plan}` no-op。
  """
  @spec accept(t(), Enumerable.t()) :: {:ok, t()} | {:error, term()}
  def accept(%__MODULE__{transfer_status: :accept} = plan, _attrs), do: {:ok, plan}

  def accept(%__MODULE__{transfer_status: :prepare} = plan, attrs) do
    attrs = Map.new(attrs)
    observed = Map.get(attrs, :observed_target_owner_epoch, plan.target_owner_epoch)

    if observed == plan.target_owner_epoch do
      {:ok,
       %{
         plan
         | transfer_status: :accept,
           target_accept_seq: Map.get(attrs, :target_accept_seq),
           target_start_tick: Map.get(attrs, :target_start_tick),
           command_forward_from_seq: Map.get(attrs, :command_forward_from_seq),
           visibility_cutover_snapshot_seq: Map.get(attrs, :visibility_cutover_snapshot_seq)
       }}
    else
      {:error, :target_epoch_mismatch}
    end
  end

  def accept(%__MODULE__{transfer_status: status}, _attrs),
    do: {:error, {:cannot_accept_from, status}}

  @doc """
  commit(status `:accept` → `:commit`):source 删除实体、target 激活。
  **幂等**:已 `:commit` 返回 `{:ok, plan}` no-op。仅能从 `:accept` commit。
  """
  @spec commit(t(), Enumerable.t()) :: {:ok, t()} | {:error, term()}
  def commit(plan, attrs \\ %{})

  def commit(%__MODULE__{transfer_status: :commit} = plan, _attrs), do: {:ok, plan}

  def commit(%__MODULE__{transfer_status: :accept} = plan, attrs) do
    attrs = Map.new(attrs)

    {:ok,
     %{
       plan
       | transfer_status: :commit,
         visibility_cutover_snapshot_seq:
           Map.get(
             attrs,
             :visibility_cutover_snapshot_seq,
             plan.visibility_cutover_snapshot_seq
           )
     }}
  end

  def commit(%__MODULE__{transfer_status: status}, _attrs),
    do: {:error, {:cannot_commit_from, status}}

  @doc """
  abort(`:prepare` / `:accept` → `:abort`):实体留在 source。
  **幂等**:已 `:abort` 返回 `{:ok, plan}` no-op;已 `:commit` 拒(`{:error, :already_committed}`)。
  """
  @spec abort(t(), term()) :: {:ok, t()} | {:error, term()}
  def abort(%__MODULE__{transfer_status: :abort} = plan, _reason), do: {:ok, plan}
  def abort(%__MODULE__{transfer_status: :commit}, _reason), do: {:error, :already_committed}
  def abort(%__MODULE__{transfer_status: :timeout}, _reason), do: {:error, :already_timed_out}

  def abort(%__MODULE__{transfer_status: status} = plan, reason)
      when status in [:prepare, :accept] do
    {:ok, %{plan | transfer_status: :abort, abort_reason: reason}}
  end

  @doc """
  timeout(`:prepare` / `:accept` → `:timeout`):deadline 过,实体留在 source。
  **幂等**:已 `:timeout` 返回 `{:ok, plan}` no-op;已 `:commit` 拒。
  """
  @spec timeout(t()) :: {:ok, t()} | {:error, term()}
  def timeout(%__MODULE__{transfer_status: :timeout} = plan), do: {:ok, plan}
  def timeout(%__MODULE__{transfer_status: :commit}), do: {:error, :already_committed}
  def timeout(%__MODULE__{transfer_status: :abort}), do: {:error, :already_aborted}

  def timeout(%__MODULE__{transfer_status: status} = plan)
      when status in [:prepare, :accept] do
    {:ok, %{plan | transfer_status: :timeout}}
  end

  @doc "终态?(commit / abort / timeout)"
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{transfer_status: s}), do: s in [:commit, :abort, :timeout]

  @doc """
  从计划构 `MmoContracts.Envelope.EntityHandoff` 信封(FROZEN-5)。
  """
  @spec entity_handoff_envelope(t()) :: {:ok, EntityHandoff.t()} | {:error, term()}
  def entity_handoff_envelope(%__MODULE__{} = plan) do
    EntityHandoff.new(
      entity_transfer_id: plan.entity_transfer_id,
      entity_id: plan.entity_id,
      source_cell_id: plan.source_cell_id,
      target_cell_id: plan.target_cell_id,
      source_owner_epoch: plan.source_owner_epoch,
      target_owner_epoch: plan.target_owner_epoch,
      source_final_tick: plan.source_final_tick,
      target_start_tick: plan.target_start_tick,
      handoff_tick: plan.handoff_tick,
      source_cell_seq: plan.source_cell_seq,
      transfer_seq: plan.transfer_seq,
      target_accept_seq: plan.target_accept_seq,
      entity_state_ref: plan.entity_state_ref,
      entity_state_digest: plan.entity_state_digest,
      transfer_payload_version: plan.transfer_payload_version,
      transfer_status: plan.transfer_status,
      command_forward_from_seq: plan.command_forward_from_seq,
      visibility_cutover_snapshot_seq: plan.visibility_cutover_snapshot_seq,
      idempotency_key: plan.idempotency_key,
      deadline_tick: plan.deadline_tick
    )
  end

  @doc "CLI / observe 用紧凑摘要。"
  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = plan) do
    %{
      entity_transfer_id: plan.entity_transfer_id,
      entity_id: plan.entity_id,
      entity_kind: plan.entity_kind,
      source_cell_id: plan.source_cell_id,
      target_cell_id: plan.target_cell_id,
      source_owner_epoch: plan.source_owner_epoch,
      target_owner_epoch: plan.target_owner_epoch,
      handoff_tick: plan.handoff_tick,
      transfer_seq: plan.transfer_seq,
      transfer_status: plan.transfer_status,
      idempotency_key: plan.idempotency_key,
      deadline_tick: plan.deadline_tick,
      abort_reason: plan.abort_reason
    }
  end

  defp require_keys(attrs, keys) do
    case Enum.find(keys, &(not Map.has_key?(attrs, &1))) do
      nil -> :ok
      missing -> {:error, {:missing, missing}}
    end
  end

  defp validate_entity_kind(nil), do: :ok
  defp validate_entity_kind(kind) when kind in @entity_kinds, do: :ok
  defp validate_entity_kind(kind), do: {:error, {:invalid_entity_kind, kind}}

  # 至少要有 entity_state_ref 或 entity_state_digest 之一(对齐信封 [ref|digest] 二选一必填)。
  defp validate_state_ref(attrs) do
    if is_nil(Map.get(attrs, :entity_state_ref)) and
         is_nil(Map.get(attrs, :entity_state_digest)) do
      {:error, {:missing, :entity_state_ref_or_digest}}
    else
      :ok
    end
  end
end
