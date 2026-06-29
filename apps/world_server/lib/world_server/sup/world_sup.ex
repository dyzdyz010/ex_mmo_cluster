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
        # Phase A4-bis-cluster step 4 (segment 2a → 2c): start
        # SceneNodeRegistry + SceneNodeMonitor *before* MapLedger so
        # MapLedger.put_region can consult the registry from its very
        # first call. SceneNodeRegistry is the state, SceneNodeMonitor
        # sweeps it on `:nodedown`.
        {WorldServer.Voxel.SceneNodeRegistry, name: WorldServer.Voxel.SceneNodeRegistry},
        {WorldServer.Voxel.SceneNodeMonitor,
         name: WorldServer.Voxel.SceneNodeMonitor, registry: WorldServer.Voxel.SceneNodeRegistry},
        {
          WorldServer.Voxel.MapLedger,
          # 阶段2:接 per-region durable 目录。物化/续约把 region 行与写令牌**同事务**落库,
          # boot 时从目录重建 assignments/leases → 懒物化的 region 跨重启自愈(CELL-23)。
          name: WorldServer.Voxel.MapLedger,
          write_token_store: DataService.Voxel.WriteTokenStore,
          scene_node_registry: WorldServer.Voxel.SceneNodeRegistry,
          region_directory: DataService.Voxel.RegionDirectoryStore
        },
        world_pack_bootstrapper_child(),
        default_region_bootstrapper_child(),
        {WorldServer.Voxel.TransactionCoordinator,
         name: WorldServer.Voxel.TransactionCoordinator,
         persist_fn: DataService.Voxel.TransactionCoordinatorStore.persist_fn(DataService.Repo),
         load_fn: DataService.Voxel.TransactionCoordinatorStore.load_fn(DataService.Repo)},
        {WorldServer.Voxel.TransactionRecoveryWatcher,
         name: WorldServer.Voxel.TransactionRecoveryWatcher,
         coordinator: WorldServer.Voxel.TransactionCoordinator,
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

  defp world_pack_bootstrapper_child do
    opts = Application.get_env(:world_server, :world_pack_bootstrapper, [])

    if Keyword.get(opts, :enabled?, false) do
      {WorldServer.Voxel.WorldPackBootstrapper,
       Keyword.put_new(opts, :name, WorldServer.Voxel.WorldPackBootstrapper)}
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
