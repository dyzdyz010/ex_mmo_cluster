defmodule VoxelRegion.EditBounds do
  @moduledoc "玩家与 NPC 共用的部署编辑范围，世界合法性仍由 World 裁决。"

  @doc """
  Prefab 请求涉及的 macro 格是否都在部署的编辑盒内；玩家连接与 NPC Body 共用。
  算不出格（未知定义 / 实例）时放行，由 World 给出原因。
  """
  def prefab_within?(world_ref, kind, request, {{_, _, _}, {_, _, _}} = bounds) do
    cells =
      case kind do
        :voxel_prefab_place_v1 ->
          with {:ok, cells} <-
                 VoxelRegion.World.prefab_cells(
                   world_ref,
                   request.definition_id,
                   request.anchor,
                   request.orientation
                 ),
               do:
                 {:ok,
                  Enum.map(cells, fn {micro, _} ->
                    elem(VoxelRegion.Prefab.macro_slot(micro), 0)
                  end)}

        :voxel_prefab_remove_v1 ->
          VoxelRegion.World.instance_cells(world_ref, request.instance_id)

        :voxel_prefab_replace_v1 ->
          VoxelRegion.World.replacement_cells(
            world_ref,
            request.instance_id,
            request.definition_id
          )
      end

    case cells do
      {:ok, cells} -> Enum.all?(cells, &within?(&1, bounds))
      {:error, _} -> true
    end
  end

  @doc "macro 格是否在部署编辑盒（半开区间 `{min, max}`）内；prefab 门与 NPC 创世编辑（`NpcServer.Genesis`）共用。"
  def within?({x, y, z}, {{a, b, c}, {d, e, f}}),
    do: x >= a and y >= b and z >= c and x < d and y < e and z < f
end
