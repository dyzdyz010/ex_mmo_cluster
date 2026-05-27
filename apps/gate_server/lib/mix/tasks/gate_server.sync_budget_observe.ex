defmodule Mix.Tasks.GateServer.SyncBudgetObserve do
  @moduledoc """
  Runs a Gate-side voxel sync-budget observe smoke.

      mix gate_server.sync_budget_observe --logical-scene-id 1 --cid 42

  The task uses an isolated World map ledger to build a partition window, then
  feeds that window into Gate's pure sync-budget planner. It writes structured
  observe logs to `.demo/observe/` by default.
  """

  use Mix.Task

  alias GateServer.CliObserve, as: GateObserve
  alias GateServer.Voxel.SyncBudget
  alias WorldServer.CliObserve, as: WorldObserve
  alias WorldServer.Voxel.MapLedger

  @shortdoc "Runs Gate voxel sync-budget CLI observe smoke"
  @switches [
    help: :boolean,
    logical_scene_id: :integer,
    cid: :integer,
    center: :string,
    near_radius: :integer,
    halo_radius: :integer,
    near_vertical_radius: :integer,
    halo_vertical_radius: :integer,
    observe_dir: :string,
    gate_observe_log: :string,
    world_observe_log: :string
  ]
  @aliases [h: :help, s: :logical_scene_id, c: :center, o: :observe_dir]

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
    center_chunk = parse_center!(Keyword.get(opts, :center, "1,0,0"))
    near_radius = Keyword.get(opts, :near_radius, 0)
    halo_radius = Keyword.get(opts, :halo_radius, 1)
    near_vertical_radius = Keyword.get(opts, :near_vertical_radius, near_radius)
    halo_vertical_radius = Keyword.get(opts, :halo_vertical_radius, halo_radius)
    paths = observe_paths(opts, logical_scene_id)
    previous_gate_log = Application.fetch_env(:gate_server, :cli_observe_log)
    previous_world_log = Application.fetch_env(:world_server, :cli_observe_log)

    {:ok, ledger} = MapLedger.start_link([])

    try do
      reset_log(paths.gate_observe_log)
      reset_log(paths.world_observe_log)
      Application.put_env(:gate_server, :cli_observe_log, paths.gate_observe_log)
      Application.put_env(:world_server, :cli_observe_log, paths.world_observe_log)

      validate_window_options!(
        near_radius,
        halo_radius,
        near_vertical_radius,
        halo_vertical_radius
      )

      seed_partition_sample!(ledger, logical_scene_id)

      window =
        MapLedger.route_window_with_leases(ledger, logical_scene_id, center_chunk,
          near_radius: near_radius,
          halo_radius: halo_radius,
          near_vertical_radius: near_vertical_radius,
          halo_vertical_radius: halo_vertical_radius
        )

      plan =
        SyncBudget.plan(%{
          cid: cid,
          partition_window: window,
          last_server_seq: 18,
          last_client_ack_seq: 10,
          recovery_request_count: 1,
          reliable_pending_bytes: 128,
          fast_lane_pending_bytes: 512,
          stream_caps: sample_stream_caps(),
          chunk_backlogs: sample_chunk_backlogs()
        })

      summary = summary(plan, paths, logical_scene_id)
      GateObserve.emit("gate_sync_budget_window", summary)
      flush_observe()
      Mix.shell().info(summary_line(summary))
    after
      if Process.alive?(ledger), do: GenServer.stop(ledger)
      flush_observe()
      restore_env(:gate_server, previous_gate_log)
      restore_env(:world_server, previous_world_log)
    end
  end

  defp seed_partition_sample!(ledger, logical_scene_id) do
    future_ms = System.system_time(:millisecond) + :timer.minutes(10)

    {:ok, _assignment} =
      MapLedger.put_region(ledger, %{
        logical_scene_id: logical_scene_id,
        region_id: 10,
        bounds_chunk_min: {0, -1, -1},
        bounds_chunk_max: {1, 2, 2},
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
        bounds_chunk_min: {1, -1, -1},
        bounds_chunk_max: {2, 2, 2},
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

  defp sample_stream_caps do
    %{
      reliable_control: 1_024,
      voxel_snapshot: 96,
      voxel_delta: 64,
      field_state: 48,
      recovery: 72
    }
  end

  defp sample_chunk_backlogs do
    %{
      {1, 0, 0} => %{
        recovery_bytes: 64,
        snapshot_bytes: 48,
        delta_bytes: 24,
        field_bytes: 16,
        known_version: 1,
        server_version: 3
      },
      {0, 0, 0} => %{
        recovery_bytes: 32,
        snapshot_bytes: 48,
        delta_bytes: 24,
        field_bytes: 16,
        known_version: 0,
        server_version: 2
      },
      {1, 1, 0} => %{
        recovery_bytes: 32,
        snapshot_bytes: 48,
        delta_bytes: 24,
        field_bytes: 16,
        known_version: 1,
        server_version: 2
      }
    }
  end

  defp summary(plan, paths, logical_scene_id) do
    %{
      logical_scene_id: logical_scene_id,
      cid: plan.cid,
      pressure: plan.pressure,
      counters: plan.counters,
      stream_caps: plan.stream_caps,
      window_summary: window_summary(plan.window_summary),
      budget_usage: plan.budget_usage,
      chunk_plans: Enum.map(plan.chunk_plans, &chunk_plan_summary/1),
      gate_observe_log: paths.gate_observe_log,
      world_observe_log: paths.world_observe_log
    }
  end

  defp window_summary(summary) do
    %{summary | center_chunk: coord_list(summary.center_chunk)}
  end

  defp chunk_plan_summary(plan) do
    %{
      chunk_coord: coord_list(plan.chunk_coord),
      tier: plan.tier,
      priority: plan.priority,
      status: plan.status,
      region_id: plan.region_id,
      lease_id: plan.lease_id,
      known_version: plan.known_version,
      server_version: plan.server_version,
      requested_bytes: plan.requested_bytes,
      budget_bytes: plan.budget_bytes,
      recovery_budget_bytes: plan.budget_bytes.recovery,
      snapshot_budget_bytes: plan.budget_bytes.voxel_snapshot,
      delta_budget_bytes: plan.budget_bytes.voxel_delta,
      field_budget_bytes: plan.budget_bytes.field_state,
      reason: plan.reason
    }
  end

  defp summary_line(summary) do
    [
      "gate_sync_budget=ok",
      "logical_scene_id=#{summary.logical_scene_id}",
      "cid=#{summary.cid}",
      "pressure=#{summary.pressure}",
      "seq_gap=#{summary.counters.seq_gap}",
      "near_radius=#{summary.window_summary.near_radius}",
      "halo_radius=#{summary.window_summary.halo_radius}",
      "near_vertical_radius=#{summary.window_summary.near_vertical_radius}",
      "halo_vertical_radius=#{summary.window_summary.halo_vertical_radius}",
      "near=#{summary.window_summary.near_chunk_count}",
      "halo=#{summary.window_summary.halo_chunk_count}",
      "assigned=#{summary.window_summary.assigned_chunk_count}",
      "unleased=#{summary.window_summary.unleased_chunk_count}",
      "missing=#{summary.window_summary.missing_chunk_count}",
      "recovery_allocated=#{summary.budget_usage.recovery.allocated_bytes}",
      "snapshot_allocated=#{summary.budget_usage.voxel_snapshot.allocated_bytes}",
      "gate_observe_log=#{summary.gate_observe_log}",
      "world_observe_log=#{summary.world_observe_log}"
    ]
    |> Enum.join(" ")
  end

  defp observe_paths(opts, logical_scene_id) do
    observe_dir = Keyword.get(opts, :observe_dir, ".demo/observe")

    %{
      gate_observe_log:
        Keyword.get(
          opts,
          :gate_observe_log,
          Path.join(observe_dir, "gate-sync-budget-window-#{logical_scene_id}.log")
        ),
      world_observe_log:
        Keyword.get(
          opts,
          :world_observe_log,
          Path.join(observe_dir, "world-sync-budget-window-#{logical_scene_id}.log")
        )
    }
  end

  defp parse_center!(value) do
    case value |> String.split(",", trim: true) |> Enum.map(&String.trim/1) do
      [x, y, z] ->
        {String.to_integer(x), String.to_integer(y), String.to_integer(z)}

      _other ->
        Mix.raise("center must be formatted as x,y,z")
    end
  rescue
    ArgumentError -> Mix.raise("center must be formatted as x,y,z")
  end

  defp validate_window_options!(
         near_radius,
         halo_radius,
         near_vertical_radius,
         halo_vertical_radius
       ) do
    cond do
      not is_integer(near_radius) or near_radius < 0 ->
        Mix.raise("near_radius must be a non-negative integer")

      not is_integer(halo_radius) or halo_radius < near_radius ->
        Mix.raise("halo_radius must be greater than or equal to near_radius")

      not is_integer(near_vertical_radius) or near_vertical_radius < 0 ->
        Mix.raise("near_vertical_radius must be a non-negative integer")

      not is_integer(halo_vertical_radius) or halo_vertical_radius < near_vertical_radius ->
        Mix.raise("halo_vertical_radius must be greater than or equal to near_vertical_radius")

      true ->
        :ok
    end
  end

  defp coord_list(nil), do: nil
  defp coord_list({x, y, z}), do: [x, y, z]
  defp coord_list([_x, _y, _z] = coord), do: coord

  defp reset_log(path) do
    File.mkdir_p!(Path.dirname(path))
    File.rm(path)
  end

  defp flush_observe do
    GateObserve.flush()
    WorldObserve.flush()
  end

  defp restore_env(app, {:ok, value}), do: Application.put_env(app, :cli_observe_log, value)
  defp restore_env(app, :error), do: Application.delete_env(app, :cli_observe_log)
end
