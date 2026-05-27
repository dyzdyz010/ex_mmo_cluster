defmodule Mix.Tasks.GateServerChunkVersionObserveTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.GateServer.ChunkVersionObserve

  test "prints and logs a chunk version ledger summary" do
    observe_log =
      Path.join(
        System.tmp_dir!(),
        "gate-chunk-version-#{System.unique_integer([:positive])}.log"
      )

    File.rm(observe_log)

    output =
      capture_io(fn ->
        ChunkVersionObserve.run([
          "--observe-log",
          observe_log,
          "--logical-scene-id",
          "77",
          "--chunk",
          "1,2,3",
          "--snapshot-version",
          "4",
          "--delta-version",
          "5"
        ])
      end)

    assert output =~ "gate_chunk_version=ok"
    assert output =~ "logical_scene_id=77"
    assert output =~ "chunk=1,2,3"
    assert output =~ "snapshot_version=4"
    assert output =~ "delta_version=5"
    assert output =~ "forwarded_chunk_versions=[{77, {1, 2, 3}, 5}]"
    assert output =~ "observe_log=#{observe_log}"

    log = File.read!(observe_log)
    assert log =~ ~s(event="gate_chunk_version_observe")
    assert log =~ "chunk_version: 5"
    assert log =~ "status: :recorded"
  end
end
