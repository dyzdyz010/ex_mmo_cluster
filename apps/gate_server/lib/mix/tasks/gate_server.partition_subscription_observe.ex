defmodule Mix.Tasks.GateServer.PartitionSubscriptionObserve do
  @moduledoc """
  Runs a Gate-side authoritative partition-subscription observe smoke.

      mix gate_server.partition_subscription_observe --logical-scene-id 1 --from 100,100,100 --to 1650,100,100
      mix gate_server.partition_subscription_observe --partition-radius 1 --voxel-snapshot-cap 128

  The task demonstrates the non-GUI path for one movement boundary refresh:
  authoritative position -> World partition window -> Gate partition context
  -> Chat presence refresh -> Scene chunk subscription diff application.
  With a halo radius and constrained snapshot cap it also shows which
  subscriptions get an initial authoritative snapshot and which are only halo
  ghost/prewarm bindings.
  """

  use Mix.Task

  alias ChatServer.Runtime, as: ChatRuntime
  alias GateServer.CliObserve, as: GateObserve
  alias GateServer.PartitionRuntime
  alias GateServer.Voxel.ClientAckLedger
  alias GateServer.Voxel.ChunkVersionLedger
  alias GateServer.Voxel.DeliveryScheduler
  alias GateServer.Voxel.SubscriptionRuntime
  alias SceneServer.Voxel.Types
  alias WorldServer.Voxel.MapLedger

  @shortdoc "Runs Gate partition-subscription CLI observe smoke"
  @switches [
    help: :boolean,
    logical_scene_id: :integer,
    cid: :integer,
    from: :string,
    to: :string,
    partition_radius: :integer,
    voxel_snapshot_cap: :integer,
    prewarm_destination_ghost: :boolean,
    known_version_mode: :string,
    known_version: :integer,
    observe_dir: :string,
    observe_log: :string
  ]
  @aliases [h: :help, s: :logical_scene_id, c: :cid, o: :observe_dir]

  @doc false
  @impl true
  def run(args) do
    {opts, _argv, invalid} = OptionParser.parse(args, switches: @switches, aliases: @aliases)

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      invalid != [] ->
        Mix.raise("invalid options: #{inspect(invalid)}")

      true ->
        run_smoke(opts)
    end
  end

  defp run_smoke(opts) do
    logical_scene_id = Keyword.get(opts, :logical_scene_id, 1)
    cid = Keyword.get(opts, :cid, 42)
    from_location = parse_location!(Keyword.get(opts, :from, "100,100,100"))
    to_location = parse_location!(Keyword.get(opts, :to, "1650,100,100"))
    from_chunk = Types.chunk_from_world_cm!(from_location)
    to_chunk = Types.chunk_from_world_cm!(to_location)
    partition_radius = Keyword.get(opts, :partition_radius, 0)
    known_version_mode = parse_known_version_mode!(Keyword.get(opts, :known_version_mode, "none"))
    known_version = non_negative_integer!(Keyword.get(opts, :known_version, 9), :known_version)
    observe_log = observe_path(opts, logical_scene_id)
    previous_gate_log = Application.fetch_env(:gate_server, :cli_observe_log)

    ensure_data_service_started()

    runtime = :"partition_subscription_chat_#{System.unique_integer([:positive])}"
    {:ok, chat_pid} = ChatRuntime.start_link(name: runtime)
    {:ok, ledger} = MapLedger.start_link([])
    scene_started = ensure_scene_voxel_started()

    try do
      reset_log(observe_log)
      Application.put_env(:gate_server, :cli_observe_log, observe_log)
      seed_partition_sample!(ledger, logical_scene_id)

      previous_context = %{
        logical_scene_id: logical_scene_id,
        chunk_coord: from_chunk,
        region_id: 10
      }

      {:ok, _session} =
        ChatRuntime.join(runtime, %{
          cid: cid,
          username: "partition-tester",
          connection_pid: self(),
          logical_scene_id: logical_scene_id,
          region_id: previous_context.region_id,
          chunk_coord: previous_context.chunk_coord
        })

      state =
        %{
          cid: cid,
          partition_context: previous_context,
          chat_context: previous_context,
          chat_session_joined?: true,
          voxel_subscriptions:
            initial_subscriptions(
              opts,
              logical_scene_id,
              from_chunk,
              to_chunk,
              previous_context.region_id
            ),
          voxel_subscription_plan: nil,
          voxel_stream_caps: stream_caps(opts),
          voxel_snapshot_estimate_bytes: Keyword.get(opts, :voxel_snapshot_cap, 128)
        }
        |> seed_known_version_mode(
          known_version_mode,
          logical_scene_id,
          to_chunk,
          known_version
        )

      {next_state, outcome} =
        case PartitionRuntime.refresh_after_movement_ack(
               state,
               %{cid: cid, ack_seq: 1, auth_tick: 1, position: to_location},
               partition_radius: partition_radius,
               route_window_fun: fn scene_id, center_chunk, radius ->
                 {:ok,
                  MapLedger.partition_window(ledger, scene_id, center_chunk,
                    near_radius: 0,
                    halo_radius: radius
                  )}
               end,
               chat_refresh_fun: fn presence ->
                 ChatRuntime.refresh_presence(runtime, presence)
               end,
               subscription_apply_fun: subscription_apply_fun(to_chunk, known_version_mode)
             ) do
          {:ok, refreshed_state, refresh_outcome} -> {refreshed_state, refresh_outcome}
          {:error, refreshed_state, refresh_outcome} -> {refreshed_state, refresh_outcome}
        end

      summary =
        summary(
          outcome,
          next_state,
          from_location,
          to_location,
          from_chunk,
          to_chunk,
          observe_log
        )

      GateObserve.emit("gate_partition_subscription_resolved", summary)
      GateObserve.flush()
      Mix.shell().info(summary_line(summary))
    after
      if Process.alive?(ledger), do: GenServer.stop(ledger)
      if Process.alive?(chat_pid), do: GenServer.stop(chat_pid)
      stop_scene_voxel_started(scene_started)
      GateObserve.flush()
      restore_env(:gate_server, previous_gate_log)
    end
  end

  defp ensure_scene_voxel_started do
    # 阶段3.1：chunk 进程身份注册表必须早于 VoxelChunkSup / ChunkDirectory。
    chunk_registry =
      case Process.whereis(SceneServer.Voxel.ChunkRegistry) do
        nil ->
          {:ok, pid} =
            Registry.start_link(keys: :unique, name: SceneServer.Voxel.ChunkRegistry)

          {:started, pid}

        pid ->
          {:existing, pid}
      end

    chunk_sup =
      case Process.whereis(SceneServer.VoxelChunkSup) do
        nil ->
          {:ok, pid} = SceneServer.VoxelChunkSup.start_link(name: SceneServer.VoxelChunkSup)
          {:started, pid}

        pid ->
          {:existing, pid}
      end

    chunk_directory =
      case Process.whereis(SceneServer.Voxel.ChunkDirectory) do
        nil ->
          {:ok, pid} =
            SceneServer.Voxel.ChunkDirectory.start_link(
              name: SceneServer.Voxel.ChunkDirectory,
              chunk_sup: SceneServer.VoxelChunkSup
            )

          {:started, pid}

        pid ->
          {:existing, pid}
      end

    %{chunk_registry: chunk_registry, chunk_sup: chunk_sup, chunk_directory: chunk_directory}
  end

  defp ensure_data_service_started do
    {:ok, _apps} = Application.ensure_all_started(:data_service)

    case Process.whereis(DataService.Repo) do
      nil ->
        case DataService.Repo.start_link() do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
        end

      _pid ->
        :ok
    end
  end

  defp stop_scene_voxel_started(%{chunk_directory: {:started, pid}, chunk_sup: chunk_sup}) do
    if Process.alive?(pid), do: GenServer.stop(pid)
    stop_scene_voxel_started(%{chunk_directory: :stopped, chunk_sup: chunk_sup})
  end

  defp stop_scene_voxel_started(%{chunk_sup: {:started, pid}} = started) do
    if Process.alive?(pid), do: DynamicSupervisor.stop(pid)
    stop_scene_voxel_started(Map.put(started, :chunk_sup, :stopped))
  end

  defp stop_scene_voxel_started(%{chunk_registry: {:started, pid}}) do
    if Process.alive?(pid), do: Process.exit(pid, :normal)
  end

  defp stop_scene_voxel_started(_started), do: :ok

  defp seed_partition_sample!(ledger, logical_scene_id) do
    future_ms = System.system_time(:millisecond) + :timer.minutes(10)

    {:ok, _assignment} =
      MapLedger.put_region(ledger, %{
        logical_scene_id: logical_scene_id,
        region_id: 10,
        bounds_chunk_min: {0, 0, 0},
        bounds_chunk_max: {1, 1, 1},
        owner_scene_instance_ref: 1_000,
        owner_epoch: 0,
        assigned_scene_node: node()
      })

    {:ok, _lease} =
      MapLedger.issue_lease(ledger, 10, 1_000,
        lease_id: 100,
        owner_epoch: 1,
        expires_at_ms: future_ms,
        token_version: 1
      )

    {:ok, _assignment} =
      MapLedger.put_region(ledger, %{
        logical_scene_id: logical_scene_id,
        region_id: 20,
        bounds_chunk_min: {1, 0, 0},
        bounds_chunk_max: {2, 1, 1},
        owner_scene_instance_ref: 2_000,
        owner_epoch: 0,
        assigned_scene_node: node()
      })

    {:ok, _lease} =
      MapLedger.issue_lease(ledger, 20, 2_000,
        lease_id: 200,
        owner_epoch: 1,
        expires_at_ms: future_ms,
        token_version: 1
      )

    :ok
  end

  defp subscription_handle(logical_scene_id, chunk_coord, region_id) do
    %{
      logical_scene_id: logical_scene_id,
      chunk_coord: chunk_coord,
      request_id: 0,
      scene_node: node(),
      region_id: region_id,
      lease_id: if(region_id == 20, do: 200, else: 100),
      owner_scene_instance_ref: region_id * 100,
      owner_epoch: 1
    }
  end

  defp initial_subscriptions(opts, logical_scene_id, from_chunk, to_chunk, from_region_id) do
    authoritative = subscription_handle(logical_scene_id, from_chunk, from_region_id)

    subscriptions = %{
      {logical_scene_id, from_chunk} => authoritative
    }

    if Keyword.get(opts, :prewarm_destination_ghost, false) do
      ghost =
        subscription_handle(logical_scene_id, to_chunk, 20)
        |> Map.merge(%{
          tier: :halo,
          priority: :opportunistic,
          send_snapshot?: false,
          initial_delivery_mode: :halo_ghost,
          snapshot_defer_reason: :snapshot_budget_exhausted
        })

      Map.put(subscriptions, {logical_scene_id, to_chunk}, ghost)
    else
      subscriptions
    end
  end

  defp summary(outcome, state, from_location, to_location, from_chunk, to_chunk, observe_log) do
    diff = outcome.subscription_diff
    plan = state.voxel_subscription_plan || %{}
    apply_summary = apply_summary(outcome)
    target_known_version = target_known_version(state)

    %{
      cid: outcome.cid,
      logical_scene_id: outcome.logical_scene_id,
      from_location: coord_list(from_location),
      to_location: coord_list(to_location),
      from_chunk: coord_list(from_chunk),
      to_chunk: coord_list(to_chunk),
      from_region_id: outcome.previous_region_id,
      to_region_id: outcome.region_id,
      boundary_kind: outcome.boundary_kind,
      status: outcome.status,
      subscription_apply_status: Map.get(outcome, :subscription_apply_status, :none),
      subscribe_count: length(diff.subscribe_chunks),
      unsubscribe_count: length(diff.unsubscribe_chunks),
      retained_count: length(diff.retained_chunks),
      pressure: Map.get(plan, :pressure, :none),
      initial_snapshot_count: Map.get(plan, :initial_snapshot_count, 0),
      ghost_subscription_count: Map.get(plan, :ghost_subscription_count, 0),
      promoted_count: Map.get(apply_summary, :promoted_count, 0),
      promotion_snapshot_count: Map.get(apply_summary, :promotion_snapshot_count, 0),
      target_known_version_source:
        Map.get(target_known_version, :target_known_version_source, :not_applicable),
      target_known_version_for_scene:
        Map.get(target_known_version, :target_known_version_for_scene),
      target_send_snapshot?: Map.get(target_known_version, :target_send_snapshot?),
      target_initial_delivery_mode: Map.get(target_known_version, :target_initial_delivery_mode),
      active_subscription_count: map_size(Map.get(state, :voxel_subscriptions, %{})),
      observe_log: observe_log
    }
  end

  defp summary_line(summary) do
    [
      "gate_partition_subscription=ok",
      "cid=#{summary.cid}",
      "logical_scene_id=#{summary.logical_scene_id}",
      "from_location=#{Enum.join(summary.from_location, ",")}",
      "to_location=#{Enum.join(summary.to_location, ",")}",
      "from_chunk=#{Enum.join(summary.from_chunk, ",")}",
      "to_chunk=#{Enum.join(summary.to_chunk, ",")}",
      "from_region_id=#{summary.from_region_id}",
      "to_region_id=#{summary.to_region_id}",
      "boundary=#{summary.boundary_kind}",
      "status=#{summary.status}",
      "subscription_apply_status=#{format_status(summary.subscription_apply_status)}",
      "subscribe_count=#{summary.subscribe_count}",
      "unsubscribe_count=#{summary.unsubscribe_count}",
      "retained_count=#{summary.retained_count}",
      "snapshot_subscriptions=#{summary.initial_snapshot_count}",
      "ghost_subscriptions=#{summary.ghost_subscription_count}",
      "promoted_subscriptions=#{summary.promoted_count}",
      "promotion_snapshots=#{summary.promotion_snapshot_count}",
      "target_known_version_source=#{summary.target_known_version_source}",
      "target_known_version_for_scene=#{format_optional(summary.target_known_version_for_scene)}",
      "target_send_snapshot=#{format_optional(summary.target_send_snapshot?)}",
      "target_initial_delivery_mode=#{format_optional(summary.target_initial_delivery_mode)}",
      "active_subscription_count=#{summary.active_subscription_count}",
      "pressure=#{summary.pressure}",
      "observe_log=#{summary.observe_log}"
    ]
    |> Enum.join(" ")
  end

  defp format_status(:ok), do: "ok"
  defp format_status(:none), do: "none"
  defp format_status({:error, reason}), do: "error:#{inspect(reason)}"
  defp format_status(status), do: inspect(status)

  defp apply_summary(outcome), do: Map.get(outcome, :subscription_apply_summary, %{})

  defp target_known_version(state) do
    Map.get(state, :partition_subscription_observe_target, %{})
  end

  defp subscription_apply_fun(target_chunk, known_version_mode) do
    fn current_state, partition_result ->
      case SubscriptionRuntime.apply_partition_result(current_state, partition_result,
             reason: :movement_boundary,
             subscriber: self()
           ) do
        {:ok, subscribed_state, apply_summary} ->
          {:ok,
           put_target_known_version(
             subscribed_state,
             partition_result,
             target_chunk,
             known_version_mode
           ), apply_summary}

        {:error, failed_state, apply_summary} ->
          {:error,
           put_target_known_version(
             failed_state,
             partition_result,
             target_chunk,
             known_version_mode
           ), apply_summary}
      end
    end
  end

  defp put_target_known_version(state, partition_result, target_chunk, known_version_mode) do
    plan = Map.get(partition_result, :subscription_plan)
    entry = target_subscribe_entry(plan, target_chunk)

    Map.put(state, :partition_subscription_observe_target, %{
      target_known_version_source: target_known_version_source(known_version_mode, entry),
      target_known_version_for_scene: entry && Map.get(entry, :known_version_for_scene),
      target_send_snapshot?: entry && Map.get(entry, :send_snapshot?),
      target_initial_delivery_mode: entry && Map.get(entry, :initial_delivery_mode)
    })
  end

  defp target_subscribe_entry(nil, _target_chunk), do: nil

  defp target_subscribe_entry(plan, target_chunk) do
    plan
    |> Map.get(:subscribe_entries, [])
    |> Enum.find(&(Map.get(&1, :chunk_coord) == target_chunk))
  end

  defp target_known_version_source(_mode, nil), do: :not_applicable

  defp target_known_version_source(:acked, %{known_version_for_scene: version})
       when is_integer(version),
       do: :client_ack

  defp target_known_version_source(:acked, _entry), do: :missing_client_ack
  defp target_known_version_source(:acked_resync, _entry), do: :resync_required
  defp target_known_version_source(:forwarded, _entry), do: :forwarded_only_rejected
  defp target_known_version_source(:none, _entry), do: :none

  defp stream_caps(opts) do
    snapshot_cap = Keyword.get(opts, :voxel_snapshot_cap, 64 * 1_024)

    %{
      reliable_control: 1_024,
      voxel_snapshot: snapshot_cap,
      voxel_delta: 32 * 1_024,
      field_state: 16 * 1_024,
      recovery: 32 * 1_024
    }
  end

  defp observe_path(opts, logical_scene_id) do
    observe_dir = Keyword.get(opts, :observe_dir, ".demo/observe")

    Keyword.get(
      opts,
      :observe_log,
      Path.join(observe_dir, "gate-partition-subscription-#{logical_scene_id}.log")
    )
  end

  defp parse_location!(value) do
    case value |> String.split(",", trim: true) |> Enum.map(&String.trim/1) do
      [x, y, z] -> {parse_number!(x), parse_number!(y), parse_number!(z)}
      _other -> Mix.raise("location must be formatted as x,y,z")
    end
  rescue
    ArgumentError -> Mix.raise("location must be formatted as x,y,z")
  end

  defp parse_number!(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _other -> raise ArgumentError
    end
  end

  defp parse_known_version_mode!("none"), do: :none
  defp parse_known_version_mode!("forwarded"), do: :forwarded
  defp parse_known_version_mode!("acked"), do: :acked
  defp parse_known_version_mode!("acked-resync"), do: :acked_resync

  defp parse_known_version_mode!(mode) do
    Mix.raise("unsupported known version mode: #{inspect(mode)}")
  end

  defp seed_known_version_mode(state, :none, _logical_scene_id, _chunk_coord, _version), do: state

  defp seed_known_version_mode(state, :forwarded, logical_scene_id, chunk_coord, version) do
    Map.put(
      state,
      :forwarded_chunk_versions,
      forwarded_versions(logical_scene_id, chunk_coord, version)
    )
  end

  defp seed_known_version_mode(state, mode, logical_scene_id, chunk_coord, version)
       when mode in [:acked, :acked_resync] do
    forwarded = forwarded_versions(logical_scene_id, chunk_coord, version)

    {:ok, client_ack_versions, _event} =
      ClientAckLedger.record_ack(
        ClientAckLedger.new(),
        forwarded,
        logical_scene_id,
        chunk_coord,
        version
      )

    state =
      state
      |> Map.put(:forwarded_chunk_versions, forwarded)
      |> Map.put(:client_ack_versions, client_ack_versions)

    if mode == :acked_resync do
      Map.put(state, :voxel_delivery, %DeliveryScheduler{
        resync_required_chunks: MapSet.new([{logical_scene_id, chunk_coord}])
      })
    else
      state
    end
  end

  defp forwarded_versions(logical_scene_id, chunk_coord, version) do
    ChunkVersionLedger.new()
    |> ChunkVersionLedger.record_version!(logical_scene_id, chunk_coord, version)
  end

  defp non_negative_integer!(value, _field) when is_integer(value) and value >= 0, do: value

  defp non_negative_integer!(value, field) do
    Mix.raise("expected #{field} as non-negative integer, got: #{inspect(value)}")
  end

  defp format_optional(nil), do: "none"
  defp format_optional(value), do: "#{value}"

  defp coord_list({x, y, z}), do: [x, y, z]

  defp reset_log(path) do
    File.mkdir_p!(Path.dirname(path))
    File.rm(path)
  end

  defp restore_env(app, {:ok, value}), do: Application.put_env(app, :cli_observe_log, value)
  defp restore_env(app, :error), do: Application.delete_env(app, :cli_observe_log)
end
