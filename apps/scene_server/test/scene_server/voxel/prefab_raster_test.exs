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

  test "rasterizes prefab slots with object provenance when owner opts are provided" do
    assert {:ok, cells} =
             PrefabRaster.rasterize(3, @blueprint_version, {0, 0, 0}, 0,
               owner_object_id: 42,
               owner_part_id: 1
             )

    assert cells != []

    Enum.each(cells, fn cell ->
      assert cell.layer_attrs.owner_object_id == 42
      assert cell.layer_attrs.owner_part_id == 1
      assert cell.layer_attrs.material_id == 3
      assert cell.layer_attrs.health == 100
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

  test "rasterizes conductive wire and power terminal blueprints" do
    assert {:ok, wire_cells} = PrefabRaster.rasterize(4, @blueprint_version, {0, 0, 0}, 0)
    assert length(wire_cells) == 32
    Enum.each(wire_cells, fn cell -> assert cell.layer_attrs.material_id == 5 end)

    assert {:ok, junction_cells} = PrefabRaster.rasterize(5, @blueprint_version, {0, 0, 0}, 0)
    assert length(junction_cells) == 56
    Enum.each(junction_cells, fn cell -> assert cell.layer_attrs.material_id == 5 end)

    assert {:ok, terminal_cells} = PrefabRaster.rasterize(6, @blueprint_version, {0, 0, 0}, 0)
    assert length(terminal_cells) == 32
    Enum.each(terminal_cells, fn cell -> assert cell.layer_attrs.material_id == 6 end)
  end

  test "macro-aligned anchor preserves slot indices and lands on that one macro" do
    # world_macro = (1, 2, 3); anchor in world-micro = (8, 16, 24).
    assert {:ok, cells} =
             PrefabRaster.rasterize(1, @blueprint_version, {@micro, 2 * @micro, 3 * @micro}, 0)

    {:ok, blueprint} = BlueprintCatalog.fetch(1, @blueprint_version)
    expected_slots = MapSet.new(blueprint.occupied_slots)
    actual_slots = MapSet.new(Enum.map(cells, & &1.micro_slot))

    Enum.each(cells, fn cell ->
      assert cell.chunk_coord == {0, 0, 0}
      assert cell.local_macro == {1, 2, 3}
    end)

    assert actual_slots == expected_slots
  end

  test "macro-aligned anchor on a chunk boundary lands at local (0, 0, 0)" do
    # world_macro (16, 0, 0) is the first cell of chunk (1, 0, 0) at local (0, 0, 0).
    anchor_micro = {16 * @micro, 0, 0}

    assert {:ok, cells} = PrefabRaster.rasterize(1, @blueprint_version, anchor_micro, 0)

    Enum.each(cells, fn cell ->
      assert cell.chunk_coord == {1, 0, 0}
      assert cell.local_macro == {0, 0, 0}
    end)
  end

  test "mid-macro anchor splits cells across the two adjacent macros along X" do
    # anchor +4 in X within macro 0 → slots with lx ∈ 0..3 stay in macro (0,0,0)
    # at x = lx+4; slots with lx ∈ 4..7 spill into macro (1,0,0) at x = lx-4.
    anchor_micro = {4, 0, 0}
    assert {:ok, cells} = PrefabRaster.rasterize(1, @blueprint_version, anchor_micro, 0)

    {:ok, blueprint} = BlueprintCatalog.fetch(1, @blueprint_version)
    assert length(cells) == length(blueprint.occupied_slots)

    macros = cells |> Enum.map(& &1.local_macro) |> Enum.uniq() |> Enum.sort()
    assert {0, 0, 0} in macros
    assert {1, 0, 0} in macros

    Enum.each(cells, fn cell ->
      assert cell.chunk_coord == {0, 0, 0}
    end)

    # Round-trip every blueprint slot to its expected (macro, slot) destination.
    Enum.each(blueprint.occupied_slots, fn slot ->
      {lx, ly, lz} = decode_slot(slot)
      wx = 4 + lx
      wy = ly
      wz = lz
      expected_macro = {div(wx, @micro), div(wy, @micro), div(wz, @micro)}
      expected_local_micro = {rem(wx, @micro), rem(wy, @micro), rem(wz, @micro)}
      expected_slot = encode_slot(expected_local_micro)

      assert Enum.any?(cells, fn cell ->
               cell.local_macro == expected_macro and cell.micro_slot == expected_slot
             end),
             "slot #{slot} expected at macro #{inspect(expected_macro)} slot #{expected_slot}"
    end)
  end

  test "mid-macro anchor near a chunk boundary spans two chunks" do
    # macro (15, 0, 0) is the last macro of chunk (0,0,0) along X.
    # anchor world-micro = 15 * 8 + 4 = 124. Slots with lx ∈ 0..3 stay in
    # macro (15, 0, 0) (chunk 0); slots with lx ∈ 4..7 spill into macro
    # (16, 0, 0) (chunk 1, local (0, 0, 0)).
    anchor_micro = {15 * @micro + 4, 0, 0}
    assert {:ok, cells} = PrefabRaster.rasterize(1, @blueprint_version, anchor_micro, 0)

    by_chunk = Enum.group_by(cells, & &1.chunk_coord)
    assert Map.has_key?(by_chunk, {0, 0, 0})
    assert Map.has_key?(by_chunk, {1, 0, 0})

    Enum.each(Map.fetch!(by_chunk, {0, 0, 0}), fn cell ->
      assert cell.local_macro == {15, 0, 0}
    end)

    Enum.each(Map.fetch!(by_chunk, {1, 0, 0}), fn cell ->
      assert cell.local_macro == {0, 0, 0}
    end)
  end

  test "negative mid-macro anchor floors toward minus infinity per slot" do
    # anchor (-1, -1, -1) shifts every blueprint slot one micro toward -∞.
    # We don't pin which sphere slots actually occupy the corner regions
    # (the geometry is up to BlueprintCatalog); we instead round-trip every
    # occupied slot through the expected (chunk, local_macro, micro_slot)
    # mapping so the rasterizer is exercised across all four `floor_div(_, 8)`
    # quadrants the negative anchor produces.
    assert {:ok, cells} = PrefabRaster.rasterize(1, @blueprint_version, {-1, -1, -1}, 0)

    {:ok, blueprint} = BlueprintCatalog.fetch(1, @blueprint_version)
    assert length(cells) == length(blueprint.occupied_slots)

    cells_set =
      MapSet.new(cells, fn cell -> {cell.chunk_coord, cell.local_macro, cell.micro_slot} end)

    Enum.each(blueprint.occupied_slots, fn slot ->
      {lx, ly, lz} = decode_slot(slot)
      wx = -1 + lx
      wy = -1 + ly
      wz = -1 + lz
      expected_macro = {floor_div(wx, @micro), floor_div(wy, @micro), floor_div(wz, @micro)}
      expected_local_micro = {floor_mod(wx, @micro), floor_mod(wy, @micro), floor_mod(wz, @micro)}
      expected_slot = encode_slot(expected_local_micro)

      expected_chunk = {
        floor_div(elem(expected_macro, 0), 16),
        floor_div(elem(expected_macro, 1), 16),
        floor_div(elem(expected_macro, 2), 16)
      }

      expected_local_macro = {
        floor_mod(elem(expected_macro, 0), 16),
        floor_mod(elem(expected_macro, 1), 16),
        floor_mod(elem(expected_macro, 2), 16)
      }

      assert {expected_chunk, expected_local_macro, expected_slot} in cells_set,
             "slot #{slot} expected at chunk #{inspect(expected_chunk)} local_macro " <>
               "#{inspect(expected_local_macro)} slot #{expected_slot}"
    end)
  end

  test "rotates conductive prefab micro occupancy around the local Y axis" do
    assert {:ok, cells} = PrefabRaster.rasterize(4, @blueprint_version, {0, 0, 0}, 1)

    assert MapSet.new(Enum.map(cells, &decode_slot(&1.micro_slot))) ==
             MapSet.new(for x <- 3..4, y <- 3..4, z <- 0..7, do: {x, y, z})
  end

  test "rejects unsupported rotation outside quarter-turn enum values" do
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

  test "group_by_chunk groups macro-aligned v2 prefabs into one chunk key" do
    {:ok, cells} = PrefabRaster.rasterize(2, @blueprint_version, {0, 0, 0}, 0)
    assert PrefabRaster.group_by_chunk(cells) == %{{0, 0, 0} => cells}
  end

  test "group_by_chunk separates cells when the anchor straddles a chunk boundary" do
    # Same setup as the cross-chunk mid-macro test; assert the helper buckets
    # the cells into two distinct chunk keys for downstream per-chunk dispatch.
    anchor_micro = {15 * @micro + 4, 0, 0}
    {:ok, cells} = PrefabRaster.rasterize(1, @blueprint_version, anchor_micro, 0)

    grouped = PrefabRaster.group_by_chunk(cells)
    assert MapSet.new(Map.keys(grouped)) == MapSet.new([{0, 0, 0}, {1, 0, 0}])
    assert grouped |> Map.values() |> Enum.map(&length/1) |> Enum.sum() == length(cells)
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

    test "conductive prefab contacts expose the intended boundary faces" do
      {:ok, wire} = BlueprintCatalog.fetch(4, @blueprint_version)
      {:ok, junction} = BlueprintCatalog.fetch(5, @blueprint_version)
      {:ok, terminal} = BlueprintCatalog.fetch(6, @blueprint_version)

      assert MapSet.new(Enum.map(wire.occupied_slots, &decode_slot/1)) ==
               MapSet.new(for x <- 0..7, y <- 3..4, z <- 3..4, do: {x, y, z})

      assert {0, 3, 3} in Enum.map(junction.occupied_slots, &decode_slot/1)
      assert {7, 3, 3} in Enum.map(junction.occupied_slots, &decode_slot/1)
      assert {3, 3, 0} in Enum.map(junction.occupied_slots, &decode_slot/1)
      assert {3, 3, 7} in Enum.map(junction.occupied_slots, &decode_slot/1)
      assert terminal.occupied_slots == wire.occupied_slots
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

  defp floor_div(dividend, divisor)
       when is_integer(dividend) and is_integer(divisor) and divisor > 0 do
    q = div(dividend, divisor)
    r = rem(dividend, divisor)
    if r < 0, do: q - 1, else: q
  end

  defp floor_mod(dividend, divisor)
       when is_integer(dividend) and is_integer(divisor) and divisor > 0 do
    r = rem(dividend, divisor)
    if r < 0, do: r + divisor, else: r
  end

  defp decode_slot(slot) do
    z = div(slot, @micro * @micro)
    rem_after_z = rem(slot, @micro * @micro)
    y = div(rem_after_z, @micro)
    x = rem(rem_after_z, @micro)
    {x, y, z}
  end

  defp encode_slot({x, y, z}) do
    x + y * @micro + z * @micro * @micro
  end

  defp popcount(word) when is_integer(word) and word >= 0 do
    do_popcount(word, 0)
  end

  defp do_popcount(0, acc), do: acc
  defp do_popcount(n, acc), do: do_popcount(Bitwise.band(n, n - 1), acc + 1)
end
