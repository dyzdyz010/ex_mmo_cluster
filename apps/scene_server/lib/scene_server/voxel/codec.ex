defmodule SceneServer.Voxel.Codec do
  @moduledoc """
  Big-endian v1 voxel snapshot codec.

  S0 supports canonical `ChunkSnapshot` payloads with fixed v1 parameters:
  `chunk_size_in_macro = 16`, `micro_resolution = 8`, and exactly 4096 macro
  headers. Refined cells now have a real wire encoding (Phase 1a); attribute
  and tag catalog sections remain limited to empty pools until later
  implementation slices add their structures.
  """

  alias SceneServer.Voxel.ChunkObjectRef
  alias SceneServer.Voxel.Hash
  alias SceneServer.Voxel.MacroCellHeader
  alias SceneServer.Voxel.MacroEnvironmentSummary
  alias SceneServer.Voxel.MicroLayer
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.ObjectCoverRef
  alias SceneServer.Voxel.RefinedCellData
  alias SceneServer.Voxel.Storage

  @section_macro_headers 0x01
  @section_normal_blocks 0x02
  @section_refined_cells 0x03
  @section_attribute_sets 0x04
  @section_tag_sets 0x05
  @section_environment_summaries 0x06
  @section_object_refs 0x07

  @snapshot_sections [
    @section_macro_headers,
    @section_normal_blocks,
    @section_refined_cells,
    @section_attribute_sets,
    @section_tag_sets,
    @section_environment_summaries,
    @section_object_refs
  ]

  @macro_header_wire_size 19
  @normal_block_wire_size 20
  @environment_wire_size 14
  @object_ref_wire_size 30
  @max_u63 9_223_372_036_854_775_807

  @doc """
  Encodes a v1 `ChunkSnapshot` payload.

  The input can be a `%SceneServer.Voxel.Storage{}` or a map with
  `:request_id` and `:storage`. When omitted, `request_id` defaults to `0`.
  """
  @spec encode_chunk_snapshot_payload(Storage.t() | map()) :: binary()
  def encode_chunk_snapshot_payload(storage_or_snapshot) do
    %{request_id: request_id, storage: storage} = normalize_snapshot_input!(storage_or_snapshot)
    chunk_hash = chunk_hash(storage)
    {cx, cy, cz} = storage.chunk_coord
    sections = encode_snapshot_sections(storage)

    IO.iodata_to_binary([
      <<request_id::unsigned-big-integer-size(64)>>,
      <<storage.logical_scene_id::unsigned-big-integer-size(64)>>,
      <<cx::signed-big-integer-size(32), cy::signed-big-integer-size(32),
        cz::signed-big-integer-size(32)>>,
      <<storage.schema_version::unsigned-big-integer-size(16)>>,
      <<storage.chunk_size_in_macro::unsigned-integer-size(8)>>,
      <<storage.micro_resolution::unsigned-integer-size(8)>>,
      <<storage.chunk_version::unsigned-big-integer-size(64)>>,
      Hash.encode64(chunk_hash),
      <<length(sections)::unsigned-big-integer-size(16)>>,
      sections
    ])
  end

  @doc "Decodes a v1 `ChunkSnapshot` payload, returning `{:ok, snapshot}` or `{:error, reason}`."
  @spec decode_chunk_snapshot_payload(binary()) :: {:ok, map()} | {:error, term()}
  def decode_chunk_snapshot_payload(payload) when is_binary(payload) do
    {:ok, decode_chunk_snapshot_payload!(payload)}
  rescue
    exception in [ArgumentError, MatchError] ->
      {:error, Exception.message(exception)}
  end

  @doc "Decodes a v1 `ChunkSnapshot` payload or raises `ArgumentError`."
  @spec decode_chunk_snapshot_payload!(binary()) :: map()
  def decode_chunk_snapshot_payload!(
        <<request_id::unsigned-big-integer-size(64),
          logical_scene_id::unsigned-big-integer-size(64), cx::signed-big-integer-size(32),
          cy::signed-big-integer-size(32), cz::signed-big-integer-size(32),
          schema_version::unsigned-big-integer-size(16),
          chunk_size_in_macro::unsigned-integer-size(8),
          micro_resolution::unsigned-integer-size(8),
          chunk_version::unsigned-big-integer-size(64),
          encoded_chunk_hash::unsigned-big-integer-size(64),
          section_count::unsigned-big-integer-size(16), rest::binary>>
      ) do
    {sections, <<>>} = decode_sections(rest, section_count, %{})

    storage =
      %Storage{
        schema_version: schema_version,
        logical_scene_id: logical_scene_id,
        chunk_coord: {cx, cy, cz},
        chunk_size_in_macro: chunk_size_in_macro,
        micro_resolution: micro_resolution,
        chunk_version: chunk_version,
        macro_headers: decode_macro_headers!(fetch_section!(sections, @section_macro_headers)),
        normal_blocks: decode_normal_blocks!(fetch_section!(sections, @section_normal_blocks)),
        refined_cells:
          decode_refined_cell_pool!(fetch_section!(sections, @section_refined_cells)),
        attribute_sets:
          decode_empty_pool!(fetch_section!(sections, @section_attribute_sets), :attribute_sets),
        tag_sets: decode_empty_pool!(fetch_section!(sections, @section_tag_sets), :tag_sets),
        environment_summaries:
          decode_environment_summaries!(fetch_section!(sections, @section_environment_summaries)),
        object_refs: decode_object_refs!(fetch_section!(sections, @section_object_refs))
      }
      |> Storage.normalize!()

    computed_chunk_hash = chunk_hash(storage)

    if computed_chunk_hash != encoded_chunk_hash do
      raise ArgumentError,
            "chunk hash mismatch: encoded=#{encoded_chunk_hash} computed=#{computed_chunk_hash}"
    end

    %{
      request_id: request_id,
      chunk_hash: encoded_chunk_hash,
      computed_chunk_hash: computed_chunk_hash,
      storage: storage
    }
  end

  def decode_chunk_snapshot_payload!(_payload) do
    raise ArgumentError, "malformed ChunkSnapshot payload"
  end

  @doc """
  Encodes a v1 `ChunkDelta` payload (protocol design 13.3, opcode `0x63`).

  Wire layout:

      logical_scene_id            u64
      chunk_coord         i32 cx, i32 cy, i32 cz
      base_chunk_version  u64
      new_chunk_version   u64
      op_count            u16
      ops[] {
        delta_kind         u8
        macro_index        u16
        cell_version       u32
        cell_hash          u32
        payload_len        u16
        payload            binary-size(payload_len)
      }

  The `payload_len` prefix is added so decoders can skip ops with unknown
  `delta_kind` values forward-compatibly. `delta_kind = 1` (CellSolid) carries
  a 20-byte `NormalBlockData`; the other kinds in the spec are not yet emitted
  by S0 and round-trip as opaque bytes.
  """
  @spec encode_chunk_delta_payload(map()) :: binary()
  def encode_chunk_delta_payload(%{
        logical_scene_id: logical_scene_id,
        chunk_coord: {cx, cy, cz},
        base_chunk_version: base_version,
        new_chunk_version: new_version,
        ops: ops
      })
      when is_integer(logical_scene_id) and is_integer(cx) and is_integer(cy) and
             is_integer(cz) and is_integer(base_version) and is_integer(new_version) and
             is_list(ops) do
    cond do
      base_version < 0 or new_version < 0 ->
        raise ArgumentError, "chunk versions must be non-negative"

      length(ops) > 0xFFFF ->
        raise ArgumentError, "delta op_count exceeds u16 range"

      true ->
        encoded_ops = Enum.map(ops, &encode_delta_op/1)

        IO.iodata_to_binary([
          <<logical_scene_id::unsigned-big-integer-size(64)>>,
          <<cx::signed-big-integer-size(32), cy::signed-big-integer-size(32),
            cz::signed-big-integer-size(32)>>,
          <<base_version::unsigned-big-integer-size(64)>>,
          <<new_version::unsigned-big-integer-size(64)>>,
          <<length(ops)::unsigned-big-integer-size(16)>>,
          encoded_ops
        ])
    end
  end

  @doc "Decodes a v1 `ChunkDelta` payload, returning `{:ok, delta}` or `{:error, reason}`."
  @spec decode_chunk_delta_payload(binary()) :: {:ok, map()} | {:error, term()}
  def decode_chunk_delta_payload(payload) when is_binary(payload) do
    {:ok, decode_chunk_delta_payload!(payload)}
  rescue
    exception in [ArgumentError, MatchError] ->
      {:error, Exception.message(exception)}
  end

  @doc "Decodes a v1 `ChunkDelta` payload or raises `ArgumentError`."
  @spec decode_chunk_delta_payload!(binary()) :: map()
  def decode_chunk_delta_payload!(
        <<logical_scene_id::unsigned-big-integer-size(64), cx::signed-big-integer-size(32),
          cy::signed-big-integer-size(32), cz::signed-big-integer-size(32),
          base_version::unsigned-big-integer-size(64), new_version::unsigned-big-integer-size(64),
          op_count::unsigned-big-integer-size(16), rest::binary>>
      ) do
    {ops, <<>>} = decode_delta_ops(rest, op_count, [])

    %{
      logical_scene_id: logical_scene_id,
      chunk_coord: {cx, cy, cz},
      base_chunk_version: base_version,
      new_chunk_version: new_version,
      ops: ops
    }
  end

  def decode_chunk_delta_payload!(_payload) do
    raise ArgumentError, "malformed ChunkDelta payload"
  end

  @doc """
  Encodes a v1 `ChunkInvalidate` payload (opcode `0x69`).

  Wire layout (21 bytes fixed):

      logical_scene_id    u64
      chunk_coord         i32 cx, i32 cy, i32 cz
      reason              u8

  Defined `reason` values:

  - `0x00` `unspecified` — generic invalidate, the client should drop and
    re-subscribe to refresh the chunk.
  - `0x01` `migration_cutover` — the region's owner Scene changed and the old
    snapshot is no longer authoritative.
  - `0x02` `region_removed` — the region was unassigned; the client must not
    re-subscribe until World announces a new owner.
  - `0x03` `catalog_changed` — attribute / tag catalog churned beneath this
    chunk; existing snapshot field references may be stale.

  Other `reason` values are accepted by the decoder for forward compatibility;
  unknown reasons round-trip as their numeric byte.
  """
  @spec encode_chunk_invalidate_payload(map()) :: binary()
  def encode_chunk_invalidate_payload(%{
        logical_scene_id: logical_scene_id,
        chunk_coord: {cx, cy, cz},
        reason: reason
      })
      when is_integer(logical_scene_id) and logical_scene_id >= 0 and is_integer(cx) and
             is_integer(cy) and is_integer(cz) and is_integer(reason) and reason >= 0 and
             reason <= 0xFF do
    <<logical_scene_id::unsigned-big-integer-size(64), cx::signed-big-integer-size(32),
      cy::signed-big-integer-size(32), cz::signed-big-integer-size(32),
      reason::unsigned-integer-size(8)>>
  end

  @doc "Decodes a v1 `ChunkInvalidate` payload, returning `{:ok, invalidate}` or `{:error, reason}`."
  @spec decode_chunk_invalidate_payload(binary()) :: {:ok, map()} | {:error, term()}
  def decode_chunk_invalidate_payload(payload) when is_binary(payload) do
    {:ok, decode_chunk_invalidate_payload!(payload)}
  rescue
    exception in [ArgumentError, MatchError] ->
      {:error, Exception.message(exception)}
  end

  @doc "Decodes a v1 `ChunkInvalidate` payload or raises `ArgumentError`."
  @spec decode_chunk_invalidate_payload!(binary()) :: map()
  def decode_chunk_invalidate_payload!(
        <<logical_scene_id::unsigned-big-integer-size(64), cx::signed-big-integer-size(32),
          cy::signed-big-integer-size(32), cz::signed-big-integer-size(32),
          reason::unsigned-integer-size(8)>>
      ) do
    %{
      logical_scene_id: logical_scene_id,
      chunk_coord: {cx, cy, cz},
      reason: reason,
      reason_name: invalidate_reason_name(reason)
    }
  end

  def decode_chunk_invalidate_payload!(_payload) do
    raise ArgumentError, "malformed ChunkInvalidate payload"
  end

  @doc "Maps a numeric ChunkInvalidate reason byte to a stable atom for log/observe consumers."
  @spec invalidate_reason_name(0..0xFF) :: atom()
  def invalidate_reason_name(0x00), do: :unspecified
  def invalidate_reason_name(0x01), do: :migration_cutover
  def invalidate_reason_name(0x02), do: :region_removed
  def invalidate_reason_name(0x03), do: :catalog_changed
  def invalidate_reason_name(_other), do: :unknown

  @doc """
  Encodes a v1 `BuildReservationIntent` payload (protocol design 13.4, opcode `0x65`).

  Wire layout (104 bytes fixed):

      request_id                u64
      client_intent_seq         u32
      logical_scene_id          u64
      parcel_id                 u64
      known_parcel_build_epoch  u64
      bounds_world_micro        AabbI64 (i64 minx,miny,minz,maxx,maxy,maxz)
      intent_hash               u64
      ttl_ms                    u32
  """
  @spec encode_build_reservation_intent_payload(map()) :: binary()
  def encode_build_reservation_intent_payload(%{
        request_id: request_id,
        client_intent_seq: client_intent_seq,
        logical_scene_id: logical_scene_id,
        parcel_id: parcel_id,
        known_parcel_build_epoch: known_parcel_build_epoch,
        bounds_world_micro: {min_x, min_y, min_z, max_x, max_y, max_z},
        intent_hash: intent_hash,
        ttl_ms: ttl_ms
      })
      when is_integer(request_id) and request_id >= 0 and
             is_integer(client_intent_seq) and client_intent_seq >= 0 and
             is_integer(logical_scene_id) and logical_scene_id >= 0 and
             is_integer(parcel_id) and parcel_id >= 0 and
             is_integer(known_parcel_build_epoch) and known_parcel_build_epoch >= 0 and
             is_integer(min_x) and is_integer(min_y) and is_integer(min_z) and
             is_integer(max_x) and is_integer(max_y) and is_integer(max_z) and
             is_integer(intent_hash) and intent_hash >= 0 and
             is_integer(ttl_ms) and ttl_ms >= 0 do
    <<request_id::unsigned-big-integer-size(64), client_intent_seq::unsigned-big-integer-size(32),
      logical_scene_id::unsigned-big-integer-size(64), parcel_id::unsigned-big-integer-size(64),
      known_parcel_build_epoch::unsigned-big-integer-size(64), min_x::signed-big-integer-size(64),
      min_y::signed-big-integer-size(64), min_z::signed-big-integer-size(64),
      max_x::signed-big-integer-size(64), max_y::signed-big-integer-size(64),
      max_z::signed-big-integer-size(64), intent_hash::unsigned-big-integer-size(64),
      ttl_ms::unsigned-big-integer-size(32)>>
  end

  @doc "Decodes a v1 `BuildReservationIntent` payload, returning `{:ok, intent}` or `{:error, reason}`."
  @spec decode_build_reservation_intent_payload(binary()) :: {:ok, map()} | {:error, term()}
  def decode_build_reservation_intent_payload(payload) when is_binary(payload) do
    {:ok, decode_build_reservation_intent_payload!(payload)}
  rescue
    exception in [ArgumentError, MatchError] ->
      {:error, Exception.message(exception)}
  end

  @doc "Decodes a v1 `BuildReservationIntent` payload or raises `ArgumentError`."
  @spec decode_build_reservation_intent_payload!(binary()) :: map()
  def decode_build_reservation_intent_payload!(
        <<request_id::unsigned-big-integer-size(64),
          client_intent_seq::unsigned-big-integer-size(32),
          logical_scene_id::unsigned-big-integer-size(64),
          parcel_id::unsigned-big-integer-size(64),
          known_parcel_build_epoch::unsigned-big-integer-size(64),
          min_x::signed-big-integer-size(64), min_y::signed-big-integer-size(64),
          min_z::signed-big-integer-size(64), max_x::signed-big-integer-size(64),
          max_y::signed-big-integer-size(64), max_z::signed-big-integer-size(64),
          intent_hash::unsigned-big-integer-size(64), ttl_ms::unsigned-big-integer-size(32)>>
      ) do
    %{
      request_id: request_id,
      client_intent_seq: client_intent_seq,
      logical_scene_id: logical_scene_id,
      parcel_id: parcel_id,
      known_parcel_build_epoch: known_parcel_build_epoch,
      bounds_world_micro: {min_x, min_y, min_z, max_x, max_y, max_z},
      intent_hash: intent_hash,
      ttl_ms: ttl_ms
    }
  end

  def decode_build_reservation_intent_payload!(_payload) do
    raise ArgumentError, "malformed BuildReservationIntent payload"
  end

  @doc """
  Encodes a v1 `PrefabPlaceIntent` payload (protocol design 13.5, opcode `0x67`).

  Wire layout:

      request_id                u64
      client_intent_seq         u32
      logical_scene_id          u64
      parcel_id                 u64
      known_parcel_build_epoch  u64
      blueprint_id              u64
      blueprint_version         u32
      anchor_world_micro        i64 x, i64 y, i64 z
      rotation                  u8
      known_ref_count           u16
      known_refs[] {
        chunk_coord             i32 cx, i32 cy, i32 cz
        chunk_version           u64
      }
      known_object_count        u16
      known_objects[] {
        object_id               u64
        object_version          u64
      }
      known_cell_ref_count      u16
      known_cell_refs[] {
        chunk_coord             i32 cx, i32 cy, i32 cz
        macro_index             u16
        cell_version            u32
        cell_hash               u32
      }
      placement_flags           u32
  """
  @spec encode_prefab_place_intent_payload(map()) :: binary()
  def encode_prefab_place_intent_payload(%{
        request_id: request_id,
        client_intent_seq: client_intent_seq,
        logical_scene_id: logical_scene_id,
        parcel_id: parcel_id,
        known_parcel_build_epoch: known_parcel_build_epoch,
        blueprint_id: blueprint_id,
        blueprint_version: blueprint_version,
        anchor_world_micro: {ax, ay, az},
        rotation: rotation,
        known_refs: known_refs,
        known_objects: known_objects,
        known_cell_refs: known_cell_refs,
        placement_flags: placement_flags
      })
      when is_integer(request_id) and request_id >= 0 and
             is_integer(client_intent_seq) and client_intent_seq >= 0 and
             is_integer(logical_scene_id) and logical_scene_id >= 0 and
             is_integer(parcel_id) and parcel_id >= 0 and
             is_integer(known_parcel_build_epoch) and known_parcel_build_epoch >= 0 and
             is_integer(blueprint_id) and blueprint_id >= 0 and
             is_integer(blueprint_version) and blueprint_version >= 0 and
             is_integer(ax) and is_integer(ay) and is_integer(az) and
             is_integer(rotation) and rotation >= 0 and rotation <= 0xFF and
             is_list(known_refs) and is_list(known_objects) and is_list(known_cell_refs) and
             is_integer(placement_flags) and placement_flags >= 0 do
    cond do
      length(known_refs) > 0xFFFF ->
        raise ArgumentError, "known_ref_count exceeds u16 range"

      length(known_objects) > 0xFFFF ->
        raise ArgumentError, "known_object_count exceeds u16 range"

      length(known_cell_refs) > 0xFFFF ->
        raise ArgumentError, "known_cell_ref_count exceeds u16 range"

      true ->
        IO.iodata_to_binary([
          <<request_id::unsigned-big-integer-size(64),
            client_intent_seq::unsigned-big-integer-size(32),
            logical_scene_id::unsigned-big-integer-size(64),
            parcel_id::unsigned-big-integer-size(64),
            known_parcel_build_epoch::unsigned-big-integer-size(64),
            blueprint_id::unsigned-big-integer-size(64),
            blueprint_version::unsigned-big-integer-size(32), ax::signed-big-integer-size(64),
            ay::signed-big-integer-size(64), az::signed-big-integer-size(64),
            rotation::unsigned-integer-size(8),
            length(known_refs)::unsigned-big-integer-size(16)>>,
          Enum.map(known_refs, &encode_prefab_known_ref/1),
          <<length(known_objects)::unsigned-big-integer-size(16)>>,
          Enum.map(known_objects, &encode_prefab_known_object/1),
          <<length(known_cell_refs)::unsigned-big-integer-size(16)>>,
          Enum.map(known_cell_refs, &encode_prefab_known_cell_ref/1),
          <<placement_flags::unsigned-big-integer-size(32)>>
        ])
    end
  end

  @doc "Decodes a v1 `PrefabPlaceIntent` payload, returning `{:ok, intent}` or `{:error, reason}`."
  @spec decode_prefab_place_intent_payload(binary()) :: {:ok, map()} | {:error, term()}
  def decode_prefab_place_intent_payload(payload) when is_binary(payload) do
    {:ok, decode_prefab_place_intent_payload!(payload)}
  rescue
    exception in [ArgumentError, MatchError] ->
      {:error, Exception.message(exception)}
  end

  @doc "Decodes a v1 `PrefabPlaceIntent` payload or raises `ArgumentError`."
  @spec decode_prefab_place_intent_payload!(binary()) :: map()
  def decode_prefab_place_intent_payload!(
        <<request_id::unsigned-big-integer-size(64),
          client_intent_seq::unsigned-big-integer-size(32),
          logical_scene_id::unsigned-big-integer-size(64),
          parcel_id::unsigned-big-integer-size(64),
          known_parcel_build_epoch::unsigned-big-integer-size(64),
          blueprint_id::unsigned-big-integer-size(64),
          blueprint_version::unsigned-big-integer-size(32), ax::signed-big-integer-size(64),
          ay::signed-big-integer-size(64), az::signed-big-integer-size(64),
          rotation::unsigned-integer-size(8), known_ref_count::unsigned-big-integer-size(16),
          rest::binary>>
      ) do
    {known_refs, after_refs} = decode_prefab_known_refs(rest, known_ref_count, [])

    <<known_object_count::unsigned-big-integer-size(16), after_object_count::binary>> = after_refs

    {known_objects, after_objects} =
      decode_prefab_known_objects(after_object_count, known_object_count, [])

    <<known_cell_ref_count::unsigned-big-integer-size(16), after_cell_count::binary>> =
      after_objects

    {known_cell_refs, <<placement_flags::unsigned-big-integer-size(32)>>} =
      decode_prefab_known_cell_refs(after_cell_count, known_cell_ref_count, [])

    %{
      request_id: request_id,
      client_intent_seq: client_intent_seq,
      logical_scene_id: logical_scene_id,
      parcel_id: parcel_id,
      known_parcel_build_epoch: known_parcel_build_epoch,
      blueprint_id: blueprint_id,
      blueprint_version: blueprint_version,
      anchor_world_micro: {ax, ay, az},
      rotation: rotation,
      known_refs: known_refs,
      known_objects: known_objects,
      known_cell_refs: known_cell_refs,
      placement_flags: placement_flags
    }
  end

  def decode_prefab_place_intent_payload!(_payload) do
    raise ArgumentError, "malformed PrefabPlaceIntent payload"
  end

  defp encode_prefab_known_ref(%{chunk_coord: {cx, cy, cz}, chunk_version: chunk_version})
       when is_integer(cx) and is_integer(cy) and is_integer(cz) and
              is_integer(chunk_version) and chunk_version >= 0 do
    <<cx::signed-big-integer-size(32), cy::signed-big-integer-size(32),
      cz::signed-big-integer-size(32), chunk_version::unsigned-big-integer-size(64)>>
  end

  defp encode_prefab_known_object(%{object_id: object_id, object_version: object_version})
       when is_integer(object_id) and object_id >= 0 and
              is_integer(object_version) and object_version >= 0 do
    <<object_id::unsigned-big-integer-size(64), object_version::unsigned-big-integer-size(64)>>
  end

  defp encode_prefab_known_cell_ref(%{
         chunk_coord: {cx, cy, cz},
         macro_index: macro_index,
         cell_version: cell_version,
         cell_hash: cell_hash
       })
       when is_integer(cx) and is_integer(cy) and is_integer(cz) and
              is_integer(macro_index) and macro_index >= 0 and macro_index <= 0xFFFF and
              is_integer(cell_version) and cell_version >= 0 and
              is_integer(cell_hash) and cell_hash >= 0 do
    <<cx::signed-big-integer-size(32), cy::signed-big-integer-size(32),
      cz::signed-big-integer-size(32), macro_index::unsigned-big-integer-size(16),
      cell_version::unsigned-big-integer-size(32), cell_hash::unsigned-big-integer-size(32)>>
  end

  defp decode_prefab_known_refs(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp decode_prefab_known_refs(
         <<cx::signed-big-integer-size(32), cy::signed-big-integer-size(32),
           cz::signed-big-integer-size(32), chunk_version::unsigned-big-integer-size(64),
           rest::binary>>,
         remaining,
         acc
       )
       when remaining > 0 do
    decode_prefab_known_refs(rest, remaining - 1, [
      %{chunk_coord: {cx, cy, cz}, chunk_version: chunk_version} | acc
    ])
  end

  defp decode_prefab_known_refs(_rest, _remaining, _acc) do
    raise ArgumentError, "malformed PrefabPlaceIntent known_refs"
  end

  defp decode_prefab_known_objects(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp decode_prefab_known_objects(
         <<object_id::unsigned-big-integer-size(64),
           object_version::unsigned-big-integer-size(64), rest::binary>>,
         remaining,
         acc
       )
       when remaining > 0 do
    decode_prefab_known_objects(rest, remaining - 1, [
      %{object_id: object_id, object_version: object_version} | acc
    ])
  end

  defp decode_prefab_known_objects(_rest, _remaining, _acc) do
    raise ArgumentError, "malformed PrefabPlaceIntent known_objects"
  end

  defp decode_prefab_known_cell_refs(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp decode_prefab_known_cell_refs(
         <<cx::signed-big-integer-size(32), cy::signed-big-integer-size(32),
           cz::signed-big-integer-size(32), macro_index::unsigned-big-integer-size(16),
           cell_version::unsigned-big-integer-size(32), cell_hash::unsigned-big-integer-size(32),
           rest::binary>>,
         remaining,
         acc
       )
       when remaining > 0 do
    decode_prefab_known_cell_refs(rest, remaining - 1, [
      %{
        chunk_coord: {cx, cy, cz},
        macro_index: macro_index,
        cell_version: cell_version,
        cell_hash: cell_hash
      }
      | acc
    ])
  end

  defp decode_prefab_known_cell_refs(_rest, _remaining, _acc) do
    raise ArgumentError, "malformed PrefabPlaceIntent known_cell_refs"
  end

  @doc """
  Encodes a single `NormalBlockData` value into the canonical 20-byte wire form.

  Used as the `CellSolid` payload inside a `ChunkDelta` op and as the per-block
  body inside a `ChunkSnapshot` `NormalBlocks` section.
  """
  @spec encode_normal_block_data(NormalBlockData.t() | map()) :: binary()
  def encode_normal_block_data(block) do
    encode_normal_block(block)
  end

  @doc "Decodes a single `NormalBlockData` value from the canonical 20-byte wire form."
  @spec decode_normal_block_data(binary()) :: NormalBlockData.t()
  def decode_normal_block_data(<<_::binary-size(@normal_block_wire_size)>> = block_binary) do
    [block] = decode_normal_blocks!(<<1::unsigned-big-integer-size(32), block_binary::binary>>)
    block
  end

  @doc "Returns the S0 canonical chunk content hash for storage truth fields."
  @spec chunk_hash(Storage.t()) :: 0..0xFFFF_FFFF_FFFF_FFFF
  def chunk_hash(%Storage{} = storage) do
    storage
    |> encode_chunk_truth_payload()
    |> Hash.digest64()
  end

  @doc "Encodes only canonical truth fields used as input to `chunk_hash/1`."
  @spec encode_chunk_truth_payload(Storage.t()) :: binary()
  def encode_chunk_truth_payload(%Storage{} = storage) do
    storage = Storage.normalize!(storage)
    {cx, cy, cz} = storage.chunk_coord

    IO.iodata_to_binary([
      <<storage.schema_version::unsigned-big-integer-size(16)>>,
      <<storage.logical_scene_id::unsigned-big-integer-size(64)>>,
      <<cx::signed-big-integer-size(32), cy::signed-big-integer-size(32),
        cz::signed-big-integer-size(32)>>,
      <<storage.chunk_size_in_macro::unsigned-integer-size(8)>>,
      <<storage.micro_resolution::unsigned-integer-size(8)>>,
      encode_macro_header_truth(storage.macro_headers),
      encode_normal_block_pool(storage.normal_blocks),
      encode_refined_cell_pool(storage.refined_cells),
      encode_environment_pool(storage.environment_summaries),
      encode_object_ref_pool(storage.object_refs),
      encode_empty_pool_for_truth(storage.attribute_sets, :attribute_sets),
      encode_empty_pool_for_truth(storage.tag_sets, :tag_sets)
    ])
  end

  defp normalize_snapshot_input!(%Storage{} = storage) do
    %{request_id: 0, storage: Storage.normalize!(storage)}
  end

  defp normalize_snapshot_input!(%{} = snapshot) do
    storage =
      snapshot
      |> fetch_any!([:storage, "storage"], :storage)
      |> Storage.normalize!()

    request_id =
      snapshot
      |> fetch_any_optional([:request_id, "request_id"], 0)
      |> uint!(@max_u63, :request_id)

    %{request_id: request_id, storage: storage}
  end

  defp encode_snapshot_sections(storage) do
    [
      encode_section(@section_macro_headers, encode_macro_headers(storage.macro_headers)),
      encode_section(@section_normal_blocks, encode_normal_block_pool(storage.normal_blocks)),
      encode_section(@section_refined_cells, encode_refined_cell_pool(storage.refined_cells)),
      encode_section(
        @section_attribute_sets,
        encode_empty_pool_for_wire(storage.attribute_sets, :attribute_sets)
      ),
      encode_section(@section_tag_sets, encode_empty_pool_for_wire(storage.tag_sets, :tag_sets)),
      encode_section(
        @section_environment_summaries,
        encode_environment_pool(storage.environment_summaries)
      ),
      encode_section(@section_object_refs, encode_object_ref_pool(storage.object_refs))
    ]
  end

  defp encode_section(section_type, section_data) do
    section_data = IO.iodata_to_binary(section_data)

    [
      <<section_type::unsigned-integer-size(8)>>,
      <<byte_size(section_data)::unsigned-big-integer-size(32)>>,
      section_data
    ]
  end

  defp encode_macro_headers(headers) do
    Enum.map(headers, fn header ->
      header = MacroCellHeader.normalize!(header)

      <<header.mode::unsigned-integer-size(8), header.flags::unsigned-big-integer-size(16),
        header.payload_index::unsigned-big-integer-size(32),
        header.environment_index::unsigned-big-integer-size(32),
        header.cell_version::unsigned-big-integer-size(32),
        header.cell_hash::unsigned-big-integer-size(32)>>
    end)
  end

  defp encode_macro_header_truth(headers) do
    Enum.map(headers, fn header ->
      header = MacroCellHeader.normalize!(header)

      <<header.mode::unsigned-integer-size(8),
        MacroCellHeader.canonical_flags(header)::unsigned-big-integer-size(16),
        header.payload_index::unsigned-big-integer-size(32),
        header.environment_index::unsigned-big-integer-size(32)>>
    end)
  end

  defp encode_normal_block_pool(blocks) do
    [
      <<length(blocks)::unsigned-big-integer-size(32)>>,
      Enum.map(blocks, &encode_normal_block/1)
    ]
  end

  defp encode_normal_block(block) do
    block = NormalBlockData.normalize!(block)

    <<block.material_id::unsigned-big-integer-size(16),
      block.state_flags::unsigned-big-integer-size(32),
      block.health::unsigned-big-integer-size(16),
      block.temperature_delta::signed-big-integer-size(16),
      block.moisture_delta::signed-big-integer-size(16),
      block.attribute_set_ref::unsigned-big-integer-size(32),
      block.tag_set_ref::unsigned-big-integer-size(32)>>
  end

  defp encode_environment_pool(summaries) do
    [
      <<length(summaries)::unsigned-big-integer-size(32)>>,
      Enum.map(summaries, &encode_environment_summary/1)
    ]
  end

  defp encode_environment_summary(summary) do
    summary = MacroEnvironmentSummary.normalize!(summary)

    <<summary.default_temperature::signed-big-integer-size(16),
      summary.default_moisture::signed-big-integer-size(16),
      summary.current_temperature::signed-big-integer-size(16),
      summary.current_moisture::signed-big-integer-size(16),
      summary.field_mask::unsigned-big-integer-size(16),
      summary.source_hash::unsigned-big-integer-size(32)>>
  end

  defp encode_object_ref_pool(refs) do
    [
      <<length(refs)::unsigned-big-integer-size(32)>>,
      Enum.map(refs, &encode_object_ref/1)
    ]
  end

  defp encode_object_ref(ref) do
    ref = ChunkObjectRef.normalize!(ref)
    {min_x, min_y, min_z} = ref.covered_macro_min
    {max_x, max_y, max_z} = ref.covered_macro_max

    <<ref.object_id::unsigned-big-integer-size(64),
      ref.object_version::unsigned-big-integer-size(64), min_x::unsigned-integer-size(8),
      min_y::unsigned-integer-size(8), min_z::unsigned-integer-size(8),
      max_x::unsigned-integer-size(8), max_y::unsigned-integer-size(8),
      max_z::unsigned-integer-size(8), ref.cover_hash::unsigned-big-integer-size(64)>>
  end

  defp encode_delta_op(%{
         delta_kind: kind,
         macro_index: macro_index,
         cell_version: cell_version,
         cell_hash: cell_hash,
         payload: payload
       })
       when is_integer(kind) and kind >= 0 and kind <= 0xFF and
              is_integer(macro_index) and macro_index >= 0 and macro_index <= 0xFFFF and
              is_integer(cell_version) and cell_version >= 0 and
              is_integer(cell_hash) and cell_hash >= 0 and is_binary(payload) do
    if byte_size(payload) > 0xFFFF do
      raise ArgumentError, "delta op payload exceeds u16 length"
    end

    [
      <<kind::unsigned-integer-size(8)>>,
      <<macro_index::unsigned-big-integer-size(16)>>,
      <<cell_version::unsigned-big-integer-size(32)>>,
      <<cell_hash::unsigned-big-integer-size(32)>>,
      <<byte_size(payload)::unsigned-big-integer-size(16)>>,
      payload
    ]
  end

  defp decode_delta_ops(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp decode_delta_ops(
         <<kind::unsigned-integer-size(8), macro_index::unsigned-big-integer-size(16),
           cell_version::unsigned-big-integer-size(32), cell_hash::unsigned-big-integer-size(32),
           payload_len::unsigned-big-integer-size(16), payload::binary-size(payload_len),
           rest::binary>>,
         remaining,
         acc
       )
       when remaining > 0 do
    op = %{
      delta_kind: kind,
      macro_index: macro_index,
      cell_version: cell_version,
      cell_hash: cell_hash,
      payload: payload
    }

    decode_delta_ops(rest, remaining - 1, [op | acc])
  end

  defp decode_delta_ops(_rest, _remaining, _acc) do
    raise ArgumentError, "malformed ChunkDelta ops binary"
  end

  defp encode_empty_pool_for_wire([], _label), do: <<0::unsigned-big-integer-size(32)>>

  defp encode_empty_pool_for_wire(values, label) do
    raise ArgumentError,
          "#{label} wire encoding is not implemented in S0, got #{length(values)} entries"
  end

  defp encode_empty_pool_for_truth([], _label), do: <<0::unsigned-big-integer-size(32)>>

  defp encode_empty_pool_for_truth(values, label) do
    raise ArgumentError,
          "#{label} canonical encoding is not implemented in S0, got #{length(values)} entries"
  end

  # ----------------------------------------------------------------------------
  # RefinedCells pool — Phase 1a wire form (protocol design §5.4).
  #
  # Identical for both wire and canonical-truth encodings. Empty list emits
  # exactly `<<0u32>>` (4 bytes count=0), byte-for-byte compatible with the
  # legacy `encode_empty_pool_for_*` output, so chunk_hash remains stable for
  # every storage whose `refined_cells` is `[]`.
  #
  # Per-cell layout:
  #   occupancy_words    u64 × 8           (64 bytes)
  #   boundary_cache     u64               (8 bytes)
  #   layer_count        u16
  #   layers[layer_count] {
  #     mask_words           u64 × 8
  #     material_id          u16
  #     state_flags          u32
  #     health               u16
  #     attribute_set_ref    u32
  #     tag_set_ref          u32
  #     owner_object_id      u64
  #     owner_part_id        u32
  #   }
  #   object_ref_count   u16
  #   object_refs[object_ref_count] {
  #     owner_object_id  u64
  #     owner_part_id    u32
  #     mask_words       u64 × 8
  #   }
  # ----------------------------------------------------------------------------

  @doc """
  Encodes a list of `RefinedCellData` into the RefinedCells section payload
  (Phase 1a wire form). The result begins with a u32 entry count and is
  byte-for-byte stable across calls; an empty list emits exactly `<<0u32>>`,
  byte-compatible with the legacy empty-pool encoding so chunk_hash stays
  stable for storages whose `refined_cells` is `[]`.
  """
  @spec encode_refined_cell_pool([RefinedCellData.t()]) :: binary()
  def encode_refined_cell_pool([]), do: <<0::unsigned-big-integer-size(32)>>

  def encode_refined_cell_pool(cells) when is_list(cells) do
    count = length(cells)

    if count > 0xFFFF_FFFF do
      raise ArgumentError, "refined_cells count #{count} exceeds u32"
    end

    IO.iodata_to_binary([
      <<count::unsigned-big-integer-size(32)>>,
      Enum.map(cells, &encode_refined_cell/1)
    ])
  end

  defp encode_refined_cell(%RefinedCellData{} = cell) do
    layer_count = length(cell.layers)
    object_ref_count = length(cell.object_refs)

    if layer_count > 0xFFFF do
      raise ArgumentError, "refined_cell layer_count #{layer_count} exceeds u16"
    end

    if object_ref_count > 0xFFFF do
      raise ArgumentError,
            "refined_cell object_ref_count #{object_ref_count} exceeds u16"
    end

    [
      encode_mask_words(cell.occupancy_words),
      <<cell.boundary_cache::unsigned-big-integer-size(64)>>,
      <<layer_count::unsigned-big-integer-size(16)>>,
      Enum.map(cell.layers, &encode_micro_layer/1),
      <<object_ref_count::unsigned-big-integer-size(16)>>,
      Enum.map(cell.object_refs, &encode_object_cover_ref/1)
    ]
  end

  defp encode_micro_layer(%MicroLayer{} = layer) do
    [
      encode_mask_words(layer.mask_words),
      <<layer.material_id::unsigned-big-integer-size(16),
        layer.state_flags::unsigned-big-integer-size(32),
        layer.health::unsigned-big-integer-size(16),
        layer.attribute_set_ref::unsigned-big-integer-size(32),
        layer.tag_set_ref::unsigned-big-integer-size(32),
        layer.owner_object_id::unsigned-big-integer-size(64),
        layer.owner_part_id::unsigned-big-integer-size(32)>>
    ]
  end

  defp encode_object_cover_ref(%ObjectCoverRef{} = ref) do
    [
      <<ref.owner_object_id::unsigned-big-integer-size(64),
        ref.owner_part_id::unsigned-big-integer-size(32)>>,
      encode_mask_words(ref.mask_words)
    ]
  end

  defp encode_mask_words(words) when length(words) == 8 do
    for w <- words, do: <<w::unsigned-big-integer-size(64)>>
  end

  @doc """
  Decodes the RefinedCells section payload back to a list of `RefinedCellData`.
  Returns `{:ok, cells}` or `{:error, reason}` instead of raising.
  """
  @spec decode_refined_cell_pool(binary()) :: {:ok, [RefinedCellData.t()]} | {:error, term()}
  def decode_refined_cell_pool(payload) when is_binary(payload) do
    {:ok, decode_refined_cell_pool!(payload)}
  rescue
    exception in [ArgumentError, MatchError] ->
      {:error, Exception.message(exception)}
  end

  @doc """
  Encodes a single `RefinedCellData` as a standalone payload (no surrounding
  count-prefixed pool). Used as the ChunkDelta op payload for
  `delta_kind = 2 (CellRefined)` (Phase 1c).

  The byte layout matches a single entry inside `encode_refined_cell_pool/1`,
  so a 1-cell pool is exactly `<<1::32>> <> encode_refined_cell_payload(cell)`.
  """
  @spec encode_refined_cell_payload(RefinedCellData.t()) :: binary()
  def encode_refined_cell_payload(%RefinedCellData{} = cell) do
    IO.iodata_to_binary(encode_refined_cell(cell))
  end

  @doc """
  Decodes a single `RefinedCellData` from a standalone payload produced by
  `encode_refined_cell_payload/1`. Raises on malformed input or trailing bytes.
  """
  @spec decode_refined_cell_payload!(binary()) :: RefinedCellData.t()
  def decode_refined_cell_payload!(payload) when is_binary(payload) do
    {cell, rest} = decode_refined_cell(payload)

    if rest != <<>> do
      raise ArgumentError,
            "trailing bytes in refined_cell payload: #{byte_size(rest)}"
    end

    cell
  end

  @doc """
  Decodes a single `RefinedCellData` standalone payload, returning
  `{:ok, cell}` or `{:error, reason}`.
  """
  @spec decode_refined_cell_payload(binary()) :: {:ok, RefinedCellData.t()} | {:error, term()}
  def decode_refined_cell_payload(payload) when is_binary(payload) do
    {:ok, decode_refined_cell_payload!(payload)}
  rescue
    exception in [ArgumentError, MatchError] ->
      {:error, Exception.message(exception)}
  end

  @doc """
  Decodes the RefinedCells section payload back to a list of `RefinedCellData`.
  Raises `ArgumentError` on malformed or trailing bytes.
  """
  @spec decode_refined_cell_pool!(binary()) :: [RefinedCellData.t()]
  def decode_refined_cell_pool!(<<0::unsigned-big-integer-size(32)>>), do: []

  def decode_refined_cell_pool!(<<count::unsigned-big-integer-size(32), rest::binary>>) do
    {cells, leftover} = decode_refined_cells(rest, count, [])

    if leftover != <<>> do
      raise ArgumentError,
            "trailing bytes in refined_cells section: #{byte_size(leftover)} bytes"
    end

    cells
  end

  def decode_refined_cell_pool!(_data),
    do: raise(ArgumentError, "malformed refined_cells pool section")

  defp decode_refined_cells(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp decode_refined_cells(data, count, acc) when count > 0 do
    {cell, rest} = decode_refined_cell(data)
    decode_refined_cells(rest, count - 1, [cell | acc])
  end

  defp decode_refined_cell(data) do
    {occupancy_words, rest} = decode_mask_words(data)

    <<boundary_cache::unsigned-big-integer-size(64), layer_count::unsigned-big-integer-size(16),
      rest::binary>> = rest

    {layers, rest} = decode_micro_layers(rest, layer_count, [])

    <<object_ref_count::unsigned-big-integer-size(16), rest::binary>> = rest

    {object_refs, rest} = decode_object_cover_refs(rest, object_ref_count, [])

    cell =
      RefinedCellData.normalize!(%{
        occupancy_words: occupancy_words,
        boundary_cache: boundary_cache,
        layers: layers,
        object_refs: object_refs
      })

    {cell, rest}
  end

  defp decode_micro_layers(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp decode_micro_layers(data, count, acc) when count > 0 do
    {mask_words, rest} = decode_mask_words(data)

    <<material_id::unsigned-big-integer-size(16), state_flags::unsigned-big-integer-size(32),
      health::unsigned-big-integer-size(16), attribute_set_ref::unsigned-big-integer-size(32),
      tag_set_ref::unsigned-big-integer-size(32), owner_object_id::unsigned-big-integer-size(64),
      owner_part_id::unsigned-big-integer-size(32), rest::binary>> = rest

    layer =
      MicroLayer.normalize!(%{
        mask_words: mask_words,
        material_id: material_id,
        state_flags: state_flags,
        health: health,
        attribute_set_ref: attribute_set_ref,
        tag_set_ref: tag_set_ref,
        owner_object_id: owner_object_id,
        owner_part_id: owner_part_id
      })

    decode_micro_layers(rest, count - 1, [layer | acc])
  end

  defp decode_object_cover_refs(rest, 0, acc), do: {Enum.reverse(acc), rest}

  defp decode_object_cover_refs(data, count, acc) when count > 0 do
    <<owner_object_id::unsigned-big-integer-size(64),
      owner_part_id::unsigned-big-integer-size(32), rest::binary>> = data

    {mask_words, rest} = decode_mask_words(rest)

    ref =
      ObjectCoverRef.normalize!(%{
        owner_object_id: owner_object_id,
        owner_part_id: owner_part_id,
        mask_words: mask_words
      })

    decode_object_cover_refs(rest, count - 1, [ref | acc])
  end

  defp decode_mask_words(<<
         w0::unsigned-big-integer-size(64),
         w1::unsigned-big-integer-size(64),
         w2::unsigned-big-integer-size(64),
         w3::unsigned-big-integer-size(64),
         w4::unsigned-big-integer-size(64),
         w5::unsigned-big-integer-size(64),
         w6::unsigned-big-integer-size(64),
         w7::unsigned-big-integer-size(64),
         rest::binary
       >>) do
    {[w0, w1, w2, w3, w4, w5, w6, w7], rest}
  end

  defp decode_sections(rest, 0, acc), do: {acc, rest}

  defp decode_sections(
         <<section_type::unsigned-integer-size(8), section_len::unsigned-big-integer-size(32),
           section_data::binary-size(section_len), rest::binary>>,
         count,
         acc
       )
       when count > 0 do
    if Map.has_key?(acc, section_type) do
      raise ArgumentError, "duplicate snapshot section #{section_type}"
    end

    decode_sections(rest, count - 1, Map.put(acc, section_type, section_data))
  end

  defp decode_sections(_rest, _count, _acc) do
    raise ArgumentError, "malformed snapshot sections"
  end

  defp fetch_section!(sections, section_type) do
    unless section_type in @snapshot_sections do
      raise ArgumentError, "unknown expected section #{section_type}"
    end

    Map.fetch!(sections, section_type)
  rescue
    KeyError ->
      raise ArgumentError, "missing snapshot section #{section_type}"
  end

  defp decode_macro_headers!(data) do
    expected_size = Storage.macro_header_count() * @macro_header_wire_size

    if byte_size(data) != expected_size do
      raise ArgumentError,
            "MacroHeaders section must be #{expected_size} bytes, got #{byte_size(data)}"
    end

    for <<mode::unsigned-integer-size(8), flags::unsigned-big-integer-size(16),
          payload_index::unsigned-big-integer-size(32),
          environment_index::unsigned-big-integer-size(32),
          cell_version::unsigned-big-integer-size(32),
          cell_hash::unsigned-big-integer-size(32) <- data>> do
      MacroCellHeader.normalize!(%{
        mode: mode,
        flags: flags,
        payload_index: payload_index,
        environment_index: environment_index,
        cell_version: cell_version,
        cell_hash: cell_hash
      })
    end
  end

  defp decode_normal_blocks!(data) do
    decode_counted_pool!(data, @normal_block_wire_size, :normal_blocks, fn
      <<material_id::unsigned-big-integer-size(16), state_flags::unsigned-big-integer-size(32),
        health::unsigned-big-integer-size(16), temperature_delta::signed-big-integer-size(16),
        moisture_delta::signed-big-integer-size(16),
        attribute_set_ref::unsigned-big-integer-size(32),
        tag_set_ref::unsigned-big-integer-size(32)>> ->
        NormalBlockData.normalize!(%{
          material_id: material_id,
          state_flags: state_flags,
          health: health,
          temperature_delta: temperature_delta,
          moisture_delta: moisture_delta,
          attribute_set_ref: attribute_set_ref,
          tag_set_ref: tag_set_ref
        })
    end)
  end

  defp decode_environment_summaries!(data) do
    decode_counted_pool!(data, @environment_wire_size, :environment_summaries, fn
      <<default_temperature::signed-big-integer-size(16),
        default_moisture::signed-big-integer-size(16),
        current_temperature::signed-big-integer-size(16),
        current_moisture::signed-big-integer-size(16), field_mask::unsigned-big-integer-size(16),
        source_hash::unsigned-big-integer-size(32)>> ->
        MacroEnvironmentSummary.normalize!(%{
          default_temperature: default_temperature,
          default_moisture: default_moisture,
          current_temperature: current_temperature,
          current_moisture: current_moisture,
          field_mask: field_mask,
          source_hash: source_hash
        })
    end)
  end

  defp decode_object_refs!(data) do
    decode_counted_pool!(data, @object_ref_wire_size, :object_refs, fn
      <<object_id::unsigned-big-integer-size(64), object_version::unsigned-big-integer-size(64),
        min_x::unsigned-integer-size(8), min_y::unsigned-integer-size(8),
        min_z::unsigned-integer-size(8), max_x::unsigned-integer-size(8),
        max_y::unsigned-integer-size(8), max_z::unsigned-integer-size(8),
        cover_hash::unsigned-big-integer-size(64)>> ->
        ChunkObjectRef.normalize!(%{
          object_id: object_id,
          object_version: object_version,
          covered_macro_min: {min_x, min_y, min_z},
          covered_macro_max: {max_x, max_y, max_z},
          cover_hash: cover_hash
        })
    end)
  end

  defp decode_empty_pool!(<<0::unsigned-big-integer-size(32)>>, _label), do: []

  defp decode_empty_pool!(<<count::unsigned-big-integer-size(32), _rest::binary>>, label) do
    raise ArgumentError, "#{label} decoding is not implemented in S0, got #{count} entries"
  end

  defp decode_empty_pool!(_data, label) do
    raise ArgumentError, "malformed #{label} empty pool section"
  end

  defp decode_counted_pool!(
         <<count::unsigned-big-integer-size(32), rest::binary>>,
         item_size,
         label,
         decoder
       ) do
    expected_size = count * item_size

    if byte_size(rest) != expected_size do
      raise ArgumentError,
            "#{label} section body must be #{expected_size} bytes, got #{byte_size(rest)}"
    end

    decode_fixed_items(rest, item_size, decoder, [])
  end

  defp decode_counted_pool!(_data, _item_size, label, _decoder) do
    raise ArgumentError, "malformed #{label} section"
  end

  defp decode_fixed_items(<<>>, _item_size, _decoder, acc), do: Enum.reverse(acc)

  defp decode_fixed_items(data, item_size, decoder, acc) do
    <<item_data::binary-size(item_size), rest::binary>> = data
    decode_fixed_items(rest, item_size, decoder, [decoder.(item_data) | acc])
  end

  defp fetch_any!(attrs, keys, label) do
    case fetch_any_optional(attrs, keys, :missing) do
      :missing -> raise ArgumentError, "missing #{label}"
      value -> value
    end
  end

  defp fetch_any_optional(attrs, keys, default) do
    Enum.find_value(keys, fn key ->
      case Map.fetch(attrs, key) do
        {:ok, value} -> {:found, value}
        :error -> nil
      end
    end)
    |> case do
      {:found, value} -> value
      nil -> default
    end
  end

  defp uint!(value, max, label) when is_integer(value) do
    if value < 0 or value > max do
      raise ArgumentError, "#{label} value #{value} outside 0..#{max}"
    end

    value
  end

  defp uint!(value, _max, label) do
    raise ArgumentError, "expected #{label} unsigned integer, got: #{inspect(value)}"
  end
end
