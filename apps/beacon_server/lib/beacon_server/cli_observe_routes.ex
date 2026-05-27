defmodule BeaconServer.CliObserveRoutes do
  @moduledoc """
  Process-independent routing table for CLI observe sinks.

  Observe logs are normally configured with application env for CLI tasks, but
  tests and long-running local smokes can overlap in one BEAM. This registry
  lets callers bind a logical scene id to a concrete log path so events follow
  their world context instead of the current global env value.
  """

  use GenServer

  @known_scopes [:chat_server, :gate_server, :scene_server, :world_server]
  @routes_key {__MODULE__, :routes}

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def register(scope, logical_scene_id, path)
      when is_atom(scope) and is_integer(logical_scene_id) and is_binary(path) do
    token = make_ref()

    case ensure_manager() do
      pid when is_pid(pid) ->
        :ok = GenServer.call(pid, {:register, scope, logical_scene_id, path, token})
        {:ok, token}

      nil ->
        {:error, :unavailable}
    end
  end

  def unregister(scope, logical_scene_id, token)
      when is_atom(scope) and is_integer(logical_scene_id) do
    case manager() do
      pid when is_pid(pid) -> GenServer.call(pid, {:unregister, scope, logical_scene_id, token})
      nil -> :ok
    end
  end

  def lookup(scope, fields) when is_atom(scope) and is_map(fields) do
    with id when is_integer(id) <- logical_scene_id(fields),
         path when is_binary(path) <- Map.get(route_paths(scope), id) do
      path
    else
      _other -> nil
    end
  end

  def lookup(_scope, _fields), do: nil

  def any?(scope) when is_atom(scope) do
    map_size(route_paths(scope)) > 0
  end

  @doc false
  def clear_all do
    case manager() do
      pid when is_pid(pid) -> GenServer.call(pid, :clear_all)
      nil -> publish_all_empty()
    end
  end

  @impl true
  def init(_opts) do
    Enum.each(@known_scopes, &publish_scope(&1, %{}))
    {:ok, %{routes: %{}}}
  end

  @impl true
  def handle_call({:register, scope, logical_scene_id, path, token}, _from, state) do
    routes =
      state.routes
      |> Map.update(scope, %{logical_scene_id => {path, token}}, fn scope_routes ->
        Map.put(scope_routes, logical_scene_id, {path, token})
      end)

    publish_scope(scope, Map.fetch!(routes, scope))
    {:reply, :ok, %{state | routes: routes}}
  end

  def handle_call({:unregister, scope, logical_scene_id, token}, _from, state) do
    scope_routes = Map.get(state.routes, scope, %{})

    next_scope_routes =
      case Map.get(scope_routes, logical_scene_id) do
        {_path, ^token} -> Map.delete(scope_routes, logical_scene_id)
        _other -> scope_routes
      end

    routes =
      if map_size(next_scope_routes) == 0 do
        Map.delete(state.routes, scope)
      else
        Map.put(state.routes, scope, next_scope_routes)
      end

    publish_scope(scope, next_scope_routes)
    {:reply, :ok, %{state | routes: routes}}
  end

  def handle_call(:clear_all, _from, _state) do
    publish_all_empty()
    {:reply, :ok, %{routes: %{}}}
  end

  defp ensure_manager do
    case manager() do
      nil ->
        _ = Application.ensure_all_started(:beacon_server)
        manager()

      pid ->
        pid
    end
  end

  defp manager do
    Process.whereis(__MODULE__)
  end

  defp publish_scope(scope, scope_routes) do
    paths =
      Map.new(scope_routes, fn {logical_scene_id, {path, _token}} ->
        {logical_scene_id, path}
      end)

    :persistent_term.put({@routes_key, scope}, paths)
  end

  defp publish_all_empty do
    Enum.each(@known_scopes, &publish_scope(&1, %{}))
    :ok
  end

  defp route_paths(scope) do
    :persistent_term.get({@routes_key, scope}, %{})
  end

  defp logical_scene_id(%{} = fields) do
    fields
    |> Map.get(:logical_scene_id, Map.get(fields, "logical_scene_id"))
    |> normalize_scene_id()
  end

  defp normalize_scene_id(value) when is_integer(value) and value >= 0, do: value

  defp normalize_scene_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id >= 0 -> id
      _other -> nil
    end
  end

  defp normalize_scene_id(_value), do: nil
end
