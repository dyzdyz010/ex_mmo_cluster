defmodule VoxelRegion.CollisionMaterialTest do
  # 只测试：完整目录与宏格/微格占用投影的接缝。
  use ExUnit.Case, async: true
  alias MmoContracts.Voxel.Payload
  alias MmoContracts.VoxelMaterialCatalog, as: Catalog
  alias VoxelRegion.CollisionSource

  test "negative region and row boundaries preserve every catalog material's blocking" do
    ids = Catalog.table() |> Enum.map(& &1["id"]) |> List.to_tuple()
    n = Payload.extent()
    cells = for i <- 0..(n*n*n-1), into: <<>>, do: <<elem(ids, rem(i, tuple_size(ids)))::little-16>>
    p = %Payload{region: {-1, 2, -3}, cells: cells}
    for coord <- [{-4, 8, -12}, {-1, 11, -9}] do
      chunk = CollisionSource.capture(p, coord)
      {cx, cy, cz} = coord
      expected = for z <- 0..15, y <- 0..15, x <- 0..15, into: <<>> do
        material = Payload.material(p, Payload.local(p.region, {cx*16+x, cy*16+y, cz*16+z}))
        <<if(Catalog.blocks_movement?(material), do: 1, else: 0)>>
      end
      assert chunk.n == 16
      assert chunk.cells == expected
      assert CollisionSource.capture(coord, fn cell ->
        {Payload.material(p, Payload.local(p.region, cell)), %{}}
      end) == chunk
    end
  end

  test "refined slots use the same catalog, including air and nonblocking water" do
    slots = Map.new(Catalog.table(), fn %{"id" => id} -> {id, {id, {1, 0}}} end)
    p = %Payload{cells: :binary.copy(<<0, 0>>, Payload.extent()**3),
      refined: %{Payload.cell_index({1, 1, 1}) => slots}}
    chunk = CollisionSource.capture(p, {0, 0, 0})
    assert chunk.n == 128
    assert chunk.scale_m == 0.125
    assert byte_size(chunk.cells) == 128**3
    expected = for {%{"id" => id}, slot} <- Enum.with_index(Catalog.table()), into: %{} do
      {rem(slot, 8)+128*(rem(div(slot, 8), 8)+128*div(slot, 64)),
       if(Catalog.blocks_movement?(id), do: 1, else: 0)}
    end
    for {index, value} <- expected, do: assert(:binary.at(chunk.cells, index) == value)
    assert Enum.sum(:binary.bin_to_list(chunk.cells)) == Enum.sum(Map.values(expected))
  end
end
