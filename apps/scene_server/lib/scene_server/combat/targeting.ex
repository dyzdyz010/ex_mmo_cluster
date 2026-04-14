defmodule SceneServer.Combat.Targeting do
  @moduledoc """
  Shared combat targeting helpers built on top of AOI actor indexing.

  The important architectural boundary here is that targeting does not care
  whether a candidate is a player or an NPC. It asks the AOI system for nearby
  actor PIDs, then asks each actor for a normalized state summary. This keeps
  player-vs-player and player-vs-NPC combat on the same abstraction.
  """

  @type vector :: {float(), float(), float()}

  @spec nearby_combatant_pids(integer(), vector(), float()) :: [pid()]
  @doc """
  Returns nearby alive combat actor PIDs, excluding the provided source CID.
  """
  def nearby_combatant_pids(exclude_cid, origin, radius) do
    SceneServer.AoiManager.get_nearby_actor_pids(origin, radius, [exclude_cid])
    |> Enum.filter(fn pid ->
      case safe_summary(pid) do
        {:ok, %{position: location, alive: true}} -> within_radius?(origin, location, radius)
        _ -> false
      end
    end)
  end

  @spec safe_location(pid()) :: {:ok, vector()} | {:error, term()}
  @doc """
  Reads a normalized location from an actor that implements `:get_state_summary`.
  """
  def safe_location(pid) do
    with {:ok, summary} <- safe_summary(pid),
         %{position: location} <- summary do
      {:ok, location}
    else
      _ -> {:error, :invalid_summary}
    end
  end

  @spec safe_summary(pid()) :: {:ok, map()} | {:error, term()}
  @doc """
  Safely requests a normalized state summary from a combat-capable actor.
  """
  def safe_summary(pid) do
    try do
      case GenServer.call(pid, :get_state_summary) do
        {:ok, summary} when is_map(summary) -> {:ok, summary}
        other -> {:error, other}
      end
    catch
      :exit, reason -> {:error, reason}
    end
  end

  @spec safe_summary_by_cid(integer()) :: {:ok, map()} | {:error, term()}
  @doc """
  Resolves an actor by CID through the AOI index and then fetches its summary.
  """
  def safe_summary_by_cid(cid) when is_integer(cid) do
    case SceneServer.AoiManager.get_actor_pid(cid) do
      pid when is_pid(pid) -> safe_summary(pid)
      _ -> {:error, :unknown_actor}
    end
  end

  defp within_radius?({ax, ay, az}, {bx, by, bz}, radius) do
    dx = ax - bx
    dy = ay - by
    dz = az - bz
    :math.sqrt(dx * dx + dy * dy + dz * dz) <= radius
  end
end
