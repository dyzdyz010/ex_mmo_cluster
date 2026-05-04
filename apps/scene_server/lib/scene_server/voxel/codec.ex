defmodule SceneServer.Voxel.Codec do
  @moduledoc """
  Big-endian v1 voxel snapshot codec.

  S0 supports canonical `ChunkSnapshot` payloads with fixed v1 parameters:
  `chunk_size_in_macro = 16`, `micro_resolution = 8`, and exactly 4096 macro
  headers. Refined cells and catalogs are sectioned but intentionally limited to
  empty pools until later implementation slices add their wire structures.
  """

  alias SceneServer.Voxel.ChunkObjectRef
  alias SceneServer.Voxel.Hash
  alias SceneServer.Voxel.MacroCellHeader
  alias SceneServer.Voxel.MacroEnvironmentSummary
  alias SceneServer.Voxel.NormalBlockData
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
          decode_empty_pool!(fetch_section!(sections, @section_refined_cells), :refined_cells),
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
      encode_empty_pool_for_truth(storage.refined_cells, :refined_cells),
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
      encode_section(
        @section_refined_cells,
        encode_empty_pool_for_wire(storage.refined_cells, :refined_cells)
      ),
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
