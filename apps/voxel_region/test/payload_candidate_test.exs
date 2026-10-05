defmodule VoxelRegion.PayloadCandidateTest do
  use ExUnit.Case, async: true

  alias MmoContracts.Voxel.{Payload, Skins}
  alias VoxelRegion.World.Payloads

  # 只测试：离线状态函数接缝，直接构造合法载荷，不修改在线 World。
  # 邻区 core 的首列投影为本区右侧 ring；limit 比较使用手算的 629 B 下界。
  setup do
    payload = %Payload{level: 1, cells: :binary.copy(<<11, 0>>, 66 * 66 * 66)}
    neighbor = %{payload | region: {1, 0, 0}, records: %{{1, 3, 4} => Skins.uniform(19)}}
    {:ok, neighbor} = Payload.decode(Payload.encode(neighbor, %{}, 0, 1))
    state = %{
      cv: 1, seq: 1, payloads: %{}, decoded: %{{1, {0, 0, 0}} => payload},
      region_bases: %{{1, {1, 0, 0}} => neighbor},
      overlay_regions: %{}, overlay: %{}, snapshots: MapSet.new([{1, {0, 0, 0}}]),
      structure: %{}, lru: :gb_trees.empty(), lru_ticks: %{}, tick: 0,
      lru_bytes: 0, resident_bytes: 0, cache_limit: 1_000_000,
      cache_stats: %{hits: 0, misses: 0, evictions: 0}
    }
    %{state: state}
  end

  test "neighbor ring counts before the strict candidate bound and equality skips", %{state: state} do
    assert {:not_smaller, skipped} = Payloads.payload_bytes(state, 1, {0, 0, 0}, 629)
    assert skipped.payloads == %{}
    assert {:ok, bytes, _, cached} = Payloads.payload_bytes(state, 1, {0, 0, 0}, 630)
    assert {:ok, payload} = Payload.decode(bytes)
    assert Map.keys(payload.records) == [{65, 3, 4}]
    assert Payload.skins(payload, {65, 3, 4}, 11) == Skins.uniform(19)
    # 缓存已有字节直接返回，最终仍由调用方按实际长度选择。
    assert {:ok, ^bytes, _, _} = Payloads.payload_bytes(cached, 1, {0, 0, 0}, 1)
  end

  test "current overlay deletes the final ring record before applying the bound", %{state: state} do
    state = %{state | overlay_regions: %{{1, {0, 0, 0}} => MapSet.new([{64, 2, 3}])},
      overlay: %{{1, {64, 2, 3}} => {11, Skins.uniform(11)}}}
    assert {:ok, bytes, _, _} = Payloads.payload_bytes(state, 1, {0, 0, 0}, 629)
    assert {:ok, payload} = Payload.decode(bytes)
    assert payload.records == %{}
  end
end
