defmodule SceneServer.Voxel.PrefabRaster do
  @moduledoc """
  Pure rasterizer that turns a v2 prefab blueprint and a world-micro anchor into
  a flat list of `(chunk_coord, local_macro_coord, micro_slot, layer_attrs)` micro
  cell writes.

  Phase A1 升级 v1 → v2:rasterizer 现在产生 micro 级 intents(每个 occupied
  micro slot 一条),不再是 macro `put_solid_block` 写。每个 v2 prefab 占用
  范围限定在 1×1×1 macro 内(由 BlueprintCatalog 的 occupied_slots 编排,
  index 0..511),所以一次 rasterize 至多落在一个 macro 上(可能跨 chunk
  边界 — 锚点 macro 落 chunk 边界时,raster 输出仍只在那一个 macro 上)。

  Out of scope for v2:

    - rotation(callers must always pass `rotation: 0`)
    - 跨 macro prefab(occupied_slots 只覆盖单 macro 0..511)
    - microgrid 高级特性 / boundary snapping / socket snapping
    - parcel 所有权检查(由 gate dispatch 走 World map ledger)
  """

  alias SceneServer.Voxel.{BlueprintCatalog, Types}

  @typedoc """
  One micro-cell write produced by the rasterizer. `layer_attrs` is the
  `MicroLayer.normalize!`-friendly attribute map (currently `material_id` +
  `health`).
  """
  @type cell :: %{
          chunk_coord: Types.chunk_coord(),
          local_macro: Types.local_macro_coord(),
          micro_slot: 0..511,
          layer_attrs: %{material_id: 0..0xFFFF, health: 0..0xFFFF}
        }

  @doc """
  Rasterizes a v2 prefab placement.

  ## Arguments

    * `blueprint_id` – the canonical v2 blueprint id (see `BlueprintCatalog`).
    * `blueprint_version` – wire-negotiated version, must match the catalog
      (v2 = 2).
    * `anchor_world_micro` – placement origin in world-micro coordinates, the
      same units used by `0x67 PrefabPlaceIntent`. Used to derive the single
      target macro by floor-dividing each axis by the micro resolution.
    * `rotation` – wire byte; only `0` is accepted in v2.

  ## Returns

    * `{:ok, cells}` – non-empty list of `cell()` writes in `BlueprintCatalog`
      slot order. All cells share the same `chunk_coord` + `local_macro`
      because v2 prefabs are single-macro.
    * `{:error, reason}` on resolution / validation failure.
  """
  @spec rasterize(non_neg_integer(), non_neg_integer(), Types.world_micro_coord(), 0..0xFF) ::
          {:ok, [cell()]} | {:error, atom()}
  def rasterize(blueprint_id, blueprint_version, anchor_world_micro, rotation) do
    with {:ok, blueprint} <- BlueprintCatalog.fetch(blueprint_id, blueprint_version),
         :ok <- validate_rotation(rotation),
         {:ok, anchor_world_macro} <- world_macro_anchor(anchor_world_micro) do
      {chunk_coord, local_macro} = Types.chunk_and_local_macro!(anchor_world_macro)

      layer_attrs = %{material_id: blueprint.material_id, health: 100}

      cells =
        Enum.map(blueprint.occupied_slots, fn slot ->
          %{
            chunk_coord: chunk_coord,
            local_macro: local_macro,
            micro_slot: slot,
            layer_attrs: layer_attrs
          }
        end)

      {:ok, cells}
    end
  end

  @doc """
  Groups raster cells by chunk for callers that want chunk-major iteration.

  v2 prefabs are single-macro so the grouping is degenerate (one chunk key,
  all cells under it),but the helper API is preserved so gate dispatch /
  observability code does not have to special-case single-macro vs
  hypothetical multi-macro v3 prefabs.
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
end
