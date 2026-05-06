defmodule SceneServer.Voxel.ChunkProcessTest do
  use ExUnit.Case, async: true

  alias DataService.Voxel.ChunkSnapshotStore
  alias DataService.Voxel.WriteTokenStore
  alias SceneServer.Voxel.ChunkProcess
  alias SceneServer.Voxel.Codec
  alias SceneServer.Voxel.MacroCellHeader
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.Storage

  test "builds snapshot payloads from hot chunk truth" do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {0, 0, 0}})

    assert {:ok, storage} =
             ChunkProcess.put_solid_block(
               chunk,
               {0, 0, 0},
               NormalBlockData.new(2, health: 50),
               cell_version: 1
             )

    assert storage.chunk_version == 1

    assert {:ok, payload} = ChunkProcess.snapshot_payload(chunk, 44)

    assert {:ok, %{request_id: 44, storage: decoded_storage}} =
             Codec.decode_chunk_snapshot_payload(payload)

    assert decoded_storage.chunk_version == 1

    assert Storage.macro_header_at(decoded_storage, 0).mode ==
             MacroCellHeader.cell_mode_solid_block()
  end

  test "subscribe immediately sends the current snapshot payload" do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {0, 0, 0}})

    assert {:ok, payload} = ChunkProcess.subscribe(chunk, self(), request_id: 55)
    assert_receive {:voxel_chunk_snapshot_payload, ^payload}

    assert {:ok, %{request_id: 55, storage: decoded_storage}} =
             Codec.decode_chunk_snapshot_payload(payload)

    assert decoded_storage.chunk_version == 0
    assert ChunkProcess.debug_state(chunk).subscriber_count == 1
  end

  test "put_solid_block pushes a second snapshot fallback payload to subscribers" do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {0, 0, 0}})

    assert {:ok, initial_payload} = ChunkProcess.subscribe(chunk, self(), request_id: 56)
    assert_receive {:voxel_chunk_snapshot_payload, ^initial_payload}

    assert {:ok, _storage} =
             ChunkProcess.put_solid_block(
               chunk,
               {0, 0, 0},
               NormalBlockData.new(2, health: 50),
               cell_version: 1
             )

    assert_receive {:voxel_chunk_snapshot_payload, updated_payload}
    assert updated_payload != initial_payload

    assert {:ok, %{request_id: 56, storage: decoded_storage}} =
             Codec.decode_chunk_snapshot_payload(updated_payload)

    assert decoded_storage.chunk_version == 1

    assert Storage.macro_header_at(decoded_storage, 0).mode ==
             MacroCellHeader.cell_mode_solid_block()
  end

  test "apply_intent writes a solid block, increments versions, and persists snapshots" do
    {_token_store, snapshot_store, lease} = start_snapshot_store()

    chunk =
      start_supervised!(
        {ChunkProcess,
         logical_scene_id: 1, chunk_coord: {1, 1, 1}, snapshot_store: snapshot_store}
      )

    assert {:ok,
            %{
              chunk_version: 1,
              persist_result: :inserted,
              snapshot_payload: first_payload
            }} =
             ChunkProcess.apply_intent(
               chunk,
               intent_attrs(lease,
                 request_id: 70,
                 macro: {0, 0, 0},
                 block: NormalBlockData.new(7, health: 25)
               )
             )

    assert {:ok, %{request_id: 70, storage: first_storage}} =
             Codec.decode_chunk_snapshot_payload(first_payload)

    assert first_storage.chunk_version == 1

    assert Storage.macro_header_at(first_storage, {0, 0, 0}).mode ==
             MacroCellHeader.cell_mode_solid_block()

    assert {:ok, %{chunk_version: 2, persist_result: :updated}} =
             ChunkProcess.apply_intent(
               chunk,
               intent_attrs(lease,
                 request_id: 71,
                 macro: {1, 0, 0},
                 block: NormalBlockData.new(8, health: 30)
               )
             )

    assert {:ok, snapshot} = ChunkSnapshotStore.get_snapshot(snapshot_store, 1, {1, 1, 1})
    assert snapshot.chunk_version == 2
    assert byte_size(snapshot.chunk_hash) == 8
    assert {:ok, %{storage: stored_storage}} = Codec.decode_chunk_snapshot_payload(snapshot.data)
    assert stored_storage.chunk_version == 2

    debug = ChunkProcess.debug_state(chunk)
    assert debug.chunk_version == 2
    assert debug.lease.lease_id == lease.lease_id
  end

  test "apply_intent skips identical solid cells without persisting or pushing deltas" do
    {_token_store, snapshot_store, lease} = start_snapshot_store()

    chunk =
      start_supervised!(
        {ChunkProcess,
         logical_scene_id: 1, chunk_coord: {1, 1, 1}, snapshot_store: snapshot_store}
      )

    block = NormalBlockData.new(7)

    assert {:ok, %{chunk_version: 1, changed?: true}} =
             ChunkProcess.apply_intent(chunk, intent_attrs(lease, macro: {0, 0, 0}, block: block))

    assert {:ok, initial_payload} = ChunkProcess.subscribe(chunk, self(), request_id: 72)
    assert_receive {:voxel_chunk_snapshot_payload, ^initial_payload}

    assert {:ok,
            %{
              chunk_version: 1,
              changed?: false,
              persist_result: :unchanged,
              snapshot_payload: noop_payload
            }} =
             ChunkProcess.apply_intent(
               chunk,
               intent_attrs(lease, request_id: 73, macro: {0, 0, 0}, block: block)
             )

    refute_received {:voxel_chunk_delta_payload, _payload}
    refute_received {:voxel_chunk_snapshot_payload, _payload}

    assert {:ok, %{request_id: 73, storage: noop_storage}} =
             Codec.decode_chunk_snapshot_payload(noop_payload)

    assert noop_storage.chunk_version == 1
    assert {:ok, snapshot} = ChunkSnapshotStore.get_snapshot(snapshot_store, 1, {1, 1, 1})
    assert snapshot.chunk_version == 1
  end

  test "apply_intents batches many cells into one chunk version and one persist" do
    {_token_store, snapshot_store, lease} = start_snapshot_store()

    chunk =
      start_supervised!(
        {ChunkProcess,
         logical_scene_id: 1, chunk_coord: {1, 1, 1}, snapshot_store: snapshot_store}
      )

    attrs =
      for x <- 0..2 do
        intent_attrs(lease, request_id: 80 + x, macro: {x, 0, 0}, block: NormalBlockData.new(5))
      end

    assert {:ok,
            %{
              chunk_version: 1,
              changed?: true,
              changed_count: 3,
              skipped_count: 0,
              persist_result: :inserted,
              snapshot_payload: payload
            }} = ChunkProcess.apply_intents(chunk, attrs)

    assert {:ok, %{storage: storage}} = Codec.decode_chunk_snapshot_payload(payload)
    assert storage.chunk_version == 1

    Enum.each(0..2, fn x ->
      assert Storage.macro_header_at(storage, {x, 0, 0}).mode ==
               MacroCellHeader.cell_mode_solid_block()
    end)

    assert {:ok, snapshot} = ChunkSnapshotStore.get_snapshot(snapshot_store, 1, {1, 1, 1})
    assert snapshot.chunk_version == 1
  end

  test "apply_intent rejects missing leases without mutating or persisting" do
    {_token_store, snapshot_store, lease} = start_snapshot_store()

    chunk =
      start_supervised!(
        {ChunkProcess,
         logical_scene_id: 1, chunk_coord: {1, 1, 1}, snapshot_store: snapshot_store}
      )

    attrs = lease |> intent_attrs() |> Map.delete(:lease)

    assert {:error, :missing_lease} = ChunkProcess.apply_intent(chunk, attrs)
    assert ChunkProcess.debug_state(chunk).chunk_version == 0

    assert {:error, :snapshot_not_found} =
             ChunkSnapshotStore.get_snapshot(snapshot_store, 1, {1, 1, 1})
  end

  test "apply_intent rejects expired leases without mutating or persisting" do
    expired_lease = %{lease() | expires_at_ms: System.system_time(:millisecond) - 1}
    {_token_store, snapshot_store, _lease} = start_snapshot_store(expired_lease)

    chunk =
      start_supervised!(
        {ChunkProcess,
         logical_scene_id: 1, chunk_coord: {1, 1, 1}, snapshot_store: snapshot_store}
      )

    assert {:error, :lease_expired} =
             ChunkProcess.apply_intent(chunk, intent_attrs(expired_lease))

    assert ChunkProcess.debug_state(chunk).chunk_version == 0

    assert {:error, :snapshot_not_found} =
             ChunkSnapshotStore.get_snapshot(snapshot_store, 1, {1, 1, 1})
  end

  test "apply_intent rejects lease identity mismatches without mutating or persisting" do
    stale_lease = lease()

    current_lease = %{
      stale_lease
      | lease_id: 101,
        owner_scene_instance_ref: 2_000,
        owner_epoch: 2
    }

    token_store = start_supervised!(WriteTokenStore)

    snapshot_store =
      start_supervised!({ChunkSnapshotStore, write_token_store: token_store})

    assert {:ok, :inserted} =
             WriteTokenStore.upsert_token(token_store, Map.put(current_lease, :token_version, 2))

    chunk =
      start_supervised!(
        {ChunkProcess,
         logical_scene_id: 1, chunk_coord: {1, 1, 1}, snapshot_store: snapshot_store}
      )

    assert {:error, :lease_id_mismatch} =
             ChunkProcess.apply_intent(chunk, intent_attrs(stale_lease))

    assert ChunkProcess.debug_state(chunk).chunk_version == 0

    assert {:error, :snapshot_not_found} =
             ChunkSnapshotStore.get_snapshot(snapshot_store, 1, {1, 1, 1})
  end

  test "apply_intent pushes a CellSolid ChunkDelta to subscribers after persistence" do
    {_token_store, snapshot_store, lease} = start_snapshot_store()

    chunk =
      start_supervised!(
        {ChunkProcess,
         logical_scene_id: 1, chunk_coord: {1, 1, 1}, snapshot_store: snapshot_store}
      )

    assert {:ok, initial_payload} = ChunkProcess.subscribe(chunk, self(), request_id: 88)
    assert_receive {:voxel_chunk_snapshot_payload, ^initial_payload}

    block = NormalBlockData.new(9)

    assert {:ok, %{chunk_version: 1}} =
             ChunkProcess.apply_intent(
               chunk,
               intent_attrs(lease, macro: {2, 0, 0}, block: block)
             )

    assert_receive {:voxel_chunk_delta_payload, delta_payload}
    refute delta_payload == initial_payload

    assert {:ok, decoded} = Codec.decode_chunk_delta_payload(delta_payload)
    assert decoded.logical_scene_id == 1
    assert decoded.chunk_coord == {1, 1, 1}
    assert decoded.base_chunk_version == 0
    assert decoded.new_chunk_version == 1

    assert [%{delta_kind: 1, cell_version: 1, payload: block_payload}] = decoded.ops
    assert Codec.decode_normal_block_data(block_payload) == NormalBlockData.normalize!(block)
  end

  test "invalidate_subscribers pushes a ChunkInvalidate payload and drops every subscriber" do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {0, 0, 0}})

    assert {:ok, initial_payload} = ChunkProcess.subscribe(chunk, self())
    assert_receive {:voxel_chunk_snapshot_payload, ^initial_payload}

    assert {:ok, %{subscriber_count: 1, reason: 0x01}} =
             ChunkProcess.invalidate_subscribers(chunk, 0x01)

    assert_receive {:voxel_chunk_invalidate_payload, payload}
    assert {:ok, decoded} = Codec.decode_chunk_invalidate_payload(payload)
    assert decoded.logical_scene_id == 1
    assert decoded.chunk_coord == {0, 0, 0}
    assert decoded.reason == 0x01
    assert decoded.reason_name == :migration_cutover

    # Subscriber list is now empty so subsequent edits do not push back.
    assert ChunkProcess.debug_state(chunk).subscriber_count == 0
  end

  test "unsubscribe stops future snapshot fallback pushes" do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {0, 0, 0}})

    assert {:ok, initial_payload} = ChunkProcess.subscribe(chunk, self())
    assert_receive {:voxel_chunk_snapshot_payload, ^initial_payload}

    assert :ok = ChunkProcess.unsubscribe(chunk, self())
    assert ChunkProcess.debug_state(chunk).subscriber_count == 0

    assert {:ok, _storage} =
             ChunkProcess.put_solid_block(
               chunk,
               {0, 0, 0},
               NormalBlockData.new(2),
               cell_version: 1
             )

    refute_received {:voxel_chunk_snapshot_payload, _payload}
  end

  test "dead subscribers are removed by monitor cleanup" do
    chunk = start_supervised!({ChunkProcess, logical_scene_id: 1, chunk_coord: {0, 0, 0}})
    parent = self()

    subscriber =
      spawn(fn ->
        case ChunkProcess.subscribe(chunk, self()) do
          {:ok, payload} ->
            receive do
              {:voxel_chunk_snapshot_payload, ^payload} ->
                send(parent, :subscriber_received_snapshot)
            after
              500 ->
                send(parent, :subscriber_snapshot_timeout)
            end

          other ->
            send(parent, {:subscriber_error, other})
        end
      end)

    monitor_ref = Process.monitor(subscriber)

    assert_receive :subscriber_received_snapshot
    assert_receive {:DOWN, ^monitor_ref, :process, ^subscriber, :normal}

    assert_eventually(fn ->
      ChunkProcess.debug_state(chunk).subscriber_count == 0
    end)
  end

  test "persists snapshots through DataService write-token fence" do
    token_store = start_supervised!(WriteTokenStore)

    snapshot_store =
      start_supervised!({ChunkSnapshotStore, write_token_store: token_store})

    lease = lease()

    assert {:ok, :inserted} =
             WriteTokenStore.upsert_token(token_store, Map.put(lease, :token_version, 1))

    chunk =
      start_supervised!(
        {ChunkProcess,
         logical_scene_id: 1, chunk_coord: {1, 1, 1}, lease: lease, snapshot_store: snapshot_store}
      )

    assert {:ok, _storage} =
             ChunkProcess.put_solid_block(chunk, 0, NormalBlockData.new(7), cell_version: 1)

    assert {:ok, :inserted} = ChunkProcess.persist(chunk)
    assert {:ok, snapshot} = ChunkSnapshotStore.get_snapshot(snapshot_store, 1, {1, 1, 1})

    assert snapshot.chunk_version == 1
    assert byte_size(snapshot.chunk_hash) == 8
    assert {:ok, %{storage: decoded_storage}} = Codec.decode_chunk_snapshot_payload(snapshot.data)
    assert decoded_storage.chunk_version == 1
  end

  test "stale lease cannot persist after token advances" do
    token_store = start_supervised!(WriteTokenStore)

    snapshot_store =
      start_supervised!({ChunkSnapshotStore, write_token_store: token_store})

    lease_v1 = lease()
    lease_v2 = %{lease_v1 | lease_id: 101, owner_scene_instance_ref: 2_000, owner_epoch: 2}

    assert {:ok, :inserted} =
             WriteTokenStore.upsert_token(token_store, Map.put(lease_v1, :token_version, 1))

    assert {:ok, :updated} =
             WriteTokenStore.upsert_token(token_store, Map.put(lease_v2, :token_version, 2))

    chunk =
      start_supervised!(
        {ChunkProcess,
         logical_scene_id: 1,
         chunk_coord: {1, 1, 1},
         lease: lease_v1,
         snapshot_store: snapshot_store}
      )

    assert {:ok, _storage} =
             ChunkProcess.put_solid_block(chunk, 0, NormalBlockData.new(7), cell_version: 1)

    assert {:error, :lease_id_mismatch} = ChunkProcess.persist(chunk)
  end

  defp lease do
    %{
      logical_scene_id: 1,
      region_id: 10,
      lease_id: 100,
      owner_scene_instance_ref: 1_000,
      owner_epoch: 1,
      bounds_chunk_min: {0, 0, 0},
      bounds_chunk_max: {4, 4, 4},
      expires_at_ms: System.system_time(:millisecond) + 60_000
    }
  end

  defp start_snapshot_store(token \\ lease()) do
    token_store = start_supervised!(WriteTokenStore)

    snapshot_store =
      start_supervised!({ChunkSnapshotStore, write_token_store: token_store})

    assert {:ok, :inserted} =
             WriteTokenStore.upsert_token(token_store, Map.put(token, :token_version, 1))

    {token_store, snapshot_store, token}
  end

  defp intent_attrs(lease, overrides \\ []) do
    %{
      request_id: 70,
      logical_scene_id: lease.logical_scene_id,
      chunk_coord: {1, 1, 1},
      lease: lease,
      operation: :put_solid_block,
      macro: 0,
      block: NormalBlockData.new(7)
    }
    |> Map.merge(Map.new(overrides))
  end

  defp assert_eventually(fun, timeout_ms \\ 500) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    assert_eventually(fun, deadline, timeout_ms)
  end

  defp assert_eventually(fun, deadline, timeout_ms) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition did not become true within #{timeout_ms}ms")
      else
        receive do
        after
          10 -> assert_eventually(fun, deadline, timeout_ms)
        end
      end
    end
  end
end
