defmodule Mix.Tasks.GateServerPartitionFailureObserveTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.GateServer.PartitionFailureObserve

  test "prints and logs an unroutable World partition failure without replacing usable context" do
    observe_log = observe_log_path("gate-partition-failure-unroutable")
    File.rm(observe_log)

    output =
      capture_io(fn ->
        PartitionFailureObserve.run([
          "--failure",
          "unroutable",
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

    assert output =~ "gate_partition_failure=ok"
    assert output =~ "failure=unroutable"
    assert output =~ "refresh_status=error"
    assert output =~ "authoritative_status=failed"
    assert output =~ "boundary=unroutable"
    assert output =~ "to_region_id=10"
    assert output =~ "partition_context_region_id=10"
    assert output =~ "partition_context_chunk=0,0,0"
    assert output =~ "chat_context_region_id=10"
    assert output =~ "chat_context_chunk=0,0,0"
    assert output =~ "previous_context_preserved=true"
    assert output =~ "partition_context_updated=false"
    assert output =~ "chat_context_updated=false"
    assert output =~ "pending_chat_presence=false"
    assert output =~ "pending_subscription_result=false"
    assert output =~ "subscription_apply_status=none"
    assert output =~ "observe_log=#{observe_log}"

    log = File.read!(observe_log)
    assert log =~ ~s(event="gate_partition_runtime_refresh_failed")
    assert log =~ ~s(event="gate_partition_failure_resolved")
    assert log =~ "failure_mode: :unroutable"
    assert log =~ "authoritative_status: :failed"
    assert log =~ "partition_context_region_id: 10"
    assert log =~ "chat_context_region_id: 10"
    assert log =~ "previous_context_preserved?: true"
    assert log =~ "partition_context_updated?: false"
  end

  test "prints and logs a Chat refresh failure with authoritative partition context pending retry" do
    observe_log = observe_log_path("gate-partition-failure-chat")
    File.rm(observe_log)

    output =
      capture_io(fn ->
        PartitionFailureObserve.run([
          "--failure",
          "chat-refresh",
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

    assert output =~ "gate_partition_failure=ok"
    assert output =~ "failure=chat_refresh"
    assert output =~ "refresh_status=error"
    assert output =~ "authoritative_status=updated"
    assert output =~ "boundary=region"
    assert output =~ "to_region_id=20"
    assert output =~ "partition_context_region_id=20"
    assert output =~ "partition_context_chunk=1,0,0"
    assert output =~ "chat_context_region_id=10"
    assert output =~ "chat_context_chunk=0,0,0"
    assert output =~ "previous_context_preserved=false"
    assert output =~ "partition_context_updated=true"
    assert output =~ "chat_context_updated=false"
    assert output =~ "pending_chat_presence=true"
    assert output =~ "pending_subscription_result=true"
    assert output =~ "subscription_apply_status=none"

    log = File.read!(observe_log)
    assert log =~ ~s(event="gate_partition_runtime_chat_refresh_failed")
    assert log =~ ~s(event="gate_partition_failure_resolved")
    assert log =~ "failure_mode: :chat_refresh"
    assert log =~ "authoritative_status: :updated"
    assert log =~ "partition_context_region_id: 20"
    assert log =~ "chat_context_region_id: 10"
    assert log =~ "partition_context_updated?: true"
    assert log =~ "pending_chat_presence?: true"
  end

  test "prints and logs a Scene subscription apply failure without rolling back partition or chat" do
    observe_log = observe_log_path("gate-partition-failure-subscription")
    File.rm(observe_log)

    output =
      capture_io(fn ->
        PartitionFailureObserve.run([
          "--failure",
          "subscription-apply",
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

    assert output =~ "gate_partition_failure=ok"
    assert output =~ "failure=subscription_apply"
    assert output =~ "refresh_status=error"
    assert output =~ "authoritative_status=updated"
    assert output =~ "boundary=region"
    assert output =~ "to_region_id=20"
    assert output =~ "partition_context_region_id=20"
    assert output =~ "partition_context_chunk=1,0,0"
    assert output =~ "chat_context_region_id=20"
    assert output =~ "chat_context_chunk=1,0,0"
    assert output =~ "previous_context_preserved=false"
    assert output =~ "partition_context_updated=true"
    assert output =~ "chat_context_updated=true"
    assert output =~ "pending_chat_presence=false"
    assert output =~ "pending_subscription_result=false"
    assert output =~ "subscription_apply_status=error:scene_unavailable"

    log = File.read!(observe_log)
    assert log =~ ~s(event="gate_partition_runtime_subscription_apply_failed")
    assert log =~ ~s(event="gate_partition_failure_resolved")
    assert log =~ "failure_mode: :subscription_apply"
    assert log =~ "authoritative_status: :updated"
    assert log =~ "partition_context_region_id: 20"
    assert log =~ "chat_context_region_id: 20"
    assert log =~ "chat_context_updated?: true"
    assert log =~ ~s(subscription_apply_status: "{:error, :scene_unavailable}")
  end

  defp observe_log_path(name) do
    Path.join(
      System.tmp_dir!(),
      "ex_mmo_cluster/#{name}-#{System.unique_integer([:positive])}.log"
    )
  end
end
