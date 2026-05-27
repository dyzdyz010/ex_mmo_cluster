defmodule Mix.Tasks.GateServer.DeliverySchedulerObserve do
  @moduledoc """
  Runs a Gate live voxel delivery scheduler observe smoke.

      mix gate_server.delivery_scheduler_observe --logical-scene-id 77 --chunk 1,2,3 --max-window-bytes 78000

  This is a non-GUI debugging path for per-connection live voxel send
  scheduling. It offers one `ChunkSnapshot`, one over-budget `ChunkDelta`, one
  `ChunkInvalidate`, and representative object / field live frames, then
  prints the scheduler counters and writes observe events when
  `:gate_server, :cli_observe_log` or `--observe-log` is set.
  """

  use Mix.Task

  alias GateServer.CliObserve, as: GateObserve
  alias GateServer.Voxel.DeliveryScheduler
  alias SceneServer.Voxel.Codec, as: SceneVoxelCodec
  alias SceneServer.Voxel.Storage

  @shortdoc "Runs Gate live voxel delivery scheduler CLI observe smoke"
  @switches [
    help: :boolean,
    logical_scene_id: :integer,
    chunk: :string,
    snapshot_version: :integer,
    delta_version: :integer,
    max_window_bytes: :integer,
    max_queue_items: :integer,
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
    snapshot_version = non_negative_integer!(Keyword.get(opts, :snapshot_version, 1))
    delta_version = non_negative_integer!(Keyword.get(opts, :delta_version, snapshot_version + 1))
    observe_log = observe_path(opts, logical_scene_id)
    previous_gate_log = Application.fetch_env(:gate_server, :cli_observe_log)

    try do
      reset_log(observe_log)
      Application.put_env(:gate_server, :cli_observe_log, observe_log)

      snapshot_payload = snapshot_payload(logical_scene_id, chunk_coord, snapshot_version)

      delta_payload =
        delta_payload(logical_scene_id, chunk_coord, snapshot_version, delta_version)

      invalidate_payload =
        SceneVoxelCodec.encode_chunk_invalidate_payload(%{
          logical_scene_id: logical_scene_id,
          chunk_coord: chunk_coord,
          reason: 0x01
        })

      object_payload = object_state_delta_payload(logical_scene_id, chunk_coord)
      field_snapshot_payload = field_region_snapshot_payload(logical_scene_id, chunk_coord, 42, 1)
      field_destroyed_payload = field_region_destroyed_payload(logical_scene_id, chunk_coord, 42)
      envelope_payload = <<0xE1, 0xE2, 0xE3>>
      envelope_control_payload = <<0xE4>>

      scheduler =
        DeliveryScheduler.new(
          max_window_bytes: Keyword.get(opts, :max_window_bytes, byte_size(snapshot_payload) + 1),
          max_queue_items: Keyword.get(opts, :max_queue_items, 8),
          max_queue_bytes:
            byte_size(snapshot_payload) + byte_size(delta_payload) + byte_size(object_payload) +
              byte_size(field_snapshot_payload) + byte_size(field_destroyed_payload) +
              byte_size(envelope_payload) + byte_size(envelope_control_payload) + 128
        )

      {scheduler, snapshot_action} =
        observe_offer(scheduler, :snapshot, snapshot_payload, "gate_voxel_delivery_offer")

      {scheduler, delta_action} =
        observe_offer(scheduler, :delta, delta_payload, "gate_voxel_delivery_offer")

      {scheduler, invalidate_action} =
        observe_offer(scheduler, :invalidate, invalidate_payload, "gate_voxel_delivery_offer")

      {scheduler, object_action} =
        observe_offer(
          scheduler,
          :object_state_delta,
          object_payload,
          "gate_voxel_delivery_offer"
        )

      {scheduler, field_snapshot_action} =
        observe_offer(
          scheduler,
          :field_region_snapshot,
          field_snapshot_payload,
          "gate_voxel_delivery_offer"
        )

      {scheduler, field_destroyed_action} =
        observe_offer(
          scheduler,
          :field_region_destroyed,
          field_destroyed_payload,
          "gate_voxel_delivery_offer"
        )

      envelope =
        field_region_envelope(logical_scene_id, chunk_coord, envelope_payload,
          region_id: 43,
          tick_count: 2
        )

      {scheduler, envelope_action} =
        observe_envelope_offer(
          scheduler,
          envelope,
          "gate_voxel_delivery_envelope_offer"
        )

      envelope_control =
        field_region_destroyed_envelope(logical_scene_id, chunk_coord, envelope_control_payload,
          region_id: 43
        )

      {scheduler, envelope_control_action} =
        observe_envelope_offer(
          scheduler,
          envelope_control,
          "gate_voxel_delivery_envelope_offer"
        )

      summary =
        scheduler
        |> DeliveryScheduler.summary()
        |> Map.merge(%{
          logical_scene_id: logical_scene_id,
          chunk_coord: chunk_coord,
          snapshot_action: snapshot_action.action,
          delta_action: delta_action.action,
          invalidate_action: invalidate_action.action,
          object_action: object_action.action,
          field_snapshot_action: field_snapshot_action.action,
          field_destroyed_action: field_destroyed_action.action,
          envelope_action: envelope_action.action,
          envelope_control_action: envelope_control_action.action,
          envelope_tier: envelope_action.tier,
          envelope_stream_class: envelope_action.stream_class,
          envelope_lease_id: envelope_action.lease_id,
          envelope_owner_epoch: envelope_action.owner_epoch,
          observe_log: observe_log
        })

      GateObserve.emit("gate_voxel_delivery_scheduler_observe", summary)
      GateObserve.flush()
      Mix.shell().info(summary_line(summary))
    after
      GateObserve.flush()
      restore_env(:gate_server, previous_gate_log)
    end
  end

  defp observe_offer(scheduler, frame_kind, payload, event) do
    {scheduler, action} = DeliveryScheduler.offer(scheduler, frame_kind, payload)

    GateObserve.emit(event, fn ->
      action
      |> Map.take([
        :action,
        :status,
        :frame_kind,
        :logical_scene_id,
        :chunk_coord,
        :object_id,
        :object_version,
        :affected_chunks,
        :region_id,
        :tick_count,
        :destroy_reason,
        :base_chunk_version,
        :chunk_version,
        :bytes,
        :pruned_count,
        :dropped_count
      ])
      |> Map.put(:summary, DeliveryScheduler.summary(scheduler))
    end)

    {scheduler, action}
  end

  defp observe_envelope_offer(scheduler, envelope, event) do
    {scheduler, action} = DeliveryScheduler.offer_envelope(scheduler, envelope)

    GateObserve.emit(event, fn ->
      action
      |> Map.take([
        :action,
        :status,
        :frame_kind,
        :logical_scene_id,
        :chunk_coord,
        :tier,
        :stream_class,
        :byte_size,
        :server_version,
        :lease_id,
        :owner_epoch,
        :metadata_source,
        :payload_decode_used,
        :region_id,
        :tick_count,
        :destroy_reason,
        :bytes,
        :pruned_count,
        :dropped_count,
        :reason,
        :expected_byte_size,
        :actual_byte_size
      ])
      |> Map.put(:summary, DeliveryScheduler.summary(scheduler))
    end)

    {scheduler, action}
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

  defp object_state_delta_payload(logical_scene_id, chunk_coord) do
    SceneVoxelCodec.encode_voxel_object_state_delta_payload(%{
      logical_scene_id: logical_scene_id,
      object_id: 1,
      object_version: 1,
      state_flags: 0x01,
      affected_chunks: [chunk_coord]
    })
  end

  defp field_region_snapshot_payload(logical_scene_id, {cx, cy, cz}, region_id, tick_count) do
    <<0x73, logical_scene_id::64-big, cx::32-big-signed, cy::32-big-signed, cz::32-big-signed,
      region_id::64-big, tick_count::32-big, 0::8, 0::16-big>>
  end

  defp field_region_destroyed_payload(logical_scene_id, {cx, cy, cz}, region_id) do
    <<0x74, logical_scene_id::64-big, cx::32-big-signed, cy::32-big-signed, cz::32-big-signed,
      region_id::64-big, 0::8>>
  end

  defp field_region_envelope(logical_scene_id, chunk_coord, payload, opts) do
    %{
      frame_kind: :field_region_snapshot,
      logical_scene_id: logical_scene_id,
      chunk_coord: chunk_coord,
      tier: :halo,
      stream_class: :field_state,
      byte_size: byte_size(payload),
      server_version: 2,
      lease_id: 100,
      owner_epoch: 1,
      region_id: Keyword.fetch!(opts, :region_id),
      tick_count: Keyword.fetch!(opts, :tick_count),
      payload: payload
    }
  end

  defp field_region_destroyed_envelope(logical_scene_id, chunk_coord, payload, opts) do
    %{
      frame_kind: :field_region_destroyed,
      logical_scene_id: logical_scene_id,
      chunk_coord: chunk_coord,
      tier: :halo,
      stream_class: :reliable_control,
      byte_size: byte_size(payload),
      server_version: 2,
      lease_id: 100,
      owner_epoch: 1,
      region_id: Keyword.fetch!(opts, :region_id),
      destroy_reason: :lease_revoked,
      payload: payload
    }
  end

  defp summary_line(summary) do
    [
      "gate_delivery_scheduler=ok",
      "logical_scene_id=#{summary.logical_scene_id}",
      "chunk=#{format_chunk(summary.chunk_coord)}",
      "snapshot_action=#{summary.snapshot_action}",
      "delta_action=#{summary.delta_action}",
      "invalidate_action=#{summary.invalidate_action}",
      "object_action=#{summary.object_action}",
      "field_snapshot_action=#{summary.field_snapshot_action}",
      "field_destroyed_action=#{summary.field_destroyed_action}",
      "envelope_action=#{summary.envelope_action}",
      "envelope_control_action=#{summary.envelope_control_action}",
      "envelope_tier=#{summary.envelope_tier}",
      "envelope_stream_class=#{summary.envelope_stream_class}",
      "envelope_lease_id=#{summary.envelope_lease_id}",
      "envelope_owner_epoch=#{summary.envelope_owner_epoch}",
      "queued_count=#{summary.queued_count}",
      "deferred_count=#{summary.deferred_count}",
      "pruned_count=#{summary.pruned_count}",
      "resync_required_count=#{summary.resync_required_count}",
      "sent_count=#{summary.sent_count}",
      "control_sent_count=#{summary.control_sent_count}",
      "event_sent_count=#{summary.event_sent_count}",
      "observe_log=#{summary.observe_log}"
    ]
    |> Enum.join(" ")
  end

  defp observe_path(opts, logical_scene_id) do
    observe_dir = Keyword.get(opts, :observe_dir, ".demo/observe")

    Keyword.get(
      opts,
      :observe_log,
      Path.join(observe_dir, "gate-delivery-scheduler-#{logical_scene_id}.log")
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
