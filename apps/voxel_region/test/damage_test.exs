defmodule VoxelRegion.DamageTest do
  use ExUnit.Case, async: true
  @moduletag :t0
  alias VoxelRegion.Damage

  test "first textured edit after empty CSR preserves texels and subsequent cached edits" do
    alias MmoContracts.Voxel.{Payload,Skins}
    for level <- [1,2] do
      extent=VoxelRegion.Reducer.skin_extent(level)
      base=%Payload{level: level,region: {0,0,0},map_extent: extent,
        cells: :binary.copy(<<11::16-little>>,Payload.extent() ** 3)}
      {:ok,empty}=Payload.decode(Payload.encode(base,%{},0,123))
      assert Payload.skin_extent(empty)==1
      texels=:binary.copy(<<11,19>>,div(extent*extent,2))
      skin={extent,{{11,texels},{11,nil},{11,nil},{11,nil},{11,nil},{11,nil}}}
      first=%{{1,1,1}=>{11,skin}}
      bytes=Payload.encode(empty,first,1,123)
      {:ok,edited}=Payload.decode(bytes)
      assert Payload.skins(edited,{1,1,1},11)==skin
      assert Payload.skin_extent(edited)==extent

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
      assert Payload.skin_extent(empty_again)==1 and Payload.skin_count(empty_again)==0
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

  # 期望均为手算：T = 500_000 µs，tick = 16_667 µs，晚到额度 L = 2 tick = 33_334 µs。
  defp admit_all(arrivals) do
    Enum.reduce(Enum.with_index(arrivals, 1), {nil, []}, fn {now, seq}, {previous, results} ->
      case Damage.admit_attack(previous, seq, now, 500_000, 16_667) do
        {:ok, next} -> {next, [:ok | results]}
        {:error, reason} -> {previous, [reason | results]}
      end
    end)
    |> then(fn {_, results} -> Enum.reverse(results) end)
  end

  @tag :cadence
  test "late arrival within two ticks keeps the schedule; early bound, sustained rate and idle restart hold" do
    # ① run-13 实测 Gate 入口（相对首段，µs）：第 4 段晚 18_580，第 5 段准点；旧规则在第 5 段拒为 tool_cooldown。
    assert admit_all([0, 500_362, 1_000_793, 1_519_373, 2_001_081]) == [:ok, :ok, :ok, :ok, :ok]

    # ② 晚到恰为 L 仍保持节拍（next = 1_000_000）；晚 L+1 则从到达时刻重算。
    assert {:ok, first} = Damage.admit_attack(nil, 1, 0, 500_000, 16_667)
    assert {:ok, %{next_us: 1_000_000} = kept} = Damage.admit_attack(first, 2, 533_334, 500_000, 16_667)
    assert {:ok, %{next_us: 1_033_335}} = Damage.admit_attack(first, 2, 533_335, 500_000, 16_667)
    # 刻意早发：最小可接纳间隔 = T − L − tick = 449_999 µs（next − tick = 983_333；比较为 now < next − tick 才拒，等号接纳）。
    assert {:error, :tool_cooldown} = Damage.admit_attack(kept, 3, 533_334 + 449_000, 500_000, 16_667)
    assert {:error, :tool_cooldown} = Damage.admit_attack(kept, 3, 983_332, 500_000, 16_667)
    assert {:ok, _} = Damage.admit_attack(kept, 3, 983_333, 500_000, 16_667)
    assert {:ok, _} = Damage.admit_attack(kept, 3, 533_334 + 451_000, 500_000, 16_667)

    # ③ 20 段交替“晚 L、早 1 tick”：全部接纳，且次数 ≤ 跨度 / T + 1（跨度 = 19T + L → 上界 20）。
    offset = fn k -> if k == 0, do: 0, else: if(rem(k, 2) == 1, do: 33_334, else: -16_667) end
    arrivals = for k <- 0..19, do: k * 500_000 + offset.(k)
    results = admit_all(arrivals)
    assert Enum.all?(results, &(&1 == :ok))
    assert Enum.count(results, &(&1 == :ok)) <= div(List.last(arrivals) - hd(arrivals), 500_000) + 1

    # ④ 空闲后（晚 9.5 s > L）从到达时刻重算：next = 10_500_000，不出现连发两次。
    assert {:ok, %{next_us: 10_500_000} = idle} = Damage.admit_attack(first, 2, 10_000_000, 500_000, 16_667)
    assert {:error, :tool_cooldown} = Damage.admit_attack(idle, 3, 10_000_001, 500_000, 16_667)
    assert {:error, :tool_cooldown} = Damage.admit_attack(idle, 3, 10_483_332, 500_000, 16_667)
    assert {:ok, _} = Damage.admit_attack(idle, 3, 10_483_333, 500_000, 16_667)
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
      # 晚到保持节拍（late_credit = 2 tick）后：next ≥ 到达 + T − 2 tick，之后每次至少推进 T，接纳至多早 1 tick，
      # 故任意两次接纳 b − a ≥ (j−i)·T − 3 tick（原界 −1 tick 对应“晚到即重置相位”的旧规则）。
      for {a,i} <- hits,{b,j} <- hits,j>i do
        assert b-a >= (j-i)*500_000-3*16_667
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
    tail = <<0.0::float-64, 1.0::float-64, 0.0::float-64, 0::signed-64,0::signed-64,0::signed-64,0::64,0::64,0::32,11::16,1::16,0::8,0::8>>
    assert {:ok,{:voxel_tool_intent,_}} = Codec.decode(prefix <> <<0>> <> tail)
    assert {:ok,{:voxel_tool_intent,%{action: 2}}} = Codec.decode(prefix <> <<2>> <> tail)
    assert {:error,:invalid_message} = Codec.decode(prefix <> <<3>> <> tail)
    assert {:error,:invalid_message} = Codec.decode(prefix)
  end
end
