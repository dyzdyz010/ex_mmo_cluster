defmodule WorldServer.Voxel.MapLedger do
  # PERS-5:durable_authoritative(region 所有权/lease/owner_epoch 单写者目录,持久化后端 MapLedgerStore)。见 MmoContracts.StateRegistry。
  use MmoContracts.StateClassed, class: :durable_authoritative

  @moduledoc """
  World-side authority for voxel region assignment, leases, and routing.

  This process is the control-plane owner for voxel region ownership. It does
  not hold full chunk truth and it does not run per-frame voxel rules. Its job is
  to decide which scene instance owns each region, publish write tokens to
  DataService, and build deterministic participant plans for cross-region
  transactions.
  """

  use GenServer

  alias WorldServer.CliObserve
  alias WorldServer.Voxel.LeaseWriteToken
  alias WorldServer.Voxel.MigrationPlan
  alias WorldServer.Voxel.RegionAssignment
  alias WorldServer.Voxel.RegionGrid
  alias WorldServer.Voxel.SceneLease
  alias WorldServer.Voxel.TransactionParticipant

  @default_lease_ttl_ms :timer.minutes(5)
  # Lazily-materialized regions (阶段1) get a long lease so a player exploring new
  # ground does not have its build lease expire mid-session. Proper lease renewal /
  # region GC is a durable-directory (阶段2) follow-up — renewing in place changes
  # lease_id/epoch and must be coordinated with the Scene's RegionRuntime, so it is
  # deliberately out of Phase-1 scope. Until then a TTL well beyond any single dev
  # session is the simplest correct mitigation (the world re-materializes fresh
  # leases on restart). See 阶段1 keystone review finding F4.
  @materialized_lease_ttl_ms :timer.hours(24)
  @migration_cutover_reason 0x01

  @doc "Starts the map ledger."
  def start_link(opts \\ []) do
    {server_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, server_opts)
  end

  @doc "Adds or replaces a region assignment in the world ledger."
  def put_region(server \\ __MODULE__, attrs) do
    GenServer.call(server, {:put_region, attrs})
  end

  @doc "Issues a lease for an existing region and publishes the DataService write token."
  def issue_lease(server \\ __MODULE__, region_id, owner_scene_instance_ref, opts \\ []) do
    GenServer.call(server, {:issue_lease, region_id, owner_scene_instance_ref, opts})
  end

  @doc "Moves a region to a new scene instance by issuing a fresh owner epoch and lease."
  def migrate_region(server \\ __MODULE__, region_id, target_scene_instance_ref, opts \\ []) do
    GenServer.call(server, {:migrate_region, region_id, target_scene_instance_ref, opts})
  end

  @doc """
  Begins a staged region migration without changing the current route or write lease.

  The returned plan contains the source Scene ref, target Scene ref, old lease,
  staged new lease, affected chunk bounds, and prewarm slice cursor. The new
  lease is only published to DataService during `cutover_migration/2`.
  """
  def begin_migration(server \\ __MODULE__, region_id, target_scene_instance_ref, opts \\ []) do
    GenServer.call(server, {:begin_migration, region_id, target_scene_instance_ref, opts})
  end

  @doc "Plans the next chunk-bound slice for a prewarming migration."
  def plan_next_migration_slice(server \\ __MODULE__, migration_id) do
    GenServer.call(server, {:plan_next_migration_slice, migration_id})
  end

  @doc "Marks a migration as prewarmed once the target Scene has loaded the handoff data."
  def mark_prewarmed(server \\ __MODULE__, migration_id) do
    GenServer.call(server, {:mark_prewarmed, migration_id})
  end

  @doc "Records one target Scene prewarm ACK for a planned migration slice."
  def mark_slice_prewarmed(server \\ __MODULE__, migration_id, attrs) do
    GenServer.call(server, {:mark_slice_prewarmed, migration_id, attrs})
  end

  @doc "Records one final catch-up ACK for a prewarmed migration slice."
  def mark_slice_final_caught_up(server \\ __MODULE__, migration_id, attrs) do
    GenServer.call(server, {:mark_slice_final_caught_up, migration_id, attrs})
  end

  @doc "Cuts over a prewarmed migration by publishing the new lease and changing route owner."
  def cutover_migration(server \\ __MODULE__, migration_id) do
    GenServer.call(server, {:cutover_migration, migration_id})
  end

  @doc "Completes a cutover migration; if called while prewarmed, it cuts over first."
  def complete_migration(server \\ __MODULE__, migration_id) do
    GenServer.call(server, {:complete_migration, migration_id})
  end

  @doc "Returns the current migration handoff payload for Scene adapters and CLI inspection."
  def migration_handoff(server \\ __MODULE__, migration_id) do
    GenServer.call(server, {:migration_handoff, migration_id})
  end

  @doc "Returns one migration plan from the ledger snapshot."
  def migration_snapshot(server \\ __MODULE__, migration_id) do
    GenServer.call(server, {:migration_snapshot, migration_id})
  end

  @doc "Routes a chunk coordinate to its current region assignment."
  def route_chunk(server \\ __MODULE__, logical_scene_id, chunk_coord) do
    GenServer.call(server, {:route_chunk, logical_scene_id, chunk_coord})
  end

  @doc "Routes a chunk coordinate and returns both the assignment and current lease."
  def route_chunk_with_lease(server \\ __MODULE__, logical_scene_id, chunk_coord) do
    GenServer.call(server, {:route_chunk_with_lease, logical_scene_id, chunk_coord})
  end

  @doc """
  Routes many chunk coordinates and returns each current assignment plus lease.

  This is the batch form Gate uses for prefab placement. It keeps World as the
  routing source of truth while avoiding one GenServer call per touched chunk.
  """
  def route_chunks_with_leases(server \\ __MODULE__, logical_scene_id, chunk_coords)
      when is_list(chunk_coords) do
    GenServer.call(server, {:route_chunks_with_leases, logical_scene_id, chunk_coords})
  end

  @doc """
  Routes a chunk, **lazily materializing** its grid region (assign Scene owner +
  monotonic epoch + lease) on a route miss, then returns the assignment and lease.

  This is the unbounded-world entry point (阶段1): unlike `route_chunk_with_lease/3`
  it never returns `:unassigned_chunk` for an in-grid chunk — it creates the region
  on demand. Gate's subscribe / edit path uses this so a player exploring new ground
  always has a routable, leased region. Materialization can still fail
  (`:scene_node_unassigned` when no Scene node is registered, or a write-token CAS
  error) — those are surfaced as `{:error, reason}`.
  """
  def route_chunk_with_lease_ensuring(server \\ __MODULE__, logical_scene_id, chunk_coord) do
    GenServer.call(server, {:route_chunk_with_lease_ensuring, logical_scene_id, chunk_coord})
  end

  @doc """
  Batch form of `route_chunk_with_lease_ensuring/3` for prefab / multi-chunk edits:
  materializes every touched chunk's region as needed and returns a coord→{assignment,
  lease} map, or `{:error, {chunk_coord, reason}}` for the first chunk that fails to
  materialize.
  """
  def route_chunks_with_leases_ensuring(server \\ __MODULE__, logical_scene_id, chunk_coords)
      when is_list(chunk_coords) do
    GenServer.call(server, {:route_chunks_with_leases_ensuring, logical_scene_id, chunk_coords})
  end

  @doc "Validates that a proposed scene write matches the current world lease."
  def validate_write(server \\ __MODULE__, attrs) do
    GenServer.call(server, {:validate_write, normalize_write(attrs)})
  end

  @doc """
  Builds Scene-owner transaction participants for affected chunks.

  Participants are keyed by the assigned Scene node, while each affected chunk
  records its real `{region_id, lease_id}` owner in `chunk_owners`.
  """
  def transaction_participants(server \\ __MODULE__, logical_scene_id, affected_chunks) do
    GenServer.call(server, {:transaction_participants, logical_scene_id, affected_chunks})
  end

  @doc "Returns a full ledger snapshot for CLI/debug inspection."
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  end

  @impl true
  def init(opts) do
    persistence_path = Keyword.get(opts, :persistence_path)

    # 阶段2:per-region durable 目录后端(DataService.Voxel.RegionDirectoryStore 或 nil)。
    # 设置即开启"物化/续约/迁移 → 每 region 一行落库"(scale-first,O(1) per change)+
    # boot 时从目录重建 assignments/leases(重启自愈)。nil = 纯内存(多数测试)。
    region_directory = Keyword.get(opts, :region_directory)
    region_directory_opts = Keyword.get(opts, :region_directory_opts, [])

    persist_fn =
      Keyword.get(opts, :persist_fn) ||
        if persistence_path, do: file_persist_fn(persistence_path)

    load_fn =
      Keyword.get(opts, :load_fn) ||
        directory_load_fn(region_directory, region_directory_opts) ||
        if persistence_path, do: file_load_fn(persistence_path)

    base = %{
      assignments: %{},
      leases: %{},
      chunk_summaries: %{},
      migrations: %{},
      write_token_store: Keyword.get(opts, :write_token_store),
      # 梯队1 step1.3:owner_epoch 经 DB 线性化分配器分配(CELL-18/23,消除 ANTI-32)。
      # 可注入(测试覆盖);默认 DataService.Voxel.RegionEpochStore。
      region_epoch_store:
        Keyword.get(opts, :region_epoch_store, DataService.Voxel.RegionEpochStore),
      persist_fn: persist_fn,
      scene_invalidator: Keyword.get(opts, :scene_invalidator),
      # Optional handle to WorldServer.Voxel.SceneNodeRegistry. Production
      # wiring sets it so put_region stores a concrete Scene owner on the
      # RegionAssignment. Without a registry, callers must provide
      # :assigned_scene_node explicitly.
      scene_node_registry: Keyword.get(opts, :scene_node_registry),
      # 阶段1:隐式分区格点。route miss → 懒物化一个 grid-aligned region,世界因此无界。
      # 默认 RegionGrid.default()(Sx=Sz=8, Sy=64,待压测);可注入做按 logical_scene 配置。
      region_grid: Keyword.get(opts, :region_grid, RegionGrid.default()),
      # owner_scene_instance_ref stamped on lazily-materialized leases. The scene
      # side reads owner identity from the published write token (never hardcodes
      # it), so any stable value is self-consistent; 1 matches the dev convention.
      materialize_owner_scene_instance_ref:
        Keyword.get(opts, :materialize_owner_scene_instance_ref, 1),
      region_directory: region_directory,
      region_directory_opts: region_directory_opts
    }

    case run_load(load_fn) do
      {:ok, restored} ->
        {:ok, Map.merge(base, restored)}

      {:error, reason} ->
        CliObserve.emit("voxel_map_ledger_persist_load_failed", fn ->
          %{reason: inspect(reason)}
        end)

        {:ok, base}
    end
  end

  @impl true
  def handle_call(message, from, state) do
    case do_handle_call(message, from, state) do
      {:reply, _reply, ^state} = ret ->
        ret

      {:reply, reply, next_state} ->
        case maybe_persist_state(next_state) do
          :ok ->
            {:reply, reply, next_state}

          {:error, reason} ->
            CliObserve.emit("voxel_map_ledger_persist_failed", fn ->
              %{reason: inspect(reason)}
            end)

            {:reply, reply, next_state}
        end
    end
  end

  defp do_handle_call({:put_region, attrs}, _from, state) do
    with {:ok, assignment} <-
           attrs
           |> RegionAssignment.new()
           |> maybe_assign_scene_node(state),
         :ok <- validate_region_bounds_available(state, assignment) do
      key = assignment.region_id

      CliObserve.emit("voxel_region_put", fn ->
        Map.take(Map.from_struct(assignment), [
          :logical_scene_id,
          :region_id,
          :owner_scene_instance_ref,
          :owner_epoch,
          :assigned_scene_node,
          :state
        ])
      end)

      # 阶段2:把显式 region 也写进 durable 目录(此时通常尚无 lease → 行的 lease_id/expires
      # 为 nil,后续 issue_lease 再原子更新)。物化路径不走这里(走 issue_lease 的原子发布)。
      _ = persist_region_row(state, assignment, Map.get(state.leases, key))

      {:reply, {:ok, assignment}, put_in(state.assignments[key], assignment)}
    else
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      {:error, reason, conflicting_assignment} ->
        assignment = RegionAssignment.new(attrs)

        CliObserve.emit("voxel_region_put_rejected", fn ->
          %{
            reason: reason,
            logical_scene_id: assignment.logical_scene_id,
            region_id: assignment.region_id,
            bounds_chunk_min: coord_list(assignment.bounds_chunk_min),
            bounds_chunk_max: coord_list(assignment.bounds_chunk_max),
            conflicting_region_id: conflicting_assignment.region_id,
            conflicting_bounds_chunk_min: coord_list(conflicting_assignment.bounds_chunk_min),
            conflicting_bounds_chunk_max: coord_list(conflicting_assignment.bounds_chunk_max)
          }
        end)

        {:reply, {:error, reason}, state}
    end
  end

  defp do_handle_call({:issue_lease, region_id, owner_scene_instance_ref, opts}, _from, state) do
    case Map.fetch(state.assignments, region_id) do
      {:ok, assignment} ->
        {reply, next_state} =
          issue_lease_for_assignment(state, assignment, owner_scene_instance_ref, opts)

        {:reply, reply, next_state}

      :error ->
        {:reply, {:error, :unknown_region}, state}
    end
  end

  defp do_handle_call({:migrate_region, region_id, target_scene_instance_ref, opts}, _from, state) do
    {reply, next_state} =
      migrate_region_in_state(state, region_id, target_scene_instance_ref, opts)

    {:reply, reply, next_state}
  end

  defp do_handle_call(
         {:begin_migration, region_id, target_scene_instance_ref, opts},
         _from,
         state
       ) do
    {reply, next_state} =
      begin_migration_in_state(state, region_id, target_scene_instance_ref, opts)

    {:reply, reply, next_state}
  end

  defp do_handle_call({:plan_next_migration_slice, migration_id}, _from, state) do
    {reply, next_state} = plan_next_migration_slice_in_state(state, migration_id)
    {:reply, reply, next_state}
  end

  defp do_handle_call({:mark_prewarmed, migration_id}, _from, state) do
    {reply, next_state} = mark_prewarmed_in_state(state, migration_id)
    {:reply, reply, next_state}
  end

  defp do_handle_call({:mark_slice_prewarmed, migration_id, attrs}, _from, state) do
    {reply, next_state} = mark_slice_prewarmed_in_state(state, migration_id, attrs)
    {:reply, reply, next_state}
  end

  defp do_handle_call({:mark_slice_final_caught_up, migration_id, attrs}, _from, state) do
    {reply, next_state} = mark_slice_final_caught_up_in_state(state, migration_id, attrs)
    {:reply, reply, next_state}
  end

  defp do_handle_call({:cutover_migration, migration_id}, _from, state) do
    {reply, next_state} = cutover_migration_in_state(state, migration_id)
    {:reply, reply, next_state}
  end

  defp do_handle_call({:complete_migration, migration_id}, _from, state) do
    {reply, next_state} = complete_migration_in_state(state, migration_id)
    {:reply, reply, next_state}
  end

  defp do_handle_call({:migration_handoff, migration_id}, _from, state) do
    reply =
      with {:ok, plan} <- fetch_migration(state, migration_id) do
        handoff = MigrationPlan.handoff(plan)

        CliObserve.emit("voxel_migration_handoff_read", fn ->
          migration_handoff_summary(handoff)
        end)

        {:ok, handoff}
      end

    {:reply, reply, state}
  end

  defp do_handle_call({:migration_snapshot, migration_id}, _from, state) do
    {:reply, fetch_migration(state, migration_id), state}
  end

  defp do_handle_call({:route_chunk, logical_scene_id, chunk_coord}, _from, state) do
    {:reply, route_chunk_in_state(state, logical_scene_id, chunk_coord), state}
  end

  defp do_handle_call({:route_chunk_with_lease, logical_scene_id, chunk_coord}, _from, state) do
    reply =
      with {:ok, assignment} <- route_chunk_in_state(state, logical_scene_id, chunk_coord),
           {:ok, lease} <- fetch_region_lease(state, assignment.region_id) do
        {:ok, %{assignment: assignment, lease: lease}}
      end

    {:reply, reply, state}
  end

  defp do_handle_call({:route_chunks_with_leases, logical_scene_id, chunk_coords}, _from, state) do
    reply =
      chunk_coords
      |> Enum.uniq()
      |> Enum.reduce_while({:ok, %{}}, fn chunk_coord, {:ok, acc} ->
        with {:ok, assignment} <- route_chunk_in_state(state, logical_scene_id, chunk_coord),
             {:ok, lease} <- fetch_region_lease(state, assignment.region_id) do
          {:cont, {:ok, Map.put(acc, chunk_coord, %{assignment: assignment, lease: lease})}}
        else
          {:error, reason} -> {:halt, {:error, {chunk_coord, reason}}}
        end
      end)

    {:reply, reply, state}
  end

  defp do_handle_call({:route_chunk_with_lease_ensuring, logical_scene_id, chunk_coord}, _from, state) do
    {reply, next_state} =
      case route_or_materialize(state, logical_scene_id, chunk_coord) do
        {:ok, assignment, st} ->
          case fetch_region_lease(st, assignment.region_id) do
            {:ok, lease} -> {{:ok, %{assignment: assignment, lease: lease}}, st}
            {:error, reason} -> {{:error, reason}, st}
          end

        {:error, reason, st} ->
          {{:error, reason}, st}
      end

    {:reply, reply, next_state}
  end

  defp do_handle_call(
         {:route_chunks_with_leases_ensuring, logical_scene_id, chunk_coords},
         _from,
         state
       ) do
    {reply, next_state} =
      chunk_coords
      |> Enum.uniq()
      |> Enum.reduce_while({%{}, state}, fn chunk_coord, {acc, st} ->
        case route_or_materialize(st, logical_scene_id, chunk_coord) do
          {:ok, assignment, st1} ->
            case fetch_region_lease(st1, assignment.region_id) do
              {:ok, lease} ->
                {:cont, {Map.put(acc, chunk_coord, %{assignment: assignment, lease: lease}), st1}}

              {:error, reason} ->
                {:halt, {{:error, {chunk_coord, reason}}, st1}}
            end

          {:error, reason, st1} ->
            {:halt, {{:error, {chunk_coord, reason}}, st1}}
        end
      end)
      |> case do
        {%{} = routes, st} -> {{:ok, routes}, st}
        {{:error, _} = error, st} -> {error, st}
      end

    {:reply, reply, next_state}
  end

  defp do_handle_call({:validate_write, write}, _from, state) do
    {:reply, validate_write_in_state(state, write), state}
  end

  defp do_handle_call(
         {:transaction_participants, logical_scene_id, affected_chunks},
         _from,
         state
       ) do
    {:reply, participants_for_chunks(state, logical_scene_id, affected_chunks), state}
  end

  defp do_handle_call(:snapshot, _from, state) do
    {:reply, state, state}
  end

  # 梯队1 step1.3(CELL-18/23):owner_epoch 经 DB 线性化分配器分配,使并发/重启的多 MapLedger
  # 无法分配冲突或回退的 epoch。opts 显式 owner_epoch(测试/回放)作为 floor,但**最终用的是
  # set_floor 生效后的 epoch = GREATEST(DB, explicit)**,而非原始 explicit:若 DB epoch 已抬过
  # (跨重启/迁移/并发),返回 stale explicit 会破坏 owner_epoch/token_version 单调性 →
  # publish_write_token 的 CAS 判 `:stale_token` → issue_lease 永久失败 / region_without_lease。
  # (这正是 DevSeed / voxel_smoke pin owner_epoch 触发 :stale_token 那一类的根因——此前靠"不 pin"
  # 绕过,这里修根因:pin 也安全,单调性恒成立。)
  defp allocate_owner_epoch(state, opts, logical_scene_id, region_id) do
    case Keyword.get(opts, :owner_epoch) do
      nil ->
        state.region_epoch_store.allocate_next(logical_scene_id, region_id)

      explicit when is_integer(explicit) ->
        state.region_epoch_store.set_floor(logical_scene_id, region_id, explicit)
    end
  end

  defp issue_lease_for_assignment(state, assignment, owner_scene_instance_ref, opts) do
    owner_epoch =
      allocate_owner_epoch(state, opts, assignment.logical_scene_id, assignment.region_id)

    lease_id = Keyword.get(opts, :lease_id, unique_positive_integer())
    ttl_ms = Keyword.get(opts, :ttl_ms, @default_lease_ttl_ms)
    expires_at_ms = Keyword.get(opts, :expires_at_ms, now_ms() + ttl_ms)
    token_version = Keyword.get(opts, :token_version, owner_epoch)
    assignment_state = Keyword.get(opts, :state, assignment.state)

    next_assignment = %{
      assignment
      | owner_scene_instance_ref: owner_scene_instance_ref,
        owner_epoch: owner_epoch,
        lease_id: lease_id,
        state: assignment_state,
        version: assignment.version + 1
    }

    lease = SceneLease.from_assignment(next_assignment, lease_id, expires_at_ms)
    token = LeaseWriteToken.from_lease(lease, token_version)

    # 阶段2 / 评审 F3:写令牌发布 + region 目录行落库走**同一事务边界**(原子),so a
    # crash/disk error after publishing the token cannot leave the client believing
    # the region is leased while the durable directory lost it.
    case publish_region_authority(state, next_assignment, lease, token) do
      :ok ->
        next_state =
          state
          |> put_in([:assignments, next_assignment.region_id], next_assignment)
          |> put_in([:leases, next_assignment.region_id], lease)

        CliObserve.emit("voxel_lease_issued", fn ->
          %{
            logical_scene_id: lease.logical_scene_id,
            region_id: lease.region_id,
            lease_id: lease.lease_id,
            owner_scene_instance_ref: lease.owner_scene_instance_ref,
            owner_epoch: lease.owner_epoch,
            token_version: token.token_version
          }
        end)

        {{:ok, lease}, next_state}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp migrate_region_in_state(state, region_id, target_scene_instance_ref, opts) do
    opts = Keyword.put_new_lazy(opts, :migration_id, fn -> default_migration_id(region_id) end)

    {begin_reply, state} =
      begin_migration_in_state(state, region_id, target_scene_instance_ref, opts)

    case begin_reply do
      {:ok, plan} ->
        with {:ok, _planned_plan, state} <- plan_all_slices_for_migrate(state, plan.migration_id),
             {:ok, _acked_plan, state} <-
               mark_all_slices_prewarmed_for_migrate(state, plan.migration_id),
             {:ok, _prewarmed_plan, state} <- mark_prewarmed_for_migrate(state, plan.migration_id),
             {:ok, _caught_up_plan, state} <-
               mark_all_slices_final_caught_up_for_migrate(state, plan.migration_id),
             {:ok, _cutover_plan, state} <- cutover_for_migrate(state, plan.migration_id),
             {:ok, completed_plan, state} <- complete_for_migrate(state, plan.migration_id) do
          {{:ok, completed_plan.new_lease}, state}
        else
          {:error, reason, state} -> {{:error, reason}, state}
        end

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp plan_all_slices_for_migrate(state, migration_id) do
    case fetch_migration(state, migration_id) do
      {:ok, %MigrationPlan{next_slice_index: index, total_slices: total} = plan}
      when index >= total ->
        {:ok, plan, state}

      {:ok, %MigrationPlan{}} ->
        case plan_next_migration_slice_in_state(state, migration_id) do
          {{:ok, _slice}, next_state} -> plan_all_slices_for_migrate(next_state, migration_id)
          {{:error, reason}, next_state} -> {:error, reason, next_state}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp mark_all_slices_prewarmed_for_migrate(state, migration_id) do
    case fetch_migration(state, migration_id) do
      {:ok, plan} ->
        Enum.reduce_while(plan.planned_slices, {:ok, state, nil}, fn slice,
                                                                     {:ok, acc_state, _last} ->
          attrs = %{
            slice_id: slice.slice_id,
            scene_ref: plan.target_scene_instance_ref,
            loaded_count: 0,
            empty_count: 0,
            max_chunk_version: 0
          }

          case mark_slice_prewarmed_in_state(acc_state, migration_id, attrs) do
            {{:ok, next_plan, _slice}, next_state} -> {:cont, {:ok, next_state, next_plan}}
            {{:error, reason}, next_state} -> {:halt, {:error, reason, next_state}}
          end
        end)
        |> case do
          {:ok, next_state, nil} -> {:ok, plan, next_state}
          {:ok, next_state, next_plan} -> {:ok, next_plan, next_state}
          {:error, reason, next_state} -> {:error, reason, next_state}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp mark_prewarmed_for_migrate(state, migration_id) do
    case mark_prewarmed_in_state(state, migration_id) do
      {{:ok, plan}, next_state} -> {:ok, plan, next_state}
      {{:error, reason}, next_state} -> {:error, reason, next_state}
    end
  end

  defp mark_all_slices_final_caught_up_for_migrate(state, migration_id) do
    case fetch_migration(state, migration_id) do
      {:ok, plan} ->
        Enum.reduce_while(plan.planned_slices, {:ok, state, nil}, fn slice,
                                                                     {:ok, acc_state, _last} ->
          attrs = %{
            slice_id: slice.slice_id,
            scene_ref: plan.target_scene_instance_ref,
            loaded_count: 0,
            empty_count: 0,
            max_chunk_version: 0,
            source_persisted_count: 0,
            source_missing_count: 0,
            source_error_count: 0
          }

          case mark_slice_final_caught_up_in_state(acc_state, migration_id, attrs) do
            {{:ok, next_plan, _slice}, next_state} -> {:cont, {:ok, next_state, next_plan}}
            {{:error, reason}, next_state} -> {:halt, {:error, reason, next_state}}
          end
        end)
        |> case do
          {:ok, next_state, nil} -> {:ok, plan, next_state}
          {:ok, next_state, next_plan} -> {:ok, next_plan, next_state}
          {:error, reason, next_state} -> {:error, reason, next_state}
        end

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp cutover_for_migrate(state, migration_id) do
    case cutover_migration_in_state(state, migration_id) do
      {{:ok, plan}, next_state} -> {:ok, plan, next_state}
      {{:error, reason}, next_state} -> {:error, reason, next_state}
    end
  end

  defp complete_for_migrate(state, migration_id) do
    case complete_migration_in_state(state, migration_id) do
      {{:ok, plan}, next_state} -> {:ok, plan, next_state}
      {{:error, reason}, next_state} -> {:error, reason, next_state}
    end
  end

  defp begin_migration_in_state(state, region_id, target_scene_instance_ref, opts) do
    with {:ok, assignment} <- fetch_region_assignment(state, region_id),
         :ok <- ensure_no_active_migration(state, region_id) do
      old_lease = Map.get(state.leases, region_id)
      now_ms = now_ms()
      _ = old_lease
      owner_epoch = allocate_owner_epoch(state, opts, assignment.logical_scene_id, region_id)
      lease_id = Keyword.get(opts, :lease_id, unique_positive_integer())
      ttl_ms = Keyword.get(opts, :ttl_ms, @default_lease_ttl_ms)
      expires_at_ms = Keyword.get(opts, :expires_at_ms, now_ms + ttl_ms)
      token_version = Keyword.get(opts, :token_version, owner_epoch)

      migration_id =
        Keyword.get_lazy(opts, :migration_id, fn -> default_migration_id(region_id) end)

      target_assignment = %{
        assignment
        | owner_scene_instance_ref: target_scene_instance_ref,
          owner_epoch: owner_epoch,
          lease_id: lease_id,
          state: :active,
          version: assignment.version + 1
      }

      new_lease = SceneLease.from_assignment(target_assignment, lease_id, expires_at_ms)

      plan =
        MigrationPlan.new(%{
          migration_id: migration_id,
          logical_scene_id: assignment.logical_scene_id,
          region_id: assignment.region_id,
          source_scene_instance_ref: assignment.owner_scene_instance_ref,
          target_scene_instance_ref: target_scene_instance_ref,
          old_lease: old_lease,
          new_lease: new_lease,
          affected_chunk_min: Keyword.get(opts, :affected_chunk_min, assignment.bounds_chunk_min),
          affected_chunk_max: Keyword.get(opts, :affected_chunk_max, assignment.bounds_chunk_max),
          token_version: token_version,
          inserted_at_ms: now_ms,
          updated_at_ms: now_ms,
          slice_axis: Keyword.get(opts, :slice_axis, :x),
          slice_width: Keyword.get(opts, :slice_width, 1)
        })

      next_state = put_in(state.migrations[plan.migration_id], plan)

      CliObserve.emit("voxel_migration_begun", fn -> MigrationPlan.summary(plan) end)

      {{:ok, plan}, next_state}
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp plan_next_migration_slice_in_state(state, migration_id) do
    with {:ok, plan} <- fetch_migration(state, migration_id),
         {:ok, slice, next_plan} <- MigrationPlan.plan_next_slice(plan, now_ms()) do
      next_state = put_in(state.migrations[migration_id], next_plan)

      CliObserve.emit("voxel_migration_slice_planned", fn ->
        %{
          migration_id: next_plan.migration_id,
          logical_scene_id: next_plan.logical_scene_id,
          region_id: next_plan.region_id,
          state: next_plan.state,
          source_scene_instance_ref: next_plan.source_scene_instance_ref,
          target_scene_instance_ref: next_plan.target_scene_instance_ref,
          slice: MigrationPlan.slice_summary(slice)
        }
      end)

      {{:ok, slice}, next_state}
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp mark_slice_prewarmed_in_state(state, migration_id, attrs) do
    now_ms = now_ms()

    with {:ok, plan} <- fetch_migration(state, migration_id),
         {:ok, attrs} <- put_ack_time(attrs, now_ms),
         {:ok, next_plan, slice} <- MigrationPlan.mark_slice_prewarmed(plan, attrs, now_ms) do
      next_state = put_in(state.migrations[migration_id], next_plan)

      CliObserve.emit("voxel_migration_slice_prewarmed", fn ->
        %{
          migration_id: next_plan.migration_id,
          logical_scene_id: next_plan.logical_scene_id,
          region_id: next_plan.region_id,
          state: next_plan.state,
          source_scene_instance_ref: next_plan.source_scene_instance_ref,
          target_scene_instance_ref: next_plan.target_scene_instance_ref,
          slice: MigrationPlan.slice_summary(slice),
          prewarm_ack_count: map_size(next_plan.prewarm_acks),
          total_slices: next_plan.total_slices
        }
      end)

      {{:ok, next_plan, slice}, next_state}
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp mark_slice_final_caught_up_in_state(state, migration_id, attrs) do
    now_ms = now_ms()

    with {:ok, plan} <- fetch_migration(state, migration_id),
         {:ok, attrs} <- put_final_catchup_ack_time(attrs, now_ms),
         {:ok, next_plan, slice} <-
           MigrationPlan.mark_slice_final_caught_up(plan, attrs, now_ms) do
      next_state = put_in(state.migrations[migration_id], next_plan)

      CliObserve.emit("voxel_migration_slice_final_caught_up", fn ->
        %{
          migration_id: next_plan.migration_id,
          logical_scene_id: next_plan.logical_scene_id,
          region_id: next_plan.region_id,
          state: next_plan.state,
          source_scene_instance_ref: next_plan.source_scene_instance_ref,
          target_scene_instance_ref: next_plan.target_scene_instance_ref,
          slice: MigrationPlan.slice_summary(slice),
          final_catchup_ack_count: map_size(next_plan.final_catchup_acks),
          total_slices: next_plan.total_slices
        }
      end)

      {{:ok, next_plan, slice}, next_state}
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp put_ack_time(attrs, now_ms) when is_map(attrs) do
    {:ok, Map.put(attrs, :acked_at_ms, Map.get(attrs, :acked_at_ms, now_ms))}
  end

  defp put_ack_time(_attrs, _now_ms), do: {:error, :invalid_migration_slice_ack}

  defp put_final_catchup_ack_time(attrs, now_ms) when is_map(attrs) do
    {:ok, Map.put(attrs, :acked_at_ms, Map.get(attrs, :acked_at_ms, now_ms))}
  end

  defp put_final_catchup_ack_time(_attrs, _now_ms),
    do: {:error, :invalid_migration_final_catchup_ack}

  defp mark_prewarmed_in_state(state, migration_id) do
    with {:ok, plan} <- fetch_migration(state, migration_id),
         {:ok, next_plan} <- MigrationPlan.mark_prewarmed(plan, now_ms()) do
      next_state = put_in(state.migrations[migration_id], next_plan)

      CliObserve.emit("voxel_migration_prewarmed", fn -> MigrationPlan.summary(next_plan) end)

      {{:ok, next_plan}, next_state}
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp cutover_migration_in_state(state, migration_id) do
    with {:ok, plan} <- fetch_migration(state, migration_id),
         :ok <- validate_cutover_source(state, plan),
         {:ok, cutover_plan} <- MigrationPlan.cutover(plan, now_ms()),
         {:ok, assignment} <- fetch_region_assignment(state, cutover_plan.region_id),
         next_assignment = assignment_from_cutover(assignment, cutover_plan),
         token = LeaseWriteToken.from_lease(cutover_plan.new_lease, cutover_plan.token_version),
         # 阶段2:迁移翻转也走原子发布——新 owner 的写令牌与 region 目录行同事务落库,
         # 避免重启后目录载到旧 owner 而写令牌已是新 owner 的 split-brain。
         :ok <- publish_region_authority(state, next_assignment, cutover_plan.new_lease, token) do
      next_state =
        state
        |> put_in([:assignments, next_assignment.region_id], next_assignment)
        |> put_in([:leases, next_assignment.region_id], cutover_plan.new_lease)
        |> put_in([:migrations, migration_id], cutover_plan)

      CliObserve.emit("voxel_migration_cutover", fn -> MigrationPlan.summary(cutover_plan) end)
      emit_cell_migration_envelope(cutover_plan)
      emit_legacy_region_migrated(cutover_plan)
      emit_cutover_invalidations(next_state, cutover_plan)

      {{:ok, cutover_plan}, next_state}
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp emit_cutover_invalidations(%{scene_invalidator: nil}, _plan), do: :ok

  defp emit_cutover_invalidations(%{scene_invalidator: invalidator}, plan)
       when is_function(invalidator, 1) do
    chunk_coords = chunk_coords_in_bounds(plan.affected_chunk_min, plan.affected_chunk_max)

    {ok_count, error_count} =
      Enum.reduce(chunk_coords, {0, 0}, fn chunk_coord, {ok_acc, err_acc} ->
        attrs = %{
          logical_scene_id: plan.logical_scene_id,
          chunk_coord: chunk_coord,
          reason: @migration_cutover_reason
        }

        case safe_invoke_scene_invalidator(invalidator, attrs) do
          {:ok, _result} -> {ok_acc + 1, err_acc}
          {:error, _reason} -> {ok_acc, err_acc + 1}
        end
      end)

    CliObserve.emit("voxel_migration_cutover_invalidate_emitted", fn ->
      %{
        migration_id: plan.migration_id,
        logical_scene_id: plan.logical_scene_id,
        region_id: plan.region_id,
        source_scene_instance_ref: plan.source_scene_instance_ref,
        target_scene_instance_ref: plan.target_scene_instance_ref,
        reason: @migration_cutover_reason,
        chunk_count: length(chunk_coords),
        ok_count: ok_count,
        error_count: error_count,
        affected_chunk_bounds: %{
          min: coord_list(plan.affected_chunk_min),
          max: coord_list(plan.affected_chunk_max)
        }
      }
    end)

    :ok
  end

  defp emit_cutover_invalidations(_state, _plan), do: :ok

  defp safe_invoke_scene_invalidator(invalidator, attrs) do
    {:ok, invalidator.(attrs)}
  rescue
    exception ->
      CliObserve.emit("voxel_migration_cutover_invalidate_failed", fn ->
        %{
          logical_scene_id: attrs.logical_scene_id,
          chunk_coord: coord_list(attrs.chunk_coord),
          reason: @migration_cutover_reason,
          error: Exception.message(exception)
        }
      end)

      {:error, exception}
  catch
    kind, reason ->
      CliObserve.emit("voxel_migration_cutover_invalidate_failed", fn ->
        %{
          logical_scene_id: attrs.logical_scene_id,
          chunk_coord: coord_list(attrs.chunk_coord),
          reason: @migration_cutover_reason,
          error: inspect({kind, reason})
        }
      end)

      {:error, {kind, reason}}
  end

  defp chunk_coords_in_bounds({min_x, min_y, min_z}, {max_x, max_y, max_z}) do
    for x <- min_x..(max_x - 1)//1,
        y <- min_y..(max_y - 1)//1,
        z <- min_z..(max_z - 1)//1 do
      {x, y, z}
    end
  end

  defp complete_migration_in_state(state, migration_id) do
    case fetch_migration(state, migration_id) do
      {:ok, %MigrationPlan{state: :prewarmed}} ->
        case cutover_migration_in_state(state, migration_id) do
          {{:ok, _cutover_plan}, next_state} ->
            complete_migration_in_state(next_state, migration_id)

          {{:error, reason}, next_state} ->
            {{:error, reason}, next_state}
        end

      {:ok, plan} ->
        case MigrationPlan.complete(plan, now_ms()) do
          {:ok, next_plan} ->
            next_state = put_in(state.migrations[migration_id], next_plan)

            CliObserve.emit("voxel_migration_completed", fn ->
              MigrationPlan.summary(next_plan)
            end)

            {{:ok, next_plan}, next_state}

          {:error, reason} ->
            {{:error, reason}, state}
        end

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp assignment_from_cutover(assignment, plan) do
    %{
      assignment
      | owner_scene_instance_ref: plan.target_scene_instance_ref,
        owner_epoch: plan.new_lease.owner_epoch,
        lease_id: plan.new_lease.lease_id,
        state: :active,
        version: assignment.version + 1
    }
  end

  defp validate_cutover_source(state, plan) do
    with {:ok, assignment} <- fetch_region_assignment(state, plan.region_id),
         :ok <- validate_assignment_source(assignment, plan),
         :ok <- validate_lease_source(Map.get(state.leases, plan.region_id), plan.old_lease) do
      :ok
    end
  end

  defp validate_assignment_source(assignment, plan) do
    cond do
      assignment.owner_scene_instance_ref != plan.source_scene_instance_ref ->
        {:error, :migration_source_owner_changed}

      not is_nil(plan.old_lease) and assignment.lease_id != plan.old_lease.lease_id ->
        {:error, :migration_source_lease_changed}

      true ->
        :ok
    end
  end

  defp validate_lease_source(nil, nil), do: :ok
  defp validate_lease_source(nil, _old_lease), do: {:error, :migration_source_lease_changed}
  defp validate_lease_source(_current_lease, nil), do: {:error, :migration_source_lease_changed}

  defp validate_lease_source(current_lease, old_lease) do
    if same_lease_identity?(current_lease, old_lease) do
      :ok
    else
      {:error, :migration_source_lease_changed}
    end
  end

  defp same_lease_identity?(left, right) do
    left.logical_scene_id == right.logical_scene_id and left.region_id == right.region_id and
      left.lease_id == right.lease_id and
      left.owner_scene_instance_ref == right.owner_scene_instance_ref and
      left.owner_epoch == right.owner_epoch
  end

  defp ensure_no_active_migration(state, region_id) do
    case active_migration_for_region(state, region_id) do
      nil -> :ok
      _plan -> {:error, :migration_already_active}
    end
  end

  defp active_migration_for_region(state, region_id) do
    state.migrations
    |> Map.values()
    |> Enum.find(&(&1.region_id == region_id and &1.state in [:prewarming, :prewarmed, :cutover]))
  end

  defp fetch_region_assignment(state, region_id) do
    case Map.fetch(state.assignments, region_id) do
      {:ok, assignment} -> {:ok, assignment}
      :error -> {:error, :unknown_region}
    end
  end

  defp maybe_assign_scene_node(%RegionAssignment{assigned_scene_node: node} = assignment, _state)
       when not is_nil(node),
       do: {:ok, assignment}

  # Ask SceneNodeRegistry which scene_node should own this region (join-order
  # round-robin). A region may not be stored without a concrete Scene owner.
  defp maybe_assign_scene_node(%RegionAssignment{} = assignment, %{
         scene_node_registry: nil
       }) do
    CliObserve.emit("voxel_region_put_no_scene_node_registry", fn ->
      %{logical_scene_id: assignment.logical_scene_id, region_id: assignment.region_id}
    end)

    {:error, :scene_node_unassigned}
  end

  defp maybe_assign_scene_node(%RegionAssignment{} = assignment, %{
         scene_node_registry: registry
       }) do
    case WorldServer.Voxel.SceneNodeRegistry.assign_region(registry, assignment.region_id) do
      {:ok, scene_node} ->
        {:ok, %{assignment | assigned_scene_node: scene_node}}

      {:error, :no_scene_nodes} ->
        CliObserve.emit("voxel_region_put_no_scene_nodes", fn ->
          %{logical_scene_id: assignment.logical_scene_id, region_id: assignment.region_id}
        end)

        {:error, :scene_node_unassigned}
    end
  end

  defp validate_region_bounds_available(_state, %RegionAssignment{state: state})
       when state != :active,
       do: :ok

  defp validate_region_bounds_available(state, %RegionAssignment{} = assignment) do
    state.assignments
    |> Map.values()
    |> Enum.find(&conflicting_active_region?(&1, assignment))
    |> case do
      nil -> :ok
      conflicting_assignment -> {:error, :region_bounds_overlap, conflicting_assignment}
    end
  end

  defp conflicting_active_region?(existing, assignment) do
    existing.state == :active and existing.region_id != assignment.region_id and
      existing.logical_scene_id == assignment.logical_scene_id and
      bounds_overlap?(existing, assignment)
  end

  defp bounds_overlap?(left, right) do
    axis_ranges_overlap?(
      left.bounds_chunk_min,
      left.bounds_chunk_max,
      right.bounds_chunk_min,
      right.bounds_chunk_max
    )
  end

  defp axis_ranges_overlap?(
         {left_min_x, left_min_y, left_min_z},
         {left_max_x, left_max_y, left_max_z},
         {right_min_x, right_min_y, right_min_z},
         {right_max_x, right_max_y, right_max_z}
       ) do
    left_min_x < right_max_x and right_min_x < left_max_x and left_min_y < right_max_y and
      right_min_y < left_max_y and left_min_z < right_max_z and right_min_z < left_max_z
  end

  defp fetch_migration(state, migration_id) do
    case Map.fetch(state.migrations, migration_id) do
      {:ok, plan} -> {:ok, plan}
      :error -> {:error, :unknown_migration}
    end
  end

  defp default_migration_id(region_id) do
    "region-#{region_id}-migration-#{unique_positive_integer()}"
  end

  # 梯队1 step1.6(cell_migration 正名):cutover 发射 formalized CellMigration 信封(FROZEN-5)。
  # 仅真实 epoch 抬升(new > old)才发;退化迁移只走既有 legacy observe。
  defp emit_cell_migration_envelope(plan) do
    case MigrationPlan.cell_migration_envelope(plan) do
      {:ok, envelope} ->
        CliObserve.emit("voxel_cell_migration_committed", fn ->
          %{
            migration_id: plan.migration_id,
            cell_id: envelope.cell_id,
            old_owner_epoch: envelope.old_owner_epoch,
            new_owner_epoch: envelope.new_owner_epoch,
            migration_tick: envelope.migration_tick,
            commit_watermark: envelope.commit_watermark,
            snapshot_ref: envelope.snapshot_ref
          }
        end)

      {:error, _reason} ->
        :ok
    end
  end

  defp emit_legacy_region_migrated(plan) do
    CliObserve.emit("voxel_region_migrated", fn ->
      lease = plan.new_lease

      %{
        migration_id: plan.migration_id,
        logical_scene_id: lease.logical_scene_id,
        region_id: lease.region_id,
        source_scene_instance_ref: plan.source_scene_instance_ref,
        owner_scene_instance_ref: lease.owner_scene_instance_ref,
        owner_epoch: lease.owner_epoch,
        lease_id: lease.lease_id,
        affected_chunk_bounds: %{
          min: coord_list(plan.affected_chunk_min),
          max: coord_list(plan.affected_chunk_max)
        }
      }
    end)
  end

  defp migration_handoff_summary(handoff) do
    %{
      migration_id: handoff.migration_id,
      logical_scene_id: handoff.logical_scene_id,
      region_id: handoff.region_id,
      state: handoff.state,
      source_scene_instance_ref: handoff.source_scene_instance_ref,
      target_scene_instance_ref: handoff.target_scene_instance_ref,
      old_lease: lease_summary(handoff.old_lease),
      new_lease: lease_summary(handoff.new_lease),
      token_version: handoff.token_version,
      affected_chunk_bounds: %{
        min: coord_list(handoff.affected_chunk_bounds.min),
        max: coord_list(handoff.affected_chunk_bounds.max)
      },
      planned_slices: Enum.map(handoff.planned_slices, &MigrationPlan.slice_summary/1),
      prewarm_ack_count: map_size(Map.get(handoff, :prewarm_acks, %{})),
      final_catchup_ack_count: map_size(Map.get(handoff, :final_catchup_acks, %{})),
      next_slice_index: handoff.next_slice_index,
      total_slices: handoff.total_slices
    }
  end

  defp lease_summary(nil), do: nil

  defp lease_summary(lease) do
    %{
      logical_scene_id: lease.logical_scene_id,
      region_id: lease.region_id,
      lease_id: lease.lease_id,
      owner_scene_instance_ref: lease.owner_scene_instance_ref,
      owner_epoch: lease.owner_epoch,
      bounds_chunk_min: coord_list(lease.bounds_chunk_min),
      bounds_chunk_max: coord_list(lease.bounds_chunk_max)
    }
  end

  # 阶段2 / 评审 F3:把"写令牌发布"与"region 目录行落库"放进**同一 Repo.transaction**,
  # 二者同生共死。任一失败 → rollback,调用方收 {:error,_} 不改内存态(原子)。两后端都未配
  # (多数测试)→ 纯内存,直接 :ok(保持既有行为)。仅配 write_token / 仅配 directory 时各自单写。
  defp publish_region_authority(state, assignment, lease, token) do
    if is_nil(state.write_token_store) and is_nil(state.region_directory) do
      :ok
    else
      DataService.Repo.transaction(fn ->
        with :ok <- publish_token_in_txn(state.write_token_store, token),
             :ok <- upsert_directory_in_txn(state, assignment, lease) do
          :ok
        else
          {:error, reason} -> DataService.Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, :ok} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp publish_token_in_txn(nil, _token), do: :ok

  defp publish_token_in_txn(_enabled, token) do
    case DataService.Voxel.WriteTokenStore.upsert_token_in_repo(
           DataService.Repo,
           LeaseWriteToken.to_map(token)
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp upsert_directory_in_txn(%{region_directory: nil}, _assignment, _lease), do: :ok

  defp upsert_directory_in_txn(%{region_directory: store} = state, assignment, lease) do
    attrs = WorldServer.Voxel.RegionDirectory.to_attrs(assignment, lease)
    store.upsert_region_in_repo(directory_repo(state), attrs)
  end

  # The directory store talks to DataService.Repo by default; an injected
  # :region_directory_opts[:repo] (tests) overrides it.
  defp directory_repo(state) do
    Keyword.get(state.region_directory_opts, :repo, DataService.Repo)
  end

  # Persists a region row outside the lease/token path (e.g. an explicit put_region
  # before a lease exists, or a migration). No-op when the directory is disabled.
  # Standalone (own transaction) — used where there is no co-located token publish.
  defp persist_region_row(%{region_directory: nil}, _assignment, _lease), do: :ok

  defp persist_region_row(%{region_directory: store} = state, assignment, lease) do
    attrs = WorldServer.Voxel.RegionDirectory.to_attrs(assignment, lease)

    case store.upsert_region(attrs, state.region_directory_opts) do
      :ok ->
        :ok

      {:error, reason} ->
        CliObserve.emit("voxel_region_directory_persist_failed", fn ->
          %{region_id: assignment.region_id, reason: inspect(reason)}
        end)

        :ok
    end
  end

  # Boot-time load_fn that rebuilds assignments/leases from the durable directory.
  defp directory_load_fn(nil, _opts), do: nil

  defp directory_load_fn(store, opts) do
    fn -> {:ok, WorldServer.Voxel.RegionDirectory.load_state(store, opts)} end
  end

  # Pure routing (never materializes). 阶段1: O(1) grid-id fast path — a chunk's
  # region_id is a pure function of (logical_scene_id, grid index), so a
  # grid-materialized region is found by a single Map.fetch. The fast path always
  # re-checks `contains_chunk?`, so it can never return a wrong region; explicit
  # (non-grid-aligned) regions from put_region/migration fall through to the
  # linear scan, preserving the old contract bit-for-bit.
  defp route_chunk_in_state(state, logical_scene_id, chunk_coord) do
    case grid_region_lookup(state, logical_scene_id, chunk_coord) do
      {:ok, assignment} -> {:ok, assignment}
      :miss -> scan_route_chunk(state, logical_scene_id, chunk_coord)
    end
  end

  defp grid_region_lookup(state, logical_scene_id, chunk_coord) do
    with {:ok, region_id} <- safe_grid_region_id(state, logical_scene_id, chunk_coord),
         {:ok, %RegionAssignment{state: :active} = assignment} <-
           Map.fetch(state.assignments, region_id),
         true <- RegionAssignment.contains_chunk?(assignment, chunk_coord),
         # Guard the invariant the fast path rests on: a grid region_id encodes
         # logical_scene_id, so the fetched assignment MUST belong to the queried
         # scene. An explicit put_region could store an assignment whose region_id
         # collides with a *different* scene's grid id while carrying a mismatched
         # logical_scene_id field; without this check the fast path would route
         # cross-scene while the scan (which filters by logical_scene_id) would not.
         # This keeps the fast path bit-for-bit equivalent to the scan for all input.
         true <- assignment.logical_scene_id == logical_scene_id do
      {:ok, assignment}
    else
      _ -> :miss
    end
  end

  # RegionGrid.region_id/2 raises past the encodable world edge; treat that as a
  # fast-path miss (the scan then returns :unassigned_chunk) rather than crashing
  # the ledger.
  defp safe_grid_region_id(state, logical_scene_id, chunk_coord) do
    index = RegionGrid.region_index(state.region_grid, chunk_coord)
    {:ok, RegionGrid.region_id(logical_scene_id, index)}
  rescue
    ArgumentError -> :error
  end

  defp scan_route_chunk(state, logical_scene_id, chunk_coord) do
    state.assignments
    |> Map.values()
    |> Enum.filter(&(&1.logical_scene_id == logical_scene_id and &1.state == :active))
    |> Enum.find(&RegionAssignment.contains_chunk?(&1, chunk_coord))
    |> case do
      nil -> {:error, :unassigned_chunk}
      assignment -> {:ok, assignment}
    end
  end

  # 阶段1 懒物化路由:命中→原样返回(state 不变);route miss→在 grid 上物化一个 region
  # (分配 Scene owner + 单调 epoch + lease)再返回。返回 {:ok, assignment, next_state}
  # | {:error, reason, next_state}。物化失败(无 Scene 节点 / 写令牌 CAS)回滚到原 state。
  defp route_or_materialize(state, logical_scene_id, chunk_coord) do
    case route_chunk_in_state(state, logical_scene_id, chunk_coord) do
      {:ok, assignment} -> {:ok, assignment, state}
      {:error, :unassigned_chunk} -> ensure_region_in_state(state, logical_scene_id, chunk_coord)
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp ensure_region_in_state(state, logical_scene_id, chunk_coord) do
    case safe_locate(state.region_grid, logical_scene_id, chunk_coord) do
      {:ok, located} -> materialize_located_region(state, logical_scene_id, located)
      :error -> {:error, :region_unencodable, state}
    end
  end

  # RegionGrid.locate/3 raises past the encodable world edge / scene-id budget;
  # treat that as a clean materialization error rather than crashing the ledger.
  defp safe_locate(grid, logical_scene_id, chunk_coord) do
    {:ok, RegionGrid.locate(grid, logical_scene_id, chunk_coord)}
  rescue
    ArgumentError -> :error
  end

  defp materialize_located_region(state, logical_scene_id, located) do
    attrs = %{
      logical_scene_id: logical_scene_id,
      region_id: located.region_id,
      bounds_chunk_min: located.bounds_chunk_min,
      bounds_chunk_max: located.bounds_chunk_max,
      owner_scene_instance_ref: state.materialize_owner_scene_instance_ref,
      # Placeholder; issue_lease_for_assignment allocates the real monotonic epoch
      # from the DB epoch store (CELL-18/23), so we never pin a stale value here.
      owner_epoch: 0
    }

    with {:ok, assignment} <-
           attrs |> RegionAssignment.new() |> maybe_assign_scene_node(state),
         :ok <- validate_region_bounds_available(state, assignment) do
      state_with_region = put_in(state.assignments[assignment.region_id], assignment)

      case issue_lease_for_assignment(
             state_with_region,
             assignment,
             assignment.owner_scene_instance_ref,
             ttl_ms: @materialized_lease_ttl_ms
           ) do
        {{:ok, lease}, next_state} ->
          materialized = next_state.assignments[assignment.region_id]

          CliObserve.emit("voxel_region_materialized", fn ->
            %{
              logical_scene_id: logical_scene_id,
              region_id: assignment.region_id,
              region_index: Tuple.to_list(located.region_index),
              bounds_chunk_min: coord_list(assignment.bounds_chunk_min),
              bounds_chunk_max: coord_list(assignment.bounds_chunk_max),
              assigned_scene_node: assignment.assigned_scene_node,
              owner_epoch: lease.owner_epoch,
              lease_id: lease.lease_id
            }
          end)

          {:ok, materialized, next_state}

        {{:error, reason}, _state} ->
          # Roll back the lease-less assignment we tentatively stored.
          {:error, reason, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
      {:error, reason, _conflicting_assignment} -> {:error, reason, state}
    end
  end

  defp validate_write_in_state(state, write) do
    with {:ok, assignment} <-
           route_chunk_in_state(state, write.logical_scene_id, write.chunk_coord),
         {:ok, lease} <- fetch_region_lease(state, assignment.region_id),
         :ok <- validate_write_identity(lease, write) do
      :ok
    end
  end

  defp fetch_region_lease(state, region_id) do
    case Map.fetch(state.leases, region_id) do
      {:ok, lease} -> {:ok, lease}
      :error -> {:error, :region_without_lease}
    end
  end

  defp validate_write_identity(lease, write) do
    cond do
      write.lease_id != lease.lease_id ->
        {:error, :lease_id_mismatch}

      write.owner_scene_instance_ref != lease.owner_scene_instance_ref ->
        {:error, :owner_scene_mismatch}

      write.owner_epoch != lease.owner_epoch ->
        {:error, :owner_epoch_mismatch}

      lease.expires_at_ms <= now_ms() ->
        {:error, :lease_expired}

      true ->
        :ok
    end
  end

  defp participants_for_chunks(state, logical_scene_id, affected_chunks) do
    routes =
      affected_chunks
      |> Enum.uniq()
      |> Enum.reduce_while({:ok, []}, fn chunk_coord, {:ok, acc} ->
        with {:ok, assignment} <- route_chunk_in_state(state, logical_scene_id, chunk_coord),
             {:ok, lease} <- fetch_region_lease(state, assignment.region_id),
             {:ok, scene_node} <- assigned_scene_node(assignment) do
          {:cont, {:ok, [{chunk_coord, assignment, lease, scene_node} | acc]}}
        else
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    with {:ok, routes} <- routes do
      routes
      |> Enum.group_by(
        fn {_coord, _assignment, _lease, scene_node} -> scene_node end,
        fn {coord, assignment, lease, _scene_node} -> {coord, assignment, lease} end
      )
      |> Enum.map(fn {scene_node, entries} ->
        entries = Enum.sort_by(entries, fn {coord, _assignment, _lease} -> coord end)
        {_first_coord, _first_assignment, first_lease} = List.first(entries)

        chunk_owners =
          Map.new(entries, fn {coord, _assignment, lease} ->
            {coord, {lease.region_id, lease.lease_id}}
          end)

        %TransactionParticipant{
          participant_key: {:scene_owner, scene_node},
          region_id: first_lease.region_id,
          lease_id: first_lease.lease_id,
          owner_scene_instance_ref: first_lease.owner_scene_instance_ref,
          owner_epoch: first_lease.owner_epoch,
          assigned_scene_node: scene_node,
          affected_chunks: Enum.map(entries, fn {coord, _assignment, _lease} -> coord end),
          chunk_owners: chunk_owners
        }
      end)
      |> Enum.sort_by(&{&1.assigned_scene_node, &1.region_id, &1.lease_id})
      |> then(&{:ok, &1})
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp assigned_scene_node(%RegionAssignment{assigned_scene_node: scene_node})
       when not is_nil(scene_node),
       do: {:ok, scene_node}

  defp assigned_scene_node(%RegionAssignment{}), do: {:error, :scene_node_unassigned}

  defp normalize_write(attrs) when is_map(attrs) do
    %{
      logical_scene_id: Map.fetch!(attrs, :logical_scene_id),
      chunk_coord: coord!(Map.fetch!(attrs, :chunk_coord)),
      lease_id: Map.fetch!(attrs, :lease_id),
      owner_scene_instance_ref: Map.fetch!(attrs, :owner_scene_instance_ref),
      owner_epoch: Map.fetch!(attrs, :owner_epoch)
    }
  end

  defp coord!({x, y, z}) when is_integer(x) and is_integer(y) and is_integer(z), do: {x, y, z}
  defp coord!([x, y, z]) when is_integer(x) and is_integer(y) and is_integer(z), do: {x, y, z}

  defp coord!(value) do
    raise ArgumentError, "expected chunk coord as {x, y, z}, got: #{inspect(value)}"
  end

  defp coord_list({x, y, z}), do: [x, y, z]

  defp unique_positive_integer do
    System.unique_integer([:positive, :monotonic])
  end

  defp now_ms, do: System.system_time(:millisecond)

  defp maybe_persist_state(%{persist_fn: nil}), do: :ok

  defp maybe_persist_state(%{persist_fn: persist_fn} = state) when is_function(persist_fn, 1) do
    payload = Map.take(state, [:assignments, :leases, :chunk_summaries, :migrations])
    persist_fn.(payload)
  end

  defp run_load(nil), do: {:ok, %{}}

  defp run_load(load_fn) when is_function(load_fn, 0) do
    case load_fn.() do
      {:ok, payload} when is_map(payload) -> validate_persisted_payload(payload)
      {:error, _reason} = err -> err
      other -> {:error, {:unexpected_load_result, other}}
    end
  rescue
    # #18:注入的 load_fn(或 file_load_fn 之外的实现)抛异常时,init 不能跟着崩
    # (会拖垮 WorldSup → server boot 失败)。收敛成 {:error,_},init 据此回落到空
    # base 并 emit voxel_map_ledger_persist_load_failed。
    exception -> {:error, {:load_fn_crashed, Exception.message(exception)}}
  end

  defp file_persist_fn(path) when is_binary(path) do
    fn payload ->
      binary = :erlang.term_to_binary(payload)
      tmp_path = path <> ".tmp"

      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(tmp_path, binary),
           :ok <- File.rename(tmp_path, path) do
        :ok
      end
    end
  end

  defp file_load_fn(path) when is_binary(path) do
    fn ->
      case File.read(path) do
        {:ok, binary} ->
          try do
            {:ok, :erlang.binary_to_term(binary, [:safe])}
          rescue
            exception in [ArgumentError] -> {:error, Exception.message(exception)}
          end

        {:error, :enoent} ->
          {:ok, %{}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp validate_persisted_payload(payload) when is_map(payload) do
    expected_keys = [:assignments, :leases, :chunk_summaries, :migrations]

    keys = Map.keys(payload)

    cond do
      keys == [] ->
        {:ok, %{}}

      Enum.any?(keys, fn key -> key not in expected_keys end) ->
        {:error, {:unexpected_keys, keys -- expected_keys}}

      Enum.any?(payload, fn {_key, value} -> not is_map(value) end) ->
        {:error, :unexpected_value_shape}

      true ->
        {:ok, sanitize_persisted_payload(payload)}
    end
  end

  defp validate_persisted_payload(_other), do: {:error, :unexpected_payload_shape}

  # #2 反序列化加固:migrations 子表只保留 %MigrationPlan{} 结构。跨版本 stale 快照 /
  # struct 形态变更可能把 plan 反序列化成 plain map,后续 MigrationPlan.handoff/summary/
  # plan_next_slice 等会对非 struct 崩(FunctionClauseError)。LOAD 时丢弃坏 plan(emit
  # 计数),其余照常恢复。镜像 TransactionCoordinator 的 drop_non_struct_transactions。
  defp sanitize_persisted_payload(payload) do
    case Map.fetch(payload, :migrations) do
      {:ok, migrations} when is_map(migrations) ->
        {kept, dropped} =
          Enum.split_with(migrations, fn {_id, plan} -> is_struct(plan, MigrationPlan) end)

        if dropped != [] do
          CliObserve.emit("voxel_map_ledger_dropped_stale_migrations", fn ->
            %{dropped_count: length(dropped), dropped_ids: Enum.map(dropped, &elem(&1, 0))}
          end)
        end

        Map.put(payload, :migrations, Map.new(kept))

      _other ->
        payload
    end
  end
end
