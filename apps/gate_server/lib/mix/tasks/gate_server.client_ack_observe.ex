defmodule Mix.Tasks.GateServer.ClientAckObserve do
  @moduledoc """
  Runs a Gate client-ACK retention observe smoke.

      mix gate_server.client_ack_observe --logical-scene-id 77 --chunk 1,2,3 --forwarded-version 5 --ack-version 5

  This is a non-GUI debugging path for the explicit `0x76 VoxelChunkAck`
  retention ledger. It records a forwarded chunk version, accepts one matching
  client ACK, rejects one impossible ACK ahead of the forwarded version, then
  clears the ACK on a migration invalidate.
  """

  use Mix.Task

  alias GateServer.CliObserve, as: GateObserve
  alias GateServer.Voxel.{ChunkVersionLedger, ClientAckLedger}
  alias SceneServer.Voxel.Codec, as: SceneVoxelCodec

  @shortdoc "Runs Gate client ACK ledger CLI observe smoke"
  @switches [
    help: :boolean,
    logical_scene_id: :integer,
    chunk: :string,
    forwarded_version: :integer,
    ack_version: :integer,
    observe_dir: :string,
    observe_log: :string
  ]
  @aliases [h: :help, s: :logical_scene_id, c: :chunk, o: :observe_dir]

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
    chunk_coord = parse_chunk!(Keyword.get(opts, :chunk, "0,0,0"))
    forwarded_version = non_negative_integer!(Keyword.get(opts, :forwarded_version, 1))
    ack_version = non_negative_integer!(Keyword.get(opts, :ack_version, forwarded_version))
    observe_log = observe_path(opts, logical_scene_id)
    previous_gate_log = Application.fetch_env(:gate_server, :cli_observe_log)

    try do
      reset_log(observe_log)
      Application.put_env(:gate_server, :cli_observe_log, observe_log)

      forwarded =
        ChunkVersionLedger.new()
        |> ChunkVersionLedger.record_version!(logical_scene_id, chunk_coord, forwarded_version)

      {:ok, acked, ack_event} =
        ClientAckLedger.record_ack(
          ClientAckLedger.new(),
          forwarded,
          logical_scene_id,
          chunk_coord,
          ack_version
        )

      {:error, _acked, ahead_event} =
        ClientAckLedger.record_ack(
          acked,
          forwarded,
          logical_scene_id,
          chunk_coord,
          forwarded_version + 1
        )

      invalidate_payload =
        SceneVoxelCodec.encode_chunk_invalidate_payload(%{
          logical_scene_id: logical_scene_id,
          chunk_coord: chunk_coord,
          reason: 0x01
        })

      {:ok, _cleared, clear_event} =
        ClientAckLedger.clear_invalidate_payload(acked, invalidate_payload)

      summary = %{
        logical_scene_id: logical_scene_id,
        chunk_coord: chunk_coord,
        forwarded_version: forwarded_version,
        ack_version: ack_version,
        ack_status: ack_event.status,
        ahead_status: ahead_event.status,
        cleared_status: clear_event.status,
        acked_chunk_versions: ClientAckLedger.format_debug(acked),
        observe_log: observe_log
      }

      GateObserve.emit("gate_client_ack_observe", summary)
      GateObserve.flush()
      Mix.shell().info(summary_line(summary))
    after
      GateObserve.flush()
      restore_env(:gate_server, previous_gate_log)
    end
  end

  defp summary_line(summary) do
    [
      "gate_client_ack=ok",
      "logical_scene_id=#{summary.logical_scene_id}",
      "chunk=#{format_chunk(summary.chunk_coord)}",
      "forwarded_version=#{summary.forwarded_version}",
      "ack_version=#{summary.ack_version}",
      "ack_status=#{summary.ack_status}",
      "ahead_status=#{summary.ahead_status}",
      "cleared_status=#{summary.cleared_status}",
      "acked_chunk_versions=#{summary.acked_chunk_versions}",
      "observe_log=#{summary.observe_log}"
    ]
    |> Enum.join(" ")
  end

  defp observe_path(opts, logical_scene_id) do
    observe_dir = Keyword.get(opts, :observe_dir, ".demo/observe")

    Keyword.get(
      opts,
      :observe_log,
      Path.join(observe_dir, "gate-client-ack-#{logical_scene_id}.log")
    )
  end

  defp parse_chunk!(value) do
    case value |> String.split(",", trim: true) |> Enum.map(&String.trim/1) do
      [x, y, z] -> {parse_integer!(x), parse_integer!(y), parse_integer!(z)}
      _other -> Mix.raise("chunk must be formatted as x,y,z")
    end
  rescue
    ArgumentError -> Mix.raise("chunk must be formatted as x,y,z")
  end

  defp parse_integer!(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _other -> raise ArgumentError
    end
  end

  defp non_negative_integer!(value) when is_integer(value) and value >= 0, do: value
  defp non_negative_integer!(_value), do: Mix.raise("versions must be non-negative integers")

  defp format_chunk({x, y, z}), do: "#{x},#{y},#{z}"

  defp reset_log(path) do
    File.mkdir_p!(Path.dirname(path))
    File.rm(path)
  end

  defp restore_env(app, {:ok, value}), do: Application.put_env(app, :cli_observe_log, value)
  defp restore_env(app, :error), do: Application.delete_env(app, :cli_observe_log)
end
