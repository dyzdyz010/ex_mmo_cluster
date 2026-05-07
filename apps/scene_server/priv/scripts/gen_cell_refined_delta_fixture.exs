# Run from umbrella root with:
#   mix run apps/scene_server/priv/scripts/gen_cell_refined_delta_fixture.exs
#
# Generates the Phase 1c-3 shared fixture `cell_refined_delta_v1.bin` and
# writes it to:
#   * apps/scene_server/test/fixtures/voxel/cell_refined_delta_v1.bin
#   * clients/web_client/test/fixtures/voxel/cell_refined_delta_v1.bin
#
# The fixture is a single RefinedCellData encoded as a standalone payload
# (no count u32 prefix) — this is the form used by ChunkDelta op payloads
# when delta_kind = 2 (CellRefined).

alias SceneServer.Voxel.Codec
alias SceneServer.Voxel.MicroLayer
alias SceneServer.Voxel.ObjectCoverRef
alias SceneServer.Voxel.RefinedCellData

defmodule FixtureGen do
  alias SceneServer.Voxel.MicroLayer
  alias SceneServer.Voxel.ObjectCoverRef
  alias SceneServer.Voxel.RefinedCellData

  def cell do
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
      boundary_cache: 0xCAFE_BABE_DEAD_BEEF,
      layers: [layer_a, layer_b],
      object_refs: [object_ref]
    )
  end
end

bytes = Codec.encode_refined_cell_payload(FixtureGen.cell())

script_dir = Path.dirname(__ENV__.file)
scene_server_root = Path.expand("../..", script_dir)
umbrella_root = Path.expand("../../../..", script_dir)

elixir_path =
  Path.join(scene_server_root, "test/fixtures/voxel/cell_refined_delta_v1.bin")

ts_path =
  Path.join(
    umbrella_root,
    "clients/web_client/test/fixtures/voxel/cell_refined_delta_v1.bin"
  )

File.mkdir_p!(Path.dirname(elixir_path))
File.mkdir_p!(Path.dirname(ts_path))
File.write!(elixir_path, bytes)
File.write!(ts_path, bytes)

IO.puts("wrote #{byte_size(bytes)} bytes:")
IO.puts("  #{Path.expand(elixir_path)}")
IO.puts("  #{ts_path}")
