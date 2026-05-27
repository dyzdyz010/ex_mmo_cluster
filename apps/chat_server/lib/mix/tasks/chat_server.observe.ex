defmodule Mix.Tasks.ChatServer.Observe do
  @moduledoc """
  Runs a standalone chat routing observe smoke.

      mix chat_server.observe --logical-scene-id 1 --channel region --text hello

  The task uses an isolated `ChatServer.Runtime`, seeds deterministic sessions,
  publishes one message, and writes structured observe logs to `.demo/observe/`
  by default.
  """

  use Mix.Task

  alias ChatServer.{CliObserve, Runtime}

  @shortdoc "Runs Chat runtime CLI observe smoke"
  @switches [
    help: :boolean,
    logical_scene_id: :integer,
    cid: :integer,
    username: :string,
    channel: :string,
    region_id: :integer,
    center: :string,
    radius: :integer,
    candidate_regions: :string,
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
    logical_scene_id = Keyword.get(opts, :logical_scene_id, 1)
    cid = Keyword.get(opts, :cid, 42)
    username = Keyword.get(opts, :username, "tester")
    text = Keyword.get(opts, :text, "hello from cli")
    observe_log = observe_log(opts, logical_scene_id)
    previous_log = Application.fetch_env(:chat_server, :cli_observe_log)

    {:ok, pid} = Runtime.start_link(name: nil)

    try do
      reset_log(observe_log)
      Application.put_env(:chat_server, :cli_observe_log, observe_log)

      seed_sessions!(pid, logical_scene_id, cid, username)

      channel = parse_channel!(opts, logical_scene_id)

      {:ok, summary} =
        Runtime.say(pid, %{
          cid: cid,
          username: username,
          logical_scene_id: logical_scene_id,
          channel: channel,
          text: text
        })

      summary = Map.put(summary, :observe_log, observe_log)
      CliObserve.flush()
      Mix.shell().info(summary_line(summary))
    after
      if Process.alive?(pid), do: GenServer.stop(pid)
      CliObserve.flush()
      restore_env(previous_log)
    end
  end

  defp seed_sessions!(runtime, logical_scene_id, cid, username) do
    :ok =
      [
        %{
          cid: cid,
          username: username,
          connection_pid: self(),
          logical_scene_id: logical_scene_id,
          region_id: 10,
          chunk_coord: {0, 0, 0}
        },
        %{
          cid: cid + 1,
          username: "nearby",
          connection_pid: self(),
          logical_scene_id: logical_scene_id,
          region_id: 10,
          chunk_coord: {1, 0, 0}
        },
        %{
          cid: cid + 2,
          username: "far-region",
          connection_pid: self(),
          logical_scene_id: logical_scene_id,
          region_id: 20,
          chunk_coord: {4, 0, 0}
        },
        %{
          cid: cid + 3,
          username: "other-scene",
          connection_pid: self(),
          logical_scene_id: logical_scene_id + 1,
          region_id: 10,
          chunk_coord: {0, 0, 0}
        }
      ]
      |> Enum.each(fn session -> {:ok, _} = Runtime.join(runtime, session) end)
  end

  defp parse_channel!(opts, logical_scene_id) do
    case Keyword.get(opts, :channel, "world") do
      "world" ->
        {:world, logical_scene_id}

      "region" ->
        {:region, logical_scene_id, Keyword.get(opts, :region_id, 10)}

      "local" ->
        center = parse_center!(Keyword.get(opts, :center, "0,0,0"))
        radius = Keyword.get(opts, :radius, 1)

        case parse_candidate_regions(Keyword.get(opts, :candidate_regions)) do
          [] -> {:local, logical_scene_id, center, radius}
          candidate_region_ids -> {:local, logical_scene_id, center, radius, candidate_region_ids}
        end

      "system" ->
        {:system, logical_scene_id}

      other ->
        Mix.raise(
          "unsupported channel #{inspect(other)}; expected world, region, local, or system"
        )
    end
  end

  defp summary_line(summary) do
    [
      "chat_observe=ok",
      "message_id=#{summary.message_id}",
      "cid=#{summary.cid}",
      "channel=#{channel_name(summary.channel)}",
      "logical_scene_id=#{logical_scene_id(summary.channel)}",
      "plan_source=#{summary.plan_source}",
      "recipient_count=#{summary.recipient_count}",
      "skipped_count=#{summary.skipped_count}",
      "history_count=#{summary.history_count}",
      "observe_log=#{summary.observe_log}"
    ]
    |> Enum.join(" ")
  end

  defp channel_name({name, _scene_id}) when name in [:world, :system], do: name
  defp channel_name({name, _scene_id, _id}) when name in [:region], do: name
  defp channel_name({:local, _scene_id, _center, _radius}), do: :local
  defp channel_name({:local, _scene_id, _center, _radius, _candidate_region_ids}), do: :local

  defp logical_scene_id({_name, scene_id}) when is_integer(scene_id), do: scene_id
  defp logical_scene_id({_name, scene_id, _id}) when is_integer(scene_id), do: scene_id
  defp logical_scene_id({:local, scene_id, _center, _radius}), do: scene_id
  defp logical_scene_id({:local, scene_id, _center, _radius, _candidate_region_ids}), do: scene_id

  defp observe_log(opts, logical_scene_id) do
    observe_dir = Keyword.get(opts, :observe_dir, ".demo/observe")
    Keyword.get(opts, :observe_log, Path.join(observe_dir, "chat-server-#{logical_scene_id}.log"))
  end

  defp parse_center!(value) do
    case value |> String.split(",", trim: true) |> Enum.map(&String.trim/1) do
      [x, y, z] -> {String.to_integer(x), String.to_integer(y), String.to_integer(z)}
      _other -> Mix.raise("center must be formatted as x,y,z")
    end
  rescue
    ArgumentError -> Mix.raise("center must be formatted as x,y,z")
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
    File.mkdir_p!(Path.dirname(path))
    File.rm(path)
  end

  defp restore_env({:ok, value}), do: Application.put_env(:chat_server, :cli_observe_log, value)
  defp restore_env(:error), do: Application.delete_env(:chat_server, :cli_observe_log)
end
