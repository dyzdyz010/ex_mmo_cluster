defmodule WorldServer.CliObserve.Writer do
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
        inspect("world_server"),
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
