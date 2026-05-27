defmodule GateServer.ChatRuntimeContractTest do
  use ExUnit.Case, async: true

  test "world channel fanout is owned by Chat runtime instead of Scene AOI" do
    runtime = start_supervised!({ChatServer.Runtime, name: nil})

    assert {:ok, _} =
             ChatServer.Runtime.join(runtime, %{
               cid: 42,
               username: "tester",
               connection_pid: self(),
               logical_scene_id: 1,
               region_id: 10,
               chunk_coord: {0, 0, 0}
             })

    assert {:ok, _} =
             ChatServer.Runtime.join(runtime, %{
               cid: 43,
               username: "nearby",
               connection_pid: self(),
               logical_scene_id: 1,
               region_id: 10,
               chunk_coord: {1, 0, 0}
             })

    assert {:ok, summary} =
             ChatServer.Runtime.say(runtime, %{
               cid: 42,
               username: "tester",
               logical_scene_id: 1,
               channel: {:world, 1},
               text: "hello world"
             })

    assert summary.channel == {:world, 1}
    assert summary.recipient_count == 2
    assert summary.history_count == 1

    assert_receive {:"$gen_cast", {:chat_message, 42, "tester", "hello world"}}, 500
    assert_receive {:"$gen_cast", {:chat_message, 42, "tester", "hello world"}}, 500
  end

  test "delivery plan supports region and local scopes from session metadata" do
    sessions = %{
      1 => %{
        cid: 1,
        connection_pid: self(),
        logical_scene_id: 7,
        region_id: 10,
        chunk_coord: {0, 0, 0}
      },
      2 => %{
        cid: 2,
        connection_pid: self(),
        logical_scene_id: 7,
        region_id: 10,
        chunk_coord: {1, 0, 0}
      },
      3 => %{
        cid: 3,
        connection_pid: self(),
        logical_scene_id: 7,
        region_id: 20,
        chunk_coord: {4, 0, 0}
      },
      4 => %{
        cid: 4,
        connection_pid: self(),
        logical_scene_id: 8,
        region_id: 10,
        chunk_coord: {0, 0, 0}
      }
    }

    assert %{recipient_cids: [1, 2]} =
             ChatServer.DeliveryPlan.plan(%{
               sessions: sessions,
               channel: {:region, 7, 10}
             })

    assert %{recipient_cids: [1, 2]} =
             ChatServer.DeliveryPlan.plan(%{
               sessions: sessions,
               channel: {:local, 7, {0, 0, 0}, 1}
             })
  end

  test "runtime removes chat session when a Gate connection exits abnormally" do
    runtime = start_supervised!({ChatServer.Runtime, name: nil})

    connection =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    assert {:ok, _} =
             ChatServer.Runtime.join(runtime, %{
               cid: 99,
               username: "stale",
               connection_pid: connection,
               logical_scene_id: 1,
               region_id: 10,
               chunk_coord: {0, 0, 0}
             })

    assert ChatServer.Runtime.snapshot(runtime).session_count == 1

    ref = Process.monitor(connection)
    Process.exit(connection, :kill)
    assert_receive {:DOWN, ^ref, :process, ^connection, :killed}, 500

    assert ChatServer.Runtime.snapshot(runtime).session_count == 0
  end
end
