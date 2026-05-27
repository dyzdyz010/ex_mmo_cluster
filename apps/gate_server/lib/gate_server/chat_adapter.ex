defmodule GateServer.ChatAdapter do
  @moduledoc """
  Gate-side adapter for the standalone chat runtime.

  Connection workers use this module to register sessions, publish chat intents,
  and clean up sessions. The adapter does not store chat truth; it only locates
  `ChatServer.RuntimeDirectory` (or an explicitly injected test/runtime server)
  and performs bounded GenServer calls.
  """

  alias SceneServer.Voxel.Types

  @chat_call_timeout 5_000

  @doc "Builds chat context from server-side character/session data."
  def context_from_character(character, location) do
    position = map_field(character, :position) || map_field(character, "position") || %{}

    %{
      logical_scene_id:
        integer_field(character, :logical_scene_id) ||
          integer_field(character, "logical_scene_id") ||
          integer_field(position, :logical_scene_id) ||
          integer_field(position, "logical_scene_id") ||
          default_logical_scene_id(),
      region_id: nil,
      chunk_coord: chunk_from_location(location),
      location: location
    }
  end

  @doc """
  Registers a chat session for a Gate connection.

  Pass `:chat_runtime` only from tests or CLI observe tasks that need an
  isolated private runtime or directory. Normal Gate connections discover the
  configured local or remote `ChatServer.RuntimeDirectory`.
  """
  def join(
        %{cid: cid, username: username, connection_pid: connection_pid, location: location} =
          attrs
      ) do
    session = %{
      cid: cid,
      username: username || "anonymous",
      connection_pid: connection_pid,
      logical_scene_id: Map.get(attrs, :logical_scene_id, default_logical_scene_id()),
      region_id: region_id(attrs),
      chunk_coord: chunk_coord(attrs, location)
    }

    with {:ok, server} <- runtime_server(attrs),
         {:ok, {:ok, joined}} <- safe_call(server, {:join, session}, @chat_call_timeout) do
      {:ok, joined}
    else
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :chat_unavailable}
    end
  end

  @doc "Publishes one client chat intent to the configured Chat runtime entry."
  def publish(%{cid: cid, username: username, text: text} = attrs) do
    logical_scene_id = Map.get(attrs, :logical_scene_id, default_logical_scene_id())
    channel = Map.get(attrs, :channel, {:world, logical_scene_id})

    with {:ok, server} <- runtime_server(attrs),
         {:ok, {:ok, summary}} <-
           safe_call(
             server,
             {:say,
              %{
                cid: cid,
                username: username || "anonymous",
                logical_scene_id: logical_scene_id,
                channel: channel,
                text: text
              }},
             @chat_call_timeout
           ) do
      {:ok, summary}
    else
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :chat_unavailable}
    end
  end

  @doc "Refreshes ChatServer presence from a server-authoritative partition context."
  def refresh_presence(%{cid: cid} = attrs) when is_integer(cid) do
    presence =
      %{
        cid: cid,
        logical_scene_id: Map.get(attrs, :logical_scene_id, default_logical_scene_id()),
        region_id: region_id(attrs),
        chunk_coord: Map.get(attrs, :chunk_coord)
      }
      |> maybe_put(:username, Map.get(attrs, :username))
      |> maybe_put(:connection_pid, Map.get(attrs, :connection_pid))

    with {:ok, server} <- runtime_server(attrs),
         {:ok, {:ok, updated}} <-
           safe_call(server, {:refresh_presence, presence}, @chat_call_timeout) do
      {:ok, updated}
    else
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :chat_unavailable}
    end
  end

  @doc """
  Removes a chat session if the runtime is available.

  Pass `%{cid: cid, chat_runtime: runtime}` from tests or observe tasks that
  joined an isolated runtime.
  """
  def leave(%{cid: cid} = attrs) when is_integer(cid) and cid >= 0 do
    leave_with_server(runtime_server(attrs), cid)
  end

  def leave(cid) when is_integer(cid) and cid >= 0 do
    leave_with_server(runtime_server(), cid)
  end

  def leave(_cid), do: :ok

  @doc "Removes a chat session from a specific runtime server."
  def leave(server, cid) when is_integer(cid) and cid >= 0 do
    leave_with_server(validate_runtime_server(server), cid)
  end

  defp leave_with_server({:ok, server}, cid) do
    _ = safe_call(server, {:leave, cid}, @chat_call_timeout)
    :ok
  end

  defp leave_with_server({:error, _reason}, _cid), do: :ok

  defp runtime_server(attrs) when is_map(attrs) do
    case Map.get(attrs, :chat_runtime) do
      nil -> runtime_server()
      server -> validate_runtime_server(server)
    end
  end

  defp validate_runtime_server(server) when is_pid(server) or is_atom(server), do: {:ok, server}

  defp validate_runtime_server({name, node} = server) when is_atom(name) and is_atom(node),
    do: {:ok, server}

  defp validate_runtime_server({:global, _term} = server), do: {:ok, server}
  defp validate_runtime_server({:via, _module, _term} = server), do: {:ok, server}
  defp validate_runtime_server(_server), do: {:error, :invalid_chat_runtime}

  defp runtime_server do
    case Process.whereis(ChatServer.RuntimeDirectory) do
      pid when is_pid(pid) ->
        {:ok, ChatServer.RuntimeDirectory}

      nil ->
        with {:ok, chat_node} <- fetch_chat_node() do
          {:ok, {ChatServer.RuntimeDirectory, chat_node}}
        end
    end
  end

  defp fetch_chat_node do
    case safe_call(GateServer.Interface, :chat_server, @chat_call_timeout) do
      {:ok, nil} -> {:error, :chat_unavailable}
      {:ok, chat_node} -> {:ok, chat_node}
      {:error, _reason} -> {:error, :chat_unavailable}
    end
  end

  defp default_logical_scene_id do
    Application.get_env(:gate_server, :default_chat_logical_scene_id, 1)
  end

  defp region_id(attrs) do
    if Map.has_key?(attrs, :region_id) do
      Map.get(attrs, :region_id)
    else
      Application.get_env(:gate_server, :default_chat_region_id)
    end
  end

  defp chunk_coord(attrs, location) do
    case Map.get(attrs, :chunk_coord) do
      {x, y, z} = coord when is_integer(x) and is_integer(y) and is_integer(z) -> coord
      _other -> chunk_from_location(location)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp chunk_from_location({x, y, z}) do
    Types.chunk_from_world_cm!({x, y, z})
  end

  defp chunk_from_location(_location), do: {0, 0, 0}

  defp map_field(map, key) when is_map(map), do: Map.get(map, key)
  defp map_field(_map, _key), do: nil

  defp integer_field(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_integer(value) -> value
      _other -> nil
    end
  end

  defp integer_field(_map, _key), do: nil

  defp safe_call(server, message, timeout) do
    try do
      {:ok, GenServer.call(server, message, timeout)}
    catch
      :exit, reason -> {:error, reason}
    end
  end
end
