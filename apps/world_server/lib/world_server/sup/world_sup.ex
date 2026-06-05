defmodule WorldServer.WorldSup do
  @moduledoc """
  This is the World Supervisor.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, [], opts)
  end

  def init(_init_arg) do
    children =
      [
        # 阶段4 / world-2pc-1:per-transaction driver 的进程身份注册表。driver 以
        # `{:transaction_driver, transaction_id}` 注册(`:unique`),via-tuple 进
        # start 参数,重启天然去重——boot sweep 和运行期 reaper 不会对同一笔事务
        # 拉起两个 driver。
        {Registry, keys: :unique, name: WorldServer.Voxel.TransactionDriverRegistry},
        # Phase A4-bis-cluster step 4 (segment 2a → 2c): start
        # SceneNodeRegistry + SceneNodeMonitor *before* MapLedger so
        # MapLedger.put_region can consult the registry from its very
        # first call.
        #
        # Phase 3 / S1 (process identity registration): region ownership is
        # durable. SceneNodeRegistry hydrates `join_order` / `region_assignments`
        # from Postgres on (re)start through
        # `DataService.Voxel.SceneNodeRegistryStore`, and SceneNodeMonitor then
        # reconciles those hydrated entries against the live node set before
        # taking over `:nodedown` sweeping. The Postgres row is the source of
        # truth; the GenServer state is a derived cache.
        {WorldServer.Voxel.SceneNodeRegistry,
         name: WorldServer.Voxel.SceneNodeRegistry,
         persist_fn: DataService.Voxel.SceneNodeRegistryStore.persist_fn(DataService.Repo),
         load_fn: DataService.Voxel.SceneNodeRegistryStore.load_fn(DataService.Repo)},
        {WorldServer.Voxel.SceneNodeMonitor,
         name: WorldServer.Voxel.SceneNodeMonitor, registry: WorldServer.Voxel.SceneNodeRegistry},
        {WorldServer.Voxel.MapLedger,
         name: WorldServer.Voxel.MapLedger,
         write_token_store: DataService.Voxel.WriteTokenStore,
         scene_node_registry: WorldServer.Voxel.SceneNodeRegistry},
        default_region_bootstrapper_child(),
        {WorldServer.Voxel.TransactionCoordinator,
         name: WorldServer.Voxel.TransactionCoordinator,
         persist_rows_fn:
           DataService.Voxel.TransactionCoordinatorStore.persist_rows_fn(DataService.Repo),
         load_fn: DataService.Voxel.TransactionCoordinatorStore.load_fn(DataService.Repo)},
        # 阶段4 / world-2pc-1:per-transaction driver 受监督进程的 DynamicSupervisor。
        # driver 崩溃由它重启,driver init 从 coordinator 持久状态续推。
        {WorldServer.Voxel.TransactionDriverSupervisor,
         name: WorldServer.Voxel.TransactionDriverSupervisor},
        # 阶段4 / world-2pc-2:boot sweep + 运行期周期 reaper + fence 对账。
        # scene_opts_resolver 既给 watcher resume 用,也给 driver dispatch 用。
        {WorldServer.Voxel.TransactionRecoveryWatcher,
         name: WorldServer.Voxel.TransactionRecoveryWatcher,
         coordinator: WorldServer.Voxel.TransactionCoordinator,
         driver_supervisor: WorldServer.Voxel.TransactionDriverSupervisor,
         scene_opts_resolver: &__MODULE__.default_scene_opts_resolver/1}
      ]
      |> Enum.reject(&is_nil/1)

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp default_region_bootstrapper_child do
    opts = Application.get_env(:world_server, :default_voxel_region_bootstrap, [])

    if Keyword.get(opts, :enabled?, false) do
      {WorldServer.Voxel.DefaultRegionBootstrapper,
       Keyword.put_new(opts, :name, WorldServer.Voxel.DefaultRegionBootstrapper)}
    end
  end

  @doc """
  Resolves `:scene_opts_by_participant` for the
  `WorldServer.Voxel.TransactionRecoveryWatcher` resume path by resolving
  **each participant's** Scene-owner node (Phase A4-bis-4 段 2d).

  Scene-owner participants carry `assigned_scene_node`. A `chunk_directory`
  target of `{SceneServer.Voxel.ChunkDirectory, scene_node}` is built per
  participant key. Missing `assigned_scene_node` is a hard routing error; the
  resolver does not infer ownership from region or lease fields.

  Returns:

  * `{:ok, executor_opts}` — every participant resolved and the map is keyed
    by `participant_key`.
  * `{:error, {:scene_unavailable, missing_keys}}` — one or more participants
    have no assigned scene_node. Watcher leaves the transaction parked and emits
    `voxel_transaction_recovery_scene_opts_unavailable`.
  """
  def default_scene_opts_resolver(participants) when is_list(participants),
    do: default_scene_opts_resolver(participants, [])

  @doc """
  Same as `default_scene_opts_resolver/1` but with injectable opts —
  The second argument is retained for call-site convenience in focused tests;
  resolver behavior is fully driven by participant data.
  """
  def default_scene_opts_resolver(participants, opts) when is_list(participants) do
    _opts = opts

    {pairs, missing} =
      Enum.reduce(participants, {[], []}, fn participant, {pairs, missing} ->
        case participant_scene_node(participant) do
          {:ok, scene_node} ->
            pair =
              {participant_key(participant),
               [chunk_directory: {SceneServer.Voxel.ChunkDirectory, scene_node}]}

            {[pair | pairs], missing}

          :error ->
            {pairs, [participant_key(participant) | missing]}
        end
      end)

    case missing do
      [] when pairs != [] ->
        {:ok, [scene_opts_by_participant: pairs |> Enum.reverse() |> Map.new()]}

      [] ->
        {:error, {:scene_unavailable, []}}

      _ ->
        {:error, {:scene_unavailable, Enum.reverse(missing)}}
    end
  end

  defp participant_scene_node(%{assigned_scene_node: scene_node})
       when not is_nil(scene_node),
       do: {:ok, scene_node}

  defp participant_scene_node(_participant), do: :error

  defp participant_key(%{participant_key: participant_key}) when not is_nil(participant_key),
    do: participant_key
end
