defmodule GateServer.SessionCodecOwnerTest do
  use ExUnit.Case, async: true
  @moduletag :t0
  alias GateServer.Session.Sink

  test "QUIC session sink encodes current session and voxel frames for the connection owner" do
    sink = Sink.quic(self(), :identity)
    assert :ok = Sink.send_encoded(sink, {:result, :ok, 0x0102030405060708})
    assert_receive {:mmo_voxel_bytes, :identity, <<0x80, 0x0102030405060708::64-big, 0>>}
    assert :ok = Sink.send_encoded(sink, {:voxel_log_transaction_payload, <<1, 2, 3>>})
    assert_receive {:mmo_voxel_bytes, :identity, <<0x79, 1, 2, 3>>}
  end

  test "Sink.encode/1 returns explicit error for non-tuple and empty-tuple messages" do
    assert {:error, {:unknown_outbound, :not_a_tuple}} = Sink.encode(:not_a_tuple)
    assert {:error, {:unknown_outbound, {}}} = Sink.encode({})
    assert {:error, {:unknown_outbound, :unknown_tag}} = Sink.encode({:unknown_tag, 1})
  end
end
