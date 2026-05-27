defmodule ChatServer.RuntimeDirectory do
  @moduledoc """
  Logical-scene directory for chat runtime shards.

  The directory owns only routing metadata: which `logical_scene_id` maps to
  which `ChatServer.Runtime` process, and which joined CID currently belongs to
  which scene shard. Each shard-local `ChatServer.Runtime` remains the owner of
  chat sessions, presence indexes, bounded history, and fan-out.
  """

  use GenServer

  alias ChatServer.{CliObserve, Runtime}

  @doc "Starts the runtime directory."
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

  @doc "Registers one chat session in its authoritative logical-scene shard."
  def join(attrs), do: join(__MODULE__, attrs)
  def join(server, attrs) when is_map(attrs), do: GenServer.call(server, {:join, attrs})

  @doc "Refreshes one session's server-authoritative chat presence."
  def refresh_presence(attrs), do: refresh_presence(__MODULE__, attrs)

  def refresh_presence(server, attrs) when is_map(attrs),
    do: GenServer.call(server, {:refresh_presence, attrs})

  @doc "Publishes one message through the authoritative logical-scene shard."
  def say(attrs), do: say(__MODULE__, attrs)
  def say(server, attrs) when is_map(attrs), do: GenServer.call(server, {:say, attrs})

  @doc "Removes one chat session from its current shard."
  def leave(cid), do: leave(__MODULE__, cid)
  def leave(server, cid) when is_integer(cid), do: GenServer.call(server, {:leave, cid})

  @doc "Returns a CLI/debug snapshot of directory and shard state."
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @impl true
  def init(opts) do
    {:ok,
     %{
       runtime_supervisor: Keyword.get(opts, :runtime_supervisor, ChatServer.RuntimeShardSup),
       shards: %{},
       shard_refs: %{},
       refs: %{},
       cid_to_scene: %{}
     }}
  end

  @impl true
  def handle_call({:join, attrs}, _from, state) do
    with {:ok, cid} <- cid(attrs),
         {:ok, scene_id} <- logical_scene_id(attrs),
         {:ok, state} <- remove_from_previous_scene(state, cid, scene_id),
         {:ok, runtime, state} <- ensure_runtime(state, scene_id),
         {:ok, session} <- call_runtime(runtime, {:join, attrs}) do
      state = put_in(state, [:cid_to_scene, session.cid], scene_id)

      CliObserve.emit("chat_runtime_directory_joined", %{
        cid: session.cid,
        logical_scene_id: scene_id,
        shard_key: scene_id,
        route_target: :scene_shard
      })

      {:reply, {:ok, session}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:refresh_presence, attrs}, _from, state) do
    cid = Map.get(attrs, :cid)

    with true <- is_integer(cid) or {:error, :invalid_cid},
         {:ok, current_scene_id} <- fetch_current_scene(state, cid),
         {:ok, target_scene_id} <- target_presence_scene(attrs, current_scene_id),
         {:ok, state} <- maybe_migrate_scene(state, attrs, current_scene_id, target_scene_id),
         {:ok, runtime} <- fetch_runtime(state, target_scene_id),
         {:ok, session} <-
           call_runtime(
             runtime,
             {:refresh_presence, Map.put(attrs, :logical_scene_id, target_scene_id)}
           ) do
      state = put_in(state, [:cid_to_scene, cid], target_scene_id)

      CliObserve.emit("chat_runtime_directory_presence_updated", %{
        cid: cid,
        logical_scene_id: target_scene_id,
        previous_logical_scene_id: current_scene_id,
        shard_key: target_scene_id,
        route_target: :scene_shard
      })

      {:reply, {:ok, session}, state}
    else
      {:error, reason} ->
        CliObserve.emit("chat_runtime_directory_presence_update_failed", %{
          cid: cid,
          reason: reason
        })

        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:say, attrs}, _from, state) do
    with {:ok, scene_id} <- message_scene(state, attrs),
         :ok <- validate_registered_scene(state, attrs, scene_id),
         {:ok, runtime} <- fetch_runtime(state, scene_id),
         {:ok, summary} <- call_runtime(runtime, {:say, attrs}) do
      routed =
        summary
        |> Map.put(:route_target, :scene_shard)
        |> Map.put(:shard_key, scene_id)

      CliObserve.emit("chat_runtime_directory_routed", %{
        cid: Map.get(attrs, :cid),
        logical_scene_id: scene_id,
        shard_key: scene_id,
        route_target: :scene_shard,
        route_result: :ok,
        channel: Map.get(routed, :channel),
        recipient_count: Map.get(routed, :recipient_count, 0)
      })

      {:reply, {:ok, routed}, state}
    else
      {:error, reason} ->
        CliObserve.emit("chat_runtime_directory_route_failed", %{
          cid: Map.get(attrs, :cid),
          reason: reason,
          channel: Map.get(attrs, :channel)
        })

        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:leave, cid}, _from, state) do
    state =
      case Map.fetch(state.cid_to_scene, cid) do
        {:ok, scene_id} ->
          case Map.fetch(state.shards, scene_id) do
            {:ok, runtime} -> _ = call_runtime(runtime, {:leave, cid})
            :error -> :ok
          end

          update_in(state, [:cid_to_scene], &Map.delete(&1, cid))

        :error ->
          state
      end

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {shards, state} =
      state.shards
      |> Enum.reduce({[], state}, fn {logical_scene_id, runtime}, {acc, state} ->
        case call_runtime(runtime, :snapshot) do
          {:ok, snapshot} ->
            entry = %{
              logical_scene_id: logical_scene_id,
              runtime_pid: runtime,
              session_count: snapshot.session_count,
              history_count: snapshot.history_count,
              presence_index: snapshot.presence_index
            }

            {[entry | acc], state}

          {:error, _reason} ->
            {acc, remove_shard(state, logical_scene_id)}
        end
      end)

    shards = Enum.sort_by(shards, & &1.logical_scene_id)

    {:reply,
     %{
       shard_count: length(shards),
       session_count: map_size(state.cid_to_scene),
       shards: shards
     }, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.fetch(state.refs, ref) do
      {:ok, logical_scene_id} ->
        state = remove_shard(state, logical_scene_id)

        CliObserve.emit("chat_runtime_shard_down", %{
          logical_scene_id: logical_scene_id,
          shard_key: logical_scene_id,
          reason: inspect(reason)
        })

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  defp ensure_runtime(state, logical_scene_id) do
    case Map.fetch(state.shards, logical_scene_id) do
      {:ok, runtime} when is_pid(runtime) ->
        if Process.alive?(runtime) do
          {:ok, runtime, state}
        else
          ensure_runtime(remove_shard(state, logical_scene_id), logical_scene_id)
        end

      _other ->
        case DynamicSupervisor.start_child(state.runtime_supervisor, {Runtime, name: nil}) do
          {:ok, runtime} ->
            ref = Process.monitor(runtime)

            state =
              state
              |> put_in([:shards, logical_scene_id], runtime)
              |> put_in([:shard_refs, logical_scene_id], ref)
              |> put_in([:refs, ref], logical_scene_id)

            CliObserve.emit("chat_runtime_shard_started", %{
              logical_scene_id: logical_scene_id,
              shard_key: logical_scene_id,
              route_target: :scene_shard
            })

            {:ok, runtime, state}

          {:error, reason} ->
            {:error, {:runtime_start_failed, reason}}
        end
    end
  end

  defp fetch_runtime(state, logical_scene_id) do
    case Map.fetch(state.shards, logical_scene_id) do
      {:ok, runtime} when is_pid(runtime) ->
        if Process.alive?(runtime), do: {:ok, runtime}, else: {:error, :sender_not_joined}

      _other ->
        {:error, :sender_not_joined}
    end
  end

  defp call_runtime(runtime, message) do
    case GenServer.call(runtime, message) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
      value -> {:ok, value}
    end
  catch
    :exit, _reason -> {:error, :sender_not_joined}
  end

  defp remove_from_previous_scene(state, cid, next_scene_id) do
    case Map.fetch(state.cid_to_scene, cid) do
      {:ok, ^next_scene_id} ->
        {:ok, state}

      {:ok, previous_scene_id} ->
        case Map.fetch(state.shards, previous_scene_id) do
          {:ok, runtime} -> _ = call_runtime(runtime, {:leave, cid})
          :error -> :ok
        end

        {:ok, update_in(state, [:cid_to_scene], &Map.delete(&1, cid))}

      :error ->
        {:ok, state}
    end
  end

  defp maybe_migrate_scene(state, _attrs, scene_id, scene_id), do: {:ok, state}

  defp maybe_migrate_scene(state, attrs, previous_scene_id, next_scene_id) do
    with :ok <- validate_migration_attrs(attrs),
         {:ok, previous_runtime} <- Map.fetch(state.shards, previous_scene_id),
         {:ok, next_runtime, state} <- ensure_runtime(state, next_scene_id) do
      _ = call_runtime(previous_runtime, {:leave, attrs.cid})

      case call_runtime(next_runtime, {:join, Map.put(attrs, :logical_scene_id, next_scene_id)}) do
        {:ok, session} ->
          {:ok, put_in(state, [:cid_to_scene, session.cid], next_scene_id)}

        {:error, reason} ->
          {:error, reason}
      end
    else
      :error -> {:error, :session_not_joined}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_migration_attrs(attrs) do
    cond do
      not is_binary(Map.get(attrs, :username)) -> {:error, :missing_migration_username}
      not is_pid(Map.get(attrs, :connection_pid)) -> {:error, :missing_migration_connection_pid}
      true -> :ok
    end
  end

  defp remove_shard(state, logical_scene_id) do
    ref = Map.get(state.shard_refs, logical_scene_id)

    if is_reference(ref), do: Process.demonitor(ref, [:flush])

    state
    |> update_in([:shards], &Map.delete(&1, logical_scene_id))
    |> update_in([:shard_refs], &Map.delete(&1, logical_scene_id))
    |> update_in([:refs], fn refs -> if ref, do: Map.delete(refs, ref), else: refs end)
    |> update_in([:cid_to_scene], fn cid_to_scene ->
      Map.reject(cid_to_scene, fn {_cid, scene_id} -> scene_id == logical_scene_id end)
    end)
  end

  defp logical_scene_id(attrs) do
    case Map.fetch(attrs, :logical_scene_id) do
      {:ok, value} when is_integer(value) -> {:ok, value}
      {:ok, _other} -> {:error, :invalid_logical_scene_id}
      :error -> {:error, :missing_logical_scene_id}
    end
  end

  defp cid(attrs) do
    case Map.fetch(attrs, :cid) do
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      {:ok, _other} -> {:error, :invalid_cid}
      :error -> {:error, :missing_cid}
    end
  end

  defp target_presence_scene(attrs, current_scene_id) do
    case Map.fetch(attrs, :logical_scene_id) do
      {:ok, value} when is_integer(value) -> {:ok, value}
      {:ok, _other} -> {:error, :invalid_logical_scene_id}
      :error -> {:ok, current_scene_id}
    end
  end

  defp message_scene(state, attrs) do
    attr_scene = Map.get(attrs, :logical_scene_id)
    channel_scene = attrs |> Map.get(:channel) |> channel_scene()
    registered_scene = Map.get(state.cid_to_scene, Map.get(attrs, :cid))

    cond do
      is_integer(attr_scene) and is_integer(channel_scene) and attr_scene != channel_scene ->
        {:error, :chat_route_mismatch}

      is_integer(registered_scene) and is_integer(channel_scene) and
          registered_scene != channel_scene ->
        {:error, :chat_route_mismatch}

      is_integer(channel_scene) ->
        {:ok, channel_scene}

      is_integer(attr_scene) ->
        {:ok, attr_scene}

      is_integer(registered_scene) ->
        {:ok, registered_scene}

      true ->
        {:error, :missing_logical_scene_id}
    end
  end

  defp validate_registered_scene(state, attrs, scene_id) do
    case Map.fetch(state.cid_to_scene, Map.get(attrs, :cid)) do
      {:ok, ^scene_id} -> :ok
      {:ok, _other_scene} -> {:error, :chat_route_mismatch}
      :error -> :ok
    end
  end

  defp channel_scene({:world, logical_scene_id}) when is_integer(logical_scene_id),
    do: logical_scene_id

  defp channel_scene({:region, logical_scene_id, _region_id}) when is_integer(logical_scene_id),
    do: logical_scene_id

  defp channel_scene({:local, logical_scene_id, _chunk_coord, _radius})
       when is_integer(logical_scene_id),
       do: logical_scene_id

  defp channel_scene({:local, logical_scene_id, _chunk_coord, _radius, _candidate_region_ids})
       when is_integer(logical_scene_id),
       do: logical_scene_id

  defp channel_scene({:system, logical_scene_id}) when is_integer(logical_scene_id),
    do: logical_scene_id

  defp channel_scene(_channel), do: nil

  defp fetch_current_scene(state, cid) do
    case Map.fetch(state.cid_to_scene, cid) do
      {:ok, scene_id} -> {:ok, scene_id}
      :error -> {:error, :session_not_joined}
    end
  end
end
