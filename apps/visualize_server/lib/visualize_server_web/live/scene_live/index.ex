defmodule VisualizeServerWeb.SceneLive.Index do
  use VisualizeServerWeb, :live_view

  require Logger

  # alias VisualizeServer.World
  # alias VisualizeServer.World.Scene

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :data_update, 1000)

    {:ok, assign(socket, :data, [])}
  end

  @impl true
  def handle_info(:data_update, socket) do
    Logger.debug("#{inspect(socket.assigns, pretty: true)}")
    Process.send_after(self(), :data_update, 1000)

    {:noreply, push_event(socket, "data", %{
      characters: [%{
        cid: 1101,
        location: %{x: 5.0, y: 10.0}
      }]
    })}
  end

  # @impl true
  # def handle_params(params, _url, socket) do
  #   {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  # end

  # defp apply_action(socket, :edit, %{"id" => id}) do
  #   socket
  #   |> assign(:page_title, "Edit Scene")
  #   |> assign(:scene, World.get_scene!(id))
  # end

  # defp apply_action(socket, :new, _params) do
  #   socket
  #   |> assign(:page_title, "New Scene")
  #   |> assign(:scene, %Scene{})
  # end

  # defp apply_action(socket, :index, _params) do
  #   socket
  #   |> assign(:page_title, "Scene Visualizer")
  #   |> assign(:scene, nil)
  # end

  # @impl true
  # def handle_event("delete", %{"id" => id}, socket) do
  #   scene = World.get_scene!(id)
  #   {:ok, _} = World.delete_scene(scene)

  #   {:noreply, assign(socket, :scenes, list_scenes())}
  # end
end
