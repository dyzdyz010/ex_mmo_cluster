defmodule GateServer.FastLaneRegistry do
  @moduledoc """
  Tracks temporary fast-lane tickets and attached UDP peers.

  The registry sits between the authenticated TCP session and the future UDP
  fast lane. TCP issues a short-lived ticket, and the UDP listener consumes that
  ticket to attach a peer address to the existing connection process.
  """

  use GenServer

  @ticket_ttl_ms 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
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

  @impl true
  def init(_init_arg) do
    {:ok, %{tickets: %{}, sessions: %{}, sessions_by_peer: %{}}}
  end

  @impl true
  def handle_call({:issue_ticket, connection_pid, session_context}, _from, state) do
    state = prune_expired_tickets(state)
    ticket = generate_ticket()

    ticket_record = %{
      connection_pid: connection_pid,
      session_context: session_context,
      expires_at: System.system_time(:millisecond) + @ticket_ttl_ms
    }

    {:reply, {:ok, ticket}, put_in(state, [:tickets, ticket], ticket_record)}
  end

  @impl true
  def handle_call({:attach_ticket, ticket, peer}, _from, state) do
    state = prune_expired_tickets(state)

    case Map.fetch(state.tickets, ticket) do
      :error ->
        {:reply, {:error, :invalid_ticket}, state}

      {:ok, %{connection_pid: connection_pid, session_context: session_context}} ->
        session = %{
          connection_pid: connection_pid,
          peer: peer,
          session_context: session_context,
          attached_at: System.system_time(:millisecond)
        }

        GenServer.cast(connection_pid, {:udp_attached, peer, ticket})

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
    {:reply, Map.get(state.sessions, connection_pid), state}
  end

  @impl true
  def handle_call({:session_for_peer, peer}, _from, state) do
    {:reply, Map.get(state.sessions_by_peer, peer), state}
  end

  defp prune_expired_tickets(state) do
    now = System.system_time(:millisecond)

    update_in(state, [:tickets], fn tickets ->
      Map.reject(tickets, fn {_ticket, %{expires_at: expires_at}} -> expires_at <= now end)
    end)
  end

  defp generate_ticket do
    18
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
