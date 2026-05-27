defmodule Mix.Tasks.GateServer.ChatBoundaryObserve do
  @moduledoc """
  Runs a Gate-side chat boundary observe smoke.

      mix gate_server.chat_boundary_observe --logical-scene-id 9 --scope region

  The task demonstrates the non-GUI path for one authoritative movement
  boundary refresh:

  Scene/World authoritative movement -> Gate partition/chat refresh ->
  server-derived scoped chat delivery.
  """

  use Mix.Task

  alias ChatServer.Runtime, as: ChatRuntime
  alias GateServer.{ChatAdapter, ChatScope}
  alias GateServer.CliObserve, as: GateObserve
  alias GateServer.PartitionRuntime
  alias SceneServer.Voxel.Types
  alias WorldServer.CliObserve, as: WorldObserve
  alias WorldServer.Voxel.MapLedger

  @shortdoc "Runs Gate chat-boundary CLI observe smoke"
  @switches [
    help: :boolean,
    logical_scene_id: :integer,
    cid: :integer,
    from: :string,
    to: :string,
    scope: :string,
    text: :string,
    local_radius: :integer,
    observe_log: :string,
    chat_observe_log: :string,
    world_observe_log: :string
  ]
  @aliases [h: :help, s: :logical_scene_id, c: :cid]

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
    scope = parse_scope!(Keyword.get(opts, :scope, "region"))
    text = Keyword.get(opts, :text, "hello-boundary")
    local_radius = Keyword.get(opts, :local_radius, 1)
    from_chunk = Types.chunk_from_world_cm!(from_location)
    to_chunk = Types.chunk_from_world_cm!(to_location)
    paths = observe_paths(opts, logical_scene_id)
    previous_gate_log = Application.fetch_env(:gate_server, :cli_observe_log)
    previous_chat_log = Application.fetch_env(:chat_server, :cli_observe_log)
    previous_world_log = Application.fetch_env(:world_server, :cli_observe_log)
    {:ok, chat_runtime} = ChatRuntime.start_link(name: nil)
    {:ok, ledger} = MapLedger.start_link([])

    old_region_receiver_cid = cid + 1
    new_region_receiver_cid = cid + 2
    other_region_receiver_cid = cid + 3

    try do
      reset_log(paths.gate_observe_log)
      reset_log(paths.chat_observe_log)
      reset_log(paths.world_observe_log)
      Application.put_env(:gate_server, :cli_observe_log, paths.gate_observe_log)
      Application.put_env(:chat_server, :cli_observe_log, paths.chat_observe_log)
      Application.put_env(:world_server, :cli_observe_log, paths.world_observe_log)

      seed_partition_sample!(ledger, logical_scene_id)

      previous_context = %{
        logical_scene_id: logical_scene_id,
        region_id: 10,
        chunk_coord: from_chunk
      }

      seed_chat_sessions!(
        chat_runtime,
        cid,
        old_region_receiver_cid,
        new_region_receiver_cid,
        other_region_receiver_cid,
        logical_scene_id,
        from_location,
        to_location,
        from_chunk,
        to_chunk
      )

      state = %{
        cid: cid,
        partition_context: previous_context,
        chat_context: previous_context,
        voxel_subscriptions: %{{logical_scene_id, from_chunk} => %{chunk_coord: from_chunk}},
        voxel_subscription_plan: nil
      }

      {next_state, outcome} =
        case PartitionRuntime.refresh_after_movement_ack(
               state,
               %{cid: cid, ack_seq: 1, auth_tick: 1, position: to_location},
               route_window_fun: route_window_fun(ledger, paths.world_observe_log),
               chat_refresh_fun: fn presence ->
                 ChatRuntime.refresh_presence(chat_runtime, presence)
               end,
               subscription_apply_fun: &chat_boundary_subscription_apply/2
             ) do
          {:ok, refreshed_state, refresh_outcome} -> {refreshed_state, refresh_outcome}
          {:error, refreshed_state, refresh_outcome} -> {refreshed_state, refresh_outcome}
        end

      {:ok, chat_target} =
        ChatScope.derive(
          scope,
          %{
            partition_context: next_state.partition_context,
            chat_context: next_state.chat_context
          },
          local_radius: local_radius
        )

      {:ok, delivery_summary} =
        ChatAdapter.publish(%{
          chat_runtime: chat_runtime,
          cid: cid,
          username: "boundary-tester",
          logical_scene_id: logical_scene_id,
          channel: chat_target.channel,
          text: text
        })

      summary =
        summary(
          outcome,
          chat_target,
          delivery_summary,
          cid,
          logical_scene_id,
          from_chunk,
          to_chunk,
          old_region_receiver_cid,
          new_region_receiver_cid,
          paths
        )

      GateObserve.emit("gate_chat_boundary_resolved", summary)
      flush_observe()
      Mix.shell().info(summary_line(summary))
    after
      if Process.alive?(ledger), do: GenServer.stop(ledger)
      if Process.alive?(chat_runtime), do: GenServer.stop(chat_runtime)
      flush_observe()
      restore_env(:gate_server, previous_gate_log)
      restore_env(:chat_server, previous_chat_log)
      restore_env(:world_server, previous_world_log)
    end
  end

  defp route_window_fun(ledger, observe_log) do
    fn logical_scene_id, center_chunk, radius ->
      window =
        MapLedger.partition_window(ledger, logical_scene_id, center_chunk,
          near_radius: 0,
          halo_radius: radius
        )

      route_index_stats = MapLedger.route_index_stats(ledger)

      WorldObserve.emit("world_partition_window", %{
        logical_scene_id: logical_scene_id,
        center_chunk: Tuple.to_list(center_chunk),
        near_radius: window.near_radius,
        halo_radius: window.halo_radius,
        route_index_source: :map_ledger,
        route_index_stats: route_index_stats,
        routed_count: Enum.count(window.route_entries, &(&1.status != :missing)),
        region_count: length(window.region_summaries),
        observe_log: observe_log
      })

      {:ok, window}
    end
  end

  defp chat_boundary_subscription_apply(current_state, partition_result) do
    diff = Map.get(partition_result, :subscription_diff, %{})

    {:ok, current_state,
     %{
       status: :skipped,
       reason: :chat_boundary_observe_no_scene_runtime,
       subscribe_count: length(Map.get(diff, :subscribe_chunks, [])),
       unsubscribe_count: length(Map.get(diff, :unsubscribe_chunks, [])),
       retained_count: length(Map.get(diff, :retained_chunks, []))
     }}
  end

  defp seed_chat_sessions!(
         runtime,
         cid,
         old_region_receiver_cid,
         new_region_receiver_cid,
         other_region_receiver_cid,
         logical_scene_id,
         from_location,
         to_location,
         from_chunk,
         to_chunk
       ) do
    {:ok, _sender} =
      ChatAdapter.join(%{
        chat_runtime: runtime,
        cid: cid,
        username: "boundary-tester",
        connection_pid: self(),
        logical_scene_id: logical_scene_id,
        region_id: 10,
        chunk_coord: from_chunk,
        location: from_location
      })

    {:ok, _old_region_receiver} =
      ChatAdapter.join(%{
        chat_runtime: runtime,
        cid: old_region_receiver_cid,
        username: "old-region",
        connection_pid: self(),
        logical_scene_id: logical_scene_id,
        region_id: 10,
        chunk_coord: from_chunk,
        location: from_location
      })

    {:ok, _new_region_receiver} =
      ChatAdapter.join(%{
        chat_runtime: runtime,
        cid: new_region_receiver_cid,
        username: "new-region",
        connection_pid: self(),
        logical_scene_id: logical_scene_id,
        region_id: 20,
        chunk_coord: to_chunk,
        location: to_location
      })

    {:ok, _other_region_receiver} =
      ChatAdapter.join(%{
        chat_runtime: runtime,
        cid: other_region_receiver_cid,
        username: "other-region",
        connection_pid: self(),
        logical_scene_id: logical_scene_id,
        region_id: 30,
        chunk_coord: {elem(to_chunk, 0) + 4, elem(to_chunk, 1), elem(to_chunk, 2)},
        location: {elem(to_location, 0) + 6400.0, elem(to_location, 1), elem(to_location, 2)}
      })

    :ok
  end

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
        assigned_scene_node: :scene_a@local
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
        assigned_scene_node: :scene_b@local
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

  defp summary(
         outcome,
         chat_target,
         delivery_summary,
         cid,
         logical_scene_id,
         from_chunk,
         to_chunk,
         old_region_receiver_cid,
         new_region_receiver_cid,
         paths
       ) do
    recipient_cids = Map.get(delivery_summary, :recipient_cids, [])

    %{
      cid: cid,
      logical_scene_id: logical_scene_id,
      from_chunk: Tuple.to_list(from_chunk),
      to_chunk: Tuple.to_list(to_chunk),
      from_region_id: outcome.previous_region_id,
      to_region_id: outcome.region_id,
      boundary_kind: outcome.boundary_kind,
      chat_presence_updated?:
        outcome.status == :updated and Map.get(outcome, :chat_refresh_status) == :ok,
      scope: chat_target.scope,
      channel: inspect(chat_target.channel, charlists: :as_lists),
      candidate_region_ids: Map.get(chat_target, :candidate_region_ids, []),
      candidate_region_radius: Map.get(chat_target, :candidate_region_radius),
      voxel_subscription_apply: subscription_apply_mode(outcome),
      recipient_count: delivery_summary.recipient_count,
      recipient_cids: recipient_cids,
      old_region_delivered?: old_region_receiver_cid in recipient_cids,
      new_region_delivered?: new_region_receiver_cid in recipient_cids,
      observe_log: paths.gate_observe_log,
      chat_observe_log: paths.chat_observe_log,
      world_observe_log: paths.world_observe_log
    }
  end

  defp summary_line(summary) do
    [
      "gate_chat_boundary=ok",
      "cid=#{summary.cid}",
      "logical_scene_id=#{summary.logical_scene_id}",
      "from_region_id=#{summary.from_region_id}",
      "to_region_id=#{summary.to_region_id}",
      "boundary=#{summary.boundary_kind}",
      "chat_presence_updated=#{summary.chat_presence_updated?}",
      "scope=#{summary.scope}",
      "channel=#{summary.channel}",
      "voxel_subscription_apply=#{summary.voxel_subscription_apply}",
      "recipient_count=#{summary.recipient_count}",
      "old_region_delivered=#{summary.old_region_delivered?}",
      "new_region_delivered=#{summary.new_region_delivered?}",
      "observe_log=#{summary.observe_log}",
      "chat_observe_log=#{summary.chat_observe_log}",
      "world_observe_log=#{summary.world_observe_log}"
    ]
    |> Enum.join(" ")
  end

  defp observe_paths(opts, logical_scene_id) do
    observe_dir = ".demo/observe"

    %{
      gate_observe_log:
        Keyword.get(
          opts,
          :observe_log,
          Path.join(observe_dir, "gate-chat-boundary-#{logical_scene_id}.log")
        ),
      chat_observe_log:
        Keyword.get(
          opts,
          :chat_observe_log,
          Path.join(observe_dir, "chat-gate-boundary-#{logical_scene_id}.log")
        ),
      world_observe_log:
        Keyword.get(
          opts,
          :world_observe_log,
          Path.join(observe_dir, "world-gate-boundary-#{logical_scene_id}.log")
        )
    }
  end

  defp subscription_apply_mode(outcome) do
    outcome
    |> Map.get(:subscription_apply_summary, %{})
    |> Map.get(:status, :not_applicable)
  end

  defp parse_scope!("region"), do: :region
  defp parse_scope!("local"), do: :local
  defp parse_scope!(scope), do: Mix.raise("unsupported scope: #{inspect(scope)}")

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

  defp reset_log(path) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "")
  end

  defp flush_observe do
    GateObserve.flush()
    ChatServer.CliObserve.flush()
    WorldObserve.flush()
  end

  defp restore_env(app, {:ok, value}), do: Application.put_env(app, :cli_observe_log, value)
  defp restore_env(app, :error), do: Application.delete_env(app, :cli_observe_log)
end
