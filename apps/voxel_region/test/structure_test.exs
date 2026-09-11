defmodule VoxelRegion.StructureTest do
  use ExUnit.Case, async: false
  import Bitwise
  alias MmoContracts.Voxel.{Codec, Payload}
  alias VoxelRegion.{FileStore, World}

  test "one metre doorway stays open at L1 L2 L3 and thin walls survive through L5" do
    children = for oct <- 0..7 do
      for z <- 0..7,y <- 0..7,x <- 0..7,
        wx = x+8*(oct &&& 1), wy = y+8*((oct >>> 1) &&& 1), wz = z+8*((oct >>> 2) &&& 1),
        wz == 0 and (wx < 4 or wx >= 12 or wy >= 12), into: %{}, do: {x+8*(y+8*z),{11,{1,0}}}
    end
    l1 = VoxelRegion.Structure.from_canonical(children)
    l2 = VoxelRegion.Structure.reduce([l1,0,0,0,0,0,0,0])
    l3 = VoxelRegion.Structure.reduce([l2,0,0,0,0,0,0,0])
    for {grid,opening} <- [{l1,{8,4,0}},{l2,{4,2,0}},{l3,{2,1,0}}] do
      assert sample(grid,opening) == 0
      assert sample(grid,{0,0,0}) == 267
    end
    l4 = VoxelRegion.Structure.reduce([l3,0,0,0,0,0,0,0])
    l5 = VoxelRegion.Structure.reduce([l4,0,0,0,0,0,0,0])
    assert sample(l5,{0,0,0}) == 267
    assert VoxelRegion.Structure.reduce([19,19,19,19,19,19,19,19]) == :binary.copy(<<19::16-little>>,4096)
  end

  test "VXR6 preserves exact grid bytes and rejects invalid structure values" do
    grid = <<267::16-little, 19::16-little, 0::size(4094*16)>>
    p = struct(Payload, level: 1, cells: :binary.copy(<<0,0>>,66*66*66)) |> Map.put(:structure,%{4430 => grid})
    bytes = Payload.encode(p,%{},9,123)
    assert binary_part(bytes,0,8) == <<"VXR6",6::32-little>>
    assert {:ok, decoded} = Payload.decode(bytes)
    assert decoded.structure == %{4430 => grid}
    assert decoded.refined == %{} and decoded.instances == %{}
    {:ok,_,raw} = Codec.decode_payload_body(bytes)
    terrain = binary_part(raw,0,byte_size(raw)-8204)
    for suffix <- [<<2::32-little,1::32-little,4430::32-little,grid::binary>>,
                   <<1::32-little,1::32-little,4430::32-little,256::16-little,0::size(4095*16)>>,
                   <<1::32-little,1::32-little,4430::32-little,11::16-little,0::size(4095*16)>>] do
      assert {:error,_} = Payload.decode(Codec.encode_payload(1,{0,0,0},9,123,terrain<>suffix,6))
    end
    assert {:error,_} = Payload.decode(Codec.encode_payload(0,{0,0,0},9,123,raw,6))
    if path = System.get_env("A3_GOLDEN"), do: File.write!(path,bytes)
  end

  test "cross region structure publishes all levels, refreshes neighboring terrain, and rebuilds after restart" do
    root = Path.join(System.tmp_dir!(),"a3_structure_#{System.unique_integer([:positive])}")
    catalog = Path.join(root,"catalog")
    File.mkdir_p!(catalog)
    bytes = <<"VXPD",1::32-little,2::32-little,0::signed-little-32,0::signed-little-32,0::signed-little-32,11::16-little,
      1::signed-little-32,0::signed-little-32,0::signed-little-32,19::16-little,0::32-little>>
    File.write!(Path.join(catalog,"wall.vxpd"),bytes)
    for level <- 0..5, x <- -1..1, y <- -1..1, z <- -1..1 do
      path = FileStore.path(root,123,level,{x,y,z})
      File.mkdir_p!(Path.dirname(path))
      p = %Payload{level: level,region: {x,y,z},cells: :binary.copy(<<0,0>>,66*66*66)}
      File.write!(path,Payload.encode(p,%{},0,123))
    end
    on_exit(fn -> File.rm_rf!(root) end)
    opts = [root: root,prefab_catalog_path: catalog,name: :a3_structure_test]
    {:ok,w} = World.start_link(opts)
    assert {:ok,1} = World.place_prefab(w,:crypto.hash(:sha256,bytes),{511,8,8},0)
    [txn] = World.entries_after(w,0)
    levels = Enum.map(txn.entries,fn e -> {:ok,h}=Codec.decode_payload_header(e.payload); h.level end)
    assert Enum.sort(Enum.uniq(levels)) == Enum.to_list(0..5)
    for level <- 1..5 do
      p = payload(w,level,{0,0,0})
      assert map_size(p.structure) > 0
      assert Enum.any?(p.structure,fn {_,g} -> Enum.any?(for(<<v::16-little <- g>>,do: v),&((&1 &&& 256) != 0)) end)
    end
    p = payload(w,1,{0,0,0})
    left = p.structure[Payload.cell_index({32,1,1})]
    assert sample(left,{15,8,8}) == 267
    assert sample(left,{14,8,8}) == 0
    assert {:ok,2} = World.apply_edit(w,{62,0,0},19)
    updated = payload(w,1,{0,0,0}).structure[Payload.cell_index({32,1,1})]
    assert sample(updated,{0,0,0}) == 19
    assert sample(updated,{15,8,8}) == 267
    assert :ok = World.compact(w)
    GenServer.stop(w)
    # 故意替换合法派生缓存；恢复必须以 L0 实际占用重建，不能信任该缓存。
    log = VoxelRegion.OverlayLog.File.open(Path.join(root,FileStore.hex(123)),123)
    [checkpoint] = VoxelRegion.OverlayLog.File.replay(log)
    entries = Enum.map(checkpoint.entries,fn
      %{payload: bytes}=e ->
        {:ok,p} = Payload.decode(bytes)
        structure = Map.new(p.structure,fn {i,_} -> {i,:binary.copy(<<275::16-little>>,4096)} end)
        %{e | payload: Payload.encode(%{p | structure: structure},%{},p.seq,p.content_version)}
      e -> e
    end)
    :ok = VoxelRegion.OverlayLog.File.checkpoint(log,%{checkpoint | entries: entries})
    {:ok,w} = World.start_link(opts)
    assert World.content_version(w) == 123
    assert payload(w,1,{0,0,0}).structure[Payload.cell_index({32,1,1})] == updated
    assert {:ok,3} = World.remove_prefab(w,{1,0})
    for level <- 1..5, do: assert(payload(w,level,{0,0,0}).structure == %{})
    GenServer.stop(w)
    {:ok,w} = World.start_link(opts)
    assert World.seq(w) == 3
    assert payload(w,1,{0,0,0}).structure == %{}
    GenServer.stop(w)
  end

  defp sample(grid,{x,y,z}) do
    <<value::16-little>> = binary_part(grid,2*(x+16*(y+16*z)),2)
    value
  end
  defp payload(w,level,region) do
    request = Codec.encode_request(0,[%{level: level,region: region,have_seq: 0,have_hash: 0}]) |> IO.iodata_to_binary()
    {:ok,reply} = World.serve(w,request)
    {:ok,123,[{:payload,^level,^region,bytes}]} = Codec.decode_reply(IO.iodata_to_binary(reply))
    {:ok,p} = Payload.decode(bytes)
    p
  end
end
