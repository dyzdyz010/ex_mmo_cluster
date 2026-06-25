defmodule WorldServer.Voxel.DefaultRegionBootstrapper do
  @moduledoc """
  Keeps the default browser-development voxel region prepared from the server side.

  This process is part of the World runtime lifecycle. It prepares the default
  region, renews its lease, and retries when Scene ownership is not ready yet.
  Browser clients can then enter the world and subscribe to chunk state without
  being responsible for creating or repairing the world first.
  """

  use GenServer

  alias WorldServer.CliObserve
  alias WorldServer.Voxel.DevSeed

  @default_retry_ms 1_000
  @default_refresh_ms :timer.minutes(30)

  @doc "Starts the default region bootstrapper."
  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  @doc "Returns current bootstrap status for tests and CLI-oriented probes."
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  end

  @impl true
  def init(opts) do
    enabled? = Keyword.get(opts, :enabled?, true)

    state = %{
      enabled?: enabled?,
      status: if(enabled?, do: :starting, else: :disabled),
      logical_scene_id: Keyword.get(opts, :logical_scene_id, 1),
      retry_ms: Keyword.get(opts, :retry_ms, @default_retry_ms),
      refresh_ms: Keyword.get(opts, :refresh_ms, @default_refresh_ms),
      # 阶段7-bis:出生点地形现在由 ChunkProcess 首触达懒 WorldGen 生成,bootstrapper 只
      # 预物化出生点 region(暖启,省掉首次订阅等物化),不再 bulk-seed 地形 → 冷启动不再
      # 背一次性 seed 的 DB I/O。设 seed_terrain?: true 可恢复旧 bulk-seed(默认关)。
      seed_terrain?: Keyword.get(opts, :seed_terrain?, false),
      seed_fun: Keyword.get(opts, :seed_fun, &DevSeed.ensure_default_region/1),
      attempts: 0,
      last_error: nil,
      last_summary: nil
    }

    if enabled? do
      {:ok, state, {:continue, :prepare}}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_continue(:prepare, state) do
    {:noreply, prepare_region(state)}
  end

  @impl true
  def handle_info(:prepare, state) do
    {:noreply, prepare_region(state)}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, Map.drop(state, [:seed_fun]), state}
  end

  defp prepare_region(%{enabled?: false} = state), do: state

  defp prepare_region(state) do
    attempts = state.attempts + 1
    opts = [logical_scene_id: state.logical_scene_id, seed_terrain?: state.seed_terrain?]

    case call_seed(state.seed_fun, opts) do
      {:ok, summary} ->
        next_state = %{
          state
          | status: :ready,
            attempts: attempts,
            last_error: nil,
            last_summary: summary
        }

        emit_ready(next_state)
        schedule_prepare(next_state.refresh_ms)
        next_state

      {:error, reason} ->
        next_state = %{
          state
          | status: :retrying,
            attempts: attempts,
            last_error: inspect(reason)
        }

        emit_retry(next_state, reason)
        schedule_prepare(next_state.retry_ms)
        next_state
    end
  end

  defp call_seed(seed_fun, opts) when is_function(seed_fun, 1) do
    seed_fun.(opts)
  catch
    :exit, reason -> {:error, {:seed_exit, reason}}
    kind, reason -> {:error, {kind, reason}}
  end

  defp schedule_prepare(:infinity), do: :ok

  defp schedule_prepare(ms) when is_integer(ms) and ms >= 0 do
    Process.send_after(self(), :prepare, ms)
    :ok
  end

  defp emit_ready(state) do
    CliObserve.emit("voxel_default_region_bootstrap_ready", %{
      logical_scene_id: state.logical_scene_id,
      attempts: state.attempts,
      status: inspect(state.status)
    })
  end

  defp emit_retry(state, reason) do
    CliObserve.emit("voxel_default_region_bootstrap_retry", %{
      logical_scene_id: state.logical_scene_id,
      attempts: state.attempts,
      reason: inspect(reason)
    })
  end
end
