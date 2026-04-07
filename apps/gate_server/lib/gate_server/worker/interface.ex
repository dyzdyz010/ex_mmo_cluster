defmodule GateServer.Interface do
  use GenServer

  require Logger

  @resource :gate_server
  @requirement [:scene_server]

  # 重试间隔：s
  @retry_rate 5

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, [], opts)
  end

  @impl true
  def init(_init_arg) do
    {:ok, %{scene_server: nil, auth_server: nil, server_state: :waiting_requirements}, 0}
  end

  @impl true
  def handle_info(:timeout, state) do
    # send(self(), :establish_links)
    {:noreply, state}
  end

  @impl true
  def handle_info(:establish_links, state) do
    Logger.info("===Starting #{Application.get_application(__MODULE__)} node initialization===", ansi_color: :blue)

    join_beacon()
    register_beacon()
    new_state = get_requirements(state)

    Logger.info("===Server initialization complete, server ready===", ansi_color: :blue)
    {:noreply, %{new_state | server_state: :ready}}
  end

  # ── Public API for TcpConnection to discover services ──

  @impl true
  def handle_call(:scene_server, _from, %{scene_server: scene} = state) do
    {:reply, scene, state}
  end

  @impl true
  def handle_call(:auth_server, _from, %{auth_server: auth} = state) do
    {:reply, auth, state}
  end

  # ── Private ──

  defp join_beacon() do
    Logger.info("Joining beacon...")

    case BeaconServer.Client.join_cluster() do
      :ok ->
        Logger.info("Joining beacon complete.", ansi_color: :green)

      :error ->
        Logger.emergency("Beacon node not up, exiting...")
        Application.stop(:gate_server)
    end
  end

  defp register_beacon() do
    Logger.info("Registering to beacon...")

    result = BeaconServer.Client.register(node(), __MODULE__, @resource, @requirement)

    if result != :ok do
      Logger.emergency("Register to beacon node failed: #{inspect(result)}\nExiting...")
      Application.stop(:gate_server)
    end

    Logger.info("Registering to beacon complete", ansi_color: :green)
  end

  defp get_requirements(state) do
    Logger.info("Getting requirements(#{inspect(@requirement)}) from beacon...")

    case BeaconServer.Client.get_requirements(node()) do
      {:ok, resources} ->
        new_state = resolve_resources(resources, state)

        Logger.info("Requirements resolved: scene_server=#{inspect(new_state.scene_server)}",
          ansi_color: :green
        )

        new_state

      {:err, nil} ->
        Logger.warning("Not meeting requirements, retrying in #{@retry_rate}s.")
        Process.sleep(@retry_rate * 1000)
        get_requirements(state)
    end
  end

  defp resolve_resources(resources, state) do
    Enum.reduce(resources, state, fn resource, acc ->
      case resource.name do
        :scene_server -> %{acc | scene_server: resource.node}
        :auth_server -> %{acc | auth_server: resource.node}
        _ -> acc
      end
    end)
  end
end
