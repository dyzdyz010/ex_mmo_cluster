# Run from umbrella root with:
#   cd apps/gate_server && mix run priv/scripts/gen_voxel_edit_intent_fixture.exs
# (or from umbrella root: mix run apps/gate_server/priv/scripts/gen_voxel_edit_intent_fixture.exs)
#
# Generates the Phase 1b shared fixture `voxel_edit_intent_v1.bin` and writes
# it to:
#   * apps/gate_server/test/fixtures/voxel/voxel_edit_intent_v1.bin
#   * clients/web_client/test/fixtures/voxel/voxel_edit_intent_v1.bin
#
# Both Elixir Codec and TypeScript encodeVoxelEditIntent must produce identical
# bytes. Two intents are concatenated (back-to-back, including their opcode
# prefixes), covering:
#   * intent A: macro-level Place with material_id, no concurrency constraints
#   * intent B: object-part Break with expected_chunk_version + expected_cell_hash
#
# This shape matches how a stream of edit intents would arrive over the wire.

alias GateServer.Codec

defmodule FixtureGen do
  alias GateServer.Codec

  def intents do
    [intent_a(), intent_b()]
  end

  defp intent_a do
    %{
      request_id: 0x0000_0000_0000_00A1,
      client_intent_seq: 1,
      logical_scene_id: 0x0000_0000_0000_002A,
      # Place
      action: 0,
      # Macro
      target_granularity: 0,
      target_world_micro: {16, 0, 32},
      face_normal: {0, 1, 0},
      material_id: 17,
      blueprint_ref: 0,
      object_ref: 0,
      part_ref: 0,
      attribute_patch_ref: 0,
      expected_chunk_version: 0xFFFF_FFFF_FFFF_FFFF,
      expected_cell_hash: 0xFFFF_FFFF,
      client_hint_hash: 0
    }
  end

  defp intent_b do
    %{
      request_id: 0x0000_0000_0000_00B2,
      client_intent_seq: 2,
      logical_scene_id: 0x0000_0000_0000_002A,
      # Break
      action: 1,
      # ObjectPart
      target_granularity: 2,
      target_world_micro: {-100, 0, 100},
      face_normal: {1, 0, -1},
      material_id: 0,
      blueprint_ref: 0,
      object_ref: 0x0000_0000_DEAD_BEEF,
      part_ref: 7,
      attribute_patch_ref: 0,
      expected_chunk_version: 0x0000_0000_0000_0123,
      expected_cell_hash: 0xCAFE_BABE,
      client_hint_hash: 0xFFFF_EEEE_DDDD_CCCC
    }
  end
end

bytes =
  FixtureGen.intents()
  |> Enum.map(fn intent ->
    {:ok, iodata} = Codec.encode({:voxel_edit_intent, intent})
    IO.iodata_to_binary(iodata)
  end)
  |> IO.iodata_to_binary()

script_dir = Path.dirname(__ENV__.file)
gate_server_root = Path.expand("../..", script_dir)
umbrella_root = Path.expand("../../../..", script_dir)

elixir_path =
  Path.join(gate_server_root, "test/fixtures/voxel/voxel_edit_intent_v1.bin")

ts_path =
  Path.join(
    umbrella_root,
    "clients/web_client/test/fixtures/voxel/voxel_edit_intent_v1.bin"
  )

File.mkdir_p!(Path.dirname(elixir_path))
File.mkdir_p!(Path.dirname(ts_path))
File.write!(elixir_path, bytes)
File.write!(ts_path, bytes)

IO.puts("wrote #{byte_size(bytes)} bytes:")
IO.puts("  #{Path.expand(elixir_path)}")
IO.puts("  #{ts_path}")
