defmodule WorldServer.Voxel.TransactionParticipant do
  @moduledoc """
  One lease-scoped participant in a cross-region voxel transaction.

  A single scene process may appear more than once when it owns multiple
  involved regions. Keeping participants lease-scoped makes migration and
  recovery checks unambiguous.
  """

  @enforce_keys [
    :region_id,
    :lease_id,
    :owner_scene_instance_ref,
    :owner_epoch,
    :affected_chunks
  ]
  defstruct [
    :region_id,
    :lease_id,
    :owner_scene_instance_ref,
    :owner_epoch,
    :affected_chunks,
    prepare_status: :pending,
    commit_status: :pending,
    last_ack_ms: 0
  ]
end
