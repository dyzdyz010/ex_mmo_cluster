defmodule ChatServer.Runtime do
  @moduledoc """
  Server-authoritative chat runtime for MMO channels.

  The runtime owns session membership, delivery planning, bounded message
  history, and observe events. It sends delivery casts to Gate connection
  processes, but it does not depend on Scene AOI loops or voxel chunk workers.
  """

  use GenServer

  alias ChatServer.{CliObserve, DeliveryPlan}

  @default_history_limit 200
  @max_text_bytes 512

  @doc "Starts a chat runtime process."
  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])

    server_opts =
      if Keyword.has_key?(server_opts, :name) do
        if Keyword.get(server_opts, :name),
          do: server_opts,
          else: Keyword.delete(server_opts, :name)
      else
        Keyword.put(server_opts, :name, __MODULE__)
      end

    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  @doc "Registers or refreshes one client chat session."
  def join(attrs), do: join(__MODULE__, attrs)

  def join(server, attrs) when is_map(attrs) do
    GenServer.call(server, {:join, attrs})
  end

  @doc "Refreshes server-authoritative region/chunk presence for one joined session."
  def refresh_presence(attrs), do: refresh_presence(__MODULE__, attrs)

  def refresh_presence(server, attrs) when is_map(attrs) do
    GenServer.call(server, {:refresh_presence, attrs})
  end

  @doc "Removes one client chat session."
  def leave(cid), do: leave(__MODULE__, cid)

  def leave(server, cid) when is_integer(cid) do
    GenServer.call(server, {:leave, cid})
  end

  @doc "Publishes one chat message through the authoritative runtime."
  def say(attrs), do: say(__MODULE__, attrs)

  def say(server, attrs) when is_map(attrs) do
    GenServer.call(server, {:say, attrs})
  end

  @doc "Returns a CLI/debug snapshot of the runtime state."
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       sessions: %{},
       presence_index: empty_presence_index(),
       monitors: %{},
       history: [],
       next_message_id: 1,
       history_limit: Keyword.get(opts, :history_limit, @default_history_limit)
     }}
  end

  @impl true
  def handle_call({:join, attrs}, _from, state) do
    cid = integer_field!(attrs, :cid)
    previous_session = Map.get(state.sessions, cid)
    session = monitor_session(normalize_session!(attrs), previous_session)
    sessions = Map.put(state.sessions, session.cid, session)

    presence_index =
      state.presence_index |> unindex_session(previous_session) |> index_session(session)

    monitors =
      state.monitors
      |> delete_monitor(previous_session)
      |> Map.put(session.monitor_ref, session.cid)

    CliObserve.emit("chat_session_joined", %{
      cid: session.cid,
      username: session.username,
      logical_scene_id: session.logical_scene_id,
      region_id: session.region_id,
      chunk_coord: session.chunk_coord,
      session_count: map_size(sessions)
    })

    {:reply, {:ok, session},
     %{state | sessions: sessions, presence_index: presence_index, monitors: monitors}}
  end

  @impl true
  def handle_call({:refresh_presence, attrs}, _from, state) do
    cid = integer_field!(attrs, :cid)

    case Map.fetch(state.sessions, cid) do
      {:ok, session} ->
        previous = snapshot_session(session)

        updated = %{
          session
          | logical_scene_id: integer_field(attrs, :logical_scene_id, session.logical_scene_id),
            region_id: optional_integer_field(attrs, :region_id, session.region_id),
            chunk_coord: optional_coord(Map.get(attrs, :chunk_coord, session.chunk_coord))
        }

        sessions = Map.put(state.sessions, cid, updated)

        presence_index =
          state.presence_index |> unindex_session(session) |> index_session(updated)

        CliObserve.emit("chat_session_presence_updated", %{
          cid: cid,
          username: updated.username,
          previous_logical_scene_id: previous.logical_scene_id,
          logical_scene_id: updated.logical_scene_id,
          previous_region_id: previous.region_id,
          region_id: updated.region_id,
          previous_chunk_coord: previous.chunk_coord,
          chunk_coord: updated.chunk_coord,
          session_count: map_size(sessions)
        })

        {:reply, {:ok, updated}, %{state | sessions: sessions, presence_index: presence_index}}

      :error ->
        CliObserve.emit("chat_session_presence_update_failed", %{
          cid: cid,
          reason: :session_not_joined,
          session_count: map_size(state.sessions)
        })

        {:reply, {:error, :session_not_joined}, state}
    end
  end

  @impl true
  def handle_call({:leave, cid}, _from, state) do
    {session, sessions, presence_index, monitors} = remove_session(state, cid)

    CliObserve.emit("chat_session_left", %{
      cid: cid,
      logical_scene_id: if(session, do: session.logical_scene_id),
      session_count: map_size(sessions)
    })

    {:reply, :ok,
     %{state | sessions: sessions, presence_index: presence_index, monitors: monitors}}
  end

  @impl true
  def handle_call({:say, attrs}, _from, state) do
    with {:ok, message_attrs} <- normalize_message(attrs),
         {:ok, sender} <- fetch_sender(state.sessions, message_attrs.cid) do
      channel = Map.get(message_attrs, :channel, {:world, sender.logical_scene_id})

      CliObserve.emit("chat_say_received", %{
        cid: message_attrs.cid,
        username: sender.username,
        channel: channel,
        text: message_attrs.text
      })

      plan =
        DeliveryPlan.plan_indexed(%{
          sessions: state.sessions,
          presence_index: state.presence_index,
          channel: channel
        })

      message = build_message(state.next_message_id, sender, message_attrs, plan.channel)

      CliObserve.emit("chat_delivery_planned", fn ->
        %{
          message_id: message.message_id,
          cid: message.cid,
          username: message.username,
          channel: message.channel,
          plan_source: plan.plan_source,
          text: message.text,
          recipient_cids: observe_cids(plan.recipient_cids),
          recipient_count: plan.recipient_count,
          skipped_count: plan.skipped_count
        }
      end)

      delivered_count = deliver(plan.recipients, message)
      history = trim_history([message | state.history], state.history_limit)

      summary = %{
        message_id: message.message_id,
        cid: message.cid,
        username: message.username,
        channel: message.channel,
        plan_source: plan.plan_source,
        recipient_cids: plan.recipient_cids,
        recipient_count: delivered_count,
        skipped_count: plan.skipped_count,
        history_count: length(history)
      }

      CliObserve.emit(
        "chat_delivered",
        Map.put(summary, :recipient_cids, observe_cids(summary.recipient_cids))
      )

      {:reply, {:ok, summary},
       %{state | history: history, next_message_id: state.next_message_id + 1}}
    else
      {:error, reason} ->
        CliObserve.emit("chat_rejected", %{
          reason: reason,
          attrs: Map.take(attrs, [:cid, :channel])
        })

        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    reply = %{
      session_count: map_size(state.sessions),
      history_count: length(state.history),
      presence_index: presence_index_summary(state.presence_index),
      sessions:
        state.sessions
        |> Map.values()
        |> Enum.sort_by(& &1.cid)
        |> Enum.map(&snapshot_session/1),
      recent_messages:
        state.history
        |> Enum.take(16)
        |> Enum.map(&snapshot_message/1)
    }

    {:reply, reply, state}
  end

  @impl true
  def handle_info({:DOWN, monitor_ref, :process, _pid, reason}, state) do
    case Map.fetch(state.monitors, monitor_ref) do
      {:ok, cid} ->
        {session, sessions, presence_index, monitors} = remove_session(state, cid)

        CliObserve.emit("chat_session_down", %{
          cid: cid,
          username: if(session, do: session.username),
          logical_scene_id: if(session, do: session.logical_scene_id),
          reason: inspect(reason),
          session_count: map_size(sessions)
        })

        {:noreply,
         %{state | sessions: sessions, presence_index: presence_index, monitors: monitors}}

      :error ->
        {:noreply, state}
    end
  end

  defp normalize_session!(attrs) do
    cid = integer_field!(attrs, :cid)

    %{
      cid: cid,
      username: string_field(attrs, :username, "anonymous"),
      connection_pid: pid_field!(attrs, :connection_pid),
      logical_scene_id: integer_field(attrs, :logical_scene_id, 1),
      region_id: optional_integer_field(attrs, :region_id),
      chunk_coord: optional_coord(Map.get(attrs, :chunk_coord))
    }
  end

  defp monitor_session(session, nil) do
    Map.put(session, :monitor_ref, Process.monitor(session.connection_pid))
  end

  defp monitor_session(session, previous_session) do
    demonitor_session(previous_session)
    monitor_session(session, nil)
  end

  defp remove_session(
         %{sessions: sessions, presence_index: presence_index, monitors: monitors},
         cid
       ) do
    {session, sessions} = Map.pop(sessions, cid)
    presence_index = unindex_session(presence_index, session)

    monitors =
      case session do
        %{monitor_ref: monitor_ref} ->
          demonitor_session(session)
          Map.delete(monitors, monitor_ref)

        _other ->
          monitors
      end

    {session, sessions, presence_index, monitors}
  end

  defp demonitor_session(%{monitor_ref: monitor_ref}) when is_reference(monitor_ref) do
    Process.demonitor(monitor_ref, [:flush])
  end

  defp demonitor_session(_session), do: :ok

  defp delete_monitor(monitors, %{monitor_ref: monitor_ref}) when is_reference(monitor_ref) do
    Map.delete(monitors, monitor_ref)
  end

  defp delete_monitor(monitors, _session), do: monitors

  defp normalize_message(attrs) do
    with {:ok, cid} <- fetch_integer(attrs, :cid),
         {:ok, text} <- fetch_text(attrs, :text) do
      {:ok,
       %{
         cid: cid,
         text: text,
         channel: Map.get(attrs, :channel)
       }}
    end
  end

  defp fetch_sender(sessions, cid) do
    case Map.fetch(sessions, cid) do
      {:ok, session} -> {:ok, session}
      :error -> {:error, :sender_not_joined}
    end
  end

  defp build_message(message_id, sender, attrs, channel) do
    %{
      message_id: message_id,
      cid: sender.cid,
      username: sender.username,
      logical_scene_id: sender.logical_scene_id,
      channel: channel,
      text: attrs.text,
      sent_at_ms: System.system_time(:millisecond)
    }
  end

  defp deliver(recipients, message) do
    Enum.reduce(recipients, 0, fn recipient, count ->
      GenServer.cast(
        recipient.connection_pid,
        {:chat_message, message.cid, message.username, message.text}
      )

      count + 1
    end)
  end

  defp trim_history(history, limit), do: Enum.take(history, limit)

  defp snapshot_session(session) do
    Map.take(session, [:cid, :username, :logical_scene_id, :region_id, :chunk_coord])
  end

  defp snapshot_message(message) do
    Map.take(message, [
      :message_id,
      :cid,
      :username,
      :logical_scene_id,
      :channel,
      :text,
      :sent_at_ms
    ])
  end

  defp empty_presence_index do
    %{world: %{}, region: %{}, local: %{}}
  end

  defp index_session(index, nil), do: index

  defp index_session(index, session) do
    index
    |> put_presence(:world, session.logical_scene_id, session.cid)
    |> maybe_put_region_presence(session)
    |> maybe_put_local_presence(session)
  end

  defp unindex_session(index, nil), do: index

  defp unindex_session(index, session) do
    index
    |> delete_presence(:world, session.logical_scene_id, session.cid)
    |> maybe_delete_region_presence(session)
    |> maybe_delete_local_presence(session)
  end

  defp maybe_put_region_presence(index, %{region_id: region_id} = session)
       when is_integer(region_id) do
    put_presence(index, :region, {session.logical_scene_id, region_id}, session.cid)
  end

  defp maybe_put_region_presence(index, _session), do: index

  defp maybe_delete_region_presence(index, %{region_id: region_id} = session)
       when is_integer(region_id) do
    delete_presence(index, :region, {session.logical_scene_id, region_id}, session.cid)
  end

  defp maybe_delete_region_presence(index, _session), do: index

  defp maybe_put_local_presence(index, %{chunk_coord: {_, _, _} = chunk_coord} = session) do
    put_presence(index, :local, {session.logical_scene_id, chunk_coord}, session.cid)
  end

  defp maybe_put_local_presence(index, _session), do: index

  defp maybe_delete_local_presence(index, %{chunk_coord: {_, _, _} = chunk_coord} = session) do
    delete_presence(index, :local, {session.logical_scene_id, chunk_coord}, session.cid)
  end

  defp maybe_delete_local_presence(index, _session), do: index

  defp put_presence(index, kind, key, cid) do
    Map.update!(index, kind, fn table ->
      Map.update(table, key, MapSet.new([cid]), &MapSet.put(&1, cid))
    end)
  end

  defp delete_presence(index, kind, key, cid) do
    Map.update!(index, kind, fn table ->
      case Map.get(table, key) do
        nil ->
          table

        cids ->
          cids = MapSet.delete(cids, cid)

          if MapSet.size(cids) == 0 do
            Map.delete(table, key)
          else
            Map.put(table, key, cids)
          end
      end
    end)
  end

  defp presence_index_summary(index) do
    %{
      world_channel_count: map_size(index.world),
      region_channel_count: map_size(index.region),
      local_channel_count: map_size(index.local),
      world_membership_count: membership_count(index.world),
      region_membership_count: membership_count(index.region),
      local_membership_count: membership_count(index.local)
    }
  end

  defp membership_count(table) do
    Enum.reduce(table, 0, fn {_key, cids}, acc -> acc + MapSet.size(cids) end)
  end

  defp observe_cids(cids), do: Enum.map(cids, &Integer.to_string/1)

  defp integer_field!(attrs, key) do
    case fetch_integer(attrs, key) do
      {:ok, value} -> value
      {:error, reason} -> raise ArgumentError, "#{key}: #{reason}"
    end
  end

  defp integer_field(attrs, key, default) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_integer(value) -> value
      :error -> default
      _other -> raise ArgumentError, "#{key} must be an integer"
    end
  end

  defp optional_integer_field(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_integer(value) -> value
      {:ok, nil} -> nil
      :error -> nil
      _other -> raise ArgumentError, "#{key} must be an integer or nil"
    end
  end

  defp optional_integer_field(attrs, key, default) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_integer(value) -> value
      {:ok, nil} -> nil
      :error -> default
      _other -> raise ArgumentError, "#{key} must be an integer or nil"
    end
  end

  defp fetch_integer(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_integer(value) -> {:ok, value}
      {:ok, _value} -> {:error, :invalid_integer}
      :error -> {:error, :missing_integer}
    end
  end

  defp string_field(attrs, key, default) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) -> value
      :error -> default
      _other -> raise ArgumentError, "#{key} must be a string"
    end
  end

  defp fetch_text(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_binary(value) ->
        text = String.trim(value)

        cond do
          text == "" -> {:error, :empty_text}
          byte_size(text) > @max_text_bytes -> {:error, :text_too_large}
          true -> {:ok, text}
        end

      {:ok, _value} ->
        {:error, :invalid_text}

      :error ->
        {:error, :missing_text}
    end
  end

  defp pid_field!(attrs, key) do
    case Map.fetch(attrs, key) do
      {:ok, value} when is_pid(value) -> value
      _other -> raise ArgumentError, "#{key} must be a pid"
    end
  end

  defp optional_coord(nil), do: nil

  defp optional_coord({x, y, z}) when is_integer(x) and is_integer(y) and is_integer(z),
    do: {x, y, z}

  defp optional_coord(value) do
    raise ArgumentError, "chunk_coord must be nil or {x, y, z}, got: #{inspect(value)}"
  end
end
