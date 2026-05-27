defmodule SceneServer.CliObserve do
  @moduledoc """
  Lightweight file-backed structured observe sink for the scene runtime.

  This module lets scene-side actors emit structured breadcrumbs for local
  automation and E2E inspection without coupling to a larger telemetry system.
  """

  alias SceneServer.CliObserve.Manager

  @route_scope :scene_server

  @doc "Returns whether scene-side observe logging is enabled."
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
      nil -> :ok
      path -> emit_enabled(path, event, fields)
    end
  rescue
    _ -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp emit_enabled(path, event, fields) when is_binary(event) and is_map(fields) do
    case ensure_writer(path) do
      writer when is_pid(writer) -> GenServer.cast(writer, {:write, event, fields})
      _other -> :ok
    end
  end

  defp path do
    Application.get_env(:scene_server, :cli_observe_log) ||
      System.get_env("SCENE_SERVER_OBSERVE_LOG")
  end

  defp path_for(fields) do
    BeaconServer.CliObserveRoutes.lookup(@route_scope, fields) || path()
  end

  @doc "Blocks until the current writer has processed pending observe writes."
  def flush(timeout \\ 5_000) do
    case path() do
      nil ->
        :ok

      path ->
        do_flush_path(path, timeout)
    end
  end

  @doc "Blocks until the writer for `path` has processed pending observe writes."
  def flush_path(path, timeout \\ 5_000) when is_binary(path) do
    do_flush_path(path, timeout)
  end

  @doc false
  def writer_pid(path \\ path()) do
    if is_binary(path), do: Manager.writer_pid(path)
  end

  @doc false
  def writer_count(path) when is_binary(path) do
    Manager.writer_count(path)
  end

  @doc false
  def stop_writer(path) when is_binary(path) do
    Manager.stop_writer(path)
  end

  defp do_flush_path(path, timeout) do
    case writer_pid(path) do
      nil ->
        :ok

      pid ->
        _state = :sys.get_state(pid, timeout)
        :ok
    end
  catch
    :exit, _reason -> :ok
  end

  defp ensure_writer(path) do
    Manager.ensure_writer(path)
  end

  defmodule Writer do
    @moduledoc false
    use GenServer

    @idle_timeout_ms 5_000

    @impl true
    def init(path) do
      {:ok, %{path: path}, @idle_timeout_ms}
    end

    @impl true
    def handle_call({:ensure_path, path}, _from, state) do
      {:reply, :ok, %{state | path: path}, @idle_timeout_ms}
    end

    @impl true
    def handle_cast({:write, event, fields}, %{path: path} = state) do
      File.mkdir_p!(Path.dirname(path))

      line =
        [
          "ts=",
          DateTime.utc_now() |> DateTime.to_iso8601(),
          " source=",
          inspect("scene_server"),
          " event=",
          inspect(event),
          " fields=",
          inspect(scrub(fields), limit: :infinity, printable_limit: :infinity),
          "\n"
        ]
        |> IO.iodata_to_binary()

      File.write!(path, line, [:append])
      {:noreply, state, @idle_timeout_ms}
    rescue
      _ -> {:noreply, state, @idle_timeout_ms}
    end

    @impl true
    def handle_cast({:write, path, event, fields}, state) do
      handle_cast({:write, event, fields}, %{state | path: path})
    end

    @impl true
    def handle_info(:timeout, state) do
      {:stop, :normal, state}
    end

    defp scrub(fields) do
      Map.new(fields, fn {key, value} -> {key, scrub_value(value)} end)
    end

    defp scrub_value(value) when is_pid(value), do: inspect(value)
    defp scrub_value(value) when is_reference(value), do: inspect(value)
    defp scrub_value(value) when is_port(value), do: inspect(value)
    defp scrub_value(value) when is_tuple(value), do: inspect(value)
    defp scrub_value(value) when is_map(value), do: scrub(value)
    defp scrub_value(value) when is_list(value), do: Enum.map(value, &scrub_value/1)
    defp scrub_value(value), do: value
  end
end
