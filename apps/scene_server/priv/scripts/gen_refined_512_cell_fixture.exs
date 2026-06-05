# Run with: cd apps/scene_server && mix run priv/scripts/gen_refined_512_cell_fixture.exs
#
# Generates the Phase 1a shared fixture `refined_512_cell_v1.bin` and writes
# it to:
#   * apps/scene_server/test/fixtures/voxel/refined_512_cell_v1.bin
#   * clients/web_client/test/fixtures/voxel/refined_512_cell_v1.bin
#
# Both Elixir and TypeScript decoders consume the same bytes and must
# produce identical fields. The fixture covers three relevant cases in two
# refined cells: empty object_refs, multiple layers, and an object cover ref
# that subsets occupancy.
#
# Field reference (paste into companion .json so reviewers can read the
# fixture without parsing bytes):
#
#   cell[0]:
#     occupancy_words = [0xFFFF, 0, 0, 0, 0, 0, 0, 0]
#     boundary_cache  = 0xCAFEBABEDEADBEEF
#     layers = [{
#       mask_words = [0xFFFF, 0, 0, 0, 0, 0, 0, 0],
#       material_id = 17, state_flags = 0x10, health = 200,
#       attribute_set_ref = 1, tag_set_ref = 2,
#       owner_object_id = 0, owner_part_id = 0
#     }]
#     object_refs = []
#
#   cell[1]:
#     occupancy_words = [0, 0, 0, 0, 0, 0, 0, 0xFF]
#     boundary_cache  = 0
#     layers = [
#       {mask_words = [0,0,0,0,0,0,0,0xF0], material_id = 42,
#        state_flags = 0, health = 100,
#        attribute_set_ref = 0, tag_set_ref = 0,
#        owner_object_id = 0xDEADBEEF, owner_part_id = 7},
#       {mask_words = [0,0,0,0,0,0,0,0x0F], material_id = 99,
#        state_flags = 0x01, health = 50,
#        attribute_set_ref = 5, tag_set_ref = 6,
#        owner_object_id = 0, owner_part_id = 0}
#     ]
#     object_refs = [{owner_object_id = 0xDEADBEEF, owner_part_id = 7,
#                     mask_words = [0,0,0,0,0,0,0,0xF0]}]

alias SceneServer.Voxel.MicroLayer
alias SceneServer.Voxel.ObjectCoverRef
alias SceneServer.Voxel.RefinedCellData
alias SceneServer.Voxel.Storage

defmodule FixtureGen do
  alias SceneServer.Voxel.MicroLayer
  alias SceneServer.Voxel.ObjectCoverRef
  alias SceneServer.Voxel.RefinedCellData

  def cells do
    [cell_0(), cell_1()]
  end

  defp cell_0 do
    layer =
      MicroLayer.new(
        mask_words: [0xFFFF, 0, 0, 0, 0, 0, 0, 0],
        material_id: 17,
        state_flags: 0x10,
        health: 200,
        attribute_set_ref: 1,
        tag_set_ref: 2,
        owner_object_id: 0,
        owner_part_id: 0
      )

    RefinedCellData.new(
      occupancy_words: [0xFFFF, 0, 0, 0, 0, 0, 0, 0],
      boundary_cache: 0xCAFE_BABE_DEAD_BEEF,
      layers: [layer],
      object_refs: []
    )
  end

  defp cell_1 do
    layer_a =
      MicroLayer.new(
        mask_words: [0, 0, 0, 0, 0, 0, 0, 0xF0],
        material_id: 42,
        state_flags: 0,
        health: 100,
        attribute_set_ref: 0,
        tag_set_ref: 0,
        owner_object_id: 0xDEAD_BEEF,
        owner_part_id: 7
      )

    layer_b =
      MicroLayer.new(
        mask_words: [0, 0, 0, 0, 0, 0, 0, 0x0F],
        material_id: 99,
        state_flags: 0x01,
        health: 50,
        attribute_set_ref: 5,
        tag_set_ref: 6,
        owner_object_id: 0,
        owner_part_id: 0
      )

    object_ref =
      ObjectCoverRef.new(
        owner_object_id: 0xDEAD_BEEF,
        owner_part_id: 7,
        mask_words: [0, 0, 0, 0, 0, 0, 0, 0xF0]
      )

    RefinedCellData.new(
      occupancy_words: [0, 0, 0, 0, 0, 0, 0, 0xFF],
      boundary_cache: 0,
      layers: [layer_a, layer_b],
      object_refs: [object_ref]
    )
  end
end

# We need the wire bytes as produced by the Codec. The pool encoder is a
# private function; instead we wrap the cells in a Storage and serialize the
# whole snapshot, then extract section 0x03 from the wire form.
storage =
  Storage.empty(1, {0, 0, 0})
  |> Map.put(:refined_cells, FixtureGen.cells())
  |> Storage.normalize!()

snapshot = SceneServer.Voxel.Codec.encode_chunk_snapshot_payload(storage)

# Snapshot wire layout (see Codec.encode_chunk_snapshot_payload/1):
#   request_id u64
#   logical_scene_id u64
#   chunk_coord i32 x3
#   schema_version u16
#   chunk_size_in_macro u8
#   micro_resolution u8
#   chunk_version u64
#   chunk_hash u64
#   section_count u16
#   sections [{ section_type u8, section_len u32, data binary }, ...]
header_bytes = 8 + 8 + 12 + 2 + 1 + 1 + 8 + 8 + 2

defmodule SectionScan do
  def find!(<<>>, _target), do: raise("section not found")

  def find!(
        <<section_type::unsigned-integer-size(8), section_len::unsigned-big-integer-size(32),
          data::binary-size(section_len), rest::binary>>,
        target
      ) do
    if section_type == target do
      data
    else
      find!(rest, target)
    end
  end
end

<<_::binary-size(^header_bytes), sections_blob::binary>> = snapshot
section_payload = SectionScan.find!(sections_blob, 0x03)

elixir_path = "test/fixtures/voxel/refined_512_cell_v1.bin"
ts_path = Path.expand("../../clients/web_client/test/fixtures/voxel/refined_512_cell_v1.bin")

File.mkdir_p!(Path.dirname(elixir_path))
File.mkdir_p!(Path.dirname(ts_path))
File.write!(elixir_path, section_payload)
File.write!(ts_path, section_payload)

IO.puts("wrote #{byte_size(section_payload)} bytes:")
IO.puts("  #{Path.expand(elixir_path)}")
IO.puts("  #{ts_path}")
