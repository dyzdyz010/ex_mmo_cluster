defmodule WorldServer.Voxel.MapLedger do
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
  alias WorldServer.Voxel.SceneLease
  alias WorldServer.Voxel.TransactionParticipant

  @default_lease_ttl_ms :timer.minutes(5)
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

  @doc "Validates that a proposed scene write matches the current world lease."
  def validate_write(server \\ __MODULE__, attrs) do
    GenServer.call(server, {:validate_write, normalize_write(attrs)})
  end

  @doc "Builds lease-scoped transaction participants for the affected chunks."
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

    persist_fn =
      Keyword.get(opts, :persist_fn) ||
        if persistence_path, do: file_persist_fn(persistence_path)

    load_fn =
      Keyword.get(opts, :load_fn) ||
        if persistence_path, do: file_load_fn(persistence_path)

    base = %{
      assignments: %{},
      leases: %{},
      chunk_summaries: %{},
      migrations: %{},
      write_token_store: Keyword.get(opts, :write_token_store),
      persist_fn: persist_fn,
      scene_invalidator: Keyword.get(opts, :scene_invalidator)
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
    assignment = RegionAssignment.new(attrs)
    key = assignment.region_id

    case validate_region_bounds_available(state, assignment) do
      :ok ->
        CliObserve.emit("voxel_region_put", fn ->
          Map.take(Map.from_struct(assignment), [
            :logical_scene_id,
            :region_id,
            :owner_scene_instance_ref,
            :owner_epoch,
            :state
          ])
        end)

        {:reply, {:ok, assignment}, put_in(state.assignments[key], assignment)}

      {:error, reason, conflicting_assignment} ->
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

  defp issue_lease_for_assignment(state, assignment, owner_scene_instance_ref, opts) do
    owner_epoch = Keyword.get(opts, :owner_epoch, assignment.owner_epoch + 1)
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

    case publish_write_token(state.write_token_store, token) do
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
      owner_epoch = Keyword.get(opts, :owner_epoch, next_owner_epoch(assignment, old_lease))
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
         :ok <- publish_write_token_for_plan(state, cutover_plan),
         {:ok, assignment} <- fetch_region_assignment(state, cutover_plan.region_id) do
      next_assignment = assignment_from_cutover(assignment, cutover_plan)

      next_state =
        state
        |> put_in([:assignments, next_assignment.region_id], next_assignment)
        |> put_in([:leases, next_assignment.region_id], cutover_plan.new_lease)
        |> put_in([:migrations, migration_id], cutover_plan)

      CliObserve.emit("voxel_migration_cutover", fn -> MigrationPlan.summary(cutover_plan) end)
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

  defp publish_write_token_for_plan(state, plan) do
    token = LeaseWriteToken.from_lease(plan.new_lease, plan.token_version)
    publish_write_token(state.write_token_store, token)
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

  defp next_owner_epoch(_assignment, %SceneLease{} = old_lease), do: old_lease.owner_epoch + 1
  defp next_owner_epoch(assignment, nil), do: assignment.owner_epoch + 1

  defp default_migration_id(region_id) do
    "region-#{region_id}-migration-#{unique_positive_integer()}"
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

  defp publish_write_token(nil, _token), do: :ok

  defp publish_write_token(server, token) when is_pid(server) do
    if Process.alive?(server) do
      do_publish_write_token(server, token)
    else
      {:error, :write_token_store_unavailable}
    end
  end

  defp publish_write_token(server, token) when is_atom(server) do
    case Process.whereis(server) do
      nil -> {:error, :write_token_store_unavailable}
      _pid -> do_publish_write_token(server, token)
    end
  end

  defp publish_write_token(server, token) do
    do_publish_write_token(server, token)
  end

  defp do_publish_write_token(server, token) do
    case DataService.Voxel.WriteTokenStore.upsert_token(server, LeaseWriteToken.to_map(token)) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp route_chunk_in_state(state, logical_scene_id, chunk_coord) do
    state.assignments
    |> Map.values()
    |> Enum.filter(&(&1.logical_scene_id == logical_scene_id and &1.state == :active))
    |> Enum.find(&RegionAssignment.contains_chunk?(&1, chunk_coord))
    |> case do
      nil -> {:error, :unassigned_chunk}
      assignment -> {:ok, assignment}
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
    affected_chunks
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, %{}}, fn chunk_coord, {:ok, acc} ->
      with {:ok, assignment} <- route_chunk_in_state(state, logical_scene_id, chunk_coord),
           {:ok, lease} <- fetch_region_lease(state, assignment.region_id) do
        key = {assignment.region_id, lease.lease_id}
        participant = Map.get(acc, key, participant_from_lease(lease))

        participant = %{
          participant
          | affected_chunks: [chunk_coord | participant.affected_chunks]
        }

        {:cont, {:ok, Map.put(acc, key, participant)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, participants_by_key} ->
        participants =
          participants_by_key
          |> Map.values()
          |> Enum.map(&%{&1 | affected_chunks: Enum.sort(&1.affected_chunks)})
          |> Enum.sort_by(&{&1.region_id, &1.lease_id})

        {:ok, participants}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp participant_from_lease(lease) do
    %TransactionParticipant{
      region_id: lease.region_id,
      lease_id: lease.lease_id,
      owner_scene_instance_ref: lease.owner_scene_instance_ref,
      owner_epoch: lease.owner_epoch,
      affected_chunks: []
    }
  end

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
        {:ok, payload}
    end
  end

  defp validate_persisted_payload(_other), do: {:error, :unexpected_payload_shape}
end
