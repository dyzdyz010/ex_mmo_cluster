defmodule SceneServer.Voxel.StorageSolidBatchTest do
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.Storage

  defp empty_storage, do: Storage.empty(1, {0, 0, 0})

  describe "put_solid_blocks — batched solid puts (cold-seed / bulk-build fast path)" do
    test "batch matches N sequential put_solid_block exactly" do
      entries = [
        {0, NormalBlockData.new(1), [cell_version: 5, cell_hash: 11]},
        {37, NormalBlockData.new(2), [cell_version: 5, cell_hash: 22]},
        {4095, NormalBlockData.new(1), [cell_version: 5, cell_hash: 33]}
      ]

      batch = Storage.put_solid_blocks(empty_storage(), entries)

      sequential =
        Enum.reduce(entries, empty_storage(), fn {macro, block, opts}, acc ->
          Storage.put_solid_block(acc, macro, block, opts)
        end)

      assert batch == sequential
      assert length(batch.normal_blocks) == 3
    end

    test "each entry keeps its own cell_version / cell_hash and payload order" do
      entries = [
        {1, NormalBlockData.new(1), [cell_version: 7, cell_hash: 100]},
        {2, NormalBlockData.new(2), [cell_version: 9, cell_hash: 200]}
      ]

      storage = Storage.put_solid_blocks(empty_storage(), entries)
      h1 = Storage.macro_header_at(storage, 1)
      h2 = Storage.macro_header_at(storage, 2)

      assert h1.cell_version == 7
      assert h1.cell_hash == 100
      assert h2.cell_version == 9
      assert h2.cell_hash == 200
      # payload indices are sequential in entry order.
      assert h1.payload_index == 0
      assert h2.payload_index == 1
    end

    test "empty entries is a no-op" do
      assert Storage.put_solid_blocks(empty_storage(), []) == empty_storage()
    end

    test "a duplicated macro keeps the last entry (matches per-cell path)" do
      entries = [
        {5, NormalBlockData.new(1), [cell_version: 1, cell_hash: 1]},
        {5, NormalBlockData.new(2), [cell_version: 2, cell_hash: 2]}
      ]

      batch = Storage.put_solid_blocks(empty_storage(), entries)

      sequential =
        Enum.reduce(entries, empty_storage(), fn {macro, block, opts}, acc ->
          Storage.put_solid_block(acc, macro, block, opts)
        end)

      assert batch == sequential
      assert Storage.macro_header_at(batch, 5).cell_version == 2
    end

    test "a full 2048-cell chunk batch equals the sequential fold" do
      entries =
        for i <- 0..2047 do
          {i, NormalBlockData.new(2), [cell_version: 1, cell_hash: 0]}
        end

      batch = Storage.put_solid_blocks(empty_storage(), entries)

      sequential =
        Enum.reduce(entries, empty_storage(), fn {macro, block, opts}, acc ->
          Storage.put_solid_block(acc, macro, block, opts)
        end)

      assert length(batch.normal_blocks) == 2048
      assert batch == sequential
    end
  end
end
