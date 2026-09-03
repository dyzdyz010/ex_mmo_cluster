defmodule VoxelRegion.ReducerTest do
  @moduledoc """
  T-1 / T-2 golden：Voxim 烘焙文件本身就是 oracle——level-L 文件的每个 owned 格 == 它 8 个 level-(L−1) 子格（子文件）的
  `Reducer.reduce_cell`，材质与表皮逐格相等（R5-A `RecursiveAndSourcePathsFollowChosenOracle` 的服务端版）。
  需要 `VOXEL_REGION_ROOT`（默认 Voxim/WorldBake）里同时烘了两级；没有就跳过。
  """
  use ExUnit.Case, async: true

  alias VoxelRegion.{FileStore, Payload, Reducer}

  @root System.get_env("VOXEL_REGION_ROOT", Path.expand("../../../../Voxim/WorldBake", __DIR__))

  defp load(cv, level, region) do
    case FileStore.read(@root, cv, level, region) do
      {:ok, bytes, _} ->
        {:ok, p} = Payload.decode(bytes)
        p

      _ ->
        nil
    end
  end

  # 找一个 level-L region，它的 8 个子 region 文件都在。
  defp find_parent(cv, level) do
    dir = Path.join([@root, FileStore.hex(cv), "L#{level}"])

    with {:ok, files} <- File.ls(dir) do
      files
      |> Enum.map(fn f -> Regex.run(~r/^r_(-?\d+)_(-?\d+)_(-?\d+)\.vxr$/, f) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.map(fn [_, x, y, z] -> {String.to_integer(x), String.to_integer(y), String.to_integer(z)} end)
      |> Enum.filter(fn {x, y, z} ->
        Enum.all?(for dx <- 0..1, dy <- 0..1, dz <- 0..1, do: File.exists?(FileStore.path(@root, cv, level - 1, {2 * x + dx, 2 * y + dy, 2 * z + dz})))
      end)
      # 要一个含地表的（表皮场非空），纯岩石 / 纯空气的 region 什么都测不到。
      |> Enum.find(fn region ->
        p = load(cv, level, region)
        p != nil and map_size(p.records) > 0
      end)
    end
  end

  defp check_level(level) do
    with {:ok, cv} <- FileStore.content_version(@root),
         {rx, ry, rz} = parent when parent != nil <- find_parent(cv, level) do
      coarse = load(cv, level, parent)
      children_files = for dz <- 0..1, dy <- 0..1, dx <- 0..1, into: %{}, do: {{2 * rx + dx, 2 * ry + dy, 2 * rz + dz}, load(cv, level - 1, {2 * rx + dx, 2 * ry + dy, 2 * rz + dz})}
      # owned 64³ 里取一个 24³ 子盒（含地表最可能的中间带），逐格比较。
      {ox, oy, oz} = Payload.origin(parent)
      mismatches =
        for lz <- 20..43, ly <- 20..43, lx <- 20..43, reduce: [] do
          acc ->
            cell = {ox + lx, oy + ly, oz + lz}
            expected = Payload.value(coarse, {lx, ly, lz})

            children =
              for oct <- 0..7 do
                {cx, cy, cz} = {elem(cell, 0) * 2 + Bitwise.band(oct, 1), elem(cell, 1) * 2 + Bitwise.band(Bitwise.bsr(oct, 1), 1), elem(cell, 2) * 2 + Bitwise.band(Bitwise.bsr(oct, 2), 1)}
                child_region = {Integer.floor_div(cx, 64), Integer.floor_div(cy, 64), Integer.floor_div(cz, 64)}
                Payload.value(Map.fetch!(children_files, child_region), Payload.local(child_region, {cx, cy, cz}))
              end

            got = Reducer.reduce_cell(children, level)
            if got == expected or length(acc) >= 5, do: acc, else: [{cell, expected, got} | acc]
        end

      assert mismatches == [], "L#{level} #{inspect(parent)}: #{inspect(mismatches, limit: 5, printable_limit: 200)}"
      {parent, coarse.map_extent}
    else
      _ -> :skip
    end
  end

  test "L1 file == reduce of 8 L0 files (uniform children, map extent 2)" do
    case check_level(1) do
      :skip -> IO.puts("skip: no baked L1 with all L0 children under #{@root}")
      {parent, ext} -> assert ext == 2, "L1 #{inspect(parent)}"
    end
  end

  test "L2 file == reduce of 8 L1 files (texel merge 2x2 -> 4x4)" do
    case check_level(2) do
      :skip -> IO.puts("skip: no baked L2 with all L1 children")
      {_, ext} -> assert ext == 4
    end
  end

  test "L3 file == reduce of 8 L2 files (8x8 mip -> 4x4)" do
    case check_level(3) do
      :skip -> IO.puts("skip: no baked L3 with all L2 children")
      {_, ext} -> assert ext == 4
    end
  end

  test "mode: non-zero majority, ties to the smallest id, all zero -> 0" do
    assert Reducer.mode([0, 0, 0]) == 0
    assert Reducer.mode([3, 1, 3, 1]) == 1
    assert Reducer.mode([2, 2, 7, 0]) == 2
    assert Reducer.reduce_material([1, 1, 1, 1, 0, 0, 0, 0]) == 0
    assert Reducer.reduce_material([1, 1, 1, 1, 2, 0, 0, 0]) == 1
  end
end
