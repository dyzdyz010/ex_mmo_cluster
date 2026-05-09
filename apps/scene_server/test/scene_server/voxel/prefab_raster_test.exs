defmodule SceneServer.Voxel.PrefabRasterTest do
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.BlueprintCatalog
  alias SceneServer.Voxel.PrefabRaster
  alias SceneServer.Voxel.Types

  @micro Types.micro_resolution()
  @blueprint_version BlueprintCatalog.blueprint_version()

  test "rasterizes the sphere blueprint at the world origin" do
    assert {:ok, cells} = PrefabRaster.rasterize(1, @blueprint_version, {0, 0, 0}, 0)

    expected_count = BlueprintCatalog.slot_count(1)
    assert length(cells) == expected_count
    assert expected_count > 0

    Enum.each(cells, fn cell ->
      assert cell.chunk_coord == {0, 0, 0}
      assert cell.local_macro == {0, 0, 0}
      assert cell.layer_attrs == %{material_id: 4, health: 100}
      assert cell.micro_slot in 0..(@micro * @micro * @micro - 1)
    end)
  end

  test "rasterizes cylinder + stairs with their own material ids" do
    assert {:ok, cylinder_cells} = PrefabRaster.rasterize(2, @blueprint_version, {0, 0, 0}, 0)
    assert length(cylinder_cells) == BlueprintCatalog.slot_count(2)
    Enum.each(cylinder_cells, fn cell -> assert cell.layer_attrs.material_id == 2 end)

    assert {:ok, stairs_cells} = PrefabRaster.rasterize(3, @blueprint_version, {0, 0, 0}, 0)
    assert length(stairs_cells) == BlueprintCatalog.slot_count(3)
    Enum.each(stairs_cells, fn cell -> assert cell.layer_attrs.material_id == 3 end)
  end

  test "anchor world-micro is floor-divided to a single target macro" do
    # world_macro = (1, 2, 3); anchor in world-micro = (8, 16, 24).
    assert {:ok, cells} =
             PrefabRaster.rasterize(1, @blueprint_version, {@micro, 2 * @micro, 3 * @micro}, 0)

    Enum.each(cells, fn cell ->
      assert cell.chunk_coord == {0, 0, 0}
      assert cell.local_macro == {1, 2, 3}
    end)
  end

  test "anchor that lands on chunk boundary keeps the macro inside the new chunk" do
    # world_macro (16, 0, 0) is the first cell of chunk (1, 0, 0) at local (0, 0, 0).
    anchor_micro = {16 * @micro, 0, 0}

    assert {:ok, cells} = PrefabRaster.rasterize(1, @blueprint_version, anchor_micro, 0)

    Enum.each(cells, fn cell ->
      assert cell.chunk_coord == {1, 0, 0}
      assert cell.local_macro == {0, 0, 0}
    end)
  end

  test "negative world-micro anchors floor toward minus infinity (Euclidean local)" do
    # world-micro -1 → world-macro -1 → chunk -1, local 15.
    assert {:ok, cells} = PrefabRaster.rasterize(1, @blueprint_version, {-1, -1, -1}, 0)

    Enum.each(cells, fn cell ->
      assert cell.chunk_coord == {-1, -1, -1}
      assert cell.local_macro == {15, 15, 15}
    end)
  end

  test "rejects unsupported rotation in v2" do
    assert {:error, :unsupported_rotation} =
             PrefabRaster.rasterize(1, @blueprint_version, {0, 0, 0}, 1)

    assert {:error, :unsupported_rotation} =
             PrefabRaster.rasterize(1, @blueprint_version, {0, 0, 0}, 90)

    assert {:error, :unsupported_rotation} =
             PrefabRaster.rasterize(1, @blueprint_version, {0, 0, 0}, 0xFF)
  end

  test "rejects unknown blueprints and v1 (legacy macro) blueprint version" do
    assert {:error, :unknown_blueprint} =
             PrefabRaster.rasterize(999, @blueprint_version, {0, 0, 0}, 0)

    # v1 used to be the macro-list catalog (pillar / floor / cube). Phase A1
    # bumped to v2 (micro-mask) without backcompat, so v1 wire payloads must
    # be rejected so the dispatch path can assume v2 layout.
    assert {:error, :blueprint_version_mismatch} =
             PrefabRaster.rasterize(1, 1, {0, 0, 0}, 0)
  end

  test "rejects malformed anchors" do
    assert {:error, :invalid_anchor_world_micro} =
             PrefabRaster.rasterize(1, @blueprint_version, {1.0, 2.0, 3.0}, 0)

    assert {:error, :invalid_anchor_world_micro} =
             PrefabRaster.rasterize(1, @blueprint_version, [0, 0, 0], 0)
  end

  test "group_by_chunk returns an empty map for an empty cell list" do
    assert PrefabRaster.group_by_chunk([]) == %{}
  end

  test "group_by_chunk groups single-macro v2 prefabs into one chunk key" do
    {:ok, cells} = PrefabRaster.rasterize(2, @blueprint_version, {0, 0, 0}, 0)
    assert PrefabRaster.group_by_chunk(cells) == %{{0, 0, 0} => cells}
  end

  describe "BlueprintCatalog v2 invariants" do
    test "all v2 blueprints have non-empty occupancy and respect 0..511 slot range" do
      Enum.each(BlueprintCatalog.all(), fn blueprint ->
        assert blueprint.version == @blueprint_version
        assert is_list(blueprint.occupied_slots)
        assert blueprint.occupied_slots != []

        Enum.each(blueprint.occupied_slots, fn slot ->
          assert is_integer(slot)
          assert slot in 0..(@micro * @micro * @micro - 1)
        end)
      end)
    end

    test "stairs blueprint follows y ≤ x rule for all occupied slots" do
      {:ok, stairs} = BlueprintCatalog.fetch(3, @blueprint_version)

      Enum.each(stairs.occupied_slots, fn slot ->
        x = rem(slot, @micro)
        y = div(rem(slot, @micro * @micro), @micro)
        assert y <= x, "stairs slot #{slot} → (#{x}, #{y}) violates y ≤ x"
      end)

      # Conversely every (x, y, z) with y ≤ x must be present.
      for x <- 0..(@micro - 1), y <- 0..x, z <- 0..(@micro - 1) do
        slot = x + y * @micro + z * @micro * @micro
        assert slot in stairs.occupied_slots
      end
    end

    test "occupancy_words round-trips slot list to 8 × u64 words" do
      {:ok, sphere} = BlueprintCatalog.fetch(1, @blueprint_version)
      words = BlueprintCatalog.occupancy_words(sphere)

      assert length(words) == 8

      total_bits =
        Enum.reduce(words, 0, fn word, acc ->
          acc + popcount(word)
        end)

      assert total_bits == length(sphere.occupied_slots)
    end
  end

  defp popcount(word) when is_integer(word) and word >= 0 do
    do_popcount(word, 0)
  end

  defp do_popcount(0, acc), do: acc
  defp do_popcount(n, acc), do: do_popcount(Bitwise.band(n, n - 1), acc + 1)
end
