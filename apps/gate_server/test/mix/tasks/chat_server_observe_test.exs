defmodule Mix.Tasks.ChatServerObserveTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  setup do
    previous = Application.fetch_env(:chat_server, :cli_observe_log)

    on_exit(fn ->
      ChatServer.CliObserve.flush()

      case previous do
        {:ok, value} -> Application.put_env(:chat_server, :cli_observe_log, value)
        :error -> Application.delete_env(:chat_server, :cli_observe_log)
      end
    end)

    :ok
  end

  test "chat observe task emits summary line and structured log" do
    observe_log = observe_log_path("chat-observe")
    File.rm(observe_log)

    output =
      capture_io(fn ->
        Mix.Tasks.ChatServer.Observe.run([
          "--logical-scene-id",
          "9",
          "--channel",
          "region",
          "--region-id",
          "10",
          "--text",
          "hello-cli",
          "--observe-log",
          observe_log
        ])
      end)

    ChatServer.CliObserve.flush()

    assert output =~ "chat_observe=ok"
    assert output =~ "logical_scene_id=9"
    assert output =~ "channel=region"
    assert output =~ "plan_source=presence_index"
    assert output =~ "recipient_count=2"
    assert output =~ "observe_log=#{observe_log}"

    assert File.read!(observe_log) =~ ~s(event="chat_delivery_planned")
    assert File.read!(observe_log) =~ "plan_source: :presence_index"
    assert File.read!(observe_log) =~ "hello-cli"
  end

  test "chat observe task can smoke local candidate-region preselection" do
    observe_log = observe_log_path("chat-observe-local-candidates")
    File.rm(observe_log)

    output =
      capture_io(fn ->
        Mix.Tasks.ChatServer.Observe.run([
          "--logical-scene-id",
          "9",
          "--channel",
          "local",
          "--center",
          "0,0,0",
          "--radius",
          "4",
          "--candidate-regions",
          "10",
          "--text",
          "candidate-local",
          "--observe-log",
          observe_log
        ])
      end)

    ChatServer.CliObserve.flush()

    assert output =~ "chat_observe=ok"
    assert output =~ "channel=local"
    assert output =~ "plan_source=presence_index"
    assert output =~ "recipient_count=2"
    assert output =~ "skipped_count=2"

    log = File.read!(observe_log)
    assert log =~ ~s(event="chat_delivery_planned")
    assert log =~ "{:local, 9, {0, 0, 0}, 4, [10]}"
    assert log =~ "candidate-local"
  end

  test "chat observe task can smoke server-only system channel" do
    observe_log = observe_log_path("chat-observe-system")
    File.rm(observe_log)

    output =
      capture_io(fn ->
        Mix.Tasks.ChatServer.Observe.run([
          "--logical-scene-id",
          "9",
          "--channel",
          "system",
          "--text",
          "maintenance",
          "--observe-log",
          observe_log
        ])
      end)

    ChatServer.CliObserve.flush()

    assert output =~ "chat_observe=ok"
    assert output =~ "channel=system"
    assert output =~ "plan_source=presence_index"
    assert output =~ "recipient_count=3"
    assert output =~ "skipped_count=1"

    log = File.read!(observe_log)
    assert log =~ ~s(event="chat_delivery_planned")
    assert log =~ "{:system, 9}"
    assert log =~ "maintenance"
  end

  defp observe_log_path(name) do
    Path.join(
      System.tmp_dir!(),
      "ex_mmo_cluster/#{name}-#{System.unique_integer([:positive])}.log"
    )
  end
end
