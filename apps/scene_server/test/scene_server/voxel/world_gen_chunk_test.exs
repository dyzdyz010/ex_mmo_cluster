defmodule SceneServer.Voxel.WorldGenChunkTest do
  # First-touch WorldGen generation in ChunkProcess (阶段3 step3.1 integration).
  use ExUnit.Case, async: false

  alias SceneServer.Voxel.ChunkProcess
  alias SceneServer.Voxel.MacroCellHeader

  defp storage_of(pid), do: :sys.get_state(pid).storage

  defp solid_count(storage) do
    Enum.count(storage.macro_headers, &(&1.mode == MacroCellHeader.cell_mode_solid_block()))
  end

  test "a first-touched (never-persisted) chunk generates baseline terrain when WorldGen is enabled" do
    pid =
      start_supervised!(
        {ChunkProcess,
         logical_scene_id: 777_001,
         chunk_coord: {0, -10, 0},
         worldgen: [enabled?: true, seed: 1337]}
      )

    storage = storage_of(pid)
    # Deep underground chunk → fully solid stone, and pristine (version 0).
    assert solid_count(storage) == 4096
    assert storage.chunk_version == 0
  end

  test "a high-altitude first-touched chunk generates empty even with WorldGen on" do
    pid =
      start_supervised!(
        {ChunkProcess,
         logical_scene_id: 777_003,
         chunk_coord: {0, 40, 0},
         worldgen: [enabled?: true, seed: 1337]}
      )

    assert solid_count(storage_of(pid)) == 0
  end

  test "a first-touched chunk is empty when WorldGen is disabled (default)" do
    pid =
      start_supervised!(
        {ChunkProcess, logical_scene_id: 777_002, chunk_coord: {0, -10, 0}}
      )

    assert solid_count(storage_of(pid)) == 0
  end
end
