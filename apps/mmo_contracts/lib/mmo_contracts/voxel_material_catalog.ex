defmodule MmoContracts.VoxelMaterialCatalog do
  @moduledoc """
  Voxim 世界线上的材质契约。

  材料 id/name 与 Voxim 的 `EVoxelMaterial` 枚举一致；随应用发布的 JSON 独占
  移动阻挡与附件支撑元数据。本模块从它编译，供 manifest、兼容身份与信任边界共同使用。
  """

  @resource Path.expand("../../priv/voxim_materials.json", __DIR__)
  @external_resource @resource

  @materials @resource |> File.read!() |> Jason.decode!()
  @blocking Map.new(@materials, fn %{"id" => id, "blocks_movement" => blocks}
                                   when is_boolean(blocks) ->
              {id, blocks}
            end)
  @support Map.new(@materials, fn %{"id" => id, "supports_attachments" => supports}
                                  when is_boolean(supports) -> {id, supports} end)
  # 复用 Session 的 blocking_hash 身份槽；v2 同时承诺移动阻挡与附件支撑，二者任一变化均失配。
  @blocking_bytes IO.iodata_to_binary([
                    "voxim-blocking-v2\n",
                    <<map_size(@blocking)::16-big>>,
                    for(
                      {id, blocks} <- Enum.sort(@blocking),
                      do: <<id::16-big, if(blocks, do: 1, else: 0), if(Map.fetch!(@support, id), do: 1, else: 0)>>
                    )
                  ])
  @blocking_hash :crypto.hash(:sha256, @blocking_bytes)

  @pairs @materials
         |> Enum.map(fn %{"id" => id, "name" => name} -> {id, name} end)

  @table Enum.map(@pairs, fn {id, name} -> %{"id" => id, "name" => name} end)
  @identity_bytes Jason.encode!(Enum.map(@pairs, &Tuple.to_list/1))
  @valid_ids MapSet.new(Enum.map(@pairs, &elem(&1, 0)))

  @spec table() :: [map()]
  def table, do: @table

  @spec identity_bytes() :: binary()
  def identity_bytes, do: @identity_bytes

  @spec valid_id?(term()) :: boolean()
  def valid_id?(id), do: MapSet.member?(@valid_ids, id)

  @doc "地面花草（32..39）：非实体格，可被建造 / 液体替换，失去下方支撑即消失，粗 LOD 上当空气。"
  def flora?(id), do: id in 32..39

  @doc "全局系统功能：与客户端 MaterialIsTrunk 相同的目录语义。"
  def trunk?(id), do: id == 19 or id in 25..27 or id in [57, 59, 61, 63]

  @doc "ReduceCellV2 水平薄层资格：非空、非液体、非透明、非叶/花草、非树干、非植物装饰；不等同移动阻挡。"
  def lod_dry_sheet?(id) do
    id != 0 and id not in [20, 21, 22, 44, 50, 74, 87] and
      id not in 28..39 and id not in [58, 60, 61, 62, 64] and
      not trunk?(id) and id not in 65..73
  end

  @doc "Movement blocking projected from the catalog metadata; unknown IDs are not terrain."
  def blocks_movement?(id), do: Map.fetch!(@blocking, id)
  @doc "附件支撑资格独立于移动阻挡；未知 ID 在目录接纳边界外。"
  def supports_attachments?(id), do: Map.fetch!(@support, id)
  def blocking_bytes, do: @blocking_bytes
  def blocking_hash, do: @blocking_hash
end
