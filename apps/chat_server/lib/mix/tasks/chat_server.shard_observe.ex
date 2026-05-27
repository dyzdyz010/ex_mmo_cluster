defmodule Mix.Tasks.ChatServer.ShardObserve do
  @moduledoc """
  Runs a scene-sharded chat routing observe smoke.

      mix chat_server.shard_observe --logical-scene-id 7 --channel world --text hello

  The task uses an isolated `ChatServer.RuntimeDirectory` plus private runtime
  shard supervisor, seeds two logical scenes, publishes one message, and writes
  structured observe logs to `.demo/observe/` by default.
  """

  use Mix.Task

  alias ChatServer.{CliObserve, RuntimeDirectory}

  @shortdoc "Runs Chat logical-scene shard routing CLI observe smoke"
  @switches [
    help: :boolean,
    logical_scene_id: :integer,
    other_logical_scene_id: :integer,
    cid: :integer,
    channel: :string,
    text: :string,
    observe_dir: :string,
    observe_log: :string
  ]
  @aliases [h: :help, s: :logical_scene_id, c: :channel, o: :observe_dir]

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
    logical_scene_id = Keyword.get(opts, :logical_scene_id, 7)
    other_logical_scene_id = Keyword.get(opts, :other_logical_scene_id, logical_scene_id + 1)
    cid = Keyword.get(opts, :cid, 42)
    text = Keyword.get(opts, :text, "hello from sharded chat")
    observe_log = observe_log(opts, logical_scene_id)
    previous_log = Application.fetch_env(:chat_server, :cli_observe_log)

    {:ok, shard_sup} = DynamicSupervisor.start_link(strategy: :one_for_one)
    {:ok, directory} = RuntimeDirectory.start_link(name: nil, runtime_supervisor: shard_sup)

    try do
      reset_log(observe_log)
      Application.put_env(:chat_server, :cli_observe_log, observe_log)

      seed_sessions!(directory, logical_scene_id, other_logical_scene_id, cid)

      channel = parse_channel!(Keyword.get(opts, :channel, "world"), logical_scene_id)

      {:ok, summary} =
        RuntimeDirectory.say(directory, %{
          cid: cid,
          logical_scene_id: logical_scene_id,
          channel: channel,
          text: text
        })

      snapshot = RuntimeDirectory.snapshot(directory)

      summary =
        summary
        |> Map.put(:observe_log, observe_log)
        |> Map.put(:shard_count, snapshot.shard_count)
        |> Map.put(:other_scene_recipient_count, other_scene_recipient_count(summary, cid))

      CliObserve.flush()
      Mix.shell().info(summary_line(summary))
    after
      if Process.alive?(directory), do: GenServer.stop(directory)
      if Process.alive?(shard_sup), do: GenServer.stop(shard_sup)
      CliObserve.flush()
      restore_env(previous_log)
    end
  end

  defp seed_sessions!(directory, logical_scene_id, other_logical_scene_id, cid) do
    [
      %{
        cid: cid,
        username: "tester",
        connection_pid: self(),
        logical_scene_id: logical_scene_id,
        region_id: 10,
        chunk_coord: {0, 0, 0}
      },
      %{
        cid: cid + 1,
        username: "neighbor",
        connection_pid: self(),
        logical_scene_id: logical_scene_id,
        region_id: 10,
        chunk_coord: {1, 0, 0}
      },
      %{
        cid: cid + 100,
        username: "other-scene",
        connection_pid: self(),
        logical_scene_id: other_logical_scene_id,
        region_id: 10,
        chunk_coord: {0, 0, 0}
      }
    ]
    |> Enum.each(fn session -> {:ok, _} = RuntimeDirectory.join(directory, session) end)
  end

  defp parse_channel!("world", logical_scene_id), do: {:world, logical_scene_id}
  defp parse_channel!("system", logical_scene_id), do: {:system, logical_scene_id}

  defp parse_channel!(other, _logical_scene_id) do
    Mix.raise("unsupported channel #{inspect(other)}; expected world or system")
  end

  defp summary_line(summary) do
    [
      "chat_shard_observe=ok",
      "message_id=#{summary.message_id}",
      "cid=#{summary.cid}",
      "logical_scene_id=#{logical_scene_id(summary.channel)}",
      "shard_key=#{summary.shard_key}",
      "route_target=#{summary.route_target}",
      "shard_count=#{summary.shard_count}",
      "plan_source=#{summary.plan_source}",
      "recipient_count=#{summary.recipient_count}",
      "skipped_count=#{summary.skipped_count}",
      "other_scene_recipient_count=#{summary.other_scene_recipient_count}",
      "observe_log=#{summary.observe_log}"
    ]
    |> Enum.join(" ")
  end

  defp logical_scene_id({_name, scene_id}) when is_integer(scene_id), do: scene_id

  defp other_scene_recipient_count(summary, cid) do
    Enum.count(summary.recipient_cids, &(&1 == cid + 100))
  end

  defp observe_log(opts, logical_scene_id) do
    observe_dir = Keyword.get(opts, :observe_dir, ".demo/observe")
    Keyword.get(opts, :observe_log, Path.join(observe_dir, "chat-shard-#{logical_scene_id}.log"))
  end

  defp reset_log(path) do
    File.mkdir_p!(Path.dirname(path))
    File.rm(path)
  end

  defp restore_env({:ok, value}), do: Application.put_env(:chat_server, :cli_observe_log, value)
  defp restore_env(:error), do: Application.delete_env(:chat_server, :cli_observe_log)
end
