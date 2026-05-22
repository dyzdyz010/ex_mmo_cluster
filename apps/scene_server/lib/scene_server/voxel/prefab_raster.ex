defmodule SceneServer.Voxel.PrefabRaster do
  @moduledoc """
  Pure rasterizer that turns a v2 prefab blueprint and a world-micro anchor into
  a flat list of `(chunk_coord, local_macro_coord, micro_slot, layer_attrs)` micro
  cell writes.

  Phase A1 升级 v1 → v2:rasterizer 现在产生 micro 级 intents(每个 occupied
  micro slot 一条),不再是 macro `put_solid_block` 写。

  Phase A1 hotfix(2026-05-09):锚点按 world-micro 精度落地,**不再** floor
  到 macro。客户端 boundary-snap preview 给出的 `anchorMicroCoord` 可以是
  mid-macro,rasterizer 会按每个 occupied slot 的局部偏移,把 prefab 的
  `(slot_x, slot_y, slot_z)` 加到 `anchor_world_micro`,再 `floor_div /
  floor_mod` 拆出每个 cell 的 `(chunk_coord, local_macro, micro_slot)`。
  这样 mid-macro 锚点会自然让 prefab 跨 2~8 个 macros / 1~4 个 chunks,
  与客户端线框预览像素级一致。Macro-aligned 锚点是退化情形:所有 cell
  都落在同一个 macro 上、slot 索引等于 blueprint 原 slot。

  Supported in v2:

    - yaw rotation in quarter turns (`0..3`) around the prefab's local 8x8
      micro footprint, matching the web client's `EVoxelRotation`.

  Out of scope for v2:

    - blueprint 自身大于 8³(目前 `BlueprintCatalog` 仍然 single-macro mask)
    - microgrid 高级特性 / boundary snapping / socket snapping
    - parcel 所有权检查(由 gate dispatch 走 World map ledger)
    - 跨 region(不同 lease)的 prefab — gate dispatch 仍走 single-lease
      路径(handoff backlog "跨 region 多 participant 事务")
  """

  alias SceneServer.Voxel.{BlueprintCatalog, Types}

  @typedoc """
  One micro-cell write produced by the rasterizer. `layer_attrs` is the
  `MicroLayer.normalize!`-friendly attribute map (currently `material_id` +
  `health`, with optional object provenance).
  """
  @type cell :: %{
          chunk_coord: Types.chunk_coord(),
          local_macro: Types.local_macro_coord(),
          micro_slot: 0..511,
          layer_attrs: %{
            required(:material_id) => 0..0xFFFF,
            required(:health) => 0..0xFFFF,
            optional(:owner_object_id) => 0..0x7FFF_FFFF_FFFF_FFFF,
            optional(:owner_part_id) => 0..0xFFFF_FFFF
          }
        }

  @doc """
  Rasterizes a v2 prefab placement.

  ## Arguments

    * `blueprint_id` – the canonical v2 blueprint id (see `BlueprintCatalog`).
    * `blueprint_version` – wire-negotiated version, must match the catalog
      (v2 = 2).
    * `anchor_world_micro` – placement origin in world-micro coordinates, the
      same units used by `0x67 PrefabPlaceIntent`. Each blueprint slot
      `(lx, ly, lz)` writes to `(anchor + (lx, ly, lz))` in world-micro space.
    * `rotation` – wire byte, `0..3` = yaw quarter turns around local Y.
    * `opts[:owner_object_id]` / `opts[:owner_part_id]` – optional object
      provenance for real prefab placement. When omitted, the rasterizer keeps
      the legacy terrain-like layer attrs so pure geometry tests and callers
      that intentionally do not allocate objects remain compatible.

  ## Returns

    * `{:ok, cells}` – non-empty list of `cell()` writes. Cells may span
      multiple macros / chunks when the anchor is not macro-aligned.
    * `{:error, reason}` on resolution / validation failure.
  """
  @spec rasterize(
          non_neg_integer(),
          non_neg_integer(),
          Types.world_micro_coord(),
          0..0xFF,
          keyword()
        ) ::
          {:ok, [cell()]} | {:error, atom()}
  def rasterize(blueprint_id, blueprint_version, anchor_world_micro, rotation, opts \\ []) do
    with {:ok, blueprint} <- BlueprintCatalog.fetch(blueprint_id, blueprint_version),
         {:ok, rotation} <- normalize_rotation(rotation),
         {:ok, anchor} <- normalize_anchor(anchor_world_micro),
         {:ok, owner_attrs} <- normalize_owner_attrs(opts) do
      layer_attrs =
        %{material_id: blueprint.material_id, health: 100}
        |> Map.merge(owner_attrs)

      cells =
        Enum.map(blueprint.occupied_slots, fn slot ->
          slot
          |> rotate_slot(rotation)
          |> rasterize_slot(anchor, layer_attrs)
        end)

      {:ok, cells}
    end
  end

  @doc """
  Groups raster cells by chunk for callers that want chunk-major iteration.

  After the Phase A1 hotfix, mid-macro anchors can produce cells across
  multiple chunks; this helper buckets them so per-chunk dispatch (lease
  resolution, transaction participants, batch storage writes) stays uniform.
  """
  @spec group_by_chunk([cell()]) :: %{Types.chunk_coord() => [cell()]}
  def group_by_chunk(cells) when is_list(cells) do
    Enum.group_by(cells, & &1.chunk_coord)
  end

  defp normalize_rotation(rotation) when rotation in 0..3, do: {:ok, rotation}
  defp normalize_rotation(rot) when is_integer(rot), do: {:error, :unsupported_rotation}
  defp normalize_rotation(_rot), do: {:error, :invalid_rotation}

  defp normalize_anchor({ax, ay, az})
       when is_integer(ax) and is_integer(ay) and is_integer(az) do
    {:ok, {ax, ay, az}}
  end

  defp normalize_anchor(_), do: {:error, :invalid_anchor_world_micro}

  defp normalize_owner_attrs(opts) when is_list(opts) do
    owner_object_id = Keyword.get(opts, :owner_object_id, 0)
    owner_part_id = Keyword.get(opts, :owner_part_id, 0)

    with {:ok, owner_object_id} <- normalize_owner_object_id(owner_object_id),
         {:ok, owner_part_id} <- normalize_owner_part_id(owner_part_id) do
      cond do
        owner_object_id == 0 and owner_part_id == 0 ->
          {:ok, %{}}

        owner_object_id == 0 ->
          {:error, :owner_part_without_object}

        true ->
          {:ok, %{owner_object_id: owner_object_id, owner_part_id: owner_part_id}}
      end
    end
  end

  defp normalize_owner_attrs(_opts), do: {:error, :invalid_owner_opts}

  defp normalize_owner_object_id(value)
       when is_integer(value) and value >= 0 and value <= 0x7FFF_FFFF_FFFF_FFFF,
       do: {:ok, value}

  defp normalize_owner_object_id(_value), do: {:error, :invalid_owner_object_id}

  defp normalize_owner_part_id(value)
       when is_integer(value) and value >= 0 and value <= 0xFFFF_FFFF,
       do: {:ok, value}

  defp normalize_owner_part_id(_value), do: {:error, :invalid_owner_part_id}

  defp rasterize_slot(slot, {ax, ay, az}, layer_attrs) do
    micro_resolution = Types.micro_resolution()
    {lx, ly, lz} = Types.micro_coord!(slot)

    wx = ax + lx
    wy = ay + ly
    wz = az + lz

    world_macro = {
      Types.floor_div(wx, micro_resolution),
      Types.floor_div(wy, micro_resolution),
      Types.floor_div(wz, micro_resolution)
    }

    local_micro = {
      Types.floor_mod(wx, micro_resolution),
      Types.floor_mod(wy, micro_resolution),
      Types.floor_mod(wz, micro_resolution)
    }

    {chunk_coord, local_macro} = Types.chunk_and_local_macro!(world_macro)

    %{
      chunk_coord: chunk_coord,
      local_macro: local_macro,
      micro_slot: Types.micro_index!(local_micro),
      layer_attrs: layer_attrs
    }
  end

  defp rotate_slot(slot, 0), do: slot

  defp rotate_slot(slot, rotation) do
    slot
    |> Types.micro_coord!()
    |> rotate_micro_coord(rotation)
    |> Types.micro_index!()
  end

  defp rotate_micro_coord({x, y, z}, rotation) do
    max = Types.micro_resolution() - 1

    case rotation do
      1 -> {max - z, y, x}
      2 -> {max - x, y, max - z}
      3 -> {z, y, max - x}
    end
  end
end
