defmodule MmoContracts.VoxelMaterialCatalog do
  @moduledoc """
  Voxim 世界线上的材质契约。

  人工维护的事实源是 Voxim 的 `EVoxelMaterial` 枚举；本模块从随应用发布的 JSON
  派生表编译，供服务端 manifest、内容身份与 Gate 信任边界共同使用。
  """

  @resource Path.expand("../../priv/voxim_materials.json", __DIR__)
  @external_resource @resource

  @materials @resource |> File.read!() |> Jason.decode!()
  @blocking Map.new(@materials, fn %{"id" => id, "blocks_movement" => blocks}
                                   when is_boolean(blocks) ->
              {id, blocks}
            end)
  @blocking_bytes IO.iodata_to_binary([
                    "voxim-blocking-v1\n",
                    <<map_size(@blocking)::16-big>>,
                    for(
                      {id, blocks} <- Enum.sort(@blocking),
                      do: <<id::16-big, if(blocks, do: 1, else: 0)>>
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

  @doc "Movement blocking projected from the catalog metadata; unknown IDs are not terrain."
  def blocks_movement?(id), do: Map.fetch!(@blocking, id)
  def blocking_bytes, do: @blocking_bytes
  def blocking_hash, do: @blocking_hash
end
