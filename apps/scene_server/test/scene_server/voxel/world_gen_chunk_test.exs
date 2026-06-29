defmodule SceneServer.Voxel.WorldGenChunkTest do
  # First-touch WorldGen generation in ChunkProcess (阶段3 step3.1 integration).
  use ExUnit.Case, async: false

  alias SceneServer.Voxel.ChunkProcess
  alias SceneServer.Voxel.MacroCellHeader
  alias SceneServer.CliObserve

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

    assert {:dev_worldgen, :snapshot_not_found} =
             ChunkProcess.debug_state(pid).materialization_source
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

    assert {:dev_worldgen, :snapshot_not_found} =
             ChunkProcess.debug_state(pid).materialization_source
  end

  test "a first-touched chunk is empty only under the explicit test empty policy" do
    pid =
      start_supervised!({ChunkProcess, logical_scene_id: 777_002, chunk_coord: {0, -10, 0}})

    assert solid_count(storage_of(pid)) == 0

    assert {:empty_policy, :snapshot_not_found} =
             ChunkProcess.debug_state(pid).materialization_source
  end

  test "strict runtime policy rejects a missing authoritative chunk snapshot" do
    previous_log = Application.get_env(:scene_server, :cli_observe_log)
    observe_path = observe_path("missing-authoritative-chunk")
    File.rm(observe_path)
    Application.put_env(:scene_server, :cli_observe_log, observe_path)

    on_exit(fn ->
      CliObserve.flush()

      case previous_log do
        nil -> Application.delete_env(:scene_server, :cli_observe_log)
        value -> Application.put_env(:scene_server, :cli_observe_log, value)
      end
    end)

    scene_id = 880_000 + System.unique_integer([:positive])

    assert {:error, reason} =
             start_supervised(
               {ChunkProcess,
                logical_scene_id: scene_id, chunk_coord: {0, -10, 0}, missing_chunk_policy: :error}
             )

    assert inspect(reason) =~ "missing_authoritative_chunk_snapshot"

    CliObserve.flush()
    log = File.read!(observe_path)
    assert log =~ ~s(event="voxel_chunk_materialization_failed")
    assert log =~ "missing_authoritative_chunk_snapshot"
  end

  defp observe_path(name) do
    Path.expand(
      "../../../../../.demo/observe/world-gen-chunk-#{name}-#{System.unique_integer([:positive])}.log",
      __DIR__
    )
  end
end
