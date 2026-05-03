defmodule WorldServer.Voxel.BoundaryVoxelEvent do
  @moduledoc """
  Lease-fenced event for ordinary cross-boundary voxel rule propagation.

  World does not process ordinary burn/freeze/fluid rule frames, but it defines
  the fields needed by scenes to reject events that arrive after a migration.
  """

  @enforce_keys [
    :event_id,
    :logical_scene_id,
    :source_region_id,
    :target_region_id,
    :source_lease_id,
    :target_lease_id,
    :source_scene_instance_ref,
    :target_scene_instance_ref,
    :source_owner_epoch,
    :target_owner_epoch,
    :boundary_chunks,
    :event_kind,
    :payload_hash,
    :payload
  ]
  defstruct [
    :event_id,
    :logical_scene_id,
    :source_region_id,
    :target_region_id,
    :source_lease_id,
    :target_lease_id,
    :source_scene_instance_ref,
    :target_scene_instance_ref,
    :source_owner_epoch,
    :target_owner_epoch,
    :boundary_chunks,
    :event_kind,
    :payload_hash,
    :payload
  ]
end
