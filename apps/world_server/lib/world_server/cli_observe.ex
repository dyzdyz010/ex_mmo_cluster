defmodule WorldServer.CliObserve do
  @moduledoc """
  File-backed structured observe sink for world-side voxel coordination.

  The world server owns the durable control-plane decisions for voxel regions,
  leases, and migrations. This sink keeps those decisions observable from CLI
  automation without coupling runtime code to a telemetry stack.
  """

  @writer __MODULE__.Writer
  @writer_key {__MODULE__, :writer}
  @route_scope :world_server

  @doc "Returns whether world-side observe logging is enabled."
  def enabled?, do: not is_nil(path()) or BeaconServer.CliObserveRoutes.any?(@route_scope)

  @doc "Routes observe events for one logical scene id to a concrete log path."
  def register_route(logical_scene_id, path) do
    BeaconServer.CliObserveRoutes.register(@route_scope, logical_scene_id, path)
  end

  @doc "Removes a logical-scene observe route created by `register_route/2`."
  def unregister_route(logical_scene_id, token) do
    BeaconServer.CliObserveRoutes.unregister(@route_scope, logical_scene_id, token)
  end

  @doc "Appends a structured observe event when logging is enabled."
  def emit(event, fields_or_fun \\ %{})

  def emit(event, fields_or_fun) do
    if enabled?() do
      emit_maybe_enabled(event, fields_or_fun)
    else
      :ok
    end
  end

  defp emit_maybe_enabled(event, fields_fun)
       when is_function(fields_fun, 0) and is_binary(event) do
    emit_maybe_enabled(event, fields_fun.())
  end

  defp emit_maybe_enabled(event, fields) when is_binary(event) and is_map(fields) do
    case path_for(fields) do
      nil ->
        :ok

      path ->
        writer = ensure_writer(path)
        GenServer.cast(writer, {:write, path, event, fields})
    end
  rescue
    _ -> :ok
  end

  defp path do
    Application.get_env(:world_server, :cli_observe_log) ||
      System.get_env("WORLD_SERVER_OBSERVE_LOG")
  end

  defp path_for(fields) do
    BeaconServer.CliObserveRoutes.lookup(@route_scope, fields) || path()
  end

  @doc "Blocks until the current writer has processed pending observe writes."
  def flush(timeout \\ 5_000) do
    case Process.whereis(@writer) do
      nil ->
        :ok

      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          _state = :sys.get_state(pid, timeout)
        end

        :ok
    end
  catch
    :exit, _reason -> :ok
  end

  defp ensure_writer(path) do
    case :persistent_term.get(@writer_key, nil) do
      %{pid: pid} when is_pid(pid) ->
        if Process.alive?(pid), do: pid, else: start_writer(path)

      _other ->
        start_writer(path)
    end
  end

  defp start_writer(path) do
    case Process.whereis(@writer) do
      nil ->
        case GenServer.start_link(@writer, path, name: @writer) do
          {:ok, pid} ->
            :persistent_term.put(@writer_key, %{pid: pid})
            pid

          {:error, {:already_started, pid}} when is_pid(pid) ->
            :persistent_term.put(@writer_key, %{pid: pid})
            pid
        end

      pid ->
        :persistent_term.put(@writer_key, %{pid: pid})
        pid
    end
  end
end
