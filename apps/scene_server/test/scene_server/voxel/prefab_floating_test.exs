defmodule SceneServer.Voxel.PrefabFloatingTest do
  @moduledoc """
  Unit tests for the pure prefab anti-floating predicate
  `ChunkProcess.prefab_floating?/2` (the `%Storage{}` clause).

  These exercise the policy directly against hand-built storage, with no chunk
  process / lease / persistence involved. The end-to-end gate path (rejecting a
  floating prefab with `:prefab_floating`, accepting one with a seeded neighbor)
  is covered in `apps/gate_server/test/gate_server/ws_connection_voxel_test.exs`.
  """
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.ChunkProcess
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.Types

  defp layer_attrs do
    %{material_id: 4, health: 100}
  end

  # Build the same prefab intent shape `tcp_connection.prefab_intents_for_chunk`
  # produces: %{macro: local_macro_coord, micro_slot: 0..511, ...}.
  defp intent(local_macro, micro_slot) do
    %{operation: :put_micro_block, macro: local_macro, micro_slot: micro_slot}
  end

  # Sphere micro slots inside one macro (matches BlueprintCatalog builtin_sphere).
  defp sphere_slots do
    for x <- 0..7,
        y <- 0..7,
        z <- 0..7,
        dx = x + 0.5 - 4.0,
        dy = y + 0.5 - 4.0,
        dz = z + 0.5 - 4.0,
        dx * dx + dy * dy + dz * dz <= (4.0 - 0.1) * (4.0 - 0.1) do
      Types.micro_index!({x, y, z})
    end
  end

  describe "prefab_floating?/2 — pure predicate" do
    test "prefab in a fully empty, interior chunk with no neighbor is floating" do
      storage = Storage.empty(1, {0, 0, 0})
      # Single micro slot at chunk-interior macro (8,8,8), micro center.
      intents = [intent({8, 8, 8}, Types.micro_index!({4, 4, 4}))]

      assert ChunkProcess.prefab_floating?(storage, intents)
    end

    test "interior sphere prefab with no neighbor is floating" do
      storage = Storage.empty(1, {0, 0, 0})
      intents = Enum.map(sphere_slots(), &intent({8, 8, 8}, &1))

      assert ChunkProcess.prefab_floating?(storage, intents)
    end

    test "a solid block directly below makes the sphere not floating" do
      # Sphere on macro (1,2,3); seed solid macro (1,1,3) directly below it so the
      # sphere's y=0 micro layer has a solid down-neighbor.
      storage =
        Storage.empty(1, {0, 0, 0})
        |> Storage.put_solid_block({1, 1, 3}, %{material_id: 2, health: 100})

      intents = Enum.map(sphere_slots(), &intent({1, 2, 3}, &1))

      refute ChunkProcess.prefab_floating?(storage, intents)
    end

    test "a refined occupied neighbor slot makes a single-cell prefab not floating" do
      # Seed one occupied micro slot adjacent (below) to the prefab cell.
      # Prefab cell: macro (8,8,8), micro (4,4,4) → chunk-local y = 8*8+4 = 68.
      # Down neighbor chunk-local y = 67 → macro y = 8 (since 67//8=8), micro y=3.
      neighbor_slot = Types.micro_index!({4, 3, 4})

      storage =
        Storage.empty(1, {0, 0, 0})
        |> Storage.put_micro_block({8, 8, 8}, neighbor_slot, layer_attrs())

      intents = [intent({8, 8, 8}, Types.micro_index!({4, 4, 4}))]

      refute ChunkProcess.prefab_floating?(storage, intents)
    end

    test "prefab self-adjacency does not count as support (still floating)" do
      # Two stacked micro cells in the same empty macro: each is the other's
      # neighbor, but both are own_cells → no external solid neighbor.
      storage = Storage.empty(1, {0, 0, 0})

      intents = [
        intent({8, 8, 8}, Types.micro_index!({4, 4, 4})),
        intent({8, 8, 8}, Types.micro_index!({4, 5, 4}))
      ]

      assert ChunkProcess.prefab_floating?(storage, intents)
    end

    test "a prefab touching a chunk boundary is leniently accepted (not floating)" do
      # Cell at chunk-local x = 0 (macro (0,*,*), micro x = 0): its -x neighbor is
      # off the chunk → any_out_of_chunk → never rejected even with no solid.
      storage = Storage.empty(1, {0, 0, 0})
      intents = [intent({0, 8, 8}, Types.micro_index!({0, 4, 4}))]

      refute ChunkProcess.prefab_floating?(storage, intents)
    end

    test "empty intent list is not floating" do
      storage = Storage.empty(1, {0, 0, 0})
      refute ChunkProcess.prefab_floating?(storage, [])
    end
  end
end
