defmodule AuthServer.Interface do
  @moduledoc """
  Auth service registration + data_service node lookup.

  The auth runtime uses this process to:

  - register itself for cluster discovery
  - resolve the current `data_service` node used by `AuthServer.Accounts`

  In the single-container MVP `data_service` lives in the same BEAM, so the
  resolved node is just `node()`. The legacy `data_contact` (Mnesia routing)
  handshake has been removed — that whole layer is excluded from the release.
  """

  use GenServer
  require Logger

  @resource :auth_server

  @doc "Starts the auth interface process."
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  @impl true
  def init(_init_arg) do
    {:ok, %{data_service: nil, server_state: :waiting_requirements}, {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, state) do
    Logger.info("===Starting auth_server node initialization===", ansi_color: :blue)

    BeaconServer.Client.join_cluster()
    BeaconServer.Client.register(@resource)

    data_service_node = node()
    Logger.info("Found data_service at #{inspect(data_service_node)}", ansi_color: :green)

    Logger.info("===Server initialization complete, server ready===", ansi_color: :blue)

    {:noreply, %{state | data_service: data_service_node, server_state: :ready}}
  end

  @impl true
  def handle_call(:data_service, _from, state) do
    {:reply, state.data_service, state}
  end
end
