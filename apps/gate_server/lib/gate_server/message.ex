defmodule GateServer.Message do
  require Logger

  @doc """
  Parse incoming tcp message from protobuf to elixir terms.
  """
  @spec parse_proto(binary) :: any
  def parse_proto(data) do
    a = Packet.decode(data)
    {:ok, a}
  end

  def handle(%Packet{payload: {:credentials, credential}}, state, connection) do
    auth_server = GenServer.call(GateServer.Interface, :auth_server)
    case GenServer.call({AuthServer.AuthWorker, auth_server.node}, {:login, credential}) do
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
