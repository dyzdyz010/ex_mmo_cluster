defmodule VoxelRegion.PrefabAuthorImportTest do
  @moduledoc "只测试：已知作者定义的Parcel准备不重新套玩家发布上限；未知定义仍受原边界约束。"
  use ExUnit.Case, async: false
  alias VoxelRegion.{Prefab, TestSupport, World}

  test "已知32769微格作者定义可原样搬运，未知目标仍拒绝玩家超限定义" do
    root = Path.join(System.tmp_dir!(), "author_import_#{System.unique_integer([:positive])}")
    catalog = Path.join(root, "catalog")
    File.mkdir_p!(catalog)
    on_exit(fn -> File.rm_rf!(root) end)
    cells = (for x <- 0..31, y <- 0..31, z <- 0..31, do: {{x,y,z},19}) ++ [{{32,0,0},19}]
    bytes = Prefab.encode(%{cells: cells, macro_cells: [], children: [], attachments: []})
    id = :crypto.hash(:sha256, bytes)
    File.write!(Path.join(catalog, Base.encode16(id, case: :lower) <> ".vxpd"), bytes)
    worlds = for kind <- [:source, :known, :unknown], into: %{} do
      directory = Path.join(root, Atom.to_string(kind))
      File.mkdir_p!(directory)
      opts = [source: TestSupport.Source, log: TestSupport.Log, observer: self(), name: nil,
        root: directory, property_catalog_path: TestSupport.catalog(),
        prefab_catalog_path: if(kind == :unknown, do: nil, else: catalog)]
      {kind, start_supervised!({World, opts}, id: kind)}
    end
    assert World.prefab_catalog(worlds.known)[id].summary.micro_cells == 32_769
    assert {:ok, _} = World.place_prefab(worlds.source, id, {0,0,0}, 0)
    box = {{0,0,0},{5,4,4}}
    assert {:ok, parcel} = World.parcel_export(worlds.source, box)
    assert parcel.definitions == %{id => bytes}
    assert {:ok, _} = World.parcel_install(worlds.known, "known-author", parcel, {0,0,0})
    assert {:ok, exported} = World.parcel_export(worlds.known, box)
    assert exported.definitions == %{id => bytes}
    assert Enum.sum(for {_, slots} <- exported.refined, do: map_size(slots)) == 32_769
    assert {:error, :micro_cell_limit} = World.parcel_install(worlds.unknown, "new-author", parcel, {0,0,0})
    assert World.seq(worlds.unknown) == 0
  end
end
