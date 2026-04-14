defmodule GateServer.FastLaneRegistry do
  @moduledoc """
  Tracks temporary fast-lane tickets and attached UDP peers.

  The registry sits between the authenticated TCP session and the future UDP
  fast lane. TCP issues a short-lived ticket, and the UDP listener consumes that
  ticket to attach a peer address to the existing connection process.

  Beyond ticket exchange, the registry is the single source of truth for UDP
  attachment lifecycle:

  - at most one UDP peer is attached to one TCP connection at a time
  - reattaching replaces any previous peer binding for that connection
  - idle peers expire automatically
  - dead TCP connections automatically lose their UDP attachment
  """

  use GenServer

  @default_ticket_ttl_ms 60_000
  @default_session_idle_timeout_ms 15_000

  @doc "Starts the shared UDP fast-lane registry."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, opts)
  end

  @doc """
  Issue a new UDP attach ticket for the given connection.
  """
  def issue_ticket(connection_pid, session_context)
      when is_pid(connection_pid) and is_map(session_context) do
    GenServer.call(__MODULE__, {:issue_ticket, connection_pid, session_context})
  end

  @doc """
  Consume a ticket and attach a UDP peer to the associated connection.
  """
  def attach_ticket(ticket, peer) when is_binary(ticket) do
    GenServer.call(__MODULE__, {:attach_ticket, ticket, peer})
  end

  @doc """
  Return the currently attached UDP session for a connection, if any.
  """
  def session_for_connection(connection_pid) when is_pid(connection_pid) do
    GenServer.call(__MODULE__, {:session_for_connection, connection_pid})
  end

  @doc """
  Return the currently attached UDP session for a peer tuple, if any.
  """
  def session_for_peer(peer) when is_tuple(peer) do
    GenServer.call(__MODULE__, {:session_for_peer, peer})
  end

  @doc """
  Refresh the idle timer for a peer and return the live attached session.

  This is used by UDP gameplay traffic so that ordinary movement packets keep
  the fast-lane attachment warm without introducing a dedicated UDP heartbeat.
  """
  def touch_peer(peer) when is_tuple(peer) do
    GenServer.call(__MODULE__, {:touch_peer, peer})
  end

  @doc """
  Remove any UDP attachment associated with a TCP connection.

  This is the explicit cleanup path used when the TCP control-plane connection
  closes before the registry notices it through process monitoring.
  """
  def detach_connection(connection_pid, reason \\ :detached) when is_pid(connection_pid) do
    GenServer.call(__MODULE__, {:detach_connection, connection_pid, reason})
  end

  @doc """
  Return a sanitized snapshot for CLI inspection.
  """
  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       tickets: %{},
       sessions: %{},
       sessions_by_peer: %{},
       monitors: %{},
       ticket_ttl_ms: Keyword.get(opts, :ticket_ttl_ms, @default_ticket_ttl_ms),
       session_idle_timeout_ms:
         Keyword.get(opts, :session_idle_timeout_ms, @default_session_idle_timeout_ms)
     }}
  end

  @impl true
  def handle_call({:issue_ticket, connection_pid, session_context}, _from, state) do
    state = prune_expired_sessions(prune_expired_tickets(state))
    ticket = generate_ticket()

    ticket_record = %{
      connection_pid: connection_pid,
      session_context: session_context,
      expires_at: System.system_time(:millisecond) + state.ticket_ttl_ms
    }

    GateServer.CliObserve.emit("fast_lane_ticket_issued", %{
      connection_pid: connection_pid,
      cid: Map.get(session_context, :cid),
      status: Map.get(session_context, :status)
    })

    {:reply, {:ok, ticket}, put_in(state, [:tickets, ticket], ticket_record)}
  end

  @impl true
  def handle_call({:attach_ticket, ticket, peer}, _from, state) do
    state = prune_expired_sessions(prune_expired_tickets(state))

    case Map.fetch(state.tickets, ticket) do
      :error ->
        GateServer.CliObserve.emit("fast_lane_attach_invalid_ticket", %{peer: peer})
        {:reply, {:error, :invalid_ticket}, state}

      {:ok, %{connection_pid: connection_pid, session_context: session_context}} ->
        state =
          state
          |> detach_connection_session(connection_pid, :peer_replaced)
          |> detach_peer_session(peer, :peer_reassigned)

        {state, monitor_ref} = ensure_connection_monitor(state, connection_pid)
        now = System.system_time(:millisecond)

        session = %{
          connection_pid: connection_pid,
          peer: peer,
          session_context: session_context,
          attached_at: now,
          last_seen_at: now,
          monitor_ref: monitor_ref
        }

        GenServer.cast(connection_pid, {:udp_attached, peer, ticket})

        GateServer.CliObserve.emit("fast_lane_attached", %{
          connection_pid: connection_pid,
          peer: peer,
          cid: Map.get(session_context, :cid),
          status: Map.get(session_context, :status)
        })

        new_state =
          state
          |> update_in([:tickets], &Map.delete(&1, ticket))
          |> put_in([:sessions, connection_pid], session)
          |> put_in([:sessions_by_peer, peer], session)

        {:reply, {:ok, session}, new_state}
    end
  end

  @impl true
  def handle_call({:session_for_connection, connection_pid}, _from, state) do
    state = prune_expired_sessions(state)
    {:reply, Map.get(state.sessions, connection_pid), state}
  end

  @impl true
  def handle_call({:session_for_peer, peer}, _from, state) do
    state = prune_expired_sessions(state)
    {:reply, Map.get(state.sessions_by_peer, peer), state}
  end

  @impl true
  def handle_call({:touch_peer, peer}, _from, state) do
    state = prune_expired_sessions(state)

    case Map.get(state.sessions_by_peer, peer) do
      nil ->
        {:reply, nil, state}

      session ->
        touched_session = %{session | last_seen_at: System.system_time(:millisecond)}

        GateServer.CliObserve.emit("fast_lane_touch_peer", %{
          peer: peer,
          connection_pid: touched_session.connection_pid,
          cid: Map.get(touched_session.session_context, :cid)
        })

        new_state =
          state
          |> put_in([:sessions, touched_session.connection_pid], touched_session)
          |> put_in([:sessions_by_peer, peer], touched_session)

        {:reply, touched_session, new_state}
    end
  end

  @impl true
  def handle_call({:detach_connection, connection_pid, reason}, _from, state) do
    GateServer.CliObserve.emit("fast_lane_detach_connection", %{
      connection_pid: connection_pid,
      reason: reason
    })

    {:reply, :ok, detach_connection_session(state, connection_pid, reason)}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = prune_expired_sessions(prune_expired_tickets(state))

    snapshot = %{
      ticket_count: map_size(state.tickets),
      session_count: map_size(state.sessions),
      sessions:
        Enum.map(state.sessions, fn {connection_pid, session} ->
          %{
            connection_pid: inspect(connection_pid),
            peer: session.peer,
            cid: Map.get(session.session_context, :cid),
            status: Map.get(session.session_context, :status),
            last_seen_at: session.last_seen_at
          }
        end)
    }

    {:reply, snapshot, state}
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, connection_pid, _reason}, state) do
    state =
      case Map.get(state.monitors, connection_pid) do
        ^monitor_ref -> detach_connection_session(state, connection_pid, :connection_down)
        _other -> state
      end

    {:noreply, state}
  end

  defp prune_expired_tickets(state) do
    now = System.system_time(:millisecond)

    update_in(state, [:tickets], fn tickets ->
      Map.reject(tickets, fn {_ticket, %{expires_at: expires_at}} -> expires_at <= now end)
    end)
  end

  defp prune_expired_sessions(state) do
    now = System.system_time(:millisecond)
    idle_timeout_ms = state.session_idle_timeout_ms

    Enum.reduce(state.sessions, state, fn {connection_pid, %{last_seen_at: last_seen_at}}, acc ->
      if now - last_seen_at >= idle_timeout_ms do
        GateServer.CliObserve.emit("fast_lane_idle_timeout", %{
          connection_pid: connection_pid,
          last_seen_at: last_seen_at
        })

        detach_connection_session(acc, connection_pid, :idle_timeout)
      else
        acc
      end
    end)
  end

  defp ensure_connection_monitor(state, connection_pid) do
    case Map.get(state.monitors, connection_pid) do
      nil ->
        monitor_ref = Process.monitor(connection_pid)
        {%{state | monitors: Map.put(state.monitors, connection_pid, monitor_ref)}, monitor_ref}

      monitor_ref ->
        {state, monitor_ref}
    end
  end

  defp detach_connection_session(state, connection_pid, reason) do
    case Map.pop(state.sessions, connection_pid) do
      {nil, _sessions} ->
        state

      {%{peer: peer}, sessions} ->
        maybe_demonitor_connection(state.monitors[connection_pid], connection_pid)
        notify_detached(connection_pid, peer, reason)

        %{
          state
          | sessions: sessions,
            sessions_by_peer: Map.delete(state.sessions_by_peer, peer),
            monitors: Map.delete(state.monitors, connection_pid)
        }
    end
  end

  defp detach_peer_session(state, peer, reason) do
    case Map.get(state.sessions_by_peer, peer) do
      nil ->
        state

      %{connection_pid: connection_pid} ->
        detach_connection_session(state, connection_pid, reason)
    end
  end

  defp maybe_demonitor_connection(nil, _connection_pid), do: :ok

  defp maybe_demonitor_connection(monitor_ref, _connection_pid) do
    Process.demonitor(monitor_ref, [:flush])
  end

  defp notify_detached(connection_pid, peer, reason) do
    if Process.alive?(connection_pid) do
      GenServer.cast(connection_pid, {:udp_detached, peer, reason})
    end
  end

  defp generate_ticket do
    18
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
