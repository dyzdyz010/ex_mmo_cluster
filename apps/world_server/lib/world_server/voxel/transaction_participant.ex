defmodule WorldServer.Voxel.TransactionParticipant do
  @moduledoc """
  One Scene-owner participant in a cross-region voxel transaction.

  `participant_key` is the transaction identity used by World prepare ACKs,
  executor dispatch, recovery, and scene opts. `assigned_scene_node` is the
  Scene owner that receives dispatch. `chunk_owners` preserves the exact
  `{region_id, lease_id}` owner for every affected chunk; callers must provide
  it explicitly instead of relying on lease-shaped compatibility defaults.
  """

  @enforce_keys [
    :participant_key,
    :region_id,
    :lease_id,
    :owner_scene_instance_ref,
    :owner_epoch,
    :assigned_scene_node,
    :affected_chunks,
    :chunk_owners
  ]
  defstruct [
    :participant_key,
    :region_id,
    :lease_id,
    :owner_scene_instance_ref,
    :owner_epoch,
    :assigned_scene_node,
    :affected_chunks,
    chunk_owners: %{},
    prepare_status: :pending,
    commit_status: :pending,
    last_ack_ms: 0
  ]
end
