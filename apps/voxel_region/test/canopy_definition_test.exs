defmodule VoxelRegion.CanopyDefinitionTest do
  use ExUnit.Case, async: true
  alias VoxelRegion.Prefab
  test "binding is explicit content addressed v4 while unbound definitions remain v3" do
    definition = %{cells: [],children: [],attachments: [],macro_cells: [{{-1,0,1},58}]}
    assert <<"VXPD",3::32-little,_::binary>> = Prefab.encode(definition)
    definition = Map.put(definition,:presentation_bindings,%{58=>2})
    expected = <<"VXPD",4::32-little,0::32,0::32,0::32,1::32-little,-1::signed-little-32,0::32,1::32-little,58::16-little,1::32-little,58::16-little,2::16-little>>
    assert Prefab.encode(definition) == expected
    assert {:ok,^definition} = Prefab.decode(expected)
    assert {:ok,_,_} = Prefab.compile(expected,%{})
    for tail <- [<<0::32>>,<<1::32-little,58::16-little,0::16>>,<<1::32-little,11::16-little,2::16-little>>,<<2::32-little,58::16-little,2::16-little,58::16-little,3::16-little>>] do
      assert {:error,:invalid_definition} = Prefab.decode(binary_part(expected,0,38) <> tail)
    end
  end
end