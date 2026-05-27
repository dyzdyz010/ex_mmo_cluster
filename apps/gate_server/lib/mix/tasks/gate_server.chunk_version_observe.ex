defmodule Mix.Tasks.GateServer.ChunkVersionObserve do
  @moduledoc """
  Runs a Gate chunk-version ledger observe smoke.

      mix gate_server.chunk_version_observe --logical-scene-id 77 --chunk 1,2,3 --snapshot-version 4 --delta-version 5

  This is a non-GUI debugging path for the per-connection voxel version
  ledger. It records one forwarded `ChunkSnapshot` and one forwarded
  `ChunkDelta`, then prints the known-version summary Gate would reuse in
  later subscription plans.
  """

  use Mix.Task

  alias GateServer.CliObserve, as: GateObserve
  alias GateServer.Voxel.ChunkVersionLedger
  alias SceneServer.Voxel.Codec, as: SceneVoxelCodec
  alias SceneServer.Voxel.Storage

  @shortdoc "Runs Gate chunk-version ledger CLI observe smoke"
  @switches [
    help: :boolean,
    logical_scene_id: :integer,
    chunk: :string,
    snapshot_version: :integer,
    delta_version: :integer,
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
    snapshot_version = non_negative_integer!(Keyword.get(opts, :snapshot_version, 0))
    delta_version = non_negative_integer!(Keyword.get(opts, :delta_version, snapshot_version + 1))
    observe_log = observe_path(opts, logical_scene_id)
    previous_gate_log = Application.fetch_env(:gate_server, :cli_observe_log)

    try do
      reset_log(observe_log)
      Application.put_env(:gate_server, :cli_observe_log, observe_log)

      snapshot_payload = snapshot_payload(logical_scene_id, chunk_coord, snapshot_version)

      {:ok, ledger, snapshot_event} =
        ChunkVersionLedger.record_payload(ChunkVersionLedger.new(), :snapshot, snapshot_payload)

      delta_payload =
        delta_payload(logical_scene_id, chunk_coord, snapshot_version, delta_version)

      {:ok, ledger, delta_event} =
        ChunkVersionLedger.record_payload(ledger, :delta, delta_payload)

      summary = %{
        logical_scene_id: logical_scene_id,
        chunk_coord: chunk_coord,
        snapshot_version: snapshot_version,
        delta_version: delta_version,
        chunk_version: Map.fetch!(delta_event, :chunk_version),
        status: Map.fetch!(delta_event, :status),
        snapshot_status: Map.fetch!(snapshot_event, :status),
        forwarded_chunk_versions: ChunkVersionLedger.format_debug(ledger),
        observe_log: observe_log
      }

      GateObserve.emit("gate_chunk_version_observe", summary)
      GateObserve.flush()
      Mix.shell().info(summary_line(summary))
    after
      GateObserve.flush()
      restore_env(:gate_server, previous_gate_log)
    end
  end

  defp snapshot_payload(logical_scene_id, chunk_coord, chunk_version) do
    storage = Storage.empty(logical_scene_id, chunk_coord, chunk_version: chunk_version)
    SceneVoxelCodec.encode_chunk_snapshot_payload(%{request_id: 1, storage: storage})
  end

  defp delta_payload(logical_scene_id, chunk_coord, base_version, new_version) do
    SceneVoxelCodec.encode_chunk_delta_payload(%{
      logical_scene_id: logical_scene_id,
      chunk_coord: chunk_coord,
      base_chunk_version: base_version,
      new_chunk_version: new_version,
      ops: []
    })
  end

  defp summary_line(summary) do
    [
      "gate_chunk_version=ok",
      "logical_scene_id=#{summary.logical_scene_id}",
      "chunk=#{format_chunk(summary.chunk_coord)}",
      "snapshot_version=#{summary.snapshot_version}",
      "delta_version=#{summary.delta_version}",
      "status=#{summary.status}",
      "forwarded_chunk_versions=#{summary.forwarded_chunk_versions}",
      "observe_log=#{summary.observe_log}"
    ]
    |> Enum.join(" ")
  end

  defp observe_path(opts, logical_scene_id) do
    observe_dir = Keyword.get(opts, :observe_dir, ".demo/observe")

    Keyword.get(
      opts,
      :observe_log,
      Path.join(observe_dir, "gate-chunk-version-#{logical_scene_id}.log")
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
