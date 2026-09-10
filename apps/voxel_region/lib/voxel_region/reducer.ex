defmodule VoxelRegion.Reducer do
  @moduledoc """
  Voxim `ReduceBlockV1` / `ReduceSkinsV1` 的逐 bit 移植（`Voxim/Source/Voxim/Voxel/Lod/VoxelLodReduce.cpp`，决策稿 §2.3）。

  值的表示：
  - 材质：0..255 的整数，0 = 空气
  - 表皮 `{ext, faces}`：`ext` = 贴图边长（1 / 2 / 4），`faces` 是 6 元组 `{id, texels}`，`texels` 是 `ext²` 字节的 binary
    （按 `v * ext + u`）或 `nil`（整面均匀 = id）。ext == 1 时 texels 恒为 nil。
  - 面序 = Voxim `EVoxelFace`：0 −X、1 +X、2 −Y、3 +Y、4 −Z、5 +Z（face / 2 = 轴，face & 1 = 正向）。
  - 子格八元组按 octant = x + 2y + 4z。

  跨端相等由 `VoxelRegion.ReducerTest` 用 Voxim 烘焙文件做 golden：L1 文件 == 8 个 L0 文件的 reduce，逐格含表皮。
  """

  import Bitwise

  @max_extent 4

  @doc "level-L 的表皮贴图边长 = min(2^L, 4)。"
  def skin_extent(level) when level >= 0, do: min(1 <<< level, @max_extent)

  @doc "非零众数，平局最小 id，全零 → 0（`VoxelMaterialMode`）。"
  def mode(ids) when is_list(ids) do
    ids
    |> Enum.reject(&(&1 == 0))
    |> Enum.frequencies()
    |> Enum.reduce({0, 0}, fn {id, votes}, {best, best_votes} ->
      if votes > best_votes or (votes == best_votes and id < best), do: {id, votes}, else: {best, best_votes}
    end)
    |> elem(0)
  end

  def mode(bin) when is_binary(bin), do: mode(:binary.bin_to_list(bin))

  @doc "占用：solid child ≥ 5 才 solid；材质 = solid children 的众数（`ReduceBlockV1`）。"
  def reduce_material(children) when length(children) == 8 do
    if Enum.count(children, &(&1 != 0)) < 5, do: 0, else: mode(children)
  end

  @doc "一个面在 (i, j) 的 texel（`FVoxelCellSkins::Texel`）。"
  def texel({1, faces}, face, _i, _j), do: elem(elem(faces, face), 0)

  def texel({ext, faces}, face, i, j) do
    case elem(faces, face) do
      {id, nil} -> id
      {_id, texels} -> :binary.at(texels, j * ext + i)
    end
  end

  @doc "整面是否每个 texel 都等于 id。"
  def face_uniform?({_ext, faces}, face) do
    case elem(faces, face) do
      {_id, nil} -> true
      {id, texels} -> texels == :binary.copy(<<id>>, byte_size(texels))
    end
  end

  @doc "`ReduceSkinsV1(children, level)`：8 个子格（level−1）的表皮 → 父格（level）的表皮，返回规范形。"
  def reduce_skins(children, level) when length(children) == 8 and level >= 1 do
    child_ext = skin_extent(level - 1)
    out_ext = skin_extent(level)
    kids = List.to_tuple(children)
    all_uniform = Enum.all?(children, fn {ext, _} -> ext == 1 end)

    faces =
      for face <- 0..5 do
        axis = div(face, 2)
        outer_bit = face &&& 1
        u = rem(axis + 1, 3)
        v = rem(axis + 2, 3)
        outer_octants = for oct <- 0..7, ((oct >>> axis) &&& 1) == outer_bit, do: oct

        if all_uniform do
          # 快路径：列值 = 外层 id ?: 内层 id，2×2 列放大成 out_ext×out_ext。
          columns =
            Enum.reduce(outer_octants, %{}, fn oct, acc ->
              outer = texel(elem(kids, oct), face, 0, 0)
              inner = texel(elem(kids, bxor(oct, 1 <<< axis)), face, 0, 0)
              Map.put(acc, ((oct >>> v) &&& 1) * 2 + ((oct >>> u) &&& 1), if(outer != 0, do: outer, else: inner))
            end)

          c = for k <- 0..3, do: Map.fetch!(columns, k)
          id = mode(c)

          if Enum.all?(c, &(&1 == hd(c))) do
            {id, nil}
          else
            half = div(out_ext, 2)
            texels = for j <- 0..(out_ext - 1), i <- 0..(out_ext - 1), into: <<>>, do: <<Enum.at(c, div(j, half) * 2 + div(i, half))>>
            {id, texels}
          end
        else
          combined = 2 * child_ext

          merged =
            Enum.reduce(outer_octants, %{}, fn oct, acc ->
              outer = elem(kids, oct)
              inner = elem(kids, bxor(oct, 1 <<< axis))
              cu = (oct >>> u) &&& 1
              cv = (oct >>> v) &&& 1

              Enum.reduce(0..(child_ext - 1), acc, fn j, acc ->
                Enum.reduce(0..(child_ext - 1), acc, fn i, acc ->
                  t = texel(outer, face, i, j)
                  t = if t != 0, do: t, else: texel(inner, face, i, j)
                  Map.put(acc, {cu * child_ext + i, cv * child_ext + j}, t)
                end)
              end)
            end)

            texels =
              if combined == out_ext do
                for j <- 0..(out_ext - 1), i <- 0..(out_ext - 1), into: <<>>, do: <<Map.fetch!(merged, {i, j})>>
              else
                for j <- 0..(out_ext - 1), i <- 0..(out_ext - 1), into: <<>> do
                  block = [Map.fetch!(merged, {2 * i, 2 * j}), Map.fetch!(merged, {2 * i + 1, 2 * j}), Map.fetch!(merged, {2 * i, 2 * j + 1}), Map.fetch!(merged, {2 * i + 1, 2 * j + 1})]
                  <<mode(block)>>
                end
              end

          {mode(texels), texels}
        end
      end

    MmoContracts.Voxel.Skins.canonical({out_ext, List.to_tuple(faces)})
  end

  @doc "`ReduceCellV1`：材质 + 表皮。"
  def reduce_cell(children, level) do
    {reduce_material(Enum.map(children, fn {m, _s} -> m end)), reduce_skins(Enum.map(children, fn {_m, s} -> s end), level)}
  end
end
