defmodule WorldServer.Voxel.BuildTransaction do
  @moduledoc """
  Recoverable world-coordinated voxel build or destruction transaction.

  The implementation currently builds deterministic participant plans. Later
  phases will persist and replay commit/abort decisions around this shape.

  ## 2PC 状态机 (阶段4 / world-2pc-3 commit durable barrier)

  状态推进:`:preparing → :prepared → :committing → :committed` 或
  `:preparing/:prepared/:aborting → :aborted`。

  - `:committing` 是 commit decision 已记录(事务**已决**,不可逆)、但还在
    等所有 participant 的 **durable-ack** 的中间态。decision 一旦落到
    `:committing`/`:committed`,任何后续失败都**不**能把它退回 abort(契约#2)。
  - `:committed` 仅当 **全部 participant 都返回 durable-ack**(对齐契约#3:
    participant 已把快照持久化到 DB、确认 `chunk_version >= 本次 commit
    version`、删 fence 后才回 `{:ok}`)才到达。
  - `commit_acks` 记录每个 participant 的 durable-ack 状态
    (`:pending` → `:durable`),供 driver/reaper 判断还要不要重投递。
  """

  @enforce_keys [
    :transaction_id,
    :logical_scene_id,
    :parcel_id,
    :reservation_id,
    :participants,
    :intent_hash,
    :decision_version,
    :timeout_at_ms
  ]
  defstruct [
    :transaction_id,
    :logical_scene_id,
    :parcel_id,
    :reservation_id,
    :participants,
    :intent_hash,
    :decision_version,
    :timeout_at_ms,
    state: :preparing,
    # Phase 3-bis: %{ participant_key => %{chunk_coord => [intent_attrs]} }.
    # Persisted alongside the transaction so a coordinator restart can
    # reconstruct the commit dispatch (TransactionRecoveryWatcher reads this
    # back when resuming a `:prepared` transaction).
    intents_by_participant: %{},
    # Phase 4 (D3):本笔事务要创建的对象实例(已 allocate object_id)。
    # 形态:[%{object_id, blueprint_id, blueprint_version, parcel_id,
    #        anchor_world_micro, rotation, owner_actor_id, covered_chunks,
    #        part_states, state_flags, object_attribute_ref,
    #        object_tag_set_ref, object_version}]
    # 跟 transaction 同生命周期持久化,coordinator 重启后 reload 完整保留;
    # commit 后由 ChunkProcess 路径 upsert 到 ObjectRegistry → SceneObjectStore。
    scene_objects: [],
    # 阶段4 / world-2pc-3:per-participant commit durable-ack 账本。
    # 形态 `%{ participant_key => :pending | :durable }`。decision 记录进
    # `:committing` 时初始化为全 `:pending`;participant 返回 durable-ack 后
    # 该 key 置 `:durable`;全部 `:durable` 时事务推进到 `:committed`。
    # 随 transaction 持久化,coordinator/driver 重启后能续判还差哪些 ack。
    commit_acks: %{}
  ]

  @typedoc "2PC 事务状态。"
  @type state ::
          :preparing | :prepared | :aborting | :committing | :committed | :aborted

  @doc """
  返回事务是否已进入**已决**区(decision 已记录,不可逆)。

  `:committing` / `:committed` 都属于已决 commit 区——契约#2 要求这些状态
  绝不能退回 abort,只能持续重投递到 `:committed`。
  """
  @spec decided_commit?(%__MODULE__{}) :: boolean()
  def decided_commit?(%__MODULE__{state: state}), do: state in [:committing, :committed]

  @doc "返回事务是否已到达任意终态(`:committed` / `:aborted`)。"
  @spec final?(%__MODULE__{}) :: boolean()
  def final?(%__MODULE__{state: state}), do: state in [:committed, :aborted]
end
