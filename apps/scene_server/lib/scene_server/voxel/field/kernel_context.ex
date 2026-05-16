defmodule SceneServer.Voxel.Field.KernelContext do
  @moduledoc """
  Read-only data passed to field kernels for one tick.

  This is intentionally small in Phase 7.A: it snapshots and normalizes the
  current storage once per field tick and exposes only chunk-local tick
  metadata. Higher-level object queries and cross-chunk reads stay outside this
  compatibility slice; effect dispatch is handed back to the owning
  `ChunkProcess` instead of being performed by the kernel.
  """

  alias SceneServer.Voxel.Field.FieldRegion
  alias SceneServer.Voxel.Storage

  @type chunk_coord :: {integer(), integer(), integer()}

  @type t :: %__MODULE__{
          storage: Storage.t() | nil | any(),
          dt_ms: pos_integer(),
          tick_count: non_neg_integer(),
          logical_scene_id: non_neg_integer(),
          chunk_coord: chunk_coord()
        }

  defstruct storage: nil,
            dt_ms: 100,
            tick_count: 0,
            logical_scene_id: 0,
            chunk_coord: {0, 0, 0}

  @spec new(FieldRegion.t(), non_neg_integer(), any(), keyword()) :: t()
  def new(%FieldRegion{} = region, logical_scene_id, storage, opts \\ [])
      when is_integer(logical_scene_id) and logical_scene_id >= 0 do
    %__MODULE__{
      storage: normalize_storage(storage),
      dt_ms: Keyword.get(opts, :dt_ms, 100),
      tick_count: region.tick_count,
      logical_scene_id: logical_scene_id,
      chunk_coord: region.chunk_coord
    }
  end

  defp normalize_storage(nil), do: nil
  defp normalize_storage(%Storage{} = storage), do: storage
  defp normalize_storage(storage) when is_map(storage), do: Storage.normalize!(storage)
  defp normalize_storage(_other), do: nil
end
