defmodule VoxelRegion.PrefabFixture do
  @moduledoc false
  alias VoxelRegion.FileStore
  alias MmoContracts.Voxel.Payload
  import ExUnit.Callbacks, only: [on_exit: 1]
  def prepare do
    root = Path.join(System.tmp_dir!(), "r7_prefab_#{System.pid()}_#{System.unique_integer([:positive])}")
    catalog = Path.join(root, "catalog")
    File.mkdir_p!(catalog)
    bytes = <<"VXPD", 1::32-little, 2::32-little, 0::signed-little-32, 0::signed-little-32, 0::signed-little-32, 11::16-little,
      1::signed-little-32, 0::signed-little-32, 0::signed-little-32, 19::16-little, 0::32-little>>
    File.write!(Path.join(catalog,"test.vxpd"),bytes)
    id = :crypto.hash(:sha256,bytes)
    for level <- 0..5, x <- -1..1, y <- -1..1, z <- -1..1 do
      path = FileStore.path(root,123,level,{x,y,z})
      File.mkdir_p!(Path.dirname(path))
      p = %Payload{level: level, region: {x,y,z}, cells: :binary.copy(<<0,0>>,66*66*66)}
      File.write!(path,Payload.encode(p,%{},0,123))
    end
    opts = [root: root, prefab_catalog_path: catalog, name: :r7_test_world]
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, id: id, opts: opts}
  end
end
