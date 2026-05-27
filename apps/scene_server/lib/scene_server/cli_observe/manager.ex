defmodule SceneServer.CliObserve.Manager do
  @moduledoc false

  use GenServer

  alias SceneServer.CliObserve.Writer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def ensure_writer(path) when is_binary(path) do
    call_manager({:ensure_writer, path}, nil)
  end

  def writer_pid(path) when is_binary(path) do
    call_manager({:writer_pid, path}, nil)
  end

  def writer_count(path) when is_binary(path) do
    call_manager({:writer_count, path}, 0)
  end

  def stop_writer(path) when is_binary(path) do
    call_manager({:stop_writer, path}, :ok)
  end

  @impl true
  def init(_opts) do
    {:ok, %{writers: %{}, refs: %{}}}
  end

  @impl true
  def terminate(_reason, state) do
    stop_all_writers(state)
    :ok
  end

  @impl true
  def handle_call({:ensure_writer, path}, _from, state) do
    case fetch_live_writer(state, path) do
      {:ok, pid} ->
        {:reply, pid, state}

      {:error, state} ->
        {pid, state} = start_writer(path, state)
        {:reply, pid, state}
    end
  end

  def handle_call({:writer_pid, path}, _from, state) do
    case fetch_live_writer(state, path) do
      {:ok, pid} -> {:reply, pid, state}
      {:error, state} -> {:reply, nil, state}
    end
  end

  def handle_call({:writer_count, path}, _from, state) do
    case fetch_live_writer(state, path) do
      {:ok, _pid} -> {:reply, 1, state}
      {:error, state} -> {:reply, 0, state}
    end
  end

  def handle_call({:stop_writer, path}, _from, state) do
    case Map.pop(state.writers, path) do
      {nil, writers} ->
        {:reply, :ok, %{state | writers: writers}}

      {%{pid: pid, ref: ref}, writers} ->
        Process.demonitor(ref, [:flush])

        if Process.alive?(pid) do
          GenServer.stop(pid, :normal)
        end

        {:reply, :ok, %{state | refs: Map.delete(state.refs, ref), writers: writers}}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.refs, ref) do
      {nil, refs} ->
        {:noreply, %{state | refs: refs}}

      {path, refs} ->
        writers =
          case Map.get(state.writers, path) do
            %{ref: ^ref} -> Map.delete(state.writers, path)
            _other -> state.writers
          end

        {:noreply, %{state | refs: refs, writers: writers}}
    end
  end

  defp manager do
    Process.whereis(__MODULE__)
  end

  defp call_manager(message, fallback) do
    case manager() do
      nil -> fallback
      pid -> GenServer.call(pid, message)
    end
  catch
    :exit, _reason -> fallback
  end

  defp fetch_live_writer(state, path) do
    case Map.get(state.writers, path) do
      %{pid: pid, ref: ref} when is_pid(pid) ->
        if Process.alive?(pid) do
          {:ok, pid}
        else
          Process.demonitor(ref, [:flush])
          {:error, remove_writer(state, path, ref)}
        end

      _other ->
        {:error, state}
    end
  end

  defp start_writer(path, state) do
    {:ok, pid} = GenServer.start(Writer, path)
    ref = Process.monitor(pid)

    state =
      state
      |> put_in([:writers, path], %{pid: pid, ref: ref})
      |> put_in([:refs, ref], path)

    {pid, state}
  end

  defp remove_writer(state, path, ref) do
    %{state | refs: Map.delete(state.refs, ref), writers: Map.delete(state.writers, path)}
  end

  defp stop_all_writers(state) do
    Enum.each(state.writers, fn {_path, %{pid: pid, ref: ref}} ->
      try do
        Process.demonitor(ref, [:flush])

        if Process.alive?(pid) do
          GenServer.stop(pid, :normal)
        end
      catch
        :exit, _reason -> :ok
      end
    end)
  end
end
