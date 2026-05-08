defmodule WorldServer.Voxel.BuildTransaction do
  @moduledoc """
  Recoverable world-coordinated voxel build or destruction transaction.

  The implementation currently builds deterministic participant plans. Later
  phases will persist and replay commit/abort decisions around this shape.
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
    # Phase 3-bis: %{ {region_id, lease_id} => %{chunk_coord => [intent_attrs]} }.
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
    scene_objects: []
  ]
end
