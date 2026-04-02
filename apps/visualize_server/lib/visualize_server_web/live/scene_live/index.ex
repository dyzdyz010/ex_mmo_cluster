defmodule VisualizeServerWeb.SceneLive.Index do
  use VisualizeServerWeb, :live_view

  @refresh_interval 1_000
  @scene_node :"scene1@127.0.0.1"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: schedule_refresh()

    {:ok,
     socket
     |> assign(:page_title, "Scene Visualizer")
     |> assign(:scene_node, Atom.to_string(@scene_node))
     |> assign(:characters, [])}
  end

  @impl true
  def handle_info(:data_update, socket) do
    schedule_refresh()
    characters = fetch_characters()

    {:noreply,
     socket
     |> assign(:characters, characters)
     |> push_event("data", %{characters: characters})}
  end

  defp schedule_refresh do
    Process.send_after(self(), :data_update, @refresh_interval)
  end

  defp fetch_characters do
    with true <- Node.alive?(),
         true <- connect_scene_node(),
         {:ok, players_map} <- fetch_players_map() do
      players_map
      |> Enum.map(&build_character/1)
      |> Enum.reject(&is_nil/1)
    else
      _ -> []
    end
  end

  defp connect_scene_node do
    case Node.connect(@scene_node) do
      true -> true
      :ignored -> true
      _ -> false
    end
  end

  defp fetch_players_map do
    case safe_call({SceneServer.PlayerManager, @scene_node}, :get_all_players) do
      {:ok, {:ok, players_map}} when is_map(players_map) -> {:ok, players_map}
      {:ok, players_map} when is_map(players_map) -> {:ok, players_map}
      _ -> {:error, :unavailable}
    end
  end

  defp build_character({cid, pid}) do
    case safe_call(pid, :get_location) do
      {:ok, {:ok, {x, y, _z}}} -> %{cid: cid, location: %{x: x, y: y}}
      {:ok, {x, y, _z}} -> %{cid: cid, location: %{x: x, y: y}}
      _ -> nil
    end
  end

  defp safe_call(server, message, timeout \\ 1_000) do
    try do
      {:ok, GenServer.call(server, message, timeout)}
    catch
      :exit, _reason -> {:error, :exit}
    end
  end
end
