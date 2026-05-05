defmodule SceneServer.Voxel.PrefabRaster do
  @moduledoc """
  Pure rasterizer that turns a v1 prefab blueprint and a world-micro anchor into
  a flat list of `(chunk_coord, local_macro_coord, NormalBlockData)` write cells.

  The rasterizer uses macro-cell granularity only. It converts the anchor from
  world-micro to world-macro coordinates with floor division (so negative world
  coordinates still land on a deterministic chunk), adds each blueprint cell
  offset, and routes the resulting world macro coordinate through
  `SceneServer.Voxel.Types.chunk_and_local_macro!/1` to obtain the
  authoritative `{chunk_coord, local_macro_coord}` pair.

  Out of scope for v1:

    - rotation (callers must always pass `rotation: 0`; non-zero values are
      rejected so we don't silently apply an identity transform that the
      client did not intend)
    - microgrid / refined cells / boundary snapping / socket snapping
    - parcel ownership / lease checks (the catalog only resolves geometry; the
      gate dispatch is the authority for routing every cell through the
      World map ledger)
  """

  alias SceneServer.Voxel.{BlueprintCatalog, NormalBlockData, Types}

  @typedoc "One macro-cell write produced by the rasterizer."
  @type cell :: %{
          chunk_coord: Types.chunk_coord(),
          local_macro: Types.local_macro_coord(),
          block: NormalBlockData.t()
        }

  @doc """
  Rasterizes a v1 prefab placement.

  ## Arguments

    * `blueprint_id` – the canonical v1 blueprint id (see `BlueprintCatalog`).
    * `blueprint_version` – wire-negotiated version, must match the catalog.
    * `anchor_world_micro` – placement origin in world-micro coordinates, the
      same units used by `0x67 PrefabPlaceIntent`.
    * `rotation` – wire byte; only `0` is accepted in v1.

  ## Returns

    * `{:ok, cells}` – non-empty list of `cell()` writes in deterministic
      blueprint order.
    * `{:error, reason}` on resolution / validation failure.
  """
  @spec rasterize(non_neg_integer(), non_neg_integer(), Types.world_micro_coord(), 0..0xFF) ::
          {:ok, [cell()]} | {:error, atom()}
  def rasterize(blueprint_id, blueprint_version, anchor_world_micro, rotation) do
    with {:ok, blueprint} <- BlueprintCatalog.fetch(blueprint_id, blueprint_version),
         :ok <- validate_rotation(rotation),
         {:ok, anchor_world_macro} <- world_macro_anchor(anchor_world_micro) do
      cells =
        Enum.map(blueprint.cells, fn offset ->
          target_world_macro = add_offset(anchor_world_macro, offset)
          {chunk_coord, local_macro} = Types.chunk_and_local_macro!(target_world_macro)

          %{
            chunk_coord: chunk_coord,
            local_macro: local_macro,
            block: NormalBlockData.new(blueprint.material_id, health: 100)
          }
        end)

      {:ok, cells}
    end
  end

  @doc """
  Groups raster cells by chunk for callers that want chunk-major iteration.

  v1 dispatch loops cell-major (one route_chunk_with_lease per cell) but tools /
  observability frequently want a per-chunk count. This helper does not change
  cell order inside a chunk.
  """
  @spec group_by_chunk([cell()]) :: %{Types.chunk_coord() => [cell()]}
  def group_by_chunk(cells) when is_list(cells) do
    Enum.group_by(cells, & &1.chunk_coord)
  end

  defp validate_rotation(0), do: :ok
  defp validate_rotation(rot) when is_integer(rot), do: {:error, :unsupported_rotation}
  defp validate_rotation(_rot), do: {:error, :invalid_rotation}

  defp world_macro_anchor({ax, ay, az})
       when is_integer(ax) and is_integer(ay) and is_integer(az) do
    micro_resolution = Types.micro_resolution()

    {:ok,
     {
       Types.floor_div(ax, micro_resolution),
       Types.floor_div(ay, micro_resolution),
       Types.floor_div(az, micro_resolution)
     }}
  end

  defp world_macro_anchor(_other), do: {:error, :invalid_anchor_world_micro}

  defp add_offset({mx, my, mz}, {ox, oy, oz}), do: {mx + ox, my + oy, mz + oz}
end
