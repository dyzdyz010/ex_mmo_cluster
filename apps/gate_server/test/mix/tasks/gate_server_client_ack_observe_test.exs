defmodule Mix.Tasks.GateServerClientAckObserveTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.GateServer.ClientAckObserve

  test "prints and logs client ACK retention evidence" do
    observe_log =
      Path.join(
        System.tmp_dir!(),
        "gate-client-ack-#{System.unique_integer([:positive])}.log"
      )

    File.rm(observe_log)

    output =
      capture_io(fn ->
        ClientAckObserve.run([
          "--observe-log",
          observe_log,
          "--logical-scene-id",
          "77",
          "--chunk",
          "1,2,3",
          "--forwarded-version",
          "5",
          "--ack-version",
          "5"
        ])
      end)

    assert output =~ "gate_client_ack=ok"
    assert output =~ "logical_scene_id=77"
    assert output =~ "chunk=1,2,3"
    assert output =~ "forwarded_version=5"
    assert output =~ "ack_version=5"
    assert output =~ "ack_status=ack_recorded"
    assert output =~ "ahead_status=ack_ahead_of_forwarded"
    assert output =~ "cleared_status=cleared"
    assert output =~ "acked_chunk_versions=[{77, {1, 2, 3}, 5}]"
    assert output =~ "observe_log=#{observe_log}"

    log = File.read!(observe_log)
    assert log =~ ~s(event="gate_client_ack_observe")
    assert log =~ "ack_status: :ack_recorded"
    assert log =~ "ahead_status: :ack_ahead_of_forwarded"
    assert log =~ "cleared_status: :cleared"
  end
end
