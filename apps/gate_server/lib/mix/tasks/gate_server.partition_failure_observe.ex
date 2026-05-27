defmodule Mix.Tasks.GateServer.PartitionFailureObserve do
  @moduledoc """
  Runs a Gate-side partition failure observe smoke.

      mix gate_server.partition_failure_observe --failure unroutable
      mix gate_server.partition_failure_observe --failure chat-refresh
      mix gate_server.partition_failure_observe --failure subscription-apply

  The task drives the shared `GateServer.PartitionRuntime` through one
  authoritative movement boundary and simulates specific downstream failures.
  It is a non-GUI probe for seamless-world recovery semantics: previous usable
  context is preserved when World cannot route, Chat failures become pending
  retry state, and Scene subscription failures do not roll back authoritative
  partition/chat context.
  """

  use Mix.Task

  alias GateServer.CliObserve, as: GateObserve
  alias GateServer.PartitionRuntime
  alias SceneServer.Voxel.Types
  alias WorldServer.Voxel.PartitionWindow

  @shortdoc "Runs Gate partition failure CLI observe smoke"
  @switches [
    help: :boolean,
    failure: :string,
    logical_scene_id: :integer,
    cid: :integer,
    from: :string,
    to: :string,
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
    failure_mode = parse_failure!(Keyword.get(opts, :failure, "unroutable"))
    logical_scene_id = Keyword.get(opts, :logical_scene_id, 1)
    cid = Keyword.get(opts, :cid, 42)
    from_location = parse_location!(Keyword.get(opts, :from, "100,100,100"))
    to_location = parse_location!(Keyword.get(opts, :to, "1650,100,100"))
    from_chunk = Types.chunk_from_world_cm!(from_location)
    to_chunk = Types.chunk_from_world_cm!(to_location)
    observe_log = observe_log(opts, logical_scene_id)
    previous_gate_log = Application.fetch_env(:gate_server, :cli_observe_log)

    previous_context = %{
      logical_scene_id: logical_scene_id,
      region_id: 10,
      chunk_coord: from_chunk
    }

    initial_state = %{
      cid: cid,
      partition_context: previous_context,
      chat_context: previous_context,
      chat_session_joined?: true,
      voxel_subscriptions: %{
        {logical_scene_id, from_chunk} => %{
          logical_scene_id: logical_scene_id,
          chunk_coord: from_chunk
        }
      },
      voxel_subscription_plan: nil
    }

    try do
      reset_log(observe_log)
      Application.put_env(:gate_server, :cli_observe_log, observe_log)

      {refresh_status, next_state, outcome} =
        refresh_failure(
          failure_mode,
          initial_state,
          cid,
          logical_scene_id,
          to_location,
          to_chunk
        )

      summary =
        summary(
          failure_mode,
          refresh_status,
          previous_context,
          next_state,
          outcome,
          from_chunk,
          to_chunk,
          observe_log
        )

      GateObserve.emit("gate_partition_failure_resolved", summary)
      GateObserve.flush()
      Mix.shell().info(summary_line(summary))
    after
      GateObserve.flush()
      restore_env(:gate_server, previous_gate_log)
    end
  end

  defp refresh_failure(failure_mode, state, cid, logical_scene_id, to_location, to_chunk) do
    ack = %{cid: cid, ack_seq: 1, auth_tick: 900, position: to_location}

    opts =
      [
        partition_radius: 0,
        route_window_fun: route_window_fun(failure_mode, logical_scene_id, to_chunk),
        chat_refresh_fun: chat_refresh_fun(failure_mode),
        subscription_apply_fun: subscription_apply_fun(failure_mode)
      ]

    case PartitionRuntime.refresh_after_movement_ack(state, ack, opts) do
      {:ok, next_state, outcome} -> {:ok, next_state, outcome}
      {:error, next_state, outcome} -> {:error, next_state, outcome}
    end
  end

  defp route_window_fun(:unroutable, _logical_scene_id, _to_chunk) do
    fn _scene_id, _center_chunk, _radius -> {:error, :unroutable_chunk} end
  end

  defp route_window_fun(_failure_mode, logical_scene_id, to_chunk) do
    window =
      PartitionWindow.build(logical_scene_id, to_chunk, near_radius: 0, halo_radius: 0)
      |> PartitionWindow.attach_routes(%{
        to_chunk => assigned_route(logical_scene_id, 20, lease(logical_scene_id, 20, 200))
      })

    fn _scene_id, _center_chunk, _radius -> {:ok, window} end
  end

  defp chat_refresh_fun(:chat_refresh) do
    fn _presence -> {:error, :chat_runtime_unavailable} end
  end

  defp chat_refresh_fun(_failure_mode) do
    fn presence -> {:ok, Map.put(presence, :username, "partition-failure-tester")} end
  end

  defp subscription_apply_fun(:subscription_apply) do
    fn current_state, partition_result ->
      diff = partition_result.subscription_diff

      {:error, current_state,
       %{
         status: :failed,
         reason: :scene_unavailable,
         subscribe_count: length(diff.subscribe_chunks),
         unsubscribe_count: length(diff.unsubscribe_chunks),
         retained_count: length(diff.retained_chunks)
       }}
    end
  end

  defp subscription_apply_fun(_failure_mode) do
    fn _current_state, _partition_result ->
      raise "subscription apply should not run for this failure mode"
    end
  end

  defp assigned_route(logical_scene_id, region_id, lease) do
    %{
      region_id: region_id,
      lease_id: lease.lease_id,
      lease: lease,
      assigned_scene_node: :"scene-a@local",
      logical_scene_id: logical_scene_id
    }
  end

  defp lease(logical_scene_id, region_id, lease_id) do
    %{
      logical_scene_id: logical_scene_id,
      region_id: region_id,
      lease_id: lease_id,
      owner_scene_instance_ref: region_id * 100,
      owner_epoch: 1,
      expires_at_ms: System.system_time(:millisecond) + :timer.minutes(10)
    }
  end

  defp summary(
         failure_mode,
         refresh_status,
         previous_context,
         next_state,
         outcome,
         from_chunk,
         to_chunk,
         observe_log
       ) do
    expected_context = expected_context(outcome)
    partition_context = context_snapshot(next_state, :partition_context)
    chat_context = context_snapshot(next_state, :chat_context)

    subscription_diff =
      Map.get(outcome, :subscription_diff, %{
        subscribe_chunks: [],
        unsubscribe_chunks: [],
        retained_chunks: []
      })

    %{
      failure_mode: failure_mode,
      refresh_status: refresh_status,
      authoritative_status: Map.get(outcome, :status, :unknown),
      cid: outcome.cid,
      logical_scene_id: outcome.logical_scene_id,
      from_chunk: Tuple.to_list(from_chunk),
      to_chunk: Tuple.to_list(to_chunk),
      from_region_id: previous_context.region_id,
      to_region_id: Map.get(next_state.partition_context || %{}, :region_id),
      partition_context_region_id: partition_context.region_id,
      partition_context_chunk: partition_context.chunk_coord,
      chat_context_region_id: chat_context.region_id,
      chat_context_chunk: chat_context.chunk_coord,
      boundary_kind: outcome.boundary_kind,
      reason: failure_reason(outcome),
      previous_context_preserved?:
        Map.get(next_state, :partition_context) == previous_context and
          Map.get(next_state, :chat_context) == previous_context,
      partition_context_updated?: context_matches?(partition_context, expected_context),
      chat_context_updated?: context_matches?(chat_context, expected_context),
      pending_chat_presence?: Map.has_key?(next_state, :pending_chat_presence),
      pending_subscription_result?: Map.has_key?(next_state, :pending_subscription_result),
      subscription_apply_status: Map.get(outcome, :subscription_apply_status, :none),
      subscribe_count: length(subscription_diff.subscribe_chunks),
      unsubscribe_count: length(subscription_diff.unsubscribe_chunks),
      retained_count: length(subscription_diff.retained_chunks),
      observe_log: observe_log
    }
  end

  defp expected_context(outcome) do
    %{
      logical_scene_id: Map.get(outcome, :logical_scene_id),
      region_id: Map.get(outcome, :region_id),
      chunk_coord: Map.get(outcome, :chunk_coord)
    }
  end

  defp context_snapshot(state, key) do
    context = Map.get(state, key) || %{}

    %{
      logical_scene_id: Map.get(context, :logical_scene_id),
      region_id: Map.get(context, :region_id),
      chunk_coord: Map.get(context, :chunk_coord)
    }
  end

  defp context_matches?(context, expected_context) do
    Enum.all?([:logical_scene_id, :region_id, :chunk_coord], fn key ->
      Map.get(context, key) == Map.get(expected_context, key)
    end)
  end

  defp failure_reason(%{subscription_apply_status: {:error, reason}}), do: reason
  defp failure_reason(%{chat_refresh_status: {:chat_refresh_failed, reason}}), do: reason
  defp failure_reason(%{reason: reason}), do: reason
  defp failure_reason(_outcome), do: :none

  defp summary_line(summary) do
    [
      "gate_partition_failure=ok",
      "failure=#{failure_token(summary.failure_mode)}",
      "refresh_status=#{summary.refresh_status}",
      "authoritative_status=#{summary.authoritative_status}",
      "cid=#{summary.cid}",
      "logical_scene_id=#{summary.logical_scene_id}",
      "from_chunk=#{Enum.join(summary.from_chunk, ",")}",
      "to_chunk=#{Enum.join(summary.to_chunk, ",")}",
      "from_region_id=#{summary.from_region_id}",
      "to_region_id=#{summary.to_region_id}",
      "partition_context_region_id=#{status_token(summary.partition_context_region_id)}",
      "partition_context_chunk=#{chunk_token(summary.partition_context_chunk)}",
      "chat_context_region_id=#{status_token(summary.chat_context_region_id)}",
      "chat_context_chunk=#{chunk_token(summary.chat_context_chunk)}",
      "boundary=#{summary.boundary_kind}",
      "reason=#{status_token(summary.reason)}",
      "previous_context_preserved=#{summary[:previous_context_preserved?]}",
      "partition_context_updated=#{summary[:partition_context_updated?]}",
      "chat_context_updated=#{summary[:chat_context_updated?]}",
      "pending_chat_presence=#{summary[:pending_chat_presence?]}",
      "pending_subscription_result=#{summary[:pending_subscription_result?]}",
      "subscription_apply_status=#{status_token(summary.subscription_apply_status)}",
      "subscribe_count=#{summary.subscribe_count}",
      "unsubscribe_count=#{summary.unsubscribe_count}",
      "retained_count=#{summary.retained_count}",
      "observe_log=#{summary.observe_log}"
    ]
    |> Enum.join(" ")
  end

  defp parse_failure!("unroutable"), do: :unroutable
  defp parse_failure!("chat-refresh"), do: :chat_refresh
  defp parse_failure!("chat_refresh"), do: :chat_refresh
  defp parse_failure!("subscription-apply"), do: :subscription_apply
  defp parse_failure!("subscription_apply"), do: :subscription_apply

  defp parse_failure!(other) do
    Mix.raise(
      "invalid --failure #{inspect(other)}; expected unroutable, chat-refresh, or subscription-apply"
    )
  end

  defp parse_location!(value) when is_binary(value) do
    case value |> String.split(",", trim: true) |> Enum.map(&parse_number!/1) do
      [x, y, z] -> {x, y, z}
      _other -> Mix.raise("expected location as x,y,z, got: #{inspect(value)}")
    end
  end

  defp parse_number!(value) do
    case Float.parse(value) do
      {number, ""} -> number
      _other -> Mix.raise("invalid number #{inspect(value)}")
    end
  end

  defp observe_log(opts, logical_scene_id) do
    observe_dir = Keyword.get(opts, :observe_dir, ".demo/observe")

    Keyword.get(
      opts,
      :observe_log,
      Path.join(observe_dir, "gate-partition-failure-#{logical_scene_id}.log")
    )
  end

  defp reset_log(path) do
    File.mkdir_p!(Path.dirname(path))
    File.rm(path)
  end

  defp restore_env(app, {:ok, value}), do: Application.put_env(app, :cli_observe_log, value)
  defp restore_env(app, :error), do: Application.delete_env(app, :cli_observe_log)

  defp failure_token(:chat_refresh), do: "chat_refresh"
  defp failure_token(:subscription_apply), do: "subscription_apply"
  defp failure_token(other), do: Atom.to_string(other)

  defp status_token({:error, reason}), do: "error:#{status_token(reason)}"
  defp status_token({kind, reason}), do: "#{status_token(kind)}:#{status_token(reason)}"
  defp status_token(nil), do: "none"
  defp status_token(value) when is_atom(value), do: Atom.to_string(value)
  defp status_token(value), do: to_string(value)

  defp chunk_token(nil), do: "none"
  defp chunk_token(value) when is_tuple(value), do: value |> Tuple.to_list() |> Enum.join(",")
  defp chunk_token(value) when is_list(value), do: Enum.join(value, ",")
  defp chunk_token(value), do: to_string(value)
end
