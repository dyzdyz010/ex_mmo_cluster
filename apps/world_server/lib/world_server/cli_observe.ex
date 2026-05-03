defmodule WorldServer.CliObserve do
  @moduledoc """
  File-backed structured observe sink for world-side voxel coordination.

  The world server owns the durable control-plane decisions for voxel regions,
  leases, and migrations. This sink keeps those decisions observable from CLI
  automation without coupling runtime code to a telemetry stack.
  """

  @writer __MODULE__.Writer
  @writer_key {__MODULE__, :writer}

  @doc "Returns whether world-side observe logging is enabled."
  def enabled?, do: not is_nil(path())

  @doc "Appends a structured observe event when logging is enabled."
  def emit(event, fields_or_fun \\ %{})

  def emit(event, fields_or_fun) do
    case path() do
      nil -> :ok
      _path -> emit_enabled(event, fields_or_fun)
    end
  end

  defp emit_enabled(event, fields_fun) when is_function(fields_fun, 0) and is_binary(event) do
    emit(event, fields_fun.())
  end

  defp emit_enabled(event, fields) when is_binary(event) and is_map(fields) do
    writer = ensure_writer(path())
    GenServer.cast(writer, {:write, event, fields})
  rescue
    _ -> :ok
  end

  defp path do
    Application.get_env(:world_server, :cli_observe_log) ||
      System.get_env("WORLD_SERVER_OBSERVE_LOG")
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
      %{pid: pid, path: ^path} when is_pid(pid) ->
        if Process.alive?(pid), do: pid, else: start_or_refresh_writer(path)

      _other ->
        start_or_refresh_writer(path)
    end
  end

  defp start_or_refresh_writer(path) do
    case Process.whereis(@writer) do
      nil ->
        {:ok, pid} = GenServer.start_link(@writer, path, name: @writer)
        :persistent_term.put(@writer_key, %{pid: pid, path: path})
        pid

      pid ->
        GenServer.call(pid, {:ensure_path, path})
        :persistent_term.put(@writer_key, %{pid: pid, path: path})
        pid
    end
  end
end
