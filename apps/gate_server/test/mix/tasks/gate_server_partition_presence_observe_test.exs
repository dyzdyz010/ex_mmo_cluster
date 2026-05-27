defmodule Mix.Tasks.GateServerPartitionPresenceObserveTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.GateServer.PartitionPresenceObserve

  test "prints and logs authoritative partition presence refresh" do
    observe_log =
      Path.join(
        System.tmp_dir!(),
        "gate-partition-presence-#{System.unique_integer([:positive])}.log"
      )

    File.rm(observe_log)

    output =
      capture_io(fn ->
        PartitionPresenceObserve.run([
          "--observe-log",
          observe_log,
          "--logical-scene-id",
          "1",
          "--cid",
          "42",
          "--from",
          "100,100,100",
          "--to",
          "1650,100,100"
        ])
      end)

    assert output =~ "gate_partition_presence=ok"
    assert output =~ "cid=42"
    assert output =~ "from_chunk=0,0,0"
    assert output =~ "to_chunk=1,0,0"
    assert output =~ "boundary=region"
    assert output =~ "chat_presence_updated=true"
    assert output =~ "observe_log=#{observe_log}"

    log = File.read!(observe_log)
    assert log =~ ~s(event="gate_partition_presence_resolved")
    assert log =~ "boundary_kind: :region"
    assert log =~ "chat_presence_updated?: true"
  end

  test "prints same-chunk no-op partition refresh without updating chat presence" do
    observe_log =
      Path.join(
        System.tmp_dir!(),
        "gate-partition-presence-same-#{System.unique_integer([:positive])}.log"
      )

    File.rm(observe_log)

    output =
      capture_io(fn ->
        PartitionPresenceObserve.run([
          "--observe-log",
          observe_log,
          "--logical-scene-id",
          "1",
          "--cid",
          "42",
          "--from",
          "100,100,100",
          "--to",
          "200,100,100"
        ])
      end)

    assert output =~ "gate_partition_presence=ok"
    assert output =~ "from_chunk=0,0,0"
    assert output =~ "to_chunk=0,0,0"
    assert output =~ "boundary=none"
    assert output =~ "subscribe_count=0"
    assert output =~ "unsubscribe_count=0"
    assert output =~ "chat_presence_updated=false"

    log = File.read!(observe_log)
    assert log =~ ~s(event="gate_partition_presence_resolved")
    assert log =~ "boundary_kind: :none"
    assert log =~ "chat_presence_updated?: false"
  end
end
