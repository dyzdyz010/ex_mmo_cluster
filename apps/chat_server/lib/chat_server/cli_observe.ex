defmodule ChatServer.CliObserve do
  @moduledoc """
  File-backed structured observe sink for the standalone chat runtime.

  Local smoke tasks and headless tests use this to inspect channel fan-out,
  skipped recipients, and history state without a GUI.
  """

  @writer __MODULE__.Writer
  @writer_key {__MODULE__, :writer}
  @route_scope :chat_server

  @doc "Returns whether chat observe logging is enabled."
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
    Application.get_env(:chat_server, :cli_observe_log) ||
      System.get_env("CHAT_SERVER_OBSERVE_LOG")
  end

  defp path_for(fields) do
    BeaconServer.CliObserveRoutes.lookup(@route_scope, fields) || path()
  end

  defp ensure_writer(path) do
    case :persistent_term.get(@writer_key, nil) do
      %{pid: pid} when is_pid(pid) ->
        if Process.alive?(pid) do
          pid
        else
          start_writer(path)
        end

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

  defmodule Writer do
    @moduledoc false
    use GenServer

    @impl true
    def init(path) do
      {:ok, %{path: path}}
    end

    @impl true
    def handle_call({:ensure_path, path}, _from, state) do
      {:reply, :ok, %{state | path: path}}
    end

    @impl true
    def handle_cast({:write, path, event, fields}, state) do
      write_line(path, event, fields)
      {:noreply, state}
    rescue
      _ -> {:noreply, state}
    end

    @impl true
    def handle_cast({:write, event, fields}, %{path: path} = state) do
      write_line(path, event, fields)
      {:noreply, state}
    rescue
      _ -> {:noreply, state}
    end

    defp write_line(path, event, fields) do
      File.mkdir_p!(Path.dirname(path))

      line =
        [
          "ts=",
          DateTime.utc_now() |> DateTime.to_iso8601(),
          " source=",
          inspect("chat_server"),
          " event=",
          inspect(event),
          " fields=",
          inspect(scrub(fields),
            limit: :infinity,
            printable_limit: :infinity,
            charlists: :as_lists
          ),
          "\n"
        ]
        |> IO.iodata_to_binary()

      File.write!(path, line, [:append])
    end

    defp scrub(fields) do
      Map.new(fields, fn {key, value} -> {key, scrub_value(value)} end)
    end

    defp scrub_value(value) when is_pid(value), do: inspect(value)
    defp scrub_value(value) when is_reference(value), do: inspect(value)
    defp scrub_value(value) when is_port(value), do: inspect(value)
    defp scrub_value(value) when is_tuple(value), do: inspect(value, charlists: :as_lists)
    defp scrub_value(value) when is_map(value), do: scrub(value)
    defp scrub_value(value) when is_list(value), do: Enum.map(value, &scrub_value/1)
    defp scrub_value(value), do: value
  end
end
