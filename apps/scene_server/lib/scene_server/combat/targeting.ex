defmodule SceneServer.Combat.Targeting do
  @type vector :: {float(), float(), float()}

  @spec nearby_player_pids(integer(), vector(), float()) :: [pid()]
  def nearby_player_pids(exclude_cid, origin, radius) do
    SceneServer.AoiManager.get_nearby_player_pids(origin, radius, [exclude_cid])
    |> Enum.filter(fn pid ->
      case safe_location(pid) do
        {:ok, location} -> within_radius?(origin, location, radius)
        _ -> false
      end
    end)
  end

  @spec safe_location(pid()) :: {:ok, vector()} | {:error, term()}
  def safe_location(pid) do
    try do
      case GenServer.call(pid, :get_location) do
        {:ok, location} -> {:ok, location}
        other -> {:error, other}
      end
    catch
      :exit, reason -> {:error, reason}
    end
  end

  defp within_radius?({ax, ay, az}, {bx, by, bz}, radius) do
    dx = ax - bx
    dy = ay - by
    dz = az - bz
    :math.sqrt(dx * dx + dy * dy + dz * dz) <= radius
  end
end
