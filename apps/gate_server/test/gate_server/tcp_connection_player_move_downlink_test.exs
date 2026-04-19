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

  test "player_move downlink encodes the remote snapshot on tcp fallback", %{
    client: client,
    pid: pid
  } do
    snapshot = %SceneServer.Movement.RemoteSnapshot{
      cid: 77,
      server_tick: 9,
      position: {11.0, 12.0, 13.0},
      velocity: {1.0, 2.0, 3.0},
      acceleration: {0.1, 0.2, 0.3},
      movement_mode: :grounded
    }

    GenServer.cast(pid, {:player_move, snapshot})

    assert {:ok,
            <<0x83, 77::64-big, 9::32-big, 11.0::float-64-big, 12.0::float-64-big,
              13.0::float-64-big, 1.0::float-64-big, 2.0::float-64-big, 3.0::float-64-big,
              0.1::float-64-big, 0.2::float-64-big, 0.3::float-64-big, 0::8>>} =
             :gen_tcp.recv(client, 0, 500)
  end
end
