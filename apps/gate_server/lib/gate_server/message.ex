defmodule GateServer.Message do
  require Logger

  @doc """
  Parse incoming tcp message from protobuf to elixir terms.
  """
  @spec decode(binary) :: {:ok, struct} | {:error, any}
  def decode(data) do
    case Protox.decode(data, Packet) do
      {:ok, packet} ->
        Logger.debug("Decoded packet: #{inspect(packet, pretty: true)}")
        {:ok, packet}
      err -> err
    end
  end

  @doc """
  Encode proto struct to IO data
  """
  @spec encode(struct) :: {:ok, iodata} | {:error, any}
  def encode(packet) do
    Logger.debug("Packet to encode: #{inspect(packet, pretty: true)}")
    case Protox.encode(packet) do
      {:ok, data} -> {:ok, data}
      err -> err
    end
  end

  def dispatch(%Packet{payload: {:authrequest, authrequest}}, state, connection) do
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
