defmodule DataContact.Interface do
  use GenServer

  require Logger

  @beacon :"beacon1@127.0.0.1"
  @resource :data_contact
  @requirement []

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  @impl true
  def init(_init_arg) do
    :erlang.monitor_node(@beacon, true)
    {:ok, %{server_state: :waiting_node}, 0}
  end

  @impl true
  def handle_info(:timeout, state) do
    send(self(), :establish_links)
    {:noreply, state}
  end

  @impl true
  def handle_info(:establish_links, state) do
    Logger.info("===Starting data_store node initialization===", ansi_color: :blue)

    join_beacon()
    register_beacon()

    Logger.info("===Server initialization complete, server ready===", ansi_color: :blue)
    {:noreply, %{state | server_state: :ready}}
  end

  defp join_beacon() do
    Logger.info("Joining beacon...")

    if !Node.connect(@beacon) do
      Logger.emergency("Beacon node not up, exiting...")
      Application.stop(:data_store)
    end

    Logger.info("Joining beacon complete.", ansi_color: :green)
  end

  defp register_beacon() do
    Logger.info("Registering to beacon...")

    result =
      GenServer.call(
        {BeaconServer.Beacon, @beacon},
        {:register, {node(), __MODULE__, @resource, @requirement}}
      )

    if result != :ok do
      Logger.emergency("Register to beacon node failed: #{inspect(result)}\nExiting...")
      Application.stop(:data_store)
    end

    Logger.info("Registering to beacon complete", ansi_color: :green)
  end
end
