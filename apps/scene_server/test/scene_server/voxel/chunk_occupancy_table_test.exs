defmodule SceneServer.Voxel.ChunkOccupancyTableTest do
  @moduledoc """
  阶段5.2 (voxel-storage-1) 单元测试：per-chunk 只读 occupancy ETS 快照。

  纯逻辑（无需 DB / 无需 chunk 进程）：直接对 `ChunkOccupancyTable` 验证
  publish/read/query 的发布-读取-解析闭环，以及与权威 `Storage` 解析的**逐位
  一致性**（测试 ③ 的数据结构层断言）。
  """
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.ChunkOccupancyTable
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.Storage

  setup do
    # 每个测试用唯一 scene_id，使 ETS 表名互不冲突；测试退出时显式删表。
    scene_id = System.unique_integer([:positive, :monotonic]) + 90_000_000
    chunk_coord = {0, 0, 0}
    table = ChunkOccupancyTable.ensure_table(scene_id, chunk_coord)
    on_exit(fn -> ChunkOccupancyTable.delete_table(table) end)
    %{scene_id: scene_id, chunk_coord: chunk_coord, table: table}
  end

  test "read_snapshot returns :not_published before any publish", %{
    scene_id: scene_id,
    chunk_coord: chunk_coord
  } do
    # 未发布前（刚 ensure_table，尚无 publish）读到 :not_published。
    assert :not_published = ChunkOccupancyTable.read_snapshot(scene_id, chunk_coord)
  end

  test "read_snapshot returns :not_published for an unknown chunk" do
    # 完全没建表的 coord。
    assert :not_published = ChunkOccupancyTable.read_snapshot(123_456_789, {9, 9, 9})
  end

  test "published snapshot serves solid occupancy and matches authoritative storage", %{
    scene_id: scene_id,
    chunk_coord: chunk_coord,
    table: table
  } do
    storage =
      Storage.empty(scene_id, chunk_coord)
      |> Storage.put_solid_block({1, 0, 0}, NormalBlockData.new(2))

    :ok = ChunkOccupancyTable.publish(table, storage)

    assert {:ok, snapshot} = ChunkOccupancyTable.read_snapshot(scene_id, chunk_coord)
    assert snapshot.chunk_version == storage.chunk_version

    samples =
      normalize!([
        %{macro: {1, 0, 0}, micro_slot: 5},
        %{macro: {0, 0, 0}, micro_slot: 5}
      ])

    result = ChunkOccupancyTable.query(snapshot, samples)

    assert result.sample_count == 2
    assert result.occupied_count == 1
    assert [%{macro: {1, 0, 0}, micro_slot: 5, mode: :solid}] = result.occupied
  end

  test "published snapshot serves refined micro occupancy", %{
    scene_id: scene_id,
    chunk_coord: chunk_coord,
    table: table
  } do
    storage =
      Storage.empty(scene_id, chunk_coord)
      |> Storage.put_micro_block({2, 0, 0}, 5, %{material_id: 7})

    :ok = ChunkOccupancyTable.publish(table, storage)
    assert {:ok, snapshot} = ChunkOccupancyTable.read_snapshot(scene_id, chunk_coord)

    samples =
      normalize!([
        %{macro: {2, 0, 0}, micro_slot: 5},
        %{macro: {2, 0, 0}, micro_slot: 6}
      ])

    result = ChunkOccupancyTable.query(snapshot, samples)
    assert result.occupied_count == 1
    assert [%{macro: {2, 0, 0}, micro_slot: 5, mode: :refined}] = result.occupied
  end

  test "republish atomically replaces the snapshot with the newer chunk_version", %{
    scene_id: scene_id,
    chunk_coord: chunk_coord,
    table: table
  } do
    v1 =
      Storage.empty(scene_id, chunk_coord)
      |> Storage.put_solid_block({1, 0, 0}, NormalBlockData.new(2))

    :ok = ChunkOccupancyTable.publish(table, v1)
    assert {:ok, s1} = ChunkOccupancyTable.read_snapshot(scene_id, chunk_coord)

    v2 =
      v1
      |> Storage.put_solid_block({3, 0, 0}, NormalBlockData.new(2))

    :ok = ChunkOccupancyTable.publish(table, v2)
    assert {:ok, s2} = ChunkOccupancyTable.read_snapshot(scene_id, chunk_coord)

    assert s2.chunk_version >= s1.chunk_version

    # 新发布后 {3,0,0} 变占用——证明发布是整版替换、读到的是最新完整投影。
    samples = normalize!([%{macro: {3, 0, 0}, micro_slot: 0}])
    assert %{occupied_count: 1} = ChunkOccupancyTable.query(s2, samples)
  end

  test "delete_table makes subsequent reads :not_published", %{
    scene_id: scene_id,
    chunk_coord: chunk_coord,
    table: table
  } do
    :ok = ChunkOccupancyTable.publish(table, Storage.empty(scene_id, chunk_coord))
    assert {:ok, _} = ChunkOccupancyTable.read_snapshot(scene_id, chunk_coord)

    :ok = ChunkOccupancyTable.delete_table(table)
    assert :not_published = ChunkOccupancyTable.read_snapshot(scene_id, chunk_coord)
    # 幂等：重复删不报错。
    assert :ok = ChunkOccupancyTable.delete_table(table)
  end

  test "normalize_samples dedups and rejects invalid samples" do
    assert {:ok, [_one]} =
             ChunkOccupancyTable.normalize_samples([
               %{macro: {1, 0, 0}, micro_slot: 5},
               %{macro: {1, 0, 0}, micro_slot: 5}
             ])

    assert {:error, _} =
             ChunkOccupancyTable.normalize_samples([%{macro: {1, 0, 0}, micro_slot: 9_999}])
  end

  defp normalize!(samples) do
    {:ok, normalized} = ChunkOccupancyTable.normalize_samples(samples)
    normalized
  end
end
