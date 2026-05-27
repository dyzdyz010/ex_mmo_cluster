defmodule Mix.Tasks.ChatServerShardObserveTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "chat shard observe task prints shard routing and logs delivery" do
    observe_log =
      Path.join(
        System.tmp_dir!(),
        "ex_mmo_cluster/chat-shard-observe-#{System.unique_integer([:positive])}.log"
      )

    File.rm(observe_log)

    output =
      capture_io(fn ->
        Mix.Tasks.ChatServer.ShardObserve.run([
          "--logical-scene-id",
          "7",
          "--other-logical-scene-id",
          "8",
          "--channel",
          "world",
          "--text",
          "scene-shard-cli",
          "--observe-log",
          observe_log
        ])
      end)

    ChatServer.CliObserve.flush()

    assert output =~ "chat_shard_observe=ok"
    assert output =~ "logical_scene_id=7"
    assert output =~ "shard_key=7"
    assert output =~ "route_target=scene_shard"
    assert output =~ "shard_count=2"
    assert output =~ "recipient_count=2"
    assert output =~ "other_scene_recipient_count=0"
    assert output =~ "observe_log=#{observe_log}"

    log = File.read!(observe_log)
    assert log =~ ~s(event="chat_runtime_directory_routed")
    assert log =~ ~s(event="chat_delivery_planned")
    assert log =~ "scene-shard-cli"
    assert log =~ "shard_key: 7"
  end
end
