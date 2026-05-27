defmodule Mix.Tasks.GateServer.ChatScopeObserve do
  @moduledoc """
  Runs a Gate-side scoped chat observe smoke.

      mix gate_server.chat_scope_observe --logical-scene-id 9 --scope region --text hello

  The task demonstrates the non-GUI path for scoped chat:
  client scope request -> server-derived partition/chat context -> Chat runtime
  delivery plan.
  """

  use Mix.Task

  alias ChatServer.Runtime, as: ChatRuntime
  alias GateServer.{ChatAdapter, ChatScope}
  alias GateServer.CliObserve, as: GateObserve

  @shortdoc "Runs Gate scoped-chat CLI observe smoke"
  @switches [
    help: :boolean,
    logical_scene_id: :integer,
    cid: :integer,
    scope: :string,
    text: :string,
    region_id: :integer,
    chunk: :string,
    local_radius: :integer,
    candidate_regions: :string,
    candidate_region_radius: :integer,
    observe_log: :string,
    chat_observe_log: :string
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
    scope = parse_scope!(Keyword.get(opts, :scope, "region"))
    text = Keyword.get(opts, :text, "hello")
    region_id = Keyword.get(opts, :region_id, 10)
    chunk_coord = parse_chunk!(Keyword.get(opts, :chunk, "0,0,0"))
    paths = observe_paths(opts, logical_scene_id)
    previous_gate_log = Application.fetch_env(:gate_server, :cli_observe_log)
    previous_chat_log = Application.fetch_env(:chat_server, :cli_observe_log)
    {:ok, runtime_pid} = ChatRuntime.start_link(name: nil)

    try do
      reset_log(paths.gate_observe_log)
      reset_log(paths.chat_observe_log)
      Application.put_env(:gate_server, :cli_observe_log, paths.gate_observe_log)
      Application.put_env(:chat_server, :cli_observe_log, paths.chat_observe_log)

      context =
        %{
          logical_scene_id: logical_scene_id,
          region_id: region_id,
          chunk_coord: chunk_coord
        }
        |> maybe_put_candidate_region_ids(opts)

      seed_chat_sessions!(runtime_pid, cid, logical_scene_id, region_id, chunk_coord)

      {:ok, chat_target} =
        ChatScope.derive(scope, %{partition_context: context, chat_context: context},
          local_radius: Keyword.get(opts, :local_radius)
        )

      {:ok, delivery_summary} =
        ChatAdapter.publish(%{
          chat_runtime: runtime_pid,
          cid: cid,
          username: "scope-tester",
          logical_scene_id: logical_scene_id,
          channel: chat_target.channel,
          text: text
        })

      summary = summary(chat_target, delivery_summary, cid, logical_scene_id, text, paths)

      GateObserve.emit("gate_chat_scope_resolved", summary)
      flush_observe()
      Mix.shell().info(summary_line(summary))
    after
      flush_observe()
      restore_env(:gate_server, previous_gate_log)
      restore_env(:chat_server, previous_chat_log)

      if Process.alive?(runtime_pid) do
        GenServer.stop(runtime_pid)
      end
    end
  end

  defp seed_chat_sessions!(runtime, cid, logical_scene_id, region_id, chunk_coord) do
    {:ok, _sender} =
      ChatAdapter.join(%{
        chat_runtime: runtime,
        cid: cid,
        username: "scope-tester",
        connection_pid: self(),
        logical_scene_id: logical_scene_id,
        region_id: region_id,
        chunk_coord: chunk_coord,
        location: {0.0, 0.0, 0.0}
      })

    {:ok, _nearby} =
      ChatAdapter.join(%{
        chat_runtime: runtime,
        cid: cid + 1,
        username: "nearby",
        connection_pid: self(),
        logical_scene_id: logical_scene_id,
        region_id: region_id,
        chunk_coord: {elem(chunk_coord, 0) + 1, elem(chunk_coord, 1), elem(chunk_coord, 2)},
        location: {0.0, 0.0, 0.0}
      })

    {:ok, _far} =
      ChatAdapter.join(%{
        chat_runtime: runtime,
        cid: cid + 2,
        username: "far",
        connection_pid: self(),
        logical_scene_id: logical_scene_id,
        region_id: region_id + 10,
        chunk_coord: {elem(chunk_coord, 0) + 4, elem(chunk_coord, 1), elem(chunk_coord, 2)},
        location: {0.0, 0.0, 0.0}
      })
  end

  defp summary(chat_target, delivery_summary, cid, logical_scene_id, text, paths) do
    %{
      cid: cid,
      logical_scene_id: logical_scene_id,
      scope: chat_target.scope,
      channel: inspect(chat_target.channel, charlists: :as_lists),
      candidate_region_ids: Map.get(chat_target, :candidate_region_ids, []),
      candidate_region_radius: Map.get(chat_target, :candidate_region_radius),
      server_derived?: chat_target.server_derived?,
      text: text,
      message_id: delivery_summary.message_id,
      recipient_cids: delivery_summary.recipient_cids,
      recipient_count: delivery_summary.recipient_count,
      skipped_count: delivery_summary.skipped_count,
      plan_source: delivery_summary.plan_source,
      observe_log: paths.gate_observe_log,
      chat_observe_log: paths.chat_observe_log
    }
  end

  defp summary_line(summary) do
    [
      "gate_chat_scope=ok",
      "cid=#{summary.cid}",
      "logical_scene_id=#{summary.logical_scene_id}",
      "scope=#{summary.scope}",
      "channel=#{summary.channel}",
      "candidate_region_ids=#{inspect(summary.candidate_region_ids, charlists: :as_lists)}",
      "candidate_region_radius=#{inspect(summary.candidate_region_radius)}",
      "server_derived=#{summary.server_derived?}",
      "message_id=#{summary.message_id}",
      "recipient_count=#{summary.recipient_count}",
      "skipped_count=#{summary.skipped_count}",
      "plan_source=#{summary.plan_source}",
      "observe_log=#{summary.observe_log}",
      "chat_observe_log=#{summary.chat_observe_log}"
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
          Path.join(observe_dir, "gate-chat-scope-#{logical_scene_id}.log")
        ),
      chat_observe_log:
        Keyword.get(
          opts,
          :chat_observe_log,
          Path.join(observe_dir, "chat-gate-scope-#{logical_scene_id}.log")
        )
    }
  end

  defp parse_scope!("world"), do: :world
  defp parse_scope!("region"), do: :region
  defp parse_scope!("local"), do: :local
  defp parse_scope!(scope), do: Mix.raise("unsupported scope: #{inspect(scope)}")

  defp parse_chunk!(value) do
    case value |> String.split(",", trim: true) |> Enum.map(&String.trim/1) do
      [x, y, z] -> {String.to_integer(x), String.to_integer(y), String.to_integer(z)}
      _other -> Mix.raise("chunk must be formatted as x,y,z")
    end
  rescue
    ArgumentError -> Mix.raise("chunk must be formatted as x,y,z")
  end

  defp maybe_put_candidate_region_ids(context, opts) do
    case parse_candidate_regions(Keyword.get(opts, :candidate_regions)) do
      [] ->
        context

      candidate_region_ids ->
        context
        |> Map.put(:candidate_region_ids, candidate_region_ids)
        |> Map.put(
          :candidate_region_radius,
          Keyword.get(opts, :candidate_region_radius, Keyword.get(opts, :local_radius, 1))
        )
    end
  end

  defp parse_candidate_regions(nil), do: []

  defp parse_candidate_regions(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(fn part ->
      part
      |> String.trim()
      |> String.to_integer()
    end)
    |> Enum.uniq()
    |> Enum.sort()
  rescue
    ArgumentError -> Mix.raise("candidate regions must be formatted as comma-separated integers")
  end

  defp reset_log(path) do
    File.rm(path)
    File.mkdir_p!(Path.dirname(path))
  end

  defp restore_env(app, {:ok, value}), do: Application.put_env(app, :cli_observe_log, value)
  defp restore_env(app, :error), do: Application.delete_env(app, :cli_observe_log)

  defp flush_observe do
    GateObserve.flush()
    ChatServer.CliObserve.flush()
  end
end
