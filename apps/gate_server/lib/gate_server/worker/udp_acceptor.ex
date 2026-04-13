defmodule GateServer.UdpAcceptor do
  @moduledoc """
  UDP listener used for the gate fast lane.

  The listener owns one shared UDP socket and serves two transport-layer jobs:

  1. Accept ticket-based fast-lane attachments for already-authenticated TCP
     sessions.
  2. Route high-frequency movement traffic for attached peers while the TCP
     connection remains the authoritative control plane.

  Session lifecycle, peer replacement, and idle expiration all live in
  `GateServer.FastLaneRegistry`; this module delegates attachment validation to
  that registry instead of trying to replicate session state locally.
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
  Send a UDP payload to an attached peer through the shared listener socket.
  """
  def send_to_peer(peer, message) when is_tuple(peer) do
    GenServer.cast(__MODULE__, {:send_to_peer, peer, message})
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
    GateServer.CliObserve.emit("udp_listen", %{port: actual_port})

    {:ok, %{socket: socket, port: actual_port}}
  end

  @impl true
  def handle_call(:port, _from, state) do
    {:reply, state.port, state}
  end

  @impl true
  def handle_cast({:send_to_peer, {ip, port}, message}, state) do
    GateServer.CliObserve.emit("udp_send", %{
      peer: "#{:inet.ntoa(ip)}:#{port}",
      message: message
    })

    send_udp(state.socket, ip, port, message)
    {:noreply, state}
  end

  @impl true
  def handle_info({:udp, socket, ip, port, data}, state) do
    GateServer.CliObserve.emit("udp_receive", fn ->
      %{peer: "#{:inet.ntoa(ip)}:#{port}", bytes: byte_size(data)}
    end)

    case GateServer.Codec.decode(data) do
      {:ok, {:fast_lane_attach, request_id, ticket}} ->
        handle_attach(socket, ip, port, request_id, ticket)

      {:ok, {:movement_input, frame}} ->
        handle_udp_movement(socket, {ip, port}, frame)

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
        GateServer.CliObserve.emit("udp_attach_ok", %{
          peer: "#{:inet.ntoa(ip)}:#{port}",
          request_id: request_id
        })

        send_udp(socket, ip, port, {:fast_lane_attached, :ok, request_id})

      {:error, reason} ->
        GateServer.CliObserve.emit("udp_attach_error", %{
          peer: "#{:inet.ntoa(ip)}:#{port}",
          request_id: request_id,
          reason: reason
        })

        send_udp(socket, ip, port, {:fast_lane_attached, :error, request_id})
    end
  end

  defp handle_udp_movement(socket, peer = {ip, port}, frame) do
    case GateServer.FastLaneRegistry.touch_peer(peer) do
      %{connection_pid: connection_pid} ->
        GateServer.CliObserve.emit("udp_movement_forward", %{
          peer: "#{:inet.ntoa(ip)}:#{port}",
          request_id: frame.seq,
          connection_pid: connection_pid
        })

        case GenServer.call(connection_pid, {:udp_movement, frame}) do
          {:ok, ack} ->
            GateServer.CliObserve.emit("udp_movement_ack", %{
              peer: "#{:inet.ntoa(ip)}:#{port}",
              request_id: ack.ack_seq,
              cid: ack.cid,
              location: ack.position
            })

            send_udp(
              socket,
              ip,
              port,
              {:movement_ack, ack.ack_seq, ack.auth_tick, ack.cid, ack.position, ack.velocity,
               ack.acceleration, ack.movement_mode, ack.correction_flags}
            )

          {:error, reason} ->
            GateServer.CliObserve.emit("udp_movement_error", %{
              peer: "#{:inet.ntoa(ip)}:#{port}",
              request_id: frame.seq,
              reason: reason
            })

            send_udp(socket, ip, port, {:result, :error, frame.seq})
        end

      nil ->
        GateServer.CliObserve.emit("udp_movement_rejected", %{
          peer: "#{:inet.ntoa(ip)}:#{port}",
          request_id: frame.seq,
          reason: :no_session
        })

        send_udp(socket, ip, port, {:result, :error, frame.seq})
    end
  end

  defp send_udp(socket, ip, port, message) do
    {:ok, payload} = GateServer.Codec.encode(message)
    :gen_udp.send(socket, ip, port, payload)
  end
end
