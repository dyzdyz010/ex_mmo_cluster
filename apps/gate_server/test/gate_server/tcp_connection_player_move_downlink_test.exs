defmodule GateServer.TcpConnectionPlayerMoveDownlinkTest do
  use ExUnit.Case, async: false

  setup do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: 4, active: true, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    {:ok, client} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, packet: 4, active: false])
    {:ok, server} = :gen_tcp.accept(listener)
    {:ok, pid} = GateServer.TcpConnection.start_link(server)
    :ok = :gen_tcp.controlling_process(server, pid)
    :ok = :gen_tcp.close(listener)

    on_exit(fn ->
      _ = :gen_tcp.close(client)
      _ = :gen_tcp.close(server)

      if Process.alive?(pid) do
        Process.exit(pid, :kill)
      end
    end)

    {:ok, client: client, pid: pid}
  end

  test "player_move downlink encodes the movement sequence on tcp fallback", %{
    client: client,
    pid: pid
  } do
    GenServer.cast(pid, {:player_move, 77, {11.0, 12.0, 13.0}, 9})

    assert {:ok,
            <<0x83, 77::64-big, 9::64-big, 11.0::float-64-big, 12.0::float-64-big,
              13.0::float-64-big>>} = :gen_tcp.recv(client, 0, 500)
  end
end
