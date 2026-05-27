defmodule Mix.Tasks.GateServerChatScopeObserveTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.GateServer.ChatScopeObserve

  test "prints and logs server-derived region chat scope" do
    observe_log = observe_log_path("gate-chat-scope")
    chat_observe_log = observe_log_path("gate-chat-scope-chat")
    File.rm(observe_log)
    File.rm(chat_observe_log)

    output =
      capture_io(fn ->
        ChatScopeObserve.run([
          "--logical-scene-id",
          "9",
          "--cid",
          "42",
          "--scope",
          "region",
          "--text",
          "hello-region",
          "--observe-log",
          observe_log,
          "--chat-observe-log",
          chat_observe_log
        ])
      end)

    assert output =~ "gate_chat_scope=ok"
    assert output =~ "logical_scene_id=9"
    assert output =~ "scope=region"
    assert output =~ "channel={:region, 9, 10}"
    assert output =~ "recipient_count=2"
    assert output =~ "skipped_count=1"
    assert output =~ "observe_log=#{observe_log}"

    GateServer.CliObserve.flush()
    ChatServer.CliObserve.flush()

    gate_log = File.read!(observe_log)
    assert gate_log =~ ~s(event="gate_chat_scope_resolved")
    assert gate_log =~ ~s(channel: "{:region, 9, 10}")
    assert gate_log =~ "server_derived?: true"

    chat_log = File.read!(chat_observe_log)
    assert chat_log =~ ~s(event="chat_delivery_planned")
    assert chat_log =~ ~s(recipient_cids: ["42", "43"])
    assert chat_log =~ "hello-region"
  end

  test "prints and logs server-derived local scope with candidate regions" do
    observe_log = observe_log_path("gate-chat-local-candidates")
    chat_observe_log = observe_log_path("gate-chat-local-candidates-chat")
    File.rm(observe_log)
    File.rm(chat_observe_log)

    output =
      capture_io(fn ->
        ChatScopeObserve.run([
          "--logical-scene-id",
          "9",
          "--cid",
          "42",
          "--scope",
          "local",
          "--local-radius",
          "4",
          "--candidate-regions",
          "10",
          "--text",
          "hello-local-candidates",
          "--observe-log",
          observe_log,
          "--chat-observe-log",
          chat_observe_log
        ])
      end)

    assert output =~ "gate_chat_scope=ok"
    assert output =~ "scope=local"
    assert output =~ "channel={:local, 9, {0, 0, 0}, 4, [10]}"
    assert output =~ "candidate_region_ids=[10]"
    assert output =~ "candidate_region_radius=4"
    assert output =~ "recipient_count=2"
    assert output =~ "skipped_count=1"

    GateServer.CliObserve.flush()
    ChatServer.CliObserve.flush()

    gate_log = File.read!(observe_log)
    assert gate_log =~ ~s(event="gate_chat_scope_resolved")
    assert gate_log =~ ~s(candidate_region_ids: [10])
    assert gate_log =~ "candidate_region_radius: 4"
    assert gate_log =~ "server_derived?: true"

    chat_log = File.read!(chat_observe_log)
    assert chat_log =~ "{:local, 9, {0, 0, 0}, 4, [10]}"
    assert chat_log =~ "hello-local-candidates"
  end

  test "prints fallback local scope when candidate radius is too small" do
    observe_log = observe_log_path("gate-chat-local-fallback")
    chat_observe_log = observe_log_path("gate-chat-local-fallback-chat")
    File.rm(observe_log)
    File.rm(chat_observe_log)

    output =
      capture_io(fn ->
        ChatScopeObserve.run([
          "--logical-scene-id",
          "9",
          "--cid",
          "42",
          "--scope",
          "local",
          "--local-radius",
          "4",
          "--candidate-regions",
          "10",
          "--candidate-region-radius",
          "1",
          "--text",
          "hello-local-fallback",
          "--observe-log",
          observe_log,
          "--chat-observe-log",
          chat_observe_log
        ])
      end)

    assert output =~ "gate_chat_scope=ok"
    assert output =~ "scope=local"
    assert output =~ "channel={:local, 9, {0, 0, 0}, 4}"
    assert output =~ "candidate_region_ids=[]"
    assert output =~ "candidate_region_radius=nil"
    assert output =~ "recipient_count=3"
    assert output =~ "skipped_count=0"

    GateServer.CliObserve.flush()
    ChatServer.CliObserve.flush()

    gate_log = File.read!(observe_log)
    assert gate_log =~ ~s(event="gate_chat_scope_resolved")
    assert gate_log =~ ~s(candidate_region_ids: [])
    assert gate_log =~ ~s(channel: "{:local, 9, {0, 0, 0}, 4}")

    chat_log = File.read!(chat_observe_log)
    assert chat_log =~ "{:local, 9, {0, 0, 0}, 4}"
    assert chat_log =~ "hello-local-fallback"
  end

  test "uses an isolated runtime without mutating an existing chat singleton" do
    observe_log = observe_log_path("gate-chat-isolated")
    chat_observe_log = observe_log_path("gate-chat-isolated-chat")
    previous_runtime = Process.whereis(ChatServer.Runtime)
    cid = System.unique_integer([:positive]) + 100_000

    output =
      capture_io(fn ->
        ChatScopeObserve.run([
          "--logical-scene-id",
          "9",
          "--cid",
          Integer.to_string(cid),
          "--scope",
          "region",
          "--text",
          "isolated-smoke",
          "--observe-log",
          observe_log,
          "--chat-observe-log",
          chat_observe_log
        ])
      end)

    assert output =~ "gate_chat_scope=ok"
    assert output =~ "recipient_count=2"

    case previous_runtime do
      nil ->
        assert Process.whereis(ChatServer.Runtime) == nil

      pid ->
        assert Process.whereis(ChatServer.Runtime) == pid

        snapshot = ChatServer.Runtime.snapshot(ChatServer.Runtime)
        refute Enum.any?(snapshot.sessions, &(&1.cid in [cid, cid + 1, cid + 2]))
        refute Enum.any?(snapshot.recent_messages, &(&1.text == "isolated-smoke"))
    end
  end

  defp observe_log_path(name) do
    Path.join(
      System.tmp_dir!(),
      "ex_mmo_cluster/#{name}-#{System.unique_integer([:positive])}.log"
    )
  end
end
