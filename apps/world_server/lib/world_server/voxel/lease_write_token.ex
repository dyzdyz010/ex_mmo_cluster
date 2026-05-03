defmodule WorldServer.Voxel.LeaseWriteToken do
  @moduledoc """
  DataService-side write token derived from a world scene lease.

  DataService stores this token locally and uses compare-and-swap semantics on
  `token_version`, so an older world decision cannot overwrite a newer lease.
  """

  @enforce_keys [
    :logical_scene_id,
    :region_id,
    :lease_id,
    :owner_scene_instance_ref,
    :owner_epoch,
    :bounds_chunk_min,
    :bounds_chunk_max,
    :expires_at_ms,
    :token_version
  ]
  defstruct [
    :logical_scene_id,
    :region_id,
    :lease_id,
    :owner_scene_instance_ref,
    :owner_epoch,
    :bounds_chunk_min,
    :bounds_chunk_max,
    :expires_at_ms,
    :token_version
  ]

  @type chunk_coord :: {integer(), integer(), integer()}

  @type t :: %__MODULE__{
          logical_scene_id: non_neg_integer(),
          region_id: non_neg_integer(),
          lease_id: non_neg_integer(),
          owner_scene_instance_ref: non_neg_integer(),
          owner_epoch: non_neg_integer(),
          bounds_chunk_min: chunk_coord(),
          bounds_chunk_max: chunk_coord(),
          expires_at_ms: non_neg_integer(),
          token_version: non_neg_integer()
        }

  @doc "Builds a write token from a scene lease and explicit token version."
  def from_lease(lease, token_version) do
    %__MODULE__{
      logical_scene_id: lease.logical_scene_id,
      region_id: lease.region_id,
      lease_id: lease.lease_id,
      owner_scene_instance_ref: lease.owner_scene_instance_ref,
      owner_epoch: lease.owner_epoch,
      bounds_chunk_min: lease.bounds_chunk_min,
      bounds_chunk_max: lease.bounds_chunk_max,
      expires_at_ms: lease.expires_at_ms,
      token_version: token_version
    }
  end

  @doc "Returns a plain map suitable for DataService without a compile-time struct dependency."
  def to_map(%__MODULE__{} = token) do
    Map.from_struct(token)
  end
end
