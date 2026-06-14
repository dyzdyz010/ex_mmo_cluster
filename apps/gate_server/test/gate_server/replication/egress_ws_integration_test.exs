defmodule GateServer.Replication.EgressWsIntegrationTest do
  # 梯队3 step3.10b:ws_connection chunk 连续流经 per-observer Replicator 出口预算转发。
  use ExUnit.Case, async: false

  alias GateServer.WsConnection

  defp encoded(tag, payload) do
    {:ok, iodata} = GateServer.Codec.encode({tag, payload})
    IO.iodata_to_binary(iodata)
  end

  defp start_conn do
    {:ok, conn} = WsConnection.start_link(self())
    conn
  end

  defp put_budget(capacity, window) do
    old_cap = Application.get_env(:gate_server, :egress_capacity_bytes)
    old_win = Application.get_env(:gate_server, :egress_window_ms)
    Application.put_env(:gate_server, :egress_capacity_bytes, capacity)
    Application.put_env(:gate_server, :egress_window_ms, window)

    on_exit(fn ->
      restore(:egress_capacity_bytes, old_cap)
      restore(:egress_window_ms, old_win)
    end)
  end

  defp restore(key, nil), do: Application.delete_env(:gate_server, key)
  defp restore(key, val), do: Application.put_env(:gate_server, key, val)

  test "正常预算下 chunk delta 即时转发到 owner(0 回归形态)" do
    put_budget(262_144, 100)
    conn = start_conn()
    payload = <<1, 2, 3, 4>>
    send(conn, {:voxel_chunk_delta_payload, payload})

    assert_receive {:gate_ws_send, bytes}, 500
    assert bytes == encoded(:voxel_chunk_delta_payload, payload)
  end

  test "snapshot 与 invalidate 也经 Replicator 转发" do
    put_budget(262_144, 100)
    conn = start_conn()

    send(conn, {:voxel_chunk_snapshot_payload, <<9, 9>>})
    send(conn, {:voxel_chunk_invalidate_payload, <<7>>})

    assert_receive {:gate_ws_send, b1}, 500
    assert b1 == encoded(:voxel_chunk_snapshot_payload, <<9, 9>>)
    assert_receive {:gate_ws_send, b2}, 500
    assert b2 == encoded(:voxel_chunk_invalidate_payload, <<7>>)
  end

  test "小预算:两 delta 都不丢、保序(backlog 经自限定 flush 排空)" do
    # 容量 100、窗 100ms(refill 1 byte/ms):首 delta(60)即发,次 delta(60)预算不足憋帧,
    # ~20ms 后自限定 flush 回血放行 → 两帧都达且保序、无丢失。
    put_budget(100, 100)
    conn = start_conn()
    p1 = :binary.copy(<<1>>, 60)
    p2 = :binary.copy(<<2>>, 60)

    send(conn, {:voxel_chunk_delta_payload, p1})
    send(conn, {:voxel_chunk_delta_payload, p2})

    assert_receive {:gate_ws_send, b1}, 500
    assert b1 == encoded(:voxel_chunk_delta_payload, p1)
    # 次帧经自限定 flush 定时器排空(给足超时容差,非紧时序断言)。
    assert_receive {:gate_ws_send, b2}, 2_000
    assert b2 == encoded(:voxel_chunk_delta_payload, p2)
  end
end
