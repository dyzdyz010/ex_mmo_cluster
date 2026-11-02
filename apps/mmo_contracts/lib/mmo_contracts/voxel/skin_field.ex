defmodule MmoContracts.Voxel.SkinField do
  @moduledoc """
  全局系统功能：已接纳且规范化的不可变表皮 CSR。各平面与贴图池共同拥有表皮真值；
  bases 是同一构造入口生成的查找索引。没有展开 map 或原始正文的第二副本。
  """
  import Bitwise
  defstruct [:rows, :xs, :faces, :masks, :bases, :fmi, :maps, :map_extent, :count]
  @opaque t :: %__MODULE__{}

  @doc "结构校验后的 CSR 检查规范形；非规范合法数据交唯一编码器规范化。"
  def admit(ext, rows, xs, faces, masks, fmi, maps) do
    n = div(byte_size(masks), 2)
    if canonical?(ext, faces, masks, fmi, maps, n),
      do: {:ok, canonical(ext, rows, xs, faces, masks, fmi, maps)}, else: :noncanonical
  end

  @doc false
  def canonical(ext, rows, xs, faces, masks, fmi, maps) do
    {bases, _} = for <<mask::16-little <- masks>>, reduce: {[], 0} do
      {acc, base} -> {[<<base::32-little>> | acc], base + popcount(mask)}
    end
    %__MODULE__{rows: rows, xs: xs, faces: faces, masks: masks,
      bases: IO.iodata_to_binary(Enum.reverse(bases)), fmi: fmi, maps: maps,
      map_extent: ext, count: div(byte_size(masks), 2)}
  end

  # 规范池每个条目唯一、都被使用且按首次使用排列；均匀贴图必须已收拢为面材质。
  defp canonical?(ext, _faces, <<>>, <<>>, <<>>, 0), do: ext == 1
  defp canonical?(ext, faces, masks, fmi, maps, n) do
    size = ext * ext
    textures = for <<texture::binary-size(size) <- maps>>, do: texture
    unique = MapSet.new(textures)
    if MapSet.size(unique) == length(textures) do
      uniforms = List.to_tuple(Enum.map(textures, fn t ->
        id = :binary.at(t, 0)
        if t == :binary.copy(<<id>>, size), do: id, else: :nonuniform
      end))
      canonical_records(masks, fmi, faces, n, 0, uniforms, 0) == tuple_size(uniforms)
    else
      false
    end
  end

  defp canonical_records(<<>>, <<>>, _faces, _n, _i, _uniforms, next), do: next
  defp canonical_records(<<mask::16-little, rest::binary>>, fmi, faces, n, i, uniforms, next) do
    case canonical_faces(mask, 0, fmi, faces, n, i, uniforms, next) do
      {fmi, next} -> canonical_records(rest, fmi, faces, n, i + 1, uniforms, next)
      :noncanonical -> :noncanonical
    end
  end

  defp canonical_faces(0, _face, fmi, _faces, _n, _i, _uniforms, next), do: {fmi, next}
  defp canonical_faces(mask, face, fmi, faces, n, i, uniforms, next) when (mask &&& 1) == 0,
    do: canonical_faces(mask >>> 1, face + 1, fmi, faces, n, i, uniforms, next)
  defp canonical_faces(mask, face, <<index::16-little, fmi::binary>>, faces, n, i, uniforms, next) do
    if index > next or elem(uniforms, index) == :binary.at(faces, face * n + i), do: :noncanonical,
      else: canonical_faces(mask >>> 1, face + 1, fmi, faces, n, i, uniforms, max(next, index + 1))
  end

  @doc "规范 CSR 线格式；只引用已经接纳的平面，不展开逐格记录。"
  def encode(%__MODULE__{} = s) do
    extent = if s.count == 0, do: 0, else: 66
    [<<extent::32-little, extent::32-little, extent::32-little, s.map_extent::32-little>>,
      <<div(byte_size(s.rows), 4)::32-little>>, s.rows,
      <<s.count::32-little>>, s.xs, <<s.count::32-little>>, s.faces, s.masks,
      <<div(byte_size(s.fmi), 2)::32-little>>, s.fmi, <<byte_size(s.maps)::32-little>>, s.maps]
  end

  @doc "局部格查找；在最多 66 条的已排序行内查找，不分配全域索引。"
  def fetch(%__MODULE__{} = s, local) do
    case position(s, local) do
      :error -> :error
      {:ok, i} -> {:ok, record(s, i)}
    end
  end

  @doc "只查有无记录，不读取六面或构造记录值。"
  def member?(%__MODULE__{} = s, local), do: position(s, local) != :error

  defp position(%__MODULE__{count: 0}, _local), do: :error
  defp position(%__MODULE__{} = s, {x, y, z}) do
    row = y + 66 * z
    <<first::32-little, last::32-little>> = binary_part(s.rows, row * 4, 8)
    find(s, x, first, last)
  end
  defp find(_s, _x, first, last) when first == last, do: :error
  defp find(s, x, first, last) do
    mid = div(first + last, 2)
    <<v::16-little>> = binary_part(s.xs, mid * 2, 2)
    cond do
      x == v -> {:ok, mid}
      x < v -> find(s, x, first, mid)
      true -> find(s, x, mid + 1, last)
    end
  end

  defp record(s, i) do
    ids = for face <- 0..5, reduce: 0 do
      ids -> ids ||| :binary.at(s.faces, face * s.count + i) <<< (face * 8)
    end
    <<mask::16-little>> = binary_part(s.masks, i * 2, 2)
    <<base::32-little>> = binary_part(s.bases, i * 4, 4)
    {ids, mask, base}
  end

  @doc "旧持久格式投影／稀疏改写时展开；不会作为第二份常驻真值保留。"
  def to_map(%__MODULE__{count: 0}), do: %{}
  def to_map(%__MODULE__{} = s) do
    for row <- 0..4355, reduce: %{} do
      acc ->
        <<first::32-little, last::32-little>> = binary_part(s.rows, row * 4, 8)
        if first == last, do: acc, else:
          Enum.reduce(first..(last - 1), acc, fn i, acc ->
            <<x::16-little>> = binary_part(s.xs, i * 2, 2)
            Map.put(acc, {x, rem(row, 66), div(row, 66)}, record(s, i))
          end)
    end
  end

  defp popcount(0), do: 0
  defp popcount(n), do: (n &&& 1) + popcount(n >>> 1)
end
