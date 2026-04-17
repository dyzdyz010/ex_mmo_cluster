defmodule VisualizeServerWeb.SceneLive.Index do
  @moduledoc """
  Live visualization of scene state by polling the remote `SceneServer.PlayerManager`.
  """

  use VisualizeServerWeb, :live_view

  require Logger

  @tick_interval 1_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :data_update, @tick_interval)

    scene_node = Application.get_env(:visualize_server, :scene_node, :"scene1@127.0.0.1")
    {:ok, assign(socket, page_title: "Scene Visualizer", scene_node: scene_node)}
  end

  @impl true
  def handle_info(:data_update, socket) do
    Process.send_after(self(), :data_update, @tick_interval)

    characters = fetch_characters(socket.assigns.scene_node)
    Logger.debug("characters: #{inspect(characters, pretty: true)}")

    {:noreply, push_event(socket, "data", %{characters: characters})}
  end

  defp fetch_characters(scene_node) do
    case safe_call({SceneServer.PlayerManager, scene_node}, :get_all_players) do
      {:ok, players_map} ->
        Enum.flat_map(players_map, fn {cid, pid} ->
          case safe_call(pid, :get_location) do
            {:ok, {x, y, _z}} -> [%{cid: cid, location: %{x: x, y: y}}]
            _ -> []
          end
        end)

      _ ->
        []
    end
  end

  defp safe_call(server, message) do
    try do
      GenServer.call(server, message, 500)
    catch
      :exit, _ -> :error
    end
  end
end
