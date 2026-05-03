defmodule SceneServer.Voxel.AabbI64 do
  @moduledoc """
  Half-open world-micro axis-aligned bounds used by voxel reservations.

  Coordinates are stored as `{x, y, z}` tuples. `min_world_micro` is included and
  `max_world_micro` is excluded, matching the protocol-wide `[min, max)` rule.
  """

  @enforce_keys [:min_world_micro, :max_world_micro]
  defstruct [:min_world_micro, :max_world_micro]

  @type coord :: {integer(), integer(), integer()}

  @type t :: %__MODULE__{
          min_world_micro: coord(),
          max_world_micro: coord()
        }

  @doc "Builds and validates a half-open world-micro AABB."
  @spec new(coord(), coord()) :: t()
  def new(min_world_micro, max_world_micro) do
    SceneServer.Voxel.Types.normalize_aabb_i64!({min_world_micro, max_world_micro})
  end
end
