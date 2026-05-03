defmodule WorldServer.Voxel.SceneLease do
  @moduledoc """
  Hot execution lease granted by the world server to one scene instance.

  The lease is a write authorization token for a region. Scene and DataService
  writes must carry the lease id, owner scene instance ref, and owner epoch.
  """

  @enforce_keys [
    :lease_id,
    :region_id,
    :logical_scene_id,
    :owner_scene_instance_ref,
    :owner_epoch,
    :expires_at_ms,
    :bounds_chunk_min,
    :bounds_chunk_max
  ]
  defstruct [
    :lease_id,
    :region_id,
    :logical_scene_id,
    :owner_scene_instance_ref,
    :owner_epoch,
    :expires_at_ms,
    :bounds_chunk_min,
    :bounds_chunk_max
  ]

  @type chunk_coord :: {integer(), integer(), integer()}

  @type t :: %__MODULE__{
          lease_id: non_neg_integer(),
          region_id: non_neg_integer(),
          logical_scene_id: non_neg_integer(),
          owner_scene_instance_ref: non_neg_integer(),
          owner_epoch: non_neg_integer(),
          expires_at_ms: non_neg_integer(),
          bounds_chunk_min: chunk_coord(),
          bounds_chunk_max: chunk_coord()
        }

  @doc "Converts a region assignment into a scene lease."
  def from_assignment(assignment, lease_id, expires_at_ms) do
    %__MODULE__{
      lease_id: lease_id,
      region_id: assignment.region_id,
      logical_scene_id: assignment.logical_scene_id,
      owner_scene_instance_ref: assignment.owner_scene_instance_ref,
      owner_epoch: assignment.owner_epoch,
      expires_at_ms: expires_at_ms,
      bounds_chunk_min: assignment.bounds_chunk_min,
      bounds_chunk_max: assignment.bounds_chunk_max
    }
  end
end
