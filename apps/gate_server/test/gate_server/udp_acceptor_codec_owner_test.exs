defmodule GateServer.UdpAcceptorCodecOwnerTest do
  use ExUnit.Case, async: false

  alias GateServer.{FastLaneRegistry, TcpConnection, UdpAcceptor}

  setup do
    start_supervised!({FastLaneRegistry, name: FastLaneRegistry})
    listener = start_supervised!({UdpAcceptor, port: 0}, restart: :temporary)
    port = GenServer.call(listener, :port)
    {:ok, socket} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_udp.close(socket) end)
    %{listener: listener, port: port, socket: socket}
  end

  test "unattached UDP movement returns old result bytes and keeps the same listener", ctx do
    {:ok, client_port} = :inet.port(ctx.socket)
    assert FastLaneRegistry.session_for_peer({{127, 0, 0, 1}, client_port}) == nil

    for seq <- [0x01020304, 0x11223344] do
      assert_error_reply(ctx, seq)
    end
  end

  test "attached UDP movement keeps the existing TCP connection error result", ctx do
    {:ok, tcp_listener} = :gen_tcp.listen(0, [:binary, active: false])
    {:ok, tcp_port} = :inet.port(tcp_listener)
    {:ok, client} = :gen_tcp.connect({127, 0, 0, 1}, tcp_port, [:binary, active: false])
    {:ok, accepted} = :gen_tcp.accept(tcp_listener)

    on_exit(fn ->
      Enum.each([accepted, client, tcp_listener], &:gen_tcp.close/1)
    end)

    connection =
      start_supervised!(%{id: TcpConnection, start: {TcpConnection, :start_link, [accepted]}})

    assert {:ok, ticket} = FastLaneRegistry.issue_ticket(connection, %{})
    request_id = 0x0102030405060708

    assert :ok =
             :gen_udp.send(
               ctx.socket,
               {127, 0, 0, 1},
               ctx.port,
               <<0x07, request_id::64-big, byte_size(ticket)::16-big, ticket::binary>>
             )

    assert {:ok, {{127, 0, 0, 1}, port, <<0x88, ^request_id::64-big, 0>>}} =
             :gen_udp.recv(ctx.socket, 0, 1_000)

    assert port == ctx.port
    {:ok, client_port} = :inet.port(ctx.socket)

    assert %{connection_pid: ^connection} =
             FastLaneRegistry.session_for_peer({{127, 0, 0, 1}, client_port})

    for seq <- [0x55667788, 0x99AABBCC] do
      assert_error_reply(ctx, seq)
    end

    assert Process.alive?(connection)
  end

  defp assert_error_reply(ctx, seq) do
    packet =
      <<0x01, seq::32-big, 1::32-big, 16::16-big, 1.0::float-32-big, 0.0::float-32-big,
        1.0::float-32-big, 0::16-big>>

    assert :ok = :gen_udp.send(ctx.socket, {127, 0, 0, 1}, ctx.port, packet)

    assert {:ok, {{127, 0, 0, 1}, port, <<0x80, ^seq::64-big, 1>>}} =
             :gen_udp.recv(ctx.socket, 0, 1_000)

    assert port == ctx.port
    assert GenServer.call(ctx.listener, :port) == ctx.port
  end
end
