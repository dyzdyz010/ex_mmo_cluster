defmodule GateServer.DialogueDispatchTest do
  @moduledoc "只测试：正式 Gate 分帧/分发配 Scene 替身，验证身份与出口，不冒充世界或真实 QUIC 验收。"
  use ExUnit.Case, async: true
  alias GateServer.Session.{Dispatch, QuicConnection, Sink}
  alias MmoContracts.Session

  defmodule Scene do
    def say(owner, identity, request) do
      send(owner, {:scene_say, identity, request})

      case request.text do
        "远处" -> {:error, :target_unavailable}
        "超时" -> exit({:timeout, :test_only})
        _ -> {:ok, %{conversation_id: 77, turn: 1}}
      end
    end
  end

  defp identity, do: %Session.Identity{session_epoch: 1, scene_id: 2, scene_epoch: 3}

  defp request,
    do: %Session.Say{
      identity: identity(),
      request_id: 4,
      target_id: 5,
      conversation_id: 0,
      text: "你好"
    }

  defp context,
    do: %{
      status: :in_scene,
      identity: identity(),
      scene: Scene,
      scene_ref: self(),
      sink: Sink.quic(self(), make_ref())
    }

  test "dispatch routes Say through the same Scene API and sends a control result" do
    ctx = context()
    req = request()
    assert {:ok, ^ctx} = Dispatch.handle({:say, req}, ctx)
    assert_receive {:scene_say, _, ^req}

    assert_receive {:mmo_reliable, _, 1,
                    %Session.SayResult{request_id: 4, conversation_id: 77, turn: 1, reason: "ok"}}

    refute_receive {:mmo_voxel_bytes, _, _}
  end

  test "authority rejection remains explicit and a timed-out call is not a claimed rejection" do
    for {text, reason} <- [{"远处", "target_unavailable"}, {"超时", "delivery_unknown"}] do
      Dispatch.handle({:say, %{request() | text: text}}, context())

      assert_receive {:mmo_reliable, _, 1,
                      %Session.SayResult{
                        request_id: 4,
                        conversation_id: 0,
                        turn: 0,
                        reason: ^reason
                      }}
    end
  end

  defp connection do
    {:ok, state} =
      QuicConnection.init(
        conn: :test_connection,
        listener: self(),
        hello: :unused,
        scene_module: Scene
      )

    %{
      state
      | identity: identity(),
        cid: 12,
        hello_seen: true,
        route: %{scene_ref: self(), world_ref: :unused},
        streams: %{control: %{purpose: 1, buffer: <<>>, started: true}}
    }
  end

  defp ingest(state, request) do
    {:ok, bytes} = Session.Codec.encode(request)

    QuicConnection.handle_info(
      {:quic, <<byte_size(bytes)::32, bytes::binary>>, :control, %{}},
      state
    )
  end

  test "current authenticated Say crosses the existing asynchronous action worker" do
    req = request()
    assert {:noreply, state} = ingest(connection(), req)
    Process.unlink(state.edit_worker)

    on_exit(fn ->
      if Process.alive?(state.edit_worker), do: Process.exit(state.edit_worker, :kill)
    end)

    assert state.edit_pending == 1
    assert_receive {:scene_say, _, ^req}
    assert_receive {:mmo_reliable, _, 1, %Session.SayResult{reason: "ok"}}
  end

  test "stale identity and transfer never route a Say to Scene" do
    state = connection()
    old = %{request() | identity: %{identity() | session_epoch: 99}}
    assert {:noreply, rejected} = ingest(state, old)
    assert rejected.edit_pending == 0

    assert {:noreply, transfer} =
             ingest(%{state | pending_transfer: %{identity: identity()}}, request())

    assert transfer.edit_pending == 0
    refute_receive {:scene_say, _, _}

    for {value, reason} <- [{rejected, "invalid_session"}, {transfer, "transfer_in_progress"}] do
      [entry] = :queue.to_list(value.reliable[1])
      {bytes, _, _} = entry

      assert {:ok, %Session.SayResult{reason: ^reason, identity: identity}} =
               Session.Codec.decode(bytes)

      assert identity == state.identity
    end
  end
end
