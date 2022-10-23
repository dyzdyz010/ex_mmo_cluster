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

      err ->
        err
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

  def dispatch(%Packet{payload: {:movement, movement}}, state, _connection) do
    # auth_server = GenServer.call(GateServer.Interface, :auth_server)
    # case GenServer.call({AuthServer.AuthWorker, auth_server.node}, {:login, authrequest}) do
    #   {:ok, agent} ->
    #     GenServer.cast(connection, {:send, "ok"})
    #     {:ok, %{state | agent: agent}}
    #   {:error, :mismatch} ->
    #     GenServer.cast(connection, {:send, "mismatch"})
    #     {:ok,state}
    #   _ -> GenServer.cast(connection, {:send, "server error"})
    #   {:ok,state}
    # end

    Logger.debug("收到位移：#{inspect(movement, pretty: true)}")

    {:ok, state}
  end

  def dispatch(%Packet{id: id, payload: {:enter_scene, enter}}, state, connection) do
    {result, new_state} =
      case GenServer.call(
             {SceneServer.PlayerManager, :"scene1@127.0.0.1"},
             {:add_player, enter.cid, connection}
           ) do
        {:ok, ppid} ->
          result = %Response.Result{packet_id: id, status_code: :ok, payload: %{}}
          {result, %{state | scene: ppid, cid: enter.cid}}

        _ ->
          result = %Response.Result{packet_id: id, status_code: :ok, payload: %{}}
          {result, state}
      end

    packet = %Packet{id: id, timestamp: :os.system_time(:millisecond), payload: {:result, result}}

    GenServer.cast(connection, {:send_data, packet})

    {:ok, new_state}
  end

  def dispatch(%Packet{id: id, timestamp: timestamp, payload: {:time_sync, _}}, state, connection) do

  end
end
