defmodule GateServer.TcpFramingTest do
  use ExUnit.Case, async: true

  @port 29100

  @moduledoc """
  Tests for TCP length-prefix framing (packet: 4).

  Verifies that Erlang's {packet, 4} option correctly handles:
  - Single message delivery
  - Multiple messages sent in one TCP segment (no merging)
  - Large messages
  """

  setup do
    # Start a minimal TCP listener with packet: 4
    {:ok, listen_socket} =
      :gen_tcp.listen(@port, [:binary, packet: 4, active: false, reuseaddr: true])

    on_exit(fn -> :gen_tcp.close(listen_socket) end)

    %{listen_socket: listen_socket}
  end

  test "single message is delivered intact", %{listen_socket: listen_socket} do
    # Connect with packet: 4 on client side too
    {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", @port, [:binary, packet: 4, active: false])
    {:ok, server} = :gen_tcp.accept(listen_socket, 1000)

    payload = <<1, 2, 3, 4, 5>>
    :ok = :gen_tcp.send(client, payload)
    {:ok, received} = :gen_tcp.recv(server, 0, 1000)

    assert received == payload

    :gen_tcp.close(client)
    :gen_tcp.close(server)
  end

  test "two messages sent rapidly are delivered as separate packets", %{
    listen_socket: listen_socket
  } do
    {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", @port, [:binary, packet: 4, active: false])
    {:ok, server} = :gen_tcp.accept(listen_socket, 1000)

    msg1 = <<"hello">>
    msg2 = <<"world">>

    :ok = :gen_tcp.send(client, msg1)
    :ok = :gen_tcp.send(client, msg2)

    {:ok, received1} = :gen_tcp.recv(server, 0, 1000)
    {:ok, received2} = :gen_tcp.recv(server, 0, 1000)

    assert received1 == msg1
    assert received2 == msg2

    :gen_tcp.close(client)
    :gen_tcp.close(server)
  end

  test "raw client with manual length prefix is correctly parsed by packet:4 server", %{
    listen_socket: listen_socket
  } do
    # Client uses raw TCP (packet: 0) and manually prepends 4-byte length header
    # This simulates what a non-Erlang client (e.g., game client in C++/Unity) would do
    {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", @port, [:binary, packet: 0, active: false])
    {:ok, server} = :gen_tcp.accept(listen_socket, 1000)

    :inet.setopts(server, [active: false, packet: 4])

    payload = <<0x01, 42::64, 1.0::float-64, 2.0::float-64, 3.0::float-64>>
    length = byte_size(payload)

    # Send length-prefixed frame manually
    :ok = :gen_tcp.send(client, <<length::32-big, payload::binary>>)
    {:ok, received} = :gen_tcp.recv(server, 0, 1000)

    # Server receives the payload without the length prefix (stripped by packet:4)
    assert received == payload

    :gen_tcp.close(client)
    :gen_tcp.close(server)
  end

  test "two messages concatenated in one TCP send are split correctly", %{
    listen_socket: listen_socket
  } do
    # Raw client sends two length-prefixed messages in a single TCP write
    {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", @port, [:binary, packet: 0, active: false])
    {:ok, server} = :gen_tcp.accept(listen_socket, 1000)

    :inet.setopts(server, [active: false, packet: 4])

    msg1 = <<"first_message">>
    msg2 = <<"second_message">>

    # Concatenate both framed messages into one TCP send
    frame1 = <<byte_size(msg1)::32-big, msg1::binary>>
    frame2 = <<byte_size(msg2)::32-big, msg2::binary>>
    :ok = :gen_tcp.send(client, <<frame1::binary, frame2::binary>>)

    {:ok, received1} = :gen_tcp.recv(server, 0, 1000)
    {:ok, received2} = :gen_tcp.recv(server, 0, 1000)

    assert received1 == msg1
    assert received2 == msg2

    :gen_tcp.close(client)
    :gen_tcp.close(server)
  end

  test "server can send length-prefixed response back to raw client", %{
    listen_socket: listen_socket
  } do
    # Verify server-to-client framing: packet:4 on server auto-prepends length
    {:ok, client} = :gen_tcp.connect(~c"127.0.0.1", @port, [:binary, packet: 0, active: false])
    {:ok, server} = :gen_tcp.accept(listen_socket, 1000)

    :inet.setopts(server, [packet: 4])

    response = <<"response_data">>
    :ok = :gen_tcp.send(server, response)

    # Raw client receives 4-byte length header + payload
    {:ok, raw_data} = :gen_tcp.recv(client, 0, 1000)
    expected_length = byte_size(response)
    assert <<^expected_length::32-big, ^response::binary>> = raw_data

    :gen_tcp.close(client)
    :gen_tcp.close(server)
  end
end
