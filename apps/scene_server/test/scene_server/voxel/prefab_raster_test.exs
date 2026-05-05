defmodule SceneServer.Voxel.PrefabRasterTest do
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.PrefabRaster
  alias SceneServer.Voxel.Types

  @micro Types.micro_resolution()

  test "rasterizes the pillar blueprint at the world origin" do
    assert {:ok, cells} = PrefabRaster.rasterize(1, 1, {0, 0, 0}, 0)

    assert length(cells) == 3

    assert Enum.map(cells, & &1.local_macro) == [{0, 0, 0}, {0, 0, 1}, {0, 0, 2}]

    Enum.each(cells, fn cell ->
      assert cell.chunk_coord == {0, 0, 0}
      assert %NormalBlockData{material_id: 1, health: 100} = cell.block
    end)
  end

  test "anchor is interpreted as world-micro and converted with floor division" do
    # Anchor world-macro 1 = world-micro 8 (since micro = 8)
    assert {:ok, cells} = PrefabRaster.rasterize(1, 1, {@micro, 2 * @micro, 3 * @micro}, 0)

    assert length(cells) == 3
    # Pillar grows along z. anchor world_macro = (1, 2, 3); cells (1,2,3),(1,2,4),(1,2,5).
    locals = Enum.map(cells, & &1.local_macro)
    assert locals == [{1, 2, 3}, {1, 2, 4}, {1, 2, 5}]

    Enum.each(cells, fn cell -> assert cell.chunk_coord == {0, 0, 0} end)
  end

  test "anchors that span chunk boundaries assign each cell to its proper chunk" do
    # Pillar starting at world-macro (15, 0, 0) spans chunk_coord (0,0,0) only on z (vertical).
    # We instead use the floor blueprint (3x3 at z=0) anchored so it crosses x=15..17,
    # which spills the x=16, x=17 cells into chunk (1, 0, 0).
    anchor_micro = {15 * @micro, 0, 0}

    assert {:ok, cells} = PrefabRaster.rasterize(2, 1, anchor_micro, 0)
    assert length(cells) == 9

    by_chunk = PrefabRaster.group_by_chunk(cells)
    assert Map.has_key?(by_chunk, {0, 0, 0})
    assert Map.has_key?(by_chunk, {1, 0, 0})

    # 3 columns of 3 cells stay in chunk (0,0,0): the x=15 column.
    assert by_chunk |> Map.fetch!({0, 0, 0}) |> length() == 3

    # The other 6 cells (x=16, x=17) end up in chunk (1,0,0) at local x ∈ {0,1}.
    {chunk_one, chunk_two} = {Map.fetch!(by_chunk, {0, 0, 0}), Map.fetch!(by_chunk, {1, 0, 0})}
    assert length(chunk_two) == 6

    Enum.each(chunk_one, fn %{local_macro: {lx, _, lz}} ->
      assert lx == 15
      assert lz == 0
    end)

    Enum.each(chunk_two, fn %{local_macro: {lx, _, lz}} ->
      assert lx in [0, 1]
      assert lz == 0
    end)
  end

  test "negative world-micro anchors floor toward minus infinity (Euclidean local)" do
    # Anchor world-micro = -1 → world-macro = -1 → chunk = -1, local = 15.
    assert {:ok, cells} = PrefabRaster.rasterize(1, 1, {-1, -1, -1}, 0)
    assert length(cells) == 3

    [{cc1, lm1, _}, {cc2, lm2, _}, {cc3, lm3, _}] =
      Enum.map(cells, fn cell ->
        {cell.chunk_coord, cell.local_macro, cell.block}
      end)

    assert cc1 == {-1, -1, -1}
    assert lm1 == {15, 15, 15}

    # z+1 from world-macro -1 is 0 -> chunk (-1, -1, 0), local (15, 15, 0).
    assert cc2 == {-1, -1, 0}
    assert lm2 == {15, 15, 0}

    # z+2 from world-macro -1 is +1 -> chunk (-1, -1, 0), local (15, 15, 1).
    assert cc3 == {-1, -1, 0}
    assert lm3 == {15, 15, 1}
  end

  test "applies a single material per blueprint to every cell" do
    assert {:ok, cells} = PrefabRaster.rasterize(2, 1, {0, 0, 0}, 0)
    Enum.each(cells, fn cell -> assert cell.block.material_id == 2 end)

    assert {:ok, cells} = PrefabRaster.rasterize(3, 1, {0, 0, 0}, 0)
    Enum.each(cells, fn cell -> assert cell.block.material_id == 3 end)
  end

  test "rejects unsupported rotation in v1" do
    assert {:error, :unsupported_rotation} = PrefabRaster.rasterize(1, 1, {0, 0, 0}, 1)
    assert {:error, :unsupported_rotation} = PrefabRaster.rasterize(1, 1, {0, 0, 0}, 90)
    assert {:error, :unsupported_rotation} = PrefabRaster.rasterize(1, 1, {0, 0, 0}, 0xFF)
  end

  test "rejects unknown blueprints and version mismatches" do
    assert {:error, :unknown_blueprint} = PrefabRaster.rasterize(999, 1, {0, 0, 0}, 0)
    assert {:error, :blueprint_version_mismatch} = PrefabRaster.rasterize(1, 2, {0, 0, 0}, 0)
  end

  test "rejects malformed anchors" do
    assert {:error, :invalid_anchor_world_micro} =
             PrefabRaster.rasterize(1, 1, {1.0, 2.0, 3.0}, 0)

    assert {:error, :invalid_anchor_world_micro} =
             PrefabRaster.rasterize(1, 1, [0, 0, 0], 0)
  end

  test "group_by_chunk returns an empty map for an empty cell list" do
    assert PrefabRaster.group_by_chunk([]) == %{}
  end
end
