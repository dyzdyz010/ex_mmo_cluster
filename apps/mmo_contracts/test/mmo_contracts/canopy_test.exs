defmodule MmoContracts.CanopyTest do
  use ExUnit.Case, async: true
  alias MmoContracts.Voxel.{Canopy, Payload, Codec, Skins}
  test "frozen sparse anchors preserve identity and residual skin bytes" do
    id = :binary.copy(<<9>>,32)
    instance = %{definition_id: id,anchor: {-8,-8,-8},orientation: 0,parent_id: {0,0},component_slot: 0}
    anchors = %{{-1,-1,-1} => {58,{7,0},2}}
    residual = %{0 => {11,Skins.uniform(11)}}
    expected = <<1::32-little,0::32,1::32-little,7::64-little,0::32,id::binary,
      -8::signed-little-64,-8::signed-little-64,-8::signed-little-64,0,0::64,0::32,0::32,
      1::32-little,-1::signed-little-64,-1::signed-little-64,-1::signed-little-64,
      7::64-little,0::32,58::16-little,2::16-little,1::32-little,0::32,11::16-little,1,11,11,11,11,11,11,0,2::32-little,0::32>>
    assert Canopy.encode(anchors,%{{7,0}=>instance},residual) == expected
    assert {:ok,^anchors,%{{7,0}=>^instance},^residual,%{}} = Canopy.decode(expected)
    assert {:error,:invalid_canopy} = Canopy.decode(expected <> <<0>>)
    assert {:error,:invalid_canopy} = Canopy.decode(binary_part(expected,0,byte_size(expected)-1))
    assert {:error,:invalid_canopy} = Canopy.decode(<<2::32-little>> <> binary_part(expected,4,byte_size(expected)-4))
  end
  test "VXRD explicit wrapper leaves canonical terrain and old payloads intact" do
    p = %Payload{cells: :binary.copy(<<58,0>>,66*66*66)}
    old = Payload.encode(p,%{},1,1)
    assert {:ok,%{version: 4},_} = Codec.unpack_payload_body(old)
    i = %{definition_id: :binary.copy(<<1>>,32),anchor: {0,0,0},orientation: 0,parent_id: {0,0},component_slot: 0}
    p = p |> Map.put(:canopy,%{{0,0,0}=>{58,{1,0},3}}) |> Map.put(:canopy_instances,%{{1,0}=>i}) |> Map.put(:canopy_residual,%{Payload.cell_index({1,1,1})=>{0,Skins.uniform(0)}})
    bytes = Payload.encode(p,%{},2,1)
    assert <<"VXRD",13::32-little,_::binary>> = bytes
    assert {:ok,decoded} = Payload.decode(bytes)
    assert decoded.cells == p.cells
    assert decoded.canopy == p.canopy
    assert decoded.canopy_residual == p.canopy_residual
    assert Payload.encode(decoded,%{},2,1) == bytes
    assert {:ok,cleared} = Payload.decode(Payload.replace_details(bytes,%Payload{},3,1))
    assert cleared.canopy == %{}
  end
  test "VXRD rejects anchors outside XYZ region and mismatched residual coverage" do
    i=%{definition_id: :binary.copy(<<1>>,32),anchor: {0,0,0},orientation: 0,parent_id: {0,0},component_slot: 0}
    p=%Payload{cells: :binary.copy(<<58,0>>,66*66*66)}
    p=p |> Map.put(:canopy_instances,%{{1,0}=>i}) |> Map.put(:canopy,%{{0,0,0}=>{58,{1,0},3}})
    assert {:error,:invalid_payload}=Payload.decode(Payload.encode(p,%{},1,1))
    p=Map.put(p,:canopy_residual,%{Payload.cell_index({1,1,1})=>{0,Skins.uniform(0)}})
    assert {:ok,_}=Payload.decode(Payload.encode(p,%{},1,1))
    for point<-[{65,0,0},{0,65,0},{0,0,65},{-2,0,0}] do
      q=Map.put(p,:canopy,%{point=>{58,{1,0},3}})
      assert {:error,:invalid_payload}=Payload.decode(Payload.encode(q,%{},1,1))
    end
  end
end