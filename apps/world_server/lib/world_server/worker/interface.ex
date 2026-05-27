defmodule WorldServer.Interface do
  use GenServer
  require Logger

  @resource :world_server
  @retry_interval_ms 30_000

  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       scene_server: nil,
       data_service: nil,
       server_state: :waiting_requirements,
       retry_interval_ms: Keyword.get(opts, :retry_interval_ms, @retry_interval_ms),
       join_fun: Keyword.get(opts, :join_fun, &BeaconServer.Client.join_cluster/0),
       register_fun: Keyword.get(opts, :register_fun, &BeaconServer.Client.register/1),
       lookup_fun: Keyword.get(opts, :lookup_fun, &BeaconServer.Client.lookup/1)
     }, {:continue, :setup}}
  end

  @impl true
  def handle_continue(:setup, state) do
    Logger.info("===Starting world_server node initialization===", ansi_color: :blue)

    {:noreply, setup_dependencies(state)}
  end

  @impl true
  def handle_info(:retry_setup, state) do
    {:noreply, setup_dependencies(state)}
  end

  defp setup_dependencies(state) do
    state.join_fun.()
    state.register_fun.(@resource)
    state.register_fun.(:voxel_transaction_coordinator)

    scene_result = state.lookup_fun.(:scene_server)
    data_result = state.lookup_fun.(:data_service)

    case {scene_result, data_result} do
      {{:ok, scene_node}, {:ok, data_node}} ->
        Logger.info(
          "Found scene_server=#{inspect(scene_node)}, data_service=#{inspect(data_node)}",
          ansi_color: :green
        )

        Logger.info("===Server initialization complete, server ready===", ansi_color: :blue)
        %{state | scene_server: scene_node, data_service: data_node, server_state: :ready}

      _missing ->
        Logger.info(
          "world_server dependencies unavailable; missing=#{inspect(missing_dependencies(scene_result, data_result))}; retrying",
          ansi_color: :yellow
        )

        Process.send_after(self(), :retry_setup, state.retry_interval_ms)
        %{state | server_state: :waiting_requirements}
    end
  end

  defp missing_dependencies(scene_result, data_result) do
    []
    |> maybe_missing(:scene_server, scene_result)
    |> maybe_missing(:data_service, data_result)
    |> Enum.reverse()
  end

  defp maybe_missing(acc, _resource, {:ok, _node}), do: acc
  defp maybe_missing(acc, resource, _result), do: [resource | acc]
end
