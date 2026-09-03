defmodule VoxelRegion.Payload do
  @moduledoc """
  一个已解码的 region 载荷：66³ cells（binary，u16 LE，x 最快，原点 region × 64 − 1）+ 稀疏表皮场（Voxim `FVoxelSkinField` 的 CSR）。

  body 布局（Voxim `SerializeRegionBody`）：
  cells `<<n::32, u16 × n>>` · Extent i32×3 · MapExtent i32 · RowStart `<<n::32, i32 × n>>` · ColX `<<n::32, u16 × n>>` ·
  RecordCount i32 + Records × 20 B（Face[6] u16、MapMask u16、2 B 对齐填充、FaceMapBase u32）· FaceMapIndex `<<n::32, u16 × n>>` ·
  Maps `<<n::32, u8 × n>>` · MapHashes `<<n::32, u64 × n>>`。

  重编码时 MapHashes 写空（客户端加载后按 CityHash64 重算），其余逐字节按同一布局。
  """

  import Bitwise
  alias VoxelRegion.Reducer

  @extent 66
  @cell_count @extent * @extent * @extent

  defstruct level: 0, region: {0, 0, 0}, seq: 0, content_version: 0, cells: <<>>, map_extent: 1, records: %{}, fmi: <<>>, maps: <<>>

  def extent, do: @extent

  @doc "region 的 66³ 原点（level 单位）。"
  def origin({x, y, z}), do: {x * 64 - 1, y * 64 - 1, z * 64 - 1}

  def cell_index({lx, ly, lz}), do: lx + @extent * (ly + @extent * lz)

  def local(region, {cx, cy, cz}) do
    {ox, oy, oz} = origin(region)
    {cx - ox, cy - oy, cz - oz}
  end

  def in_span?({lx, ly, lz}), do: lx >= 0 and ly >= 0 and lz >= 0 and lx < @extent and ly < @extent and lz < @extent

  @doc "完整载荷字节 → struct。"
  def decode(bytes) do
    with {:ok, header, raw} <- VoxelRegion.Codec.decode_payload_body(bytes),
         {:ok, payload} <- decode_body(raw) do
      {:ok, %{payload | level: header.level, region: header.region, seq: header.seq, content_version: header.content_version}}
    end
  end

  def decode_body(<<n::32-little, cells::binary-size(n * 2), _ex::32-little, _ey::32-little, _ez::32-little, map_extent::32-little, rest::binary>>)
      when n == @cell_count do
    with {:ok, row_start, rest} <- array(rest, 4),
         {:ok, col_x, rest} <- array(rest, 2),
         <<record_count::32-little, records::binary-size(record_count * 20), rest::binary>> <- rest,
         {:ok, fmi, rest} <- array(rest, 2),
         {:ok, maps, rest} <- array(rest, 1),
         {:ok, _hashes, <<>>} <- array(rest, 8) do
      map_extent = max(map_extent, 1)
      {:ok, %__MODULE__{cells: cells, map_extent: map_extent, records: build_records(row_start, col_x, records), fmi: fmi, maps: maps}}
    else
      _ -> {:error, :invalid_payload}
    end
  end

  def decode_body(_), do: {:error, :invalid_payload}

  defp array(bin, size) do
    case bin do
      <<n::32-little, data::binary-size(n * size), rest::binary>> -> {:ok, data, rest}
      _ -> {:error, :invalid_payload}
    end
  end

  defp build_records(<<>>, _col_x, _records), do: %{}

  defp build_records(row_start, col_x, records) do
    rows = for <<v::32-little <- row_start>>, do: v
    xs = for <<v::16-little <- col_x>>, do: v
    xs = List.to_tuple(xs)

    rows
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {[first, last], row}, acc ->
      if first == last do
        acc
      else
        y = rem(row, @extent)
        z = div(row, @extent)

        Enum.reduce(first..(last - 1), acc, fn k, acc ->
          <<_::binary-size(k * 20), f0::16-little, f1::16-little, f2::16-little, f3::16-little, f4::16-little, f5::16-little, mask::16-little, _pad::16, base::32-little, _::binary>> = records
          Map.put(acc, {elem(xs, k), y, z}, {{f0, f1, f2, f3, f4, f5}, mask, base})
        end)
      end
    end)
  end

  @doc "local 格的材质。"
  def material(%__MODULE__{cells: cells}, local) do
    <<m::16-little>> = binary_part(cells, cell_index(local) * 2, 2)
    m
  end

  @doc "local 格的表皮（规范形）；没有记录 = 六面均匀 material。"
  def skins(%__MODULE__{} = p, local, material) do
    case Map.fetch(p.records, local) do
      :error ->
        Reducer.uniform(material)

      {:ok, {ids, mask, base}} ->
        ext = p.map_extent

        faces =
          for face <- 0..5 do
            id = elem(ids, face)
            bit = 1 <<< face

            if (mask &&& bit) != 0 do
              slot = base + popcount(mask &&& (bit - 1))
              <<index::16-little>> = binary_part(p.fmi, slot * 2, 2)
              {id, binary_part(p.maps, index * ext * ext, ext * ext)}
            else
              {id, nil}
            end
          end

        Reducer.canonical({ext, List.to_tuple(faces)})
    end
  end

  defp popcount(0), do: 0
  defp popcount(n), do: (n &&& 1) + popcount(n >>> 1)

  @doc "material + skins（规范形）。"
  def value(%__MODULE__{} = p, local) do
    m = material(p, local)
    {m, skins(p, local, m)}
  end

  @doc """
  按 overrides（local → {material, skins}）改写后重编码成完整载荷字节（seq 换成给定值）。
  表皮记录 = 原记录（去掉被覆盖的格）∪ overrides 里非平凡的格，按 (z, y, x) 升序写 CSR；贴图池按内容去重；MapHashes 写空。
  """
  def encode(%__MODULE__{} = p, overrides, seq, content_version) do
    cells = splice_cells(p.cells, overrides)
    ext = p.map_extent

    base_records =
      p.records
      |> Map.keys()
      |> Enum.reject(&Map.has_key?(overrides, &1))
      |> Map.new(fn local -> {local, skins(p, local, material(p, local))} end)

    override_records =
      overrides
      |> Enum.reject(fn {_, {m, s}} -> Reducer.trivial?(s, m) end)
      |> Map.new(fn {local, {_, s}} -> {local, s} end)

    records = Enum.sort_by(Map.merge(base_records, override_records), fn {{x, y, z}, _} -> {z, y, x} end)
    {row_start, col_x, recs, fmi, maps} = build_csr(records, ext)

    raw =
      IO.iodata_to_binary([
        <<@cell_count::32-little>>,
        cells,
        <<@extent::32-little, @extent::32-little, @extent::32-little, ext::32-little>>,
        <<length(row_start)::32-little>>,
        Enum.map(row_start, &<<&1::32-little>>),
        <<length(col_x)::32-little>>,
        Enum.map(col_x, &<<&1::16-little>>),
        <<length(recs)::32-little>>,
        recs,
        <<length(fmi)::32-little>>,
        Enum.map(fmi, &<<&1::16-little>>),
        <<byte_size(maps)::32-little>>,
        maps,
        <<0::32-little>>
      ])

    VoxelRegion.Codec.encode_payload(p.level, p.region, seq, content_version, raw)
  end

  defp splice_cells(cells, overrides) when map_size(overrides) == 0, do: cells

  defp splice_cells(cells, overrides) do
    {acc, pos} =
      overrides
      |> Enum.map(fn {local, {m, _}} -> {cell_index(local) * 2, m} end)
      |> Enum.sort()
      |> Enum.reduce({[], 0}, fn {idx, m}, {acc, pos} ->
        {[<<m::16-little>>, binary_part(cells, pos, idx - pos) | acc], idx + 2}
      end)

    IO.iodata_to_binary(Enum.reverse([binary_part(cells, pos, byte_size(cells) - pos) | acc]))
  end

  defp build_csr([], _ext), do: {[], [], [], [], <<>>}

  defp build_csr(records, ext) do
    rows = @extent * @extent

    {recs, col_x, fmi, fmi_count, maps, _pool, by_row} =
      Enum.reduce(records, {[], [], [], 0, <<>>, %{}, %{}}, fn {{x, y, z}, {_sext, faces}}, {recs, col_x, fmi, fmi_count, maps, pool, by_row} ->
        base = fmi_count

        {ids, mask, fmi, fmi_count, maps, pool} =
          Enum.reduce(0..5, {[], 0, fmi, fmi_count, maps, pool}, fn face, {ids, mask, fmi, fmi_count, maps, pool} ->
            case elem(faces, face) do
              {id, nil} ->
                {[id | ids], mask, fmi, fmi_count, maps, pool}

              {id, texels} ->
                texels = if byte_size(texels) == ext * ext, do: texels, else: :binary.copy(<<id>>, ext * ext)

                {index, maps, pool} =
                  case Map.fetch(pool, texels) do
                    {:ok, i} -> {i, maps, pool}
                    :error -> {map_size(pool), maps <> texels, Map.put(pool, texels, map_size(pool))}
                  end

                {[id | ids], mask ||| (1 <<< face), [index | fmi], fmi_count + 1, maps, pool}
            end
          end)

        rec = IO.iodata_to_binary([Enum.map(Enum.reverse(ids), &<<&1::16-little>>), <<mask::16-little, 0::16, base::32-little>>])
        row = y + @extent * z
        {[rec | recs], [x | col_x], fmi, fmi_count, maps, pool, Map.update(by_row, row, 1, &(&1 + 1))}
      end)

    {row_start_rev, _total} =
      Enum.reduce(0..(rows - 1), {[0], 0}, fn row, {acc, count} ->
        n = count + Map.get(by_row, row, 0)
        {[n | acc], n}
      end)

    {Enum.reverse(row_start_rev), Enum.reverse(col_x), Enum.reverse(recs), Enum.reverse(fmi), maps}
  end
end
