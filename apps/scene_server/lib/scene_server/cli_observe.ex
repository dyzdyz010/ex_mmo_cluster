defmodule SceneServer.CliObserve do
  @moduledoc """
  Lightweight file-backed structured observe sink for the scene runtime.

  This module lets scene-side actors emit structured breadcrumbs for local
  automation and E2E inspection without coupling to a larger telemetry system.
  """

  @writer __MODULE__.Writer
  @writer_key {__MODULE__, :writer}

  @doc "Returns whether scene-side observe logging is enabled."
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
    Application.get_env(:scene_server, :cli_observe_log) ||
      System.get_env("SCENE_SERVER_OBSERVE_LOG")
  end

  defp ensure_writer(path) do
    case :persistent_term.get(@writer_key, nil) do
      %{pid: pid, path: ^path} when is_pid(pid) ->
        if Process.alive?(pid) do
          pid
        else
          start_or_refresh_writer(path)
        end

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
      {:noreply, state}
    rescue
      _ -> {:noreply, state}
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
