defmodule GateServer.Voxel.DeliverySchedulerTest do
  use ExUnit.Case, async: true

  alias GateServer.Voxel.DeliveryScheduler
  alias SceneServer.Voxel.Codec, as: SceneVoxelCodec
  alias SceneServer.Voxel.Storage

  test "object state deltas bypass the live voxel data budget as event traffic" do
    first_payload = snapshot_payload(7, {0, 0, 0}, 1)

    object_payload =
      object_state_delta_payload(7,
        object_id: 99,
        object_version: 3,
        affected_chunks: [{0, 0, 0}]
      )

    scheduler =
      DeliveryScheduler.new(
        max_window_bytes: byte_size(first_payload) + 1,
        max_queue_items: 8,
        max_queue_bytes: byte_size(first_payload) + byte_size(object_payload) + 128
      )

    {scheduler, %{action: :send_now}} =
      DeliveryScheduler.offer(scheduler, :snapshot, first_payload)

    assert {scheduler,
            %{
              action: :send_now,
              status: :event,
              frame_kind: :object_state_delta,
              logical_scene_id: 7,
              object_id: 99,
              object_version: 3
            }} = DeliveryScheduler.offer(scheduler, :object_state_delta, object_payload)

    summary = DeliveryScheduler.summary(scheduler)
    assert summary.queued_count == 0
    assert summary.event_sent_count == 1
    assert summary.window_bytes_used == byte_size(first_payload)
  end

  test "field region snapshots are budgeted and destroyed messages prune queued field data" do
    first_payload = snapshot_payload(7, {0, 0, 0}, 1)
    field_payload = field_region_snapshot_payload(7, {0, 0, 0}, 42, 9)
    destroyed_payload = field_region_destroyed_payload(7, {0, 0, 0}, 42)

    scheduler =
      DeliveryScheduler.new(
        max_window_bytes: byte_size(first_payload) + 1,
        max_queue_items: 8,
        max_queue_bytes: byte_size(first_payload) + byte_size(field_payload) + 128
      )

    {scheduler, %{action: :send_now}} =
      DeliveryScheduler.offer(scheduler, :snapshot, first_payload)

    {scheduler, %{action: :queued, frame_kind: :field_region_snapshot, region_id: 42}} =
      DeliveryScheduler.offer(scheduler, :field_region_snapshot, field_payload)

    assert {scheduler,
            %{
              action: :send_now,
              frame_kind: :field_region_destroyed,
              region_id: 42,
              pruned_count: 1
            }} = DeliveryScheduler.offer(scheduler, :field_region_destroyed, destroyed_payload)

    summary = DeliveryScheduler.summary(scheduler)
    assert summary.queued_count == 0
    assert summary.control_sent_count == 1
    assert summary.pruned_count == 1
  end

  test "field region destroyed does not prune other regions in the same chunk" do
    first_payload = snapshot_payload(7, {0, 0, 0}, 1)
    first_field_payload = field_region_snapshot_payload(7, {0, 0, 0}, 42, 9)
    second_field_payload = field_region_snapshot_payload(7, {0, 0, 0}, 43, 9)
    destroyed_payload = field_region_destroyed_payload(7, {0, 0, 0}, 42)

    scheduler =
      DeliveryScheduler.new(
        max_window_bytes: byte_size(first_payload) + 1,
        max_queue_items: 8,
        max_queue_bytes:
          byte_size(first_payload) + byte_size(first_field_payload) +
            byte_size(second_field_payload) + 128
      )

    {scheduler, %{action: :send_now}} =
      DeliveryScheduler.offer(scheduler, :snapshot, first_payload)

    {scheduler, %{action: :queued}} =
      DeliveryScheduler.offer(scheduler, :field_region_snapshot, first_field_payload)

    {scheduler, %{action: :queued}} =
      DeliveryScheduler.offer(scheduler, :field_region_snapshot, second_field_payload)

    {scheduler, %{action: :send_now, pruned_count: 1}} =
      DeliveryScheduler.offer(scheduler, :field_region_destroyed, destroyed_payload)

    assert DeliveryScheduler.summary(scheduler).queued_count == 1

    assert {_scheduler, [%{payload: ^second_field_payload, region_id: 43}]} =
             scheduler
             |> DeliveryScheduler.reset_window()
             |> DeliveryScheduler.drain()
  end

  test "malformed field region destroyed is rejected without pruning queued field data" do
    first_payload = snapshot_payload(7, {0, 0, 0}, 1)
    field_payload = field_region_snapshot_payload(7, {0, 0, 0}, 42, 9)
    malformed_destroyed_payload = field_region_destroyed_payload(7, {0, 0, 0}, 42) <> <<0xFF>>

    scheduler =
      DeliveryScheduler.new(
        max_window_bytes: byte_size(first_payload) + 1,
        max_queue_items: 8,
        max_queue_bytes: byte_size(first_payload) + byte_size(field_payload) + 128
      )

    {scheduler, %{action: :send_now}} =
      DeliveryScheduler.offer(scheduler, :snapshot, first_payload)

    {scheduler, %{action: :queued}} =
      DeliveryScheduler.offer(scheduler, :field_region_snapshot, field_payload)

    assert {scheduler,
            %{
              action: :dropped,
              status: :decode_failed,
              frame_kind: :field_region_destroyed,
              reason: :invalid_field_region_destroyed_header
            }} =
             DeliveryScheduler.offer(
               scheduler,
               :field_region_destroyed,
               malformed_destroyed_payload
             )

    summary = DeliveryScheduler.summary(scheduler)
    assert summary.queued_count == 1
    assert summary.control_sent_count == 0
    assert summary.dropped_count == 1
    assert summary.pruned_count == 0
  end

  test "field region snapshot scheduling only needs the wire header" do
    first_payload = snapshot_payload(7, {0, 0, 0}, 1)

    header_only_field_payload =
      <<0x73, 7::64-big, 0::32-big-signed, 0::32-big-signed, 0::32-big-signed, 42::64-big,
        9::32-big, 0x01::8, 2::16-big>>

    scheduler =
      DeliveryScheduler.new(
        max_window_bytes: byte_size(first_payload) + 1,
        max_queue_items: 8,
        max_queue_bytes: byte_size(first_payload) + byte_size(header_only_field_payload) + 128
      )

    {scheduler, %{action: :send_now}} =
      DeliveryScheduler.offer(scheduler, :snapshot, first_payload)

    assert {_scheduler,
            %{
              action: :queued,
              status: :deferred,
              frame_kind: :field_region_snapshot,
              logical_scene_id: 7,
              chunk_coord: {0, 0, 0},
              region_id: 42,
              tick_count: 9
            }} =
             DeliveryScheduler.offer(
               scheduler,
               :field_region_snapshot,
               header_only_field_payload
             )
  end

  test "delivery envelopes schedule field snapshots from metadata without payload header decode" do
    first_payload = snapshot_payload(7, {0, 0, 0}, 1)
    opaque_field_payload = <<1, 2, 3>>

    scheduler =
      DeliveryScheduler.new(
        max_window_bytes: byte_size(first_payload) + 1,
        max_queue_items: 8,
        max_queue_bytes: byte_size(first_payload) + byte_size(opaque_field_payload) + 128
      )

    {scheduler, %{action: :send_now}} =
      DeliveryScheduler.offer(scheduler, :snapshot, first_payload)

    assert {scheduler,
            %{
              action: :queued,
              status: :deferred,
              frame_kind: :field_region_snapshot,
              logical_scene_id: 7,
              chunk_coord: {0, 0, 0},
              region_id: 42,
              tick_count: 9,
              tier: :halo,
              stream_class: :field_state,
              byte_size: 3,
              bytes: 3,
              server_version: 12,
              lease_id: 101,
              owner_epoch: 2,
              payload: ^opaque_field_payload
            }} =
             DeliveryScheduler.offer_envelope(scheduler, %{
               frame_kind: :field_region_snapshot,
               logical_scene_id: 7,
               chunk_coord: {0, 0, 0},
               region_id: 42,
               tick_count: 9,
               tier: :halo,
               stream_class: :field_state,
               byte_size: byte_size(opaque_field_payload),
               server_version: 12,
               lease_id: 101,
               owner_epoch: 2,
               payload: opaque_field_payload
             })

    assert DeliveryScheduler.summary(scheduler).queued_count == 1
  end

  test "invalid delivery envelopes are dropped with an observable reason" do
    scheduler = DeliveryScheduler.new()

    assert {scheduler,
            %{
              action: :dropped,
              status: :invalid_envelope,
              frame_kind: :field_region_snapshot,
              reason: :byte_size_mismatch,
              expected_byte_size: 4,
              actual_byte_size: 3,
              dropped_count: 1
            }} =
             DeliveryScheduler.offer_envelope(scheduler, %{
               frame_kind: :field_region_snapshot,
               logical_scene_id: 7,
               chunk_coord: {0, 0, 0},
               region_id: 42,
               tick_count: 9,
               byte_size: 4,
               payload: <<1, 2, 3>>
             })

    summary = DeliveryScheduler.summary(scheduler)
    assert summary.queued_count == 0
    assert summary.dropped_count == 1
  end

  test "control delivery envelopes prune queued field envelopes for the same region" do
    first_payload = snapshot_payload(7, {0, 0, 0}, 1)
    field_payload = <<1, 2, 3>>
    destroyed_payload = <<4>>

    scheduler =
      DeliveryScheduler.new(
        max_window_bytes: byte_size(first_payload) + 1,
        max_queue_items: 8,
        max_queue_bytes: byte_size(first_payload) + byte_size(field_payload) + 128
      )

    {scheduler, %{action: :send_now}} =
      DeliveryScheduler.offer(scheduler, :snapshot, first_payload)

    {scheduler, %{action: :queued}} =
      DeliveryScheduler.offer_envelope(scheduler, %{
        frame_kind: :field_region_snapshot,
        logical_scene_id: 7,
        chunk_coord: {0, 0, 0},
        region_id: 42,
        tick_count: 9,
        tier: :halo,
        stream_class: :field_state,
        byte_size: byte_size(field_payload),
        server_version: 12,
        lease_id: 101,
        owner_epoch: 2,
        payload: field_payload
      })

    assert {scheduler,
            %{
              action: :send_now,
              status: :control,
              frame_kind: :field_region_destroyed,
              logical_scene_id: 7,
              chunk_coord: {0, 0, 0},
              region_id: 42,
              destroy_reason: :lease_revoked,
              tier: :halo,
              stream_class: :reliable_control,
              lease_id: 101,
              owner_epoch: 2,
              pruned_count: 1,
              payload: ^destroyed_payload
            }} =
             DeliveryScheduler.offer_envelope(scheduler, %{
               frame_kind: :field_region_destroyed,
               logical_scene_id: 7,
               chunk_coord: {0, 0, 0},
               region_id: 42,
               destroy_reason: :lease_revoked,
               tier: :halo,
               stream_class: :reliable_control,
               byte_size: byte_size(destroyed_payload),
               server_version: 12,
               lease_id: 101,
               owner_epoch: 2,
               payload: destroyed_payload
             })

    summary = DeliveryScheduler.summary(scheduler)
    assert summary.queued_count == 0
    assert summary.control_sent_count == 1
    assert summary.pruned_count == 1
  end

  test "queues live voxel frames once the per-window budget is exhausted" do
    first_payload = snapshot_payload(7, {0, 0, 0}, 1)

    second_payload =
      delta_payload(7, {0, 0, 0}, base_chunk_version: 1, new_chunk_version: 2)

    scheduler =
      DeliveryScheduler.new(
        max_window_bytes: byte_size(first_payload) + 1,
        max_queue_items: 8,
        max_queue_bytes: byte_size(first_payload) + byte_size(second_payload) + 128
      )

    assert {scheduler, %{action: :send_now, frame_kind: :snapshot}} =
             DeliveryScheduler.offer(scheduler, :snapshot, first_payload)

    assert {scheduler, %{action: :queued, frame_kind: :delta, logical_scene_id: 7}} =
             DeliveryScheduler.offer(scheduler, :delta, second_payload)

    summary = DeliveryScheduler.summary(scheduler)
    assert summary.queued_count == 1
    assert summary.deferred_count == 1
    assert summary.sent_count == 1
    assert summary.window_bytes_used == byte_size(first_payload)
  end

  test "queues tiny voxel frames once the per-window frame budget is exhausted" do
    first_payload = snapshot_payload(7, {0, 0, 0}, 1)
    second_payload = snapshot_payload(7, {1, 0, 0}, 1)
    third_payload = snapshot_payload(7, {2, 0, 0}, 1)

    scheduler =
      DeliveryScheduler.new(
        max_window_bytes: 1_000_000,
        max_window_items: 2,
        max_queue_items: 8,
        max_queue_bytes:
          byte_size(first_payload) + byte_size(second_payload) + byte_size(third_payload) + 128
      )

    {scheduler, %{action: :send_now}} =
      DeliveryScheduler.offer(scheduler, :snapshot, first_payload)

    {scheduler, %{action: :send_now}} =
      DeliveryScheduler.offer(scheduler, :snapshot, second_payload)

    assert {scheduler, %{action: :queued, frame_kind: :snapshot, logical_scene_id: 7}} =
             DeliveryScheduler.offer(scheduler, :snapshot, third_payload)

    summary = DeliveryScheduler.summary(scheduler)
    assert summary.queued_count == 1
    assert summary.sent_count == 2
    assert summary.window_items_used == 2
    assert summary.window_bytes_used == byte_size(first_payload) + byte_size(second_payload)

    assert {scheduler, [%{action: :send_now, payload: ^third_payload}]} =
             scheduler
             |> DeliveryScheduler.reset_window()
             |> DeliveryScheduler.drain()

    assert DeliveryScheduler.summary(scheduler).window_items_used == 1
  end

  test "drains queued frames after the delivery window resets" do
    first_payload = snapshot_payload(7, {0, 0, 0}, 1)

    second_payload =
      delta_payload(7, {0, 0, 0}, base_chunk_version: 1, new_chunk_version: 2)

    scheduler =
      DeliveryScheduler.new(
        max_window_bytes: byte_size(first_payload) + 1,
        max_queue_items: 8,
        max_queue_bytes: byte_size(first_payload) + byte_size(second_payload) + 128
      )

    {scheduler, %{action: :send_now}} =
      DeliveryScheduler.offer(scheduler, :snapshot, first_payload)

    {scheduler, %{action: :queued}} = DeliveryScheduler.offer(scheduler, :delta, second_payload)

    assert {scheduler, [%{action: :send_now, frame_kind: :delta, payload: ^second_payload}]} =
             scheduler
             |> DeliveryScheduler.reset_window()
             |> DeliveryScheduler.drain()

    summary = DeliveryScheduler.summary(scheduler)
    assert summary.queued_count == 0
    assert summary.sent_count == 2
    assert summary.window_bytes_used == byte_size(second_payload)
  end

  test "chunk invalidates bypass the data budget and prune queued frames for that chunk" do
    first_payload = snapshot_payload(7, {0, 0, 0}, 1)

    second_payload =
      delta_payload(7, {0, 0, 0}, base_chunk_version: 1, new_chunk_version: 2)

    invalidate_payload =
      SceneVoxelCodec.encode_chunk_invalidate_payload(%{
        logical_scene_id: 7,
        chunk_coord: {0, 0, 0},
        reason: 0x01
      })

    scheduler =
      DeliveryScheduler.new(
        max_window_bytes: byte_size(first_payload) + 1,
        max_queue_items: 8,
        max_queue_bytes: byte_size(first_payload) + byte_size(second_payload) + 128
      )

    {scheduler, %{action: :send_now}} =
      DeliveryScheduler.offer(scheduler, :snapshot, first_payload)

    {scheduler, %{action: :queued}} = DeliveryScheduler.offer(scheduler, :delta, second_payload)

    assert {scheduler, %{action: :send_now, frame_kind: :invalidate, pruned_count: 1}} =
             DeliveryScheduler.offer(scheduler, :invalidate, invalidate_payload)

    summary = DeliveryScheduler.summary(scheduler)
    assert summary.queued_count == 0
    assert summary.control_sent_count == 1
  end

  test "keeps the queue bounded without breaking already queued delta order" do
    first_payload = snapshot_payload(7, {0, 0, 0}, 1)

    queued_payload =
      delta_payload(7, {0, 0, 0}, base_chunk_version: 1, new_chunk_version: 2)

    newer_payload =
      delta_payload(7, {1, 0, 0}, base_chunk_version: 0, new_chunk_version: 1)

    scheduler =
      DeliveryScheduler.new(
        max_window_bytes: byte_size(first_payload) + 1,
        max_queue_items: 1,
        max_queue_bytes: byte_size(queued_payload) + byte_size(newer_payload) + 128
      )

    {scheduler, %{action: :send_now}} =
      DeliveryScheduler.offer(scheduler, :snapshot, first_payload)

    {scheduler, %{action: :queued}} = DeliveryScheduler.offer(scheduler, :delta, queued_payload)

    assert {scheduler, %{action: :dropped, status: :queue_full, dropped_count: 1}} =
             DeliveryScheduler.offer(scheduler, :delta, newer_payload)

    summary = DeliveryScheduler.summary(scheduler)
    assert summary.queued_count == 1
    assert summary.dropped_count == 1
    assert summary.queued_bytes == byte_size(queued_payload)
    assert summary.resync_required_count == 1

    assert {_scheduler, [%{payload: ^queued_payload}]} =
             scheduler
             |> DeliveryScheduler.reset_window()
             |> DeliveryScheduler.drain()
  end

  test "drops later deltas for a chunk whose continuity was broken by overflow" do
    first_payload = snapshot_payload(7, {0, 0, 0}, 1)

    dropped_payload =
      delta_payload(7, {0, 0, 0}, base_chunk_version: 1, new_chunk_version: 2)

    later_payload =
      delta_payload(7, {0, 0, 0}, base_chunk_version: 2, new_chunk_version: 3)

    invalidate_payload =
      SceneVoxelCodec.encode_chunk_invalidate_payload(%{
        logical_scene_id: 7,
        chunk_coord: {0, 0, 0},
        reason: 0x01
      })

    scheduler =
      DeliveryScheduler.new(
        max_window_bytes: byte_size(first_payload) + 1,
        max_queue_items: 0,
        max_queue_bytes: byte_size(dropped_payload) + 128
      )

    {scheduler, %{action: :send_now}} =
      DeliveryScheduler.offer(scheduler, :snapshot, first_payload)

    {scheduler, %{action: :dropped, status: :queue_full}} =
      DeliveryScheduler.offer(scheduler, :delta, dropped_payload)

    assert {scheduler, %{action: :dropped, status: :resync_required}} =
             DeliveryScheduler.offer(scheduler, :delta, later_payload)

    assert DeliveryScheduler.summary(scheduler).resync_required_count == 1
    assert DeliveryScheduler.resync_required_chunks(scheduler, 7) == [{0, 0, 0}]
    assert DeliveryScheduler.resync_required_chunks(scheduler, 8) == []

    assert {scheduler, %{action: :send_now, frame_kind: :invalidate}} =
             DeliveryScheduler.offer(scheduler, :invalidate, invalidate_payload)

    assert DeliveryScheduler.summary(scheduler).resync_required_count == 1

    scheduler = DeliveryScheduler.clear_resync_required(scheduler, 7, {0, 0, 0})

    assert DeliveryScheduler.summary(scheduler).resync_required_count == 0
  end

  test "pruning queued chunk data does not clear resync-required retention blockers" do
    first_payload = snapshot_payload(7, {0, 0, 0}, 1)

    dropped_payload =
      delta_payload(7, {0, 0, 0}, base_chunk_version: 1, new_chunk_version: 2)

    scheduler =
      DeliveryScheduler.new(
        max_window_bytes: byte_size(first_payload) + 1,
        max_queue_items: 0,
        max_queue_bytes: byte_size(dropped_payload) + 128
      )

    {scheduler, %{action: :send_now}} =
      DeliveryScheduler.offer(scheduler, :snapshot, first_payload)

    {scheduler, %{action: :dropped, status: :queue_full}} =
      DeliveryScheduler.offer(scheduler, :delta, dropped_payload)

    assert DeliveryScheduler.resync_required_chunks(scheduler, 7) == [{0, 0, 0}]

    scheduler = DeliveryScheduler.prune_chunks(scheduler, 7, [{0, 0, 0}])

    assert DeliveryScheduler.resync_required_chunks(scheduler, 7) == [{0, 0, 0}]
  end

  test "malformed live voxel data still consumes delivery budget" do
    first_payload = snapshot_payload(7, {0, 0, 0}, 1)

    scheduler =
      DeliveryScheduler.new(
        max_window_bytes: byte_size(first_payload) + 1,
        max_queue_items: 8,
        max_queue_bytes: byte_size(first_payload) + 128
      )

    {scheduler, %{action: :send_now}} =
      DeliveryScheduler.offer(scheduler, :snapshot, first_payload)

    assert {scheduler, %{action: :queued, status: :decode_failed, frame_kind: :snapshot}} =
             DeliveryScheduler.offer(scheduler, :snapshot, <<1, 2, 3>>)

    summary = DeliveryScheduler.summary(scheduler)
    assert summary.queued_count == 1
    assert summary.window_bytes_used == byte_size(first_payload)
  end

  defp snapshot_payload(logical_scene_id, chunk_coord, chunk_version) do
    storage = Storage.empty(logical_scene_id, chunk_coord, chunk_version: chunk_version)
    SceneVoxelCodec.encode_chunk_snapshot_payload(%{request_id: 101, storage: storage})
  end

  defp delta_payload(logical_scene_id, chunk_coord, opts) do
    SceneVoxelCodec.encode_chunk_delta_payload(%{
      logical_scene_id: logical_scene_id,
      chunk_coord: chunk_coord,
      base_chunk_version: Keyword.fetch!(opts, :base_chunk_version),
      new_chunk_version: Keyword.fetch!(opts, :new_chunk_version),
      ops: []
    })
  end

  defp object_state_delta_payload(logical_scene_id, opts) do
    SceneVoxelCodec.encode_voxel_object_state_delta_payload(%{
      logical_scene_id: logical_scene_id,
      object_id: Keyword.fetch!(opts, :object_id),
      object_version: Keyword.fetch!(opts, :object_version),
      state_flags: Keyword.get(opts, :state_flags, 0x01),
      affected_chunks: Keyword.fetch!(opts, :affected_chunks)
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
end
