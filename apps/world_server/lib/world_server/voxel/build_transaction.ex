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
    state: :preparing
  ]
end
