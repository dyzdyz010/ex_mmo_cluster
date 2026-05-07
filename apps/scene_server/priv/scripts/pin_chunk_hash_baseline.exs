# Run with: cd apps/scene_server && mix run priv/scripts/pin_chunk_hash_baseline.exs
#
# Prints chunk_hash values for three baseline storages used by the
# Phase 1a codec regression suite. The numbers MUST be pinned into
# `test/scene_server/voxel/codec_test.exs` BEFORE Step 4 rewrites the
# refined_cells encoder. Any future change to these values is a wire
# break and must be reviewed explicitly.
#
# Baselines:
#   * empty   — bare empty chunk
#   * seed    — small starter platform (3x3 stone at y=0)
#   * mixed   — solid blocks + one environment summary

alias SceneServer.Voxel.Codec

defmodule BaselineFixtures do
  alias SceneServer.Voxel.MacroEnvironmentSummary
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.Storage

  def empty do
    Storage.empty(42, {-1, 0, 2}, chunk_version: 7)
  end

  def seed do
    base = Storage.empty(123, {0, 0, 0}, chunk_version: 9)
    block = NormalBlockData.new(11, health: 100)

    Enum.reduce(0..8, base, fn i, acc ->
      mx = rem(i, 3)
      mz = div(i, 3)

      Storage.put_solid_block(acc, {mx, 0, mz}, block,
        cell_version: 1,
        cell_hash: 0xA000_0000 + i
      )
    end)
  end

  def mixed do
    seed_storage = seed()

    env =
      MacroEnvironmentSummary.new(
        default_temperature: 20,
        default_moisture: 40,
        current_temperature: 25,
        current_moisture: 38,
        field_mask: 0x000F,
        source_hash: 0xCAFE_BABE
      )

    %{seed_storage | environment_summaries: [env]}
    |> Storage.normalize!()
  end
end

IO.puts("# Pinned chunk_hash baselines (paste into codec_test.exs)")
IO.puts("")

empty_hash = Codec.chunk_hash(BaselineFixtures.empty())
seed_hash = Codec.chunk_hash(BaselineFixtures.seed())
mixed_hash = Codec.chunk_hash(BaselineFixtures.mixed())

IO.puts(
  "@empty_baseline_chunk_hash 0x#{Integer.to_string(empty_hash, 16) |> String.pad_leading(16, "0")}"
)

IO.puts(
  "@seed_baseline_chunk_hash  0x#{Integer.to_string(seed_hash, 16) |> String.pad_leading(16, "0")}"
)

IO.puts(
  "@mixed_baseline_chunk_hash 0x#{Integer.to_string(mixed_hash, 16) |> String.pad_leading(16, "0")}"
)
