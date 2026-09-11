defmodule MmoContracts.R7PrefabTest do
  use ExUnit.Case, async: true
  alias MmoContracts.Voxel.{Codec, Payload}

  test "VXR5 preserves actual owner occupancy and complete identity" do
    p = struct(Payload, cells: :binary.copy(<<0, 0>>, 66*66*66))
    p = Map.put(p, :refined, %{4430 => %{7 => {11, {9, 0}}}})
    p = Map.put(p, :instances, %{{9, 0} => %{definition_id: :binary.copy(<<42>>, 32), anchor: {-1, 8, 129}, orientation: 1}})
    bytes = Payload.encode(p, %{}, 9, 123)
    assert <<"VXR5", 5::32-little, _::binary>> = bytes
    assert {:ok, decoded} = Payload.decode(bytes)
    assert decoded.refined == p.refined
    assert decoded.instances == p.instances
    assert decoded.content_version == 123
  end

  test "placement and removal decode exact identity without client footprint" do
    id = :binary.copy(<<42>>, 32)
    assert {:ok, {:voxel_prefab_place_v1, request}} = Codec.decode(<<0x7A, 1::64, 2::32, 3::64, id::binary, -1::signed-64, 8::signed-64, 129::signed-64, 1>>)
    assert request.definition_id == id
    assert request.anchor == {-1, 8, 129}
    assert {:ok, {:voxel_prefab_remove_v1, %{instance_id: {9, 0}}}} = Codec.decode(<<0x7B, 1::64, 2::32, 3::64, 9::64, 0::32>>)
  end

  test "payload format and body agree; refined macro storage is Air" do
    p = struct(Payload,cells: :binary.copy(<<0,0>>,66*66*66))
    <<_::binary-size(8),tail::binary>> = Payload.encode(p,%{},0,123)
    assert {:error,:invalid_payload} = Payload.decode(<<"VXR5",5::32-little,tail::binary>>)
    p = %{p | refined: %{4430 => %{7 => {11,{9,0}}}},
      instances: %{{9,0} => %{definition_id: :binary.copy(<<42>>,32),anchor: {-1,8,129},orientation: 1}}}
    <<_::binary-size(8),tail::binary>> = Payload.encode(p,%{},9,123)
    assert {:error,:invalid_payload} = Payload.decode(<<"VXR4",4::32-little,tail::binary>>)
    bytes = Payload.encode(p,%{{8,1,1} => {11,MmoContracts.Voxel.Skins.uniform(11)}},9,123)
    assert {:error,:invalid_payload} = Payload.decode(bytes)
  end
  test "VXR7 ancestor identity and replacement frozen bytes" do
    root = %{definition_id: :binary.copy(<<42>>,32),anchor: {-1,8,129},orientation: 1,parent_id: {0,0},component_slot: 0}
    child = %{root | parent_id: {9,0}, component_slot: 17}
    p = %Payload{cells: :binary.copy(<<0,0>>,66*66*66),refined: %{4430 => %{7 => {11,{10,0}}}},instances: %{{9,0} => root,{10,0} => child}}
    bytes = Payload.encode(p,%{},10,123)
    assert <<"VXR7",7::32-little,_::binary>> = bytes
    assert {:ok,decoded} = Payload.decode(bytes)
    assert decoded.instances == p.instances
    assert {:error,:invalid_payload} = Payload.decode(Payload.encode(%{p | level: 1},%{},10,123))
    assert {:ok,{:voxel_prefab_replace_v1,%{instance_id: {10,0},definition_id: id}}} = Codec.decode(<<0x7C,1::64,2::32,3::64,10::64,0::32,root.definition_id::binary>>)
    assert id == root.definition_id
    assert {:error,:invalid_message} = Codec.decode(<<0x7C,1>>)
  end
  test "VXR7 rejects invalid ancestry at the payload boundary" do
    base = %{definition_id: :binary.copy(<<42>>,32),anchor: {0,0,0},orientation: 0,parent_id: {0,0},component_slot: 0}
    p = %Payload{cells: :binary.copy(<<0,0>>,66*66*66),refined: %{4430 => %{7 => {11,{10,0}}}}}
    for parent <- [{10,0},{11,0},{8,0}] do
      bytes = Payload.encode(%{p | instances: %{{9,0} => base,{10,0} => %{base | parent_id: parent,component_slot: 17}}},%{},10,123)
      assert {:error,:invalid_payload} = Payload.decode(bytes)
    end
  end
end
