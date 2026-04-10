defmodule GateServer.UdpAcceptor do
  @moduledoc """
  UDP listener used for fast-lane bootstrap.

  The listener currently accepts only the ticket-based attach handshake. It
  does not yet route gameplay movement over UDP; that remains a later phase.
  """

  use GenServer
  require Logger

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 500
    }
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, opts)
  end

  @doc """
  Return the currently bound UDP port.
  """
  def port do
    case Process.whereis(__MODULE__) do
      nil -> Application.get_env(:gate_server, :udp_port, 29_001)
      _pid -> GenServer.call(__MODULE__, :port)
    end
  end

  @impl true
  def init(opts) do
    requested_port =
      Keyword.get(opts, :port, Application.get_env(:gate_server, :udp_port, 29_001))

    socket_opts = [:binary, active: true, reuseaddr: true]
    {:ok, socket} = :gen_udp.open(requested_port, socket_opts)
    {:ok, actual_port} = :inet.port(socket)

    Logger.info("Gate UDP acceptor listening on port #{actual_port}")

    {:ok, %{socket: socket, port: actual_port}}
  end

  @impl true
  def handle_call(:port, _from, state) do
    {:reply, state.port, state}
  end

  @impl true
  def handle_info({:udp, socket, ip, port, data}, state) do
    case GateServer.Codec.decode(data) do
      {:ok, {:fast_lane_attach, request_id, ticket}} ->
        handle_attach(socket, ip, port, request_id, ticket)

      {:ok, {:movement, cid, timestamp, location, velocity, acceleration, request_id}} ->
        handle_udp_movement(
          socket,
          {ip, port},
          request_id,
          cid,
          timestamp,
          location,
          velocity,
          acceleration
        )

      {:ok, unexpected} ->
        Logger.warning("Unhandled UDP payload: #{inspect(unexpected)}")

      {:error, reason} ->
        Logger.warning("Invalid UDP payload: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  defp handle_attach(socket, ip, port, request_id, ticket) do
    case GateServer.FastLaneRegistry.attach_ticket(ticket, {ip, port}) do
      {:ok, _session} ->
        send_udp(socket, ip, port, {:fast_lane_attached, :ok, request_id})

      {:error, _reason} ->
        send_udp(socket, ip, port, {:fast_lane_attached, :error, request_id})
    end
  end

  defp handle_udp_movement(
         socket,
         peer = {ip, port},
         request_id,
         cid,
         timestamp,
         location,
         velocity,
         acceleration
       ) do
    case GateServer.FastLaneRegistry.session_for_peer(peer) do
      %{connection_pid: connection_pid} ->
        case GenServer.call(
               connection_pid,
               {:udp_movement, request_id, cid, timestamp, location, velocity, acceleration}
             ) do
          {:ok, ack_cid, ack_location} ->
            send_udp(socket, ip, port, {:movement_result, :ok, request_id, ack_cid, ack_location})

          {:error, _reason} ->
            send_udp(socket, ip, port, {:result, :error, request_id})
        end

      nil ->
        send_udp(socket, ip, port, {:result, :error, request_id})
    end
  end

  defp send_udp(socket, ip, port, message) do
    {:ok, payload} = GateServer.Codec.encode(message)
    :gen_udp.send(socket, ip, port, payload)
  end
end
