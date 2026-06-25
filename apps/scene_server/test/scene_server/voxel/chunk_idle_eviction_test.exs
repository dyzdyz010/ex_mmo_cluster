defmodule SceneServer.Voxel.ChunkIdleEvictionTest do
  # 阶段3 step3.2: idle 驱逐(无订阅者 + 无活跃 field 连续 idle 超时则自停)。
  use ExUnit.Case, async: false

  alias SceneServer.Voxel.ChunkProcess

  defp start_chunk(opts) do
    spec = %{
      id: make_ref(),
      start: {ChunkProcess, :start_link, [opts]},
      restart: :temporary
    }

    start_supervised!(spec)
  end

  test "an idle chunk (no subscribers, no field regions) self-evicts after the timeout" do
    pid =
      start_chunk(
        logical_scene_id: 778_001,
        chunk_coord: {0, 0, 0},
        idle_eviction: [enabled?: true, check_ms: 30, evict_after_ms: 60]
      )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
  end

  test "eviction is disabled by default — the chunk stays alive" do
    pid = start_chunk(logical_scene_id: 778_002, chunk_coord: {0, 0, 0})

    Process.sleep(200)
    assert Process.alive?(pid)
  end

  test "an explicitly-disabled chunk stays alive even past a short would-be timeout" do
    pid =
      start_chunk(
        logical_scene_id: 778_003,
        chunk_coord: {0, 0, 0},
        idle_eviction: false
      )

    Process.sleep(200)
    assert Process.alive?(pid)
  end
end
