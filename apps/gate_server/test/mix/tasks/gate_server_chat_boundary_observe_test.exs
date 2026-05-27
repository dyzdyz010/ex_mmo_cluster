defmodule Mix.Tasks.GateServerChatBoundaryObserveTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.GateServer.ChatBoundaryObserve

  test "runs with default parameters" do
    output =
      capture_io(fn ->
        ChatBoundaryObserve.run([])
      end)

    assert output =~ "gate_chat_boundary=ok"
    assert output =~ "boundary=region"
    assert output =~ "from_region_id=10"
    assert output =~ "to_region_id=20"
    assert output =~ "scope=region"
  end

  test "region scope crosses into the new region and only delivers there" do
    observe_log = observe_log_path("gate-chat-boundary-region")
    chat_observe_log = observe_log_path("gate-chat-boundary-region-chat")
    world_observe_log = observe_log_path("gate-chat-boundary-region-world")
    File.rm(observe_log)
    File.rm(chat_observe_log)
    File.rm(world_observe_log)

    output =
      capture_io(fn ->
        ChatBoundaryObserve.run([
          "--logical-scene-id",
          "9",
          "--cid",
          "42",
          "--from",
          "100,100,100",
          "--to",
          "1650,100,100",
          "--scope",
          "region",
          "--text",
          "hello-boundary-region",
          "--observe-log",
          observe_log,
          "--chat-observe-log",
          chat_observe_log,
          "--world-observe-log",
          world_observe_log
        ])
      end)

    assert output =~ "gate_chat_boundary=ok"
    assert output =~ "boundary=region"
    assert output =~ "from_region_id=10"
    assert output =~ "to_region_id=20"
    assert output =~ "chat_presence_updated=true"
    assert output =~ "scope=region"
    assert output =~ "channel={:region, 9, 20}"
    assert output =~ "voxel_subscription_apply=skipped"
    assert output =~ "recipient_count=2"
    assert output =~ "old_region_delivered=false"
    assert output =~ "new_region_delivered=true"
    assert output =~ "observe_log=#{observe_log}"
    assert output =~ "chat_observe_log=#{chat_observe_log}"
    assert output =~ "world_observe_log=#{world_observe_log}"

    gate_log = File.read!(observe_log)
    assert gate_log =~ ~s(event="gate_chat_boundary_resolved")
    assert gate_log =~ "boundary_kind: :region"
    assert gate_log =~ ~s(channel: "{:region, 9, 20}")
    assert gate_log =~ "voxel_subscription_apply: :skipped"
    assert gate_log =~ "old_region_delivered?: false"
    assert gate_log =~ "new_region_delivered?: true"
    refute gate_log =~ ~s(event="voxel_subscription_diff_failed")
    refute gate_log =~ ~s(event="gate_partition_runtime_subscription_apply_failed")

    chat_log = File.read!(chat_observe_log)
    assert chat_log =~ ~s(event="chat_session_presence_updated")
    assert chat_log =~ "previous_region_id: 10"
    assert chat_log =~ "region_id: 20"
    assert chat_log =~ ~s(event="chat_delivery_planned")
    assert chat_log =~ ~s(recipient_cids: ["42", "44"])
    assert chat_log =~ "hello-boundary-region"

    world_log = File.read!(world_observe_log)
    assert world_log =~ ~s(event="world_partition_window")
    assert world_log =~ "route_index_source: :map_ledger"
    assert world_log =~ "route_index_stats"
  end

  test "local scope uses refreshed chunk and candidate regions" do
    observe_log = observe_log_path("gate-chat-boundary-local")
    chat_observe_log = observe_log_path("gate-chat-boundary-local-chat")
    world_observe_log = observe_log_path("gate-chat-boundary-local-world")
    File.rm(observe_log)
    File.rm(chat_observe_log)
    File.rm(world_observe_log)

    output =
      capture_io(fn ->
        ChatBoundaryObserve.run([
          "--logical-scene-id",
          "9",
          "--cid",
          "42",
          "--from",
          "100,100,100",
          "--to",
          "1650,100,100",
          "--scope",
          "local",
          "--local-radius",
          "0",
          "--text",
          "hello-boundary-local",
          "--observe-log",
          observe_log,
          "--chat-observe-log",
          chat_observe_log,
          "--world-observe-log",
          world_observe_log
        ])
      end)

    assert output =~ "gate_chat_boundary=ok"
    assert output =~ "boundary=region"
    assert output =~ "chat_presence_updated=true"
    assert output =~ "scope=local"
    assert output =~ "channel={:local, 9, {1, 0, 0}, 0, [10, 20]}"
    assert output =~ "voxel_subscription_apply=skipped"
    assert output =~ "recipient_count=2"
    assert output =~ "old_region_delivered=false"
    assert output =~ "new_region_delivered=true"

    gate_log = File.read!(observe_log)
    assert gate_log =~ ~s(event="gate_chat_boundary_resolved")
    assert gate_log =~ ~s(scope: :local)
    assert gate_log =~ "voxel_subscription_apply: :skipped"
    assert gate_log =~ "candidate_region_ids: [10, 20]"
    assert gate_log =~ "candidate_region_radius: 1"
    refute gate_log =~ ~s(event="voxel_subscription_diff_failed")
    refute gate_log =~ ~s(event="gate_partition_runtime_subscription_apply_failed")

    chat_log = File.read!(chat_observe_log)
    assert chat_log =~ ~s(event="chat_session_presence_updated")
    assert chat_log =~ ~s(event="chat_delivery_planned")
    assert chat_log =~ "{:local, 9, {1, 0, 0}, 0, [10, 20]}"
    assert chat_log =~ ~s(recipient_cids: ["42", "44"])
    assert chat_log =~ "hello-boundary-local"

    world_log = File.read!(world_observe_log)
    assert world_log =~ ~s(event="world_partition_window")
    assert world_log =~ "center_chunk: [1, 0, 0]"
  end

  test "same chunk keeps the old chat presence and reports boundary none" do
    observe_log = observe_log_path("gate-chat-boundary-none")
    chat_observe_log = observe_log_path("gate-chat-boundary-none-chat")
    world_observe_log = observe_log_path("gate-chat-boundary-none-world")
    File.rm(observe_log)
    File.rm(chat_observe_log)
    File.rm(world_observe_log)

    output =
      capture_io(fn ->
        ChatBoundaryObserve.run([
          "--logical-scene-id",
          "9",
          "--cid",
          "42",
          "--from",
          "100,100,100",
          "--to",
          "200,100,100",
          "--scope",
          "region",
          "--text",
          "hello-boundary-none",
          "--observe-log",
          observe_log,
          "--chat-observe-log",
          chat_observe_log,
          "--world-observe-log",
          world_observe_log
        ])
      end)

    assert output =~ "gate_chat_boundary=ok"
    assert output =~ "boundary=none"
    assert output =~ "from_region_id=10"
    assert output =~ "to_region_id=10"
    assert output =~ "chat_presence_updated=false"
    assert output =~ "scope=region"
    assert output =~ "channel={:region, 9, 10}"
    assert output =~ "old_region_delivered=true"
    assert output =~ "new_region_delivered=false"

    gate_log = File.read!(observe_log)
    assert gate_log =~ ~s(event="gate_chat_boundary_resolved")
    assert gate_log =~ "boundary_kind: :none"
    assert gate_log =~ "chat_presence_updated?: false"

    chat_log = File.read!(chat_observe_log)
    refute chat_log =~ ~s(event="chat_session_presence_updated")
    assert chat_log =~ ~s(event="chat_delivery_planned")
    assert chat_log =~ ~s(recipient_cids: ["42", "43"])

    world_log = File.read!(world_observe_log)
    refute world_log =~ ~s(event="world_partition_window")
  end

  defp observe_log_path(name) do
    Path.join(
      System.tmp_dir!(),
      "ex_mmo_cluster/#{name}-#{System.unique_integer([:positive])}.log"
    )
  end
end
