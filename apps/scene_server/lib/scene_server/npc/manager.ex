defmodule SceneServer.Npc.Manager do
  @moduledoc """
  Registry/entrypoint for active NPC actors.

  `Npc.Manager` owns spawn-time indexing and lookup. It does not make decisions
  for NPCs; once spawned, each active NPC is driven by its own `Npc.Actor`
  process under `SceneServer.NpcActorSup`.
  """

  use GenServer

  alias SceneServer.Npc.{Actor, Profile}

  @npc_ready_attempts 40
  @npc_ready_sleep_ms 25

  @doc """
  Starts the active NPC registry process.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  @impl true
  def init(_init_arg) do
    {:ok, %{npcs: %{}}}
  end

  @impl true
  def handle_call({:spawn_npc, npc_id, opts}, _from, %{npcs: npcs} = state) do
    profile = Profile.default(npc_id, opts)

    with {:ok, npc_pid} <-
           DynamicSupervisor.start_child(
             SceneServer.NpcActorSup,
             {Actor, {profile, opts}}
           ),
         :ok <- await_npc_ready(npc_pid) do
      {:reply, {:ok, npc_pid}, %{state | npcs: Map.put_new(npcs, npc_id, npc_pid)}}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:get_all_npcs, _from, %{npcs: npcs} = state) do
    {:reply, {:ok, npcs}, state}
  end

  @impl true
  def handle_call({:get_npc, npc_id}, _from, %{npcs: npcs} = state) do
    {:reply, {:ok, Map.get(npcs, npc_id)}, state}
  end

  @impl true
  def handle_call(:get_all_npc_summaries, _from, %{npcs: npcs} = state) do
    summaries =
      npcs
      |> Enum.map(fn {npc_id, pid} ->
        case safe_summary(pid) do
          {:ok, summary} -> {npc_id, summary}
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Map.new()

    {:reply, {:ok, summaries}, state}
  end

  defp safe_summary(pid) when is_pid(pid) do
    try do
      case GenServer.call(pid, :get_state_summary) do
        {:ok, summary} when is_map(summary) -> {:ok, summary}
        other -> {:error, other}
      end
    catch
      :exit, reason -> {:error, reason}
    end
  end

  defp await_npc_ready(npc_pid, attempts \\ @npc_ready_attempts)
  defp await_npc_ready(_npc_pid, 0), do: {:error, :npc_not_ready}

  defp await_npc_ready(npc_pid, attempts) do
    try do
      case GenServer.call(npc_pid, :await_ready) do
        :ok ->
          :ok

        {:error, :not_ready} ->
          Process.sleep(@npc_ready_sleep_ms)
          await_npc_ready(npc_pid, attempts - 1)

        {:error, reason} ->
          {:error, reason}
      end
    catch
      :exit, reason -> {:error, reason}
    end
  end
end
