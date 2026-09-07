defmodule GateServer.SessionCodecOwnerTest do
  use ExUnit.Case, async: true
  alias GateServer.Session.{Dispatch, Sink}

  test "actual session sink sends current session and voxel bytes and retained NPC bytes" do
    sink = Sink.ws(self())
    assert :ok = Sink.send_encoded(sink, {:result, :ok, 0x0102030405060708})
    assert_receive {:gate_ws_send, <<0x80, 0x0102030405060708::64-big, 0>>}
    assert :ok = Sink.send_encoded(sink, {:voxel_log_transaction_payload, <<1, 2, 3>>})
    assert_receive {:gate_ws_send, <<0x79, 1, 2, 3>>}
    assert :ok = Sink.send_encoded(sink, {:actor_identity, 90_001, :npc, "NPC"})
    assert_receive {:gate_ws_send, <<0x8E, 90_001::64-big, 1, 3::16-big, "NPC">>}
  end

  test "ingress routes current opcodes and keeps the legacy branch available" do
    assert Dispatch.decode(<<0x04, 123::64-big>>) == {:ok, {:heartbeat, 123}}

    assert Dispatch.decode(<<0x78, 7::64-big, 8::32-big, 9::64-big, 0::32-big>>) ==
             {:ok,
              {:voxel_batch_edit_intent,
               %{request_id: 7, client_intent_seq: 8, logical_scene_id: 9, edits: []}}}

    assert Dispatch.decode(<<0x06, 123::64-big>>) == {:ok, {:fast_lane_request, 123}}
    assert Dispatch.decode(<<0x04>>) == {:error, :invalid_message}
  end
end
