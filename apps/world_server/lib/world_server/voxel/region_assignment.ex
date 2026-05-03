defmodule WorldServer.Voxel.RegionAssignment do
  @moduledoc """
  Durable world-ledger assignment for one voxel region.

  `logical_scene_id` is the persistent scene/world partition. The hot owner is
  `owner_scene_instance_ref + owner_epoch`; migrations must advance the epoch so
  stale scene processes cannot keep writing the same chunks.
  """

  @enforce_keys [
    :region_id,
    :logical_scene_id,
    :bounds_chunk_min,
    :bounds_chunk_max,
    :owner_scene_instance_ref,
    :owner_epoch
  ]
  defstruct [
    :region_id,
    :logical_scene_id,
    :bounds_chunk_min,
    :bounds_chunk_max,
    :owner_scene_instance_ref,
    :owner_epoch,
    :lease_id,
    state: :active,
    summary_hash: 0,
    version: 0
  ]

  @type chunk_coord :: {integer(), integer(), integer()}
  @type state :: :active | :migrating | :draining | :inactive

  @type t :: %__MODULE__{
          region_id: non_neg_integer(),
          logical_scene_id: non_neg_integer(),
          bounds_chunk_min: chunk_coord(),
          bounds_chunk_max: chunk_coord(),
          owner_scene_instance_ref: non_neg_integer(),
          owner_epoch: non_neg_integer(),
          lease_id: non_neg_integer() | nil,
          state: state(),
          summary_hash: non_neg_integer(),
          version: non_neg_integer()
        }

  @doc "Builds a normalized region assignment struct from a map or keyword list."
  def new(attrs) when is_list(attrs), do: attrs |> Map.new() |> new()

  def new(attrs) when is_map(attrs) do
    %__MODULE__{
      region_id: fetch!(attrs, :region_id),
      logical_scene_id: fetch!(attrs, :logical_scene_id),
      bounds_chunk_min: coord!(fetch!(attrs, :bounds_chunk_min)),
      bounds_chunk_max: coord!(fetch!(attrs, :bounds_chunk_max)),
      owner_scene_instance_ref: fetch!(attrs, :owner_scene_instance_ref),
      owner_epoch: fetch!(attrs, :owner_epoch),
      lease_id: Map.get(attrs, :lease_id),
      state: Map.get(attrs, :state, :active),
      summary_hash: Map.get(attrs, :summary_hash, 0),
      version: Map.get(attrs, :version, 0)
    }
  end

  @doc "Returns whether a chunk coordinate is inside this assignment's half-open bounds."
  def contains_chunk?(%__MODULE__{} = assignment, chunk_coord) do
    contains?(coord!(chunk_coord), assignment.bounds_chunk_min, assignment.bounds_chunk_max)
  end

  defp contains?({cx, cy, cz}, {min_x, min_y, min_z}, {max_x, max_y, max_z}) do
    cx >= min_x and cx < max_x and cy >= min_y and cy < max_y and cz >= min_z and cz < max_z
  end

  defp coord!({x, y, z}) when is_integer(x) and is_integer(y) and is_integer(z), do: {x, y, z}
  defp coord!([x, y, z]) when is_integer(x) and is_integer(y) and is_integer(z), do: {x, y, z}

  defp coord!(value) do
    raise ArgumentError, "expected chunk coord as {x, y, z}, got: #{inspect(value)}"
  end

  defp fetch!(attrs, key) do
    Map.fetch!(attrs, key)
  rescue
    KeyError ->
      raise ArgumentError, "missing required #{inspect(key)}"
  end
end
