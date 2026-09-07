defmodule MmoContracts.VoxelMaterialCatalog do
  @moduledoc """
  Voxim 世界线上的材质契约。

  人工维护的事实源是 Voxim 的 `EVoxelMaterial` 枚举；本模块从随应用发布的 JSON
  派生表编译，供服务端 manifest、内容身份与 Gate 信任边界共同使用。
  """

  @resource Path.expand("../../priv/voxim_materials.json", __DIR__)
  @external_resource @resource

  @pairs @resource
         |> File.read!()
         |> Jason.decode!()
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
end
