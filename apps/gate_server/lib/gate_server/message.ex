defmodule GateServer.Message do
  require Logger

  def msg_recv(msg, connection, state) do
    {:ok, packet} = parse_proto(msg)
    handle(packet, state, connection)
  end

  @doc """
  Parse incoming tcp message from protobuf to elixir terms.
  """
  @spec parse_proto(binary) :: {:ok, struct} | {:error, any}
  def parse_proto(data) do
    Protox.decode(data, Packet)
  end

  def handle(%Packet{payload: {:authrequest, authrequest}}, state, connection) do
    auth_server = GenServer.call(GateServer.Interface, :auth_server)
    case GenServer.call({AuthServer.AuthWorker, auth_server.node}, {:login, authrequest}) do
      {:ok, agent} ->
        GenServer.cast(connection, {:send, "ok"})
        {:ok, %{state | agent: agent}}
      {:error, :mismatch} ->
        GenServer.cast(connection, {:send, "mismatch"})
        {:ok,state}
      _ -> GenServer.cast(connection, {:send, "server error"})
      {:ok,state}
    end
  end
  def handle(%Packet{payload: _}, _state, connection) do
    GenServer.cast(connection, {:send, "ok"})
  end
end
