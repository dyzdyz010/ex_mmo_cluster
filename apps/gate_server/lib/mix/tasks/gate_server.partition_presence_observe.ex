defmodule Mix.Tasks.GateServer.PartitionPresenceObserve do
  @moduledoc """
  Runs a Gate-side authoritative partition-presence observe smoke.

      mix gate_server.partition_presence_observe --logical-scene-id 1 --from 100,100,100 --to 1650,100,100

  The task demonstrates the non-GUI path for one movement boundary refresh:
  authoritative position -> World partition window -> Gate subscription diff
  -> Chat presence refresh.
  """

  use Mix.Task

  alias ChatServer.Runtime, as: ChatRuntime
  alias GateServer.CliObserve, as: GateObserve
  alias GateServer.PartitionRuntime
  alias SceneServer.Voxel.Types
  alias WorldServer.CliObserve, as: WorldObserve
  alias WorldServer.Voxel.MapLedger

  @shortdoc "Runs Gate partition-presence CLI observe smoke"
  @switches [
    help: :boolean,
    logical_scene_id: :integer,
    cid: :integer,
    from: :string,
    to: :string,
    observe_dir: :string,
    observe_log: :string,
    chat_observe_log: :string,
    world_observe_log: :string
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
    paths = observe_paths(opts, logical_scene_id)
    previous_gate_log = Application.fetch_env(:gate_server, :cli_observe_log)
    previous_chat_log = Application.fetch_env(:chat_server, :cli_observe_log)
    previous_world_log = Application.fetch_env(:world_server, :cli_observe_log)

    {:ok, chat_pid} = ChatRuntime.start_link(name: nil)
    runtime = chat_pid
    {:ok, ledger} = MapLedger.start_link([])

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
               route_window_fun: fn scene_id, center_chunk, radius ->
                 {:ok,
                  MapLedger.partition_window(ledger, scene_id, center_chunk,
                    near_radius: 0,
                    halo_radius: radius
                  )}
               end,
               chat_refresh_fun: fn presence ->
                 ChatRuntime.refresh_presence(runtime, presence)
               end
             ) do
          {:ok, refreshed_state, refresh_outcome} -> {refreshed_state, refresh_outcome}
          {:error, refreshed_state, refresh_outcome} -> {refreshed_state, refresh_outcome}
        end

      summary =
        summary(outcome, next_state, from_location, to_location, from_chunk, to_chunk, paths)

      GateObserve.emit("gate_partition_presence_resolved", summary)
      flush_observe()
      Mix.shell().info(summary_line(summary))
    after
      if Process.alive?(ledger), do: GenServer.stop(ledger)
      if Process.alive?(chat_pid), do: GenServer.stop(chat_pid)
      flush_observe()
      restore_env(:gate_server, previous_gate_log)
      restore_env(:chat_server, previous_chat_log)
      restore_env(:world_server, previous_world_log)
    end
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

  defp summary(outcome, state, from_location, to_location, from_chunk, to_chunk, paths) do
    diff = outcome.subscription_diff
    plan = state.voxel_subscription_plan || %{}

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
      subscribe_count: length(diff.subscribe_chunks),
      unsubscribe_count: length(diff.unsubscribe_chunks),
      retained_count: length(diff.retained_chunks),
      chat_presence_updated?: outcome.status == :updated and outcome.chat_refresh_status == :ok,
      pressure: Map.get(plan, :pressure, :none),
      observe_log: paths.gate_observe_log,
      chat_observe_log: paths.chat_observe_log,
      world_observe_log: paths.world_observe_log
    }
  end

  defp summary_line(summary) do
    [
      "gate_partition_presence=ok",
      "cid=#{summary.cid}",
      "logical_scene_id=#{summary.logical_scene_id}",
      "from_location=#{Enum.join(summary.from_location, ",")}",
      "to_location=#{Enum.join(summary.to_location, ",")}",
      "from_chunk=#{Enum.join(summary.from_chunk, ",")}",
      "to_chunk=#{Enum.join(summary.to_chunk, ",")}",
      "from_region_id=#{summary.from_region_id}",
      "to_region_id=#{summary.to_region_id}",
      "boundary=#{summary.boundary_kind}",
      "subscribe_count=#{summary.subscribe_count}",
      "unsubscribe_count=#{summary.unsubscribe_count}",
      "retained_count=#{summary.retained_count}",
      "chat_presence_updated=#{summary.chat_presence_updated?}",
      "pressure=#{summary.pressure}",
      "observe_log=#{summary.observe_log}"
    ]
    |> Enum.join(" ")
  end

  defp observe_paths(opts, logical_scene_id) do
    observe_dir = Keyword.get(opts, :observe_dir, ".demo/observe")

    %{
      gate_observe_log:
        Keyword.get(
          opts,
          :observe_log,
          Path.join(observe_dir, "gate-partition-presence-#{logical_scene_id}.log")
        ),
      chat_observe_log:
        Keyword.get(
          opts,
          :chat_observe_log,
          Path.join(observe_dir, "chat-partition-presence-#{logical_scene_id}.log")
        ),
      world_observe_log:
        Keyword.get(
          opts,
          :world_observe_log,
          Path.join(observe_dir, "world-partition-presence-#{logical_scene_id}.log")
        )
    }
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

  defp coord_list({x, y, z}), do: [x, y, z]

  defp reset_log(path) do
    File.mkdir_p!(Path.dirname(path))
    File.rm(path)
  end

  defp flush_observe do
    GateObserve.flush()
    ChatServer.CliObserve.flush()
    WorldObserve.flush()
  end

  defp restore_env(app, {:ok, value}), do: Application.put_env(app, :cli_observe_log, value)
  defp restore_env(app, :error), do: Application.delete_env(app, :cli_observe_log)
end
