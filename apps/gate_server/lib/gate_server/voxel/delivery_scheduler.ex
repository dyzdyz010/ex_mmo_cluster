defmodule GateServer.Voxel.DeliveryScheduler do
  @moduledoc """
  Pure per-connection scheduler for live voxel payload delivery.

  Subscription planning reserves budget before Gate asks Scene for chunks.
  This scheduler covers the other half of the transport boundary: Scene may
  push live `ChunkSnapshot` / `ChunkDelta` payloads after subscription, and
  Gate must decide whether each payload can be written to one client connection
  now or should wait for a later send window.

  Scene remains the authoritative voxel state owner. Gate only owns local
  transport pressure, a bounded queue, and delivery observability.
  """

  alias GateServer.Voxel.DeliveryEnvelope
  alias SceneServer.Voxel.Codec, as: SceneVoxelCodec
  @default_max_window_bytes 64 * 1_024
  @default_max_window_items 32
  @default_max_queue_items 64
  @default_max_queue_bytes 1_024 * 1_024
  @default_window_interval_ms 50

  defstruct max_window_bytes: @default_max_window_bytes,
            max_window_items: @default_max_window_items,
            max_queue_items: @default_max_queue_items,
            max_queue_bytes: @default_max_queue_bytes,
            window_interval_ms: @default_window_interval_ms,
            window_bytes_used: 0,
            window_items_used: 0,
            queue: [],
            queued_bytes: 0,
            sent_count: 0,
            control_sent_count: 0,
            event_sent_count: 0,
            deferred_count: 0,
            dropped_count: 0,
            pruned_count: 0,
            oversize_count: 0,
            resync_required_chunks: MapSet.new(),
            next_queue_seq: 1

  @type frame_kind ::
          :snapshot
          | :delta
          | :invalidate
          | :object_state_delta
          | :field_region_snapshot
          | :field_region_destroyed

  @doc "Builds a new live delivery scheduler with bounded defaults."
  def new(opts \\ []) do
    opts = Map.new(opts)

    %__MODULE__{
      max_window_bytes:
        non_negative_integer!(
          Map.get(opts, :max_window_bytes, @default_max_window_bytes),
          :max_window_bytes
        ),
      max_window_items:
        non_negative_integer!(
          Map.get(opts, :max_window_items, @default_max_window_items),
          :max_window_items
        ),
      max_queue_items:
        non_negative_integer!(
          Map.get(opts, :max_queue_items, @default_max_queue_items),
          :max_queue_items
        ),
      max_queue_bytes:
        non_negative_integer!(
          Map.get(opts, :max_queue_bytes, @default_max_queue_bytes),
          :max_queue_bytes
        ),
      window_interval_ms:
        positive_integer!(
          Map.get(opts, :window_interval_ms, @default_window_interval_ms),
          :window_interval_ms
        )
    }
  end

  @doc "Returns an existing scheduler or a new default scheduler for nil state."
  def ensure(%__MODULE__{} = scheduler), do: scheduler
  def ensure(nil), do: new()

  def ensure(%{} = attrs) do
    struct(__MODULE__, attrs)
  end

  @doc """
  Offers one live voxel frame to the scheduler.

  `:snapshot`, `:delta`, and `:field_region_snapshot` payloads consume the
  per-window data budget. `:object_state_delta` is event traffic and bypasses
  that blocking data queue. `:invalidate` and `:field_region_destroyed` payloads
  are reliable control traffic: they bypass the data budget and prune queued
  data that they invalidate before being returned for immediate delivery.
  """
  def offer(scheduler, frame_kind, payload)
      when frame_kind in [
             :snapshot,
             :delta,
             :invalidate,
             :object_state_delta,
             :field_region_snapshot,
             :field_region_destroyed
           ] and is_binary(payload) do
    scheduler = ensure(scheduler)

    case decode_frame(frame_kind, payload) do
      {:ok, %{frame_kind: control_kind} = frame}
      when control_kind in [:invalidate, :field_region_destroyed] ->
        {scheduler, pruned_count} = prune_control_frame(scheduler, frame)

        scheduler =
          %{
            scheduler
            | control_sent_count: scheduler.control_sent_count + 1
          }

        {scheduler,
         frame
         |> Map.merge(%{
           action: :send_now,
           status: :control,
           payload: payload,
           bytes: byte_size(payload),
           pruned_count: pruned_count
         })}

      {:ok, %{frame_kind: :object_state_delta} = frame} ->
        send_event_frame(
          scheduler,
          Map.merge(frame, %{payload: payload, bytes: byte_size(payload)})
        )

      {:ok, frame} ->
        schedule_data_frame(
          scheduler,
          Map.merge(frame, %{payload: payload, bytes: byte_size(payload)})
        )

      {:error, %{frame_kind: frame_kind} = frame}
      when frame_kind in [:snapshot, :delta, :object_state_delta, :field_region_snapshot] ->
        frame =
          Map.merge(frame, %{
            status: :decode_failed,
            payload: payload,
            bytes: byte_size(payload)
          })

        if frame_kind == :object_state_delta do
          send_event_frame(scheduler, frame)
        else
          schedule_data_frame(scheduler, frame)
        end

      {:error, %{frame_kind: :field_region_destroyed} = frame} ->
        drop_decode_failed_frame(
          scheduler,
          Map.merge(frame, %{
            status: :decode_failed,
            payload: payload,
            bytes: byte_size(payload)
          })
        )

      {:error, frame} ->
        {scheduler,
         frame
         |> Map.merge(%{
           action: :send_now,
           status: :decode_failed,
           payload: payload,
           bytes: byte_size(payload)
         })}
    end
  end

  @doc """
  Offers one metadata-complete Scene-to-Gate delivery envelope.

  Envelope metadata is treated as the transport boundary truth after validation,
  so Gate does not decode the payload header just to schedule, prune, or observe
  the frame.
  """
  def offer_envelope(scheduler, envelope) do
    case DeliveryEnvelope.normalize(envelope) do
      {:ok, frame} ->
        offer_frame(scheduler, frame)

      {:error, frame} ->
        reject_envelope(scheduler, frame)
    end
  end

  @doc """
  Offers an already-normalized delivery envelope frame to the scheduler.

  The transport worker owns connection-level fencing such as lease, epoch, and
  region checks. Once that boundary has accepted the frame, the scheduler should
  not normalize it again on the hot path.
  """
  def offer_frame(scheduler, %{frame_kind: control_kind} = frame)
      when control_kind in [:invalidate, :field_region_destroyed] do
    scheduler = ensure(scheduler)
    {scheduler, pruned_count} = prune_control_frame(scheduler, frame)

    scheduler =
      %{
        scheduler
        | control_sent_count: scheduler.control_sent_count + 1
      }

    {scheduler,
     Map.merge(frame, %{
       action: :send_now,
       status: :control,
       pruned_count: pruned_count
     })}
  end

  def offer_frame(scheduler, %{frame_kind: :object_state_delta} = frame) do
    scheduler
    |> ensure()
    |> send_event_frame(frame)
  end

  def offer_frame(scheduler, %{} = frame) do
    scheduler
    |> ensure()
    |> schedule_data_frame(frame)
  end

  @doc "Records a rejected delivery envelope in scheduler counters and action logs."
  def reject_envelope(scheduler, frame) when is_map(frame) do
    scheduler
    |> ensure()
    |> drop_invalid_envelope(frame)
  end

  @doc "Resets the per-window byte counter before a drain attempt."
  def reset_window(scheduler) do
    %{ensure(scheduler) | window_bytes_used: 0, window_items_used: 0}
  end

  @doc """
  Drains queued frames in FIFO order until the data budget is exhausted.

  Returned actions are ready for the owning transport process to send. Version
  ledgers must be updated by the caller after the actual send succeeds.
  """
  def drain(scheduler) do
    scheduler = ensure(scheduler)
    {scheduler, actions} = drain_queue(scheduler.queue, scheduler, [])
    {scheduler, Enum.reverse(actions)}
  end

  @doc "Removes queued data frames for one chunk."
  def prune_chunk(scheduler, logical_scene_id, chunk_coord) do
    scheduler = ensure(scheduler)

    {removed, retained} =
      Enum.split_with(scheduler.queue, fn frame ->
        Map.get(frame, :logical_scene_id) == logical_scene_id and
          Map.get(frame, :chunk_coord) == chunk_coord
      end)

    pruned_count = length(removed)

    {
      %{
        scheduler
        | queue: retained,
          queued_bytes: queue_bytes(retained),
          pruned_count: scheduler.pruned_count + pruned_count
      },
      pruned_count
    }
  end

  @doc "Removes queued data frames for a list of chunks in one logical scene."
  def prune_chunks(scheduler, logical_scene_id, chunks) when is_list(chunks) do
    Enum.reduce(chunks, ensure(scheduler), fn chunk_coord, acc ->
      {next_scheduler, _count} = prune_chunk(acc, logical_scene_id, chunk_coord)
      next_scheduler
    end)
  end

  @doc "Returns true when queued live data is waiting for a future window."
  def queued?(scheduler), do: length(ensure(scheduler).queue) > 0

  @doc "Returns the configured delivery-window interval in milliseconds."
  def window_interval_ms(scheduler), do: ensure(scheduler).window_interval_ms

  @doc "Returns chunk coords whose delta continuity is broken and need resync."
  def resync_required_chunks(scheduler, logical_scene_id) do
    logical_scene_id = non_negative_integer!(logical_scene_id, :logical_scene_id)

    scheduler
    |> ensure()
    |> Map.fetch!(:resync_required_chunks)
    |> Enum.flat_map(fn
      {^logical_scene_id, chunk_coord} -> [chunk_coord]
      {_other_scene_id, _chunk_coord} -> []
    end)
    |> Enum.sort()
  end

  @doc "Clears the resync-required marker after a replacement snapshot or delivered invalidate."
  def clear_resync_required(scheduler, logical_scene_id, chunk_coord) do
    scheduler = ensure(scheduler)

    %{
      scheduler
      | resync_required_chunks:
          MapSet.delete(scheduler.resync_required_chunks, {logical_scene_id, chunk_coord})
    }
  end

  @doc "Builds a bounded, deterministic debug summary."
  def summary(scheduler) do
    scheduler = ensure(scheduler)

    %{
      max_window_bytes: scheduler.max_window_bytes,
      max_window_items: scheduler.max_window_items,
      window_interval_ms: scheduler.window_interval_ms,
      window_bytes_used: scheduler.window_bytes_used,
      window_items_used: scheduler.window_items_used,
      max_queue_items: scheduler.max_queue_items,
      max_queue_bytes: scheduler.max_queue_bytes,
      queued_count: length(scheduler.queue),
      queued_bytes: scheduler.queued_bytes,
      sent_count: scheduler.sent_count,
      control_sent_count: scheduler.control_sent_count,
      event_sent_count: scheduler.event_sent_count,
      deferred_count: scheduler.deferred_count,
      dropped_count: scheduler.dropped_count,
      pruned_count: scheduler.pruned_count,
      oversize_count: scheduler.oversize_count,
      resync_required_count: MapSet.size(scheduler.resync_required_chunks)
    }
  end

  defp schedule_data_frame(scheduler, %{frame_kind: :snapshot} = frame) do
    scheduler =
      if chunk_identified?(frame) do
        {scheduler, _pruned_count} =
          prune_chunk_data(scheduler, frame.logical_scene_id, frame.chunk_coord)

        __MODULE__.clear_resync_required(scheduler, frame.logical_scene_id, frame.chunk_coord)
      else
        scheduler
      end

    schedule_data_frame_unblocked(scheduler, frame)
  end

  defp schedule_data_frame(scheduler, %{frame_kind: :delta} = frame) do
    if chunk_identified?(frame) and resync_required?(scheduler, frame) do
      scheduler = %{scheduler | dropped_count: scheduler.dropped_count + 1}

      {scheduler,
       frame
       |> Map.merge(%{
         action: :dropped,
         status: :resync_required,
         dropped_count: 1
       })}
    else
      schedule_data_frame_unblocked(scheduler, frame)
    end
  end

  defp schedule_data_frame(scheduler, %{frame_kind: :field_region_snapshot} = frame) do
    scheduler =
      if field_region_identified?(frame) do
        {scheduler, _pruned_count} =
          prune_field_region(
            scheduler,
            frame.logical_scene_id,
            frame.chunk_coord,
            frame.region_id
          )

        scheduler
      else
        scheduler
      end

    schedule_data_frame_unblocked(scheduler, frame)
  end

  defp schedule_data_frame(scheduler, frame) do
    schedule_data_frame_unblocked(scheduler, frame)
  end

  defp send_event_frame(scheduler, frame) do
    scheduler = %{scheduler | event_sent_count: scheduler.event_sent_count + 1}
    {scheduler, Map.merge(frame, %{action: :send_now, status: delivery_status(frame, :event)})}
  end

  defp drop_decode_failed_frame(scheduler, frame) do
    scheduler = %{scheduler | dropped_count: scheduler.dropped_count + 1}
    {scheduler, Map.merge(frame, %{action: :dropped, status: :decode_failed, dropped_count: 1})}
  end

  defp drop_invalid_envelope(scheduler, frame) do
    scheduler = %{scheduler | dropped_count: scheduler.dropped_count + 1}

    {scheduler,
     Map.merge(frame, %{action: :dropped, status: :invalid_envelope, dropped_count: 1})}
  end

  defp schedule_data_frame_unblocked(scheduler, frame) do
    cond do
      can_send_now?(scheduler, frame.bytes) ->
        status =
          delivery_status(
            frame,
            if(frame.bytes > scheduler.max_window_bytes, do: :oversize, else: :scheduled)
          )

        scheduler =
          %{
            scheduler
            | window_bytes_used: scheduler.window_bytes_used + frame.bytes,
              window_items_used: scheduler.window_items_used + 1,
              sent_count: scheduler.sent_count + 1,
              oversize_count: scheduler.oversize_count + if(status == :oversize, do: 1, else: 0)
          }

        {scheduler, Map.merge(frame, %{action: :send_now, status: status})}

      true ->
        enqueue_frame(scheduler, frame)
    end
  end

  defp enqueue_frame(scheduler, frame) do
    frame = Map.put(frame, :queue_seq, scheduler.next_queue_seq)

    if queue_would_overflow?(scheduler, frame) do
      scheduler =
        scheduler
        |> maybe_mark_resync_required(frame)
        |> Map.update!(:dropped_count, &(&1 + 1))
        |> Map.update!(:deferred_count, &(&1 + 1))
        |> Map.update!(:next_queue_seq, &(&1 + 1))

      {scheduler,
       frame
       |> Map.delete(:queue_seq)
       |> Map.merge(%{
         action: :dropped,
         status: :queue_full,
         dropped_count: 1
       })}
    else
      queue = scheduler.queue ++ [frame]

      scheduler = %{
        scheduler
        | queue: queue,
          queued_bytes: queue_bytes(queue),
          deferred_count: scheduler.deferred_count + 1,
          next_queue_seq: scheduler.next_queue_seq + 1
      }

      action =
        frame
        |> Map.delete(:queue_seq)
        |> Map.merge(%{
          action: :queued,
          status: delivery_status(frame, :deferred),
          dropped_count: 0
        })

      {scheduler, action}
    end
  end

  defp drain_queue([], scheduler, actions) do
    {%{scheduler | queue: [], queued_bytes: 0}, actions}
  end

  defp drain_queue([frame | rest] = queue, scheduler, actions) do
    if can_send_now?(scheduler, frame.bytes) do
      status =
        delivery_status(
          frame,
          if(frame.bytes > scheduler.max_window_bytes, do: :oversize, else: :scheduled)
        )

      scheduler = %{
        scheduler
        | window_bytes_used: scheduler.window_bytes_used + frame.bytes,
          window_items_used: scheduler.window_items_used + 1,
          sent_count: scheduler.sent_count + 1,
          oversize_count: scheduler.oversize_count + if(status == :oversize, do: 1, else: 0)
      }

      action =
        frame
        |> Map.delete(:queue_seq)
        |> Map.merge(%{action: :send_now, status: status})

      drain_queue(rest, scheduler, [action | actions])
    else
      {%{scheduler | queue: queue, queued_bytes: queue_bytes(queue)}, actions}
    end
  end

  defp can_send_now?(scheduler, bytes) do
    remaining = scheduler.max_window_bytes - scheduler.window_bytes_used

    item_allowed =
      scheduler.max_window_items > 0 and scheduler.window_items_used < scheduler.max_window_items

    item_allowed and
      (bytes <= remaining or
         (scheduler.window_bytes_used == 0 and bytes > scheduler.max_window_bytes))
  end

  defp queue_bytes(queue) do
    Enum.reduce(queue, 0, fn frame, acc -> acc + frame.bytes end)
  end

  defp queue_would_overflow?(scheduler, frame) do
    length(scheduler.queue) + 1 > scheduler.max_queue_items or
      scheduler.queued_bytes + frame.bytes > scheduler.max_queue_bytes
  end

  defp delivery_status(%{status: :decode_failed}, _default_status), do: :decode_failed
  defp delivery_status(_frame, default_status), do: default_status

  defp chunk_identified?(%{logical_scene_id: _logical_scene_id, chunk_coord: _chunk_coord}),
    do: true

  defp chunk_identified?(_frame), do: false

  defp field_region_identified?(%{
         logical_scene_id: _logical_scene_id,
         chunk_coord: _chunk_coord,
         region_id: _region_id
       }),
       do: true

  defp field_region_identified?(_frame), do: false

  defp chunk_key(%{logical_scene_id: logical_scene_id, chunk_coord: chunk_coord}) do
    {logical_scene_id, chunk_coord}
  end

  defp resync_required?(scheduler, frame) do
    MapSet.member?(scheduler.resync_required_chunks, chunk_key(frame))
  end

  defp maybe_mark_resync_required(scheduler, %{frame_kind: frame_kind} = frame)
       when frame_kind in [:snapshot, :delta] do
    if chunk_identified?(frame) do
      %{
        scheduler
        | resync_required_chunks: MapSet.put(scheduler.resync_required_chunks, chunk_key(frame))
      }
    else
      scheduler
    end
  end

  defp maybe_mark_resync_required(scheduler, _frame), do: scheduler

  defp prune_control_frame(scheduler, %{frame_kind: :invalidate} = frame) do
    prune_chunk(scheduler, frame.logical_scene_id, frame.chunk_coord)
  end

  defp prune_control_frame(scheduler, %{frame_kind: :field_region_destroyed} = frame) do
    if field_region_identified?(frame) do
      prune_field_region(scheduler, frame.logical_scene_id, frame.chunk_coord, frame.region_id)
    else
      {scheduler, 0}
    end
  end

  defp prune_chunk_data(scheduler, logical_scene_id, chunk_coord) do
    prune_queue(scheduler, fn frame ->
      Map.get(frame, :frame_kind) in [:snapshot, :delta] and
        Map.get(frame, :logical_scene_id) == logical_scene_id and
        Map.get(frame, :chunk_coord) == chunk_coord
    end)
  end

  defp prune_field_region(scheduler, logical_scene_id, chunk_coord, region_id) do
    prune_queue(scheduler, fn frame ->
      Map.get(frame, :frame_kind) == :field_region_snapshot and
        Map.get(frame, :logical_scene_id) == logical_scene_id and
        Map.get(frame, :chunk_coord) == chunk_coord and
        Map.get(frame, :region_id) == region_id
    end)
  end

  defp prune_queue(scheduler, predicate) do
    scheduler = ensure(scheduler)
    {removed, retained} = Enum.split_with(scheduler.queue, predicate)
    pruned_count = length(removed)

    {
      %{
        scheduler
        | queue: retained,
          queued_bytes: queue_bytes(retained),
          pruned_count: scheduler.pruned_count + pruned_count
      },
      pruned_count
    }
  end

  defp decode_frame(:snapshot, payload) do
    case SceneVoxelCodec.decode_chunk_snapshot_payload(payload) do
      {:ok, %{storage: storage}} ->
        {:ok,
         %{
           frame_kind: :snapshot,
           logical_scene_id: storage.logical_scene_id,
           chunk_coord: storage.chunk_coord,
           chunk_version: storage.chunk_version
         }}

      {:error, reason} ->
        {:error, %{frame_kind: :snapshot, reason: reason}}
    end
  end

  defp decode_frame(:delta, payload) do
    case SceneVoxelCodec.decode_chunk_delta_payload(payload) do
      {:ok,
       %{
         logical_scene_id: logical_scene_id,
         chunk_coord: chunk_coord,
         base_chunk_version: base_chunk_version,
         new_chunk_version: new_chunk_version
       }} ->
        {:ok,
         %{
           frame_kind: :delta,
           logical_scene_id: logical_scene_id,
           chunk_coord: chunk_coord,
           base_chunk_version: base_chunk_version,
           chunk_version: new_chunk_version
         }}

      {:error, reason} ->
        {:error, %{frame_kind: :delta, reason: reason}}
    end
  end

  defp decode_frame(:invalidate, payload) do
    case SceneVoxelCodec.decode_chunk_invalidate_payload(payload) do
      {:ok,
       %{
         logical_scene_id: logical_scene_id,
         chunk_coord: chunk_coord,
         reason: reason,
         reason_name: reason_name
       }} ->
        {:ok,
         %{
           frame_kind: :invalidate,
           logical_scene_id: logical_scene_id,
           chunk_coord: chunk_coord,
           reason: reason,
           reason_name: reason_name
         }}

      {:error, reason} ->
        {:error, %{frame_kind: :invalidate, reason: reason}}
    end
  end

  defp decode_frame(:object_state_delta, payload) do
    case SceneVoxelCodec.decode_voxel_object_state_delta_payload(payload) do
      {:ok,
       %{
         logical_scene_id: logical_scene_id,
         object_id: object_id,
         object_version: object_version,
         affected_chunks: affected_chunks
       }, _rest} ->
        {:ok,
         %{
           frame_kind: :object_state_delta,
           logical_scene_id: logical_scene_id,
           object_id: object_id,
           object_version: object_version,
           affected_chunks: affected_chunks
         }}

      {:error, reason} ->
        {:error, %{frame_kind: :object_state_delta, reason: reason}}
    end
  end

  defp decode_frame(:field_region_snapshot, payload) do
    case decode_field_snapshot(payload) do
      {:ok,
       %{
         logical_scene_id: logical_scene_id,
         chunk_coord: chunk_coord,
         region_id: region_id,
         tick_count: tick_count
       }} ->
        {:ok,
         %{
           frame_kind: :field_region_snapshot,
           logical_scene_id: logical_scene_id,
           chunk_coord: chunk_coord,
           region_id: region_id,
           tick_count: tick_count
         }}

      {:error, reason} ->
        {:error, %{frame_kind: :field_region_snapshot, reason: reason}}
    end
  end

  defp decode_frame(:field_region_destroyed, payload) do
    case decode_field_destroyed(payload) do
      {:ok,
       %{
         logical_scene_id: logical_scene_id,
         chunk_coord: chunk_coord,
         region_id: region_id,
         destroy_reason: destroy_reason
       }} ->
        {:ok,
         %{
           frame_kind: :field_region_destroyed,
           logical_scene_id: logical_scene_id,
           chunk_coord: chunk_coord,
           region_id: region_id,
           destroy_reason: destroy_reason
         }}

      {:error, reason} ->
        {:error, %{frame_kind: :field_region_destroyed, reason: reason}}
    end
  end

  defp decode_field_snapshot(
         <<0x73, logical_scene_id::64-big, cx::32-big-signed, cy::32-big-signed,
           cz::32-big-signed, region_id::64-big, tick_count::32-big, _field_mask::8,
           _cell_count::16-big, _rest::binary>>
       ) do
    {:ok,
     %{
       logical_scene_id: logical_scene_id,
       chunk_coord: {cx, cy, cz},
       region_id: region_id,
       tick_count: tick_count
     }}
  end

  defp decode_field_snapshot(_payload), do: {:error, :invalid_field_region_snapshot_header}

  defp decode_field_destroyed(
         <<0x74, logical_scene_id::64-big, cx::32-big-signed, cy::32-big-signed,
           cz::32-big-signed, region_id::64-big, reason_byte::8>>
       ) do
    {:ok,
     %{
       logical_scene_id: logical_scene_id,
       chunk_coord: {cx, cy, cz},
       region_id: region_id,
       destroy_reason: decode_field_destroy_reason(reason_byte)
     }}
  end

  defp decode_field_destroyed(_payload), do: {:error, :invalid_field_region_destroyed_header}

  defp decode_field_destroy_reason(0x00), do: :expired
  defp decode_field_destroy_reason(0x01), do: :lease_revoked
  defp decode_field_destroy_reason(0x02), do: :explicit
  defp decode_field_destroy_reason(0x03), do: :chunk_crash
  defp decode_field_destroy_reason(_reason_byte), do: :unknown

  defp non_negative_integer!(value, _key) when is_integer(value) and value >= 0, do: value

  defp non_negative_integer!(value, key) do
    raise ArgumentError, "#{inspect(key)} must be a non-negative integer, got: #{inspect(value)}"
  end

  defp positive_integer!(value, _key) when is_integer(value) and value > 0, do: value

  defp positive_integer!(value, key) do
    raise ArgumentError, "#{inspect(key)} must be a positive integer, got: #{inspect(value)}"
  end
end
