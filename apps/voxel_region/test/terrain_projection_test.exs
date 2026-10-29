defmodule VoxelRegion.TerrainProjectionTest do
  @moduledoc "只测试：不可变合法地形输入的区域基底、ring 与 overlay 优先级，不向运行中的 World 写真值。"
  use ExUnit.Case, async: true
  alias VoxelRegion.World.{Canonical, Payloads}
  alias MmoContracts.Voxel.{Payload, Skins}

  defmodule Missing do
    def read(_, _, _), do: {:error, :missing}
  end

  @tag :ring_delta
  test "相等材料行不逐格构造规范值候选，core内非空skin不影响ring" do
    plain = %Payload{level: 0, region: {2, -1, 3}, cells: :binary.copy(<<11, 0>>, 66 * 66 * 66)}
    skin = {2, {{11, <<11, 12, 11, 12>>}, {11, nil}, {11, nil}, {11, nil}, {11, nil}, {11, nil}}}
    {:ok, center} = plain |> Payload.encode(%{{3, 3, 3} => {11, skin}}, 0, 123) |> Payload.decode()
    assert map_size(center.records) > 0
    state = ring_state(center, %{})
    {result, calls} = count_value_comparisons(fn -> Payloads.terrain_materials(state, 0, center.region) end)
    assert {:ok, materials, overrides, ^state} = result
    assert materials == center.cells and overrides == %{}
    assert calls == 0
  end

  @tag :ring_delta
  test "26邻区ring与center相等时不构造覆盖表，完整编码字节不变" do
    center = %Payload{level: 0, region: {2, -1, 3}, cells: :binary.copy(<<11, 0>>, 66 * 66 * 66)}
    state = ring_state(center, %{})
    assert {:ok, materials, overrides, ^state} = Payloads.terrain_materials(state, 0, center.region)
    assert map_size(overrides) == 0
    assert materials == center.cells
    assert Payload.encode(center, overrides, 1, 123) == Payload.encode(center, full_ring(11), 1, 123)
  end

  @tag :ring_delta
  test "负XYZ面棱角只留下实际差额，完整编码仍按原坐标和值" do
    region = {2, -1, 3}
    center = %Payload{level: 0, region: region, cells: :binary.copy(<<0, 0>>, 66 * 66 * 66)}
    neighbors = %{
      {1, -1, 3} => payload({1, -1, 3}, %{{127, -62, 194} => 21}),
      {3, -1, 3} => payload({3, -1, 3}, %{{192, -62, 194} => 19}),
      {2, -2, 3} => payload({2, -2, 3}, %{{191, -65, 194} => 21}),
      {2, 0, 3} => payload({2, 0, 3}, %{{128, 0, 194} => 22}),
      {2, -1, 2} => payload({2, -1, 2}, %{{191, -62, 191} => 19}),
      {2, -1, 4} => payload({2, -1, 4}, %{{128, -62, 256} => 22}),
      {1, -2, 3} => payload({1, -2, 3}, %{{127, -65, 194} => 22}),
      {1, -2, 2} => payload({1, -2, 2}, %{{127, -65, 191} => 19})
    }
    expected = %{{0, 3, 3} => {21, Skins.uniform(21)}, {65, 3, 3} => {19, Skins.uniform(19)},
      {64, 0, 3} => {21, Skins.uniform(21)}, {1, 65, 3} => {22, Skins.uniform(22)},
      {64, 3, 0} => {19, Skins.uniform(19)}, {1, 3, 65} => {22, Skins.uniform(22)},
      {0, 0, 3} => {22, Skins.uniform(22)},
      {0, 0, 0} => {19, Skins.uniform(19)}}
    state = ring_state(center, neighbors)
    assert {:ok, _, overrides, ^state} = Payloads.terrain_materials(state, 0, region)
    assert overrides == expected
    assert Payload.encode(center, overrides, 7, 123) == Payload.encode(center, Map.merge(full_ring(0), expected), 7, 123)
  end

  @tag :ring_delta
  test "同材质的非平凡skin仍精确比较，相同纹理省略而变化纹理保留" do
    region = {2, -1, 3}
    neighbor_region = {1, -1, 3}
    a = {2, {{11, <<11, 12, 11, 12>>}, {11, nil}, {11, nil}, {11, nil}, {11, nil}, {11, nil}}}
    b = {2, {{11, <<11, 12, 12, 11>>}, {11, nil}, {11, nil}, {11, nil}, {11, nil}, {11, nil}}}
    plain = %Payload{level: 0, region: region, cells: :binary.copy(<<11, 0>>, 66 * 66 * 66)}
    {:ok, center} = plain |> Payload.encode(%{{0, 3, 3} => {11, a}, {0, 4, 4} => {11, a},
      {0, 5, 5} => {11, a}}, 0, 123) |> Payload.decode()
    {:ok, neighbor} = %{plain | region: neighbor_region}
      |> Payload.encode(%{{64, 3, 3} => {11, a}, {64, 4, 4} => {11, b}}, 0, 123) |> Payload.decode()
    state = ring_state(center, %{neighbor_region => neighbor})
    assert {:ok, _, overrides, ^state} = Payloads.terrain_materials(state, 0, region)
    assert overrides == %{{0, 4, 4} => {11, b}, {0, 5, 5} => {11, Skins.uniform(11)}}
    complete = Map.merge(full_ring(11), %{{0, 3, 3} => {11, a}, {0, 4, 4} => {11, b}})
    assert Payload.encode(center, overrides, 7, 123) == Payload.encode(center, complete, 7, 123)
  end

  @tag :ring_delta
  test "本区基底和负XYZ角邻区ring共用原terrain投影，overlay最终覆盖" do
    region = {0, 1, -1}
    neighbor = {-1, 0, -2}
    center = {0, 64, -64}
    corner = {-1, 63, -65}
    state = %{region_bases: %{{0, region} => payload(region, %{center => 21}),
      {0, neighbor} => payload(neighbor, %{corner => 22})}, decoded: %{},
      overlay: %{{0, center} => {0, Skins.uniform(0)}},
      overlay_regions: %{{0, region} => MapSet.new([center])}, snapshots: MapSet.new([{0, region}]), source: Missing, source_state: nil}
    assert {:ok, materials, overrides, ^state} = Payloads.terrain_materials(state, 0, region)
    assert elem(Payload.value(%Payload{cells: materials}, Payload.local(region, center)), 0) == 21
    assert elem(overrides[{1, 1, 1}], 0) == 0
    assert elem(overrides[{0, 0, 0}], 0) == 22
    assert {:ok, {0, _}, _} = Canonical.cell_value(state, 0, center)
    assert {:ok, {22, _}, _} = Canonical.cell_value(state, 0, corner)

    state = %{state | overlay: Map.put(state.overlay, {0, corner}, {21, Skins.uniform(21)}),
      overlay_regions: %{{0, region} => MapSet.new([center, corner])}}
    assert {:ok, _, changed, _} = Payloads.terrain_materials(state, 0, region)
    assert elem(changed[{0, 0, 0}], 0) == 21
    assert {:ok, {21, _}, _} = Canonical.cell_value(state, 0, corner)
  end

  test "缺失地形保持原错误，不生成空气候选" do
    state = %{region_bases: %{}, overlay_regions: %{}, decoded: %{}, cache: VoxelRegion.World.Cache.new(1_048_576),
      snapshots: MapSet.new(), source: Missing, source_state: nil}
    assert {:error, :missing, failed} = Payloads.terrain_materials(state, 0, {0, 1, -1})
    assert failed.decoded == %{}
    assert Payloads.cached_keys(failed) == []
  end

  defp payload(region, materials) do
    base = %Payload{level: 0, region: region, cells: :binary.copy(<<0, 0>>, 66 * 66 * 66)}
    overrides = Map.new(materials, fn {cell, m} -> {Payload.local(region, cell), {m, Skins.uniform(m)}} end)
    {:ok, payload} = base |> Payload.encode(overrides, 0, 123) |> Payload.decode()
    payload
  end

  defp count_value_comparisons(action) do
    mfa = {Payload, :same_value?, 4}
    pid = self()
    session = :trace.session_create(:ring_span_comparisons, self(), [])
    try do
      assert :trace.function(session, mfa, true, [:call_time]) == 1
      assert :trace.process(session, pid, true, [:call, :arity]) == 1
      result = action.()
      assert :trace.process(session, pid, false, [:call, :arity]) == 1
      {:call_time, rows} = :trace.info(session, mfa, :call_time)
      calls = for {^pid, count, _, _} <- rows, reduce: 0 do
        total -> total + count
      end
      {result, calls}
    after
      :trace.process(session, pid, false, [:call, :arity])
      assert :trace.session_destroy(session)
    end
  end

  defp ring_state(%Payload{region: {x, y, z}} = center, neighbors) do
    bases = for dx <- -1..1, dy <- -1..1, dz <- -1..1,
      region = {x + dx, y + dy, z + dz}, into: %{},
      do: {{0, region}, Map.get(neighbors, region, %Payload{level: 0, region: region, cells: center.cells})}
    %{region_bases: Map.put(bases, {0, center.region}, center), decoded: %{}, overlay: %{},
      overlay_regions: %{}, snapshots: MapSet.new(Map.keys(bases)), source: Missing, source_state: nil}
  end

  # 手算六个边界面作为旧完整覆盖输入；面交线和顶点由map自然归一，不调用待测ring投影。
  defp full_ring(material) do
    value = {material, Skins.uniform(material)}
    for a <- 0..65, b <- 0..65,
      local <- [{0, a, b}, {65, a, b}, {a, 0, b}, {a, 65, b}, {a, b, 0}, {a, b, 65}],
      into: %{}, do: {local, value}
  end
end
