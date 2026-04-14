defmodule SceneServer.Interface do
  @moduledoc """
  Scene service registration entrypoint.

  This process is intentionally small: it joins the service-discovery cluster
  and registers the scene node so gate/auth/demo tooling can locate it.
  """

  use GenServer
  require Logger

  @resource :scene_server

  @doc "Starts the scene service interface process."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  @impl true
  def init(_init_arg) do
    {:ok, %{server_state: :waiting_requirements}, {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, state) do
    Logger.info("===Starting scene_server node initialization===", ansi_color: :blue)

    BeaconServer.Client.join_cluster()
    BeaconServer.Client.register(@resource)

    Logger.info("===Server initialization complete, server ready===", ansi_color: :blue)
    {:noreply, %{state | server_state: :ready}}
  end
end
