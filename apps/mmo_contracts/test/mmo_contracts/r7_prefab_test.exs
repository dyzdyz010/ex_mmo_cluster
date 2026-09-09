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
end
