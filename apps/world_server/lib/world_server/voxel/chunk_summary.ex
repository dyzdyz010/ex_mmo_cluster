defmodule WorldServer.Voxel.ChunkSummary do
  @moduledoc """
  World-ledger summary of one authoritative voxel chunk.

  This is intentionally small: World keeps routing, ownership, version, and hash
  metadata, while full chunk truth stays in Scene hot memory and DataService
  snapshots.
  """

  @enforce_keys [
    :logical_scene_id,
    :chunk_coord,
    :lease_id,
    :owner_scene_instance_ref,
    :owner_epoch,
    :chunk_version,
    :chunk_hash
  ]
  defstruct [
    :logical_scene_id,
    :chunk_coord,
    :lease_id,
    :owner_scene_instance_ref,
    :owner_epoch,
    :chunk_version,
    :chunk_hash,
    parcel_id: nil,
    dirty_state: :clean,
    last_persisted_ms: 0
  ]
end
