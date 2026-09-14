defmodule VoxelRegion.DamageTest do
  use ExUnit.Case, async: true
  alias VoxelRegion.Damage

  test "first textured edit after empty CSR preserves texels and subsequent cached edits" do
    alias MmoContracts.Voxel.{Payload,Skins}
    for level <- [1,2] do
      extent=VoxelRegion.Reducer.skin_extent(level)
      base=%Payload{level: level,region: {0,0,0},map_extent: extent,
        cells: :binary.copy(<<11::16-little>>,Payload.extent() ** 3)}
      {:ok,empty}=Payload.decode(Payload.encode(base,%{},0,123))
      assert empty.map_extent==1
      texels=:binary.copy(<<11,19>>,div(extent*extent,2))
      skin={extent,{{11,texels},{11,nil},{11,nil},{11,nil},{11,nil},{11,nil}}}
      first=%{{1,1,1}=>{11,skin}}
      bytes=Payload.encode(empty,first,1,123)
      {:ok,edited}=Payload.decode(bytes)
      assert Payload.skins(edited,{1,1,1},11)==skin
      assert edited.map_extent==extent

      next_texels=:binary.copy(<<19,11>>,div(extent*extent,2))
      next_skin={extent,{{19,next_texels},{11,nil},{11,nil},{11,nil},{11,nil},{11,nil}}}
      second=%{{2,1,1}=>{11,next_skin}}
      cached=Payload.replace_cells_and_details(bytes,second,edited,2,123)
      assert cached==Payload.encode(empty,Map.merge(first,second),2,123)
      {:ok,both}=Payload.decode(cached)
      assert Payload.skins(both,{1,1,1},11)==skin
      assert Payload.skins(both,{2,1,1},11)==next_skin

      clear=Map.new([{1,1,1},{2,1,1}],&{&1,{11,Skins.uniform(11)}})
      {:ok,empty_again}=Payload.decode(Payload.encode(both,clear,3,123))
      assert empty_again.map_extent==1 and empty_again.records==%{}
      {:ok,restored}=Payload.decode(Payload.encode(empty_again,first,4,123))
      assert Payload.skins(restored,{1,1,1},11)==skin
    end
  end

  @tag :cadence
  test "half-second input with one-tick jitter keeps every hit without accumulating credit" do
    arrivals=for i <- 0..199,do: i*500_000+Enum.at([0,16_000,0,10_000],rem(i,4))
    Enum.reduce(Enum.with_index(arrivals,1),nil,fn {now,seq},previous ->
      assert {:ok,next}=Damage.admit_attack(previous,seq,now,500_000,16_667)
      next
    end)
    assert {:ok,first}=Damage.admit_attack(nil,1,0,500_000,16_667)
    assert {:ok,early}=Damage.admit_attack(first,2,484_000,500_000,16_667)
    assert {:error,:tool_cooldown}=Damage.admit_attack(early,3,968_000,500_000,16_667)
    assert {:error,:replayed_attack}=Damage.admit_attack(early,2,2_000_000,500_000,16_667)
    assert {:ok,idle}=Damage.admit_attack(early,3,10_000_000,500_000,16_667)
    assert {:error,:tool_cooldown}=Damage.admit_attack(idle,4,10_000_001,500_000,16_667)
  end

  @tag :cadence
  test "twenty Hz attempts obey the same sustained bound as arbitrary jitter" do
    for arrivals <- [Enum.to_list(0..10_000_000//50_000),
                     Enum.map(0..999,&(&1*20_000+rem(&1*7919,17_000)))] do
      {_,accepted}=Enum.reduce(Enum.with_index(arrivals,1),{nil,[]},fn {now,seq},{previous,hits} ->
        case Damage.admit_attack(previous,seq,now,500_000,16_667) do
          {:ok,next} -> {next,[now|hits]}
          {:error,:tool_cooldown} -> {previous,hits}
        end
      end)
      hits=Enum.reverse(accepted) |> Enum.with_index()
      for {a,i} <- hits,{b,j} <- hits,j>i do
        assert b-a >= (j-i)*500_000-16_667
      end
      if length(arrivals)==201,do: assert(length(hits)==21)
    end
  end

  test "most specific action applies once and micro damage scales with material volume" do
    material = %{"max_hp_per_macro" => 100.0, "defense" => 2.0,
      "responses" => [%{"action" => "damage", "multiplier" => 0.5},
        %{"action" => "damage.physical.mine", "multiplier" => 2.0}]}
    tool = %{"action" => "damage.physical.mine", "power" => 30.0}
    assert Damage.amount(material,tool,0) == 56.0
    assert Damage.amount(material,tool,1) == 56.0/512
    assert Damage.max_hp(material,1) == 100.0/512
    assert Damage.amount(material,%{tool | "power" => 1.0},0) == 0.0
  end

  test "DDA visits occupied micro without skipping thin surfaces and stops at first obstruction" do
    at = fn cell, visited ->
      value = if cell in [{-1,0,0},{-3,0,0}], do: %{micro: cell}, else: nil
      {value,[cell|visited]}
    end
    assert {:ok,%{micro: {-1,0,0}},_} = Damage.raycast({0.2,0.0625,0.0625},{-1.0,0.0,0.0},6.0,[],at)
    assert {:error,:no_target,_} = Damage.raycast({0.2,0.0625,0.0625},{1.0,0.0,0.0},6.0,[],at)
  end

  test "network rejects invalid action, direction, tool and truncated frame" do
    alias MmoContracts.Voxel.Codec
    prefix = <<0x7D, 1::64, 1::32, 1::64>>
    tail = <<0.0::float-64, 1.0::float-64, 0.0::float-64, 0::signed-64,0::signed-64,0::signed-64,0::64,0::64,0::32,11::16,1::16>>
    assert {:ok,{:voxel_tool_intent,_}} = Codec.decode(prefix <> <<0>> <> tail)
    assert {:ok,{:voxel_tool_intent,%{action: 2}}} = Codec.decode(prefix <> <<2>> <> tail)
    assert {:error,:invalid_message} = Codec.decode(prefix <> <<3>> <> tail)
    assert {:error,:invalid_message} = Codec.decode(prefix)
  end
end
