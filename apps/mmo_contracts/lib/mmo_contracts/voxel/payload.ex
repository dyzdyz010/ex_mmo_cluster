defmodule MmoContracts.Voxel.Payload do
  @moduledoc """
  一个已解码的 region 载荷：66³ cells（binary，u16 LE，x 最快，原点 region × 64 − 1）+ 稀疏表皮场（Voxim `FVoxelSkinField` 的 CSR）。

  body 布局 v4（Voxim `SerializeRegionBody`，决策稿 D-9；服务端 Rust `skin::encode` 与本模块 `encode/4` 输出同一布局）：
  cells `<<n::32, u16 × n>>` · Extent i32×3 · MapExtent i32 · RowStart `<<n::32, i32 × n>>` · ColX `<<n::32, u16 × n>>` ·
  RecordCount u32 + 六个 face id 平面（各 u8 × n）+ MapMask 平面（u16 × n）· FaceMapIndex `<<n::32, u16 × n>>` · Maps `<<n::32, u8 × n>>`。

  记录的 FaceMapBase（该记录非均匀面在 FaceMapIndex 里的起点）= 之前所有记录 mask popcount 之和，读方重算；贴图 hash 不传（客户端按 CityHash64 重算）。
  """

  import Bitwise
  alias MmoContracts.Voxel.Skins

  @extent 66
  @cell_count @extent * @extent * @extent
  @max_map_extent 4

  defstruct level: 0,
            region: {0, 0, 0},
            seq: 0,
            content_version: 0,
            cells: <<>>,
            map_extent: 1,
            records: %{},
            fmi: <<>>,
            maps: <<>>,
            refined: %{},
            instances: %{},
            format_version: 4

  @doc "region 载荷每轴 cell 数（含边缘）。"
  def extent, do: @extent

  @doc "v4 格/CSR 数量和 u16 贴图索引决定的最大编码容量；不是运行时预算。"
  def max_body_bytes,
    do:
      4 + @cell_count * (2 + 2 + 8 + 12) + 16 + 5 * 4 + (@extent * @extent + 1) * 4 +
        65536 * @max_map_extent * @max_map_extent

  @doc "region 的 66³ 原点（level 单位）。"
  def origin({x, y, z}), do: {x * 64 - 1, y * 64 - 1, z * 64 - 1}

  @doc "local XYZ 转为 x 最快的 cell 下标。"
  def cell_index({lx, ly, lz}), do: lx + @extent * (ly + @extent * lz)

  @doc "region 与 level 坐标转 local XYZ。"
  def local(region, {cx, cy, cz}) do
    {ox, oy, oz} = origin(region)
    {cx - ox, cy - oy, cz - oz}
  end

  @doc "local XYZ 是否位于载荷范围。"
  def in_span?({lx, ly, lz}),
    do: lx >= 0 and ly >= 0 and lz >= 0 and lx < @extent and ly < @extent and lz < @extent

  @doc "完整载荷字节 → struct。"
  def decode(bytes) do
    with {:ok, header, raw} <- MmoContracts.Voxel.Codec.decode_payload_body(bytes),
         {:ok, payload} <- decode_body(raw),
         true <- binary_part(bytes,0,4) == if(payload.format_version == 5,do: "VXR5",else: "VXR4"),
         true <- Enum.all?(payload.refined,fn {index,_} -> binary_part(payload.cells,index*2,2) == <<0,0>> end) do
      {:ok,
       %{
         payload
         | level: header.level,
           region: header.region,
           seq: header.seq,
           content_version: header.content_version
       }}
    else
      false -> {:error,:invalid_payload}
      error -> error
    end
  end

  @doc "VXR4 解压后的 CSR body 解码为不可变载荷。"
  def decode_body(
        <<n::32-little, cells::binary-size(n * 2), ex::32-little, ey::32-little, ez::32-little,
          map_extent::32-little, rest::binary>>
      )
      when n == @cell_count and map_extent in [1, 2, @max_map_extent] and
             ((ex == 0 and ey == 0 and ez == 0) or
                (ex == @extent and ey == @extent and ez == @extent)) do
    with {:ok, row_start, rest} <- array(rest, 4),
         {:ok, col_x, rest} <- array(rest, 2),
         <<record_count::32-little, faces::binary-size(record_count * 6),
           masks::binary-size(record_count * 2), rest::binary>> <- rest,
         {:ok, fmi, rest} <- array(rest, 2),
         {:ok, maps, tail} <- array(rest, 1),
         {:ok, refined, instances, version} <- MmoContracts.Voxel.Refined.decode(tail),
         {:ok, records} <-
           decode_records({ex, ey, ez}, map_extent, row_start, col_x, faces, masks, fmi, maps) do
      {:ok,
       %__MODULE__{
         cells: cells,
         map_extent: map_extent,
         records: records,
         fmi: fmi,
         maps: maps, refined: refined, instances: instances, format_version: version
       }}
    else
      _ -> {:error, :invalid_payload}
    end
  end

  def decode_body(_), do: {:error, :invalid_payload}

  defp decode_records(extent, map_extent, row_start, col_x, faces, masks, fmi, maps) do
    rows = for <<v::32-little <- row_start>>, do: v
    xs = List.to_tuple(for <<v::16-little <- col_x>>, do: v)
    mask_values = for <<v::16-little <- masks>>, do: v
    record_count = length(mask_values)
    texels = map_extent * map_extent
    map_count = div(byte_size(maps), texels)

    shape_ok =
      tuple_size(xs) == record_count and record_count <= @cell_count and
        rem(byte_size(maps), texels) == 0 and map_count <= 65536 and
        Enum.all?(mask_values, &(&1 <= 63)) and
        byte_size(fmi) == Enum.sum(Enum.map(mask_values, &popcount/1)) * 2 and
        Enum.all?(for(<<i::16-little <- fmi>>, do: i), &(&1 < map_count))

    rows_ok =
      if not shape_ok do
        false
      else
        if record_count == 0 do
          rows == [] and fmi == <<>> and maps == <<>>
        else
          extent == {@extent, @extent, @extent} and length(rows) == @extent * @extent + 1 and
            hd(rows) == 0 and List.last(rows) == record_count and
            Enum.all?(Enum.chunk_every(rows, 2, 1, :discard), fn [first, last] ->
              first <= last and last <= record_count and
                (first == last or
                   Enum.all?(first..(last - 1), fn i ->
                     elem(xs, i) < @extent and (i == first or elem(xs, i - 1) < elem(xs, i))
                   end))
            end)
        end
      end

    if shape_ok and rows_ok,
      do: {:ok, build_records(row_start, col_x, faces, masks)},
      else: {:error, :invalid_payload}
  end

  defp array(bin, size) do
    case bin do
      <<n::32-little, data::binary-size(n * size), rest::binary>> -> {:ok, data, rest}
      _ -> {:error, :invalid_payload}
    end
  end

  defp build_records(<<>>, _col_x, _faces, _masks), do: %{}

  defp build_records(row_start, col_x, faces, masks) do
    n = div(byte_size(masks), 2)
    rows = for <<v::32-little <- row_start>>, do: v
    xs = List.to_tuple(for <<v::16-little <- col_x>>, do: v)
    mask_list = for <<v::16-little <- masks>>, do: v
    {bases, _} = Enum.map_reduce(mask_list, 0, fn mask, base -> {base, base + popcount(mask)} end)
    ms = List.to_tuple(mask_list)
    bases = List.to_tuple(bases)

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
          ids = List.to_tuple(for face <- 0..5, do: :binary.at(faces, face * n + k))
          Map.put(acc, {elem(xs, k), y, z}, {ids, elem(ms, k), elem(bases, k)})
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
        Skins.uniform(material)

      {:ok, {ids, mask, base}} ->
        ext = p.map_extent

        faces =
          for face <- 0..5 do
            id = elem(ids, face)
            bit = 1 <<< face

            if (mask &&& bit) != 0 do
              slot = base + popcount(mask &&& bit - 1)
              <<index::16-little>> = binary_part(p.fmi, slot * 2, 2)
              {id, binary_part(p.maps, index * ext * ext, ext * ext)}
            else
              {id, nil}
            end
          end

        Skins.canonical({ext, List.to_tuple(faces)})
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
  表皮记录 = 原记录（去掉被覆盖的格）∪ overrides 里非平凡的格，按 (z, y, x) 升序写 CSR；贴图池按内容去重。
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
      |> Enum.reject(fn {_, {m, s}} -> Skins.trivial?(s, m) end)
      |> Map.new(fn {local, {_, s}} -> {local, s} end)

    records =
      Enum.sort_by(Map.merge(base_records, override_records), fn {{x, y, z}, _} -> {z, y, x} end)

    {row_start, col_x, faces, masks, fmi, maps} = build_csr(records, ext)

    # 空场（L0，或编辑后没有非平凡格）与 Rust `skin::encode` / 客户端空 FVoxelSkinField 同字节：Extent 0、MapExtent 1。
    # 客户端写回缓存的副本按同一规则编码，hash 才能与这里物化的载荷相等（否则重启后重发 payload 而不是 unchanged）。
    {field_extent, field_map_extent} = if records == [], do: {0, 1}, else: {@extent, ext}

    raw =
      IO.iodata_to_binary([
        <<@cell_count::32-little>>,
        cells,
        <<field_extent::32-little, field_extent::32-little, field_extent::32-little,
          field_map_extent::32-little>>,
        <<length(row_start)::32-little>>,
        Enum.map(row_start, &<<&1::32-little>>),
        <<length(col_x)::32-little>>,
        Enum.map(col_x, &<<&1::16-little>>),
        <<length(masks)::32-little>>,
        faces,
        Enum.map(masks, &<<&1::16-little>>),
        <<length(fmi)::32-little>>,
        Enum.map(fmi, &<<&1::16-little>>),
        <<byte_size(maps)::32-little>>,
        maps
      ])

    version = if map_size(p.refined) > 0 or map_size(p.instances) > 0, do: 5, else: 4
    raw = if version == 5, do: raw <> MmoContracts.Voxel.Refined.encode(p.refined, p.instances), else: raw
    MmoContracts.Voxel.Codec.encode_payload(p.level, p.region, seq, content_version, raw, version)
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

  defp build_csr([], _ext), do: {[], [], [], [], [], <<>>}

  defp build_csr(records, ext) do
    rows = @extent * @extent

    {ids_rev, masks_rev, col_x, fmi, maps, _pool, by_row} =
      Enum.reduce(records, {[], [], [], [], <<>>, %{}, %{}}, fn {{x, y, z}, {_sext, faces}},
                                                                {ids_rev, masks_rev, col_x, fmi,
                                                                 maps, pool, by_row} ->
        {ids, mask, fmi, maps, pool} =
          Enum.reduce(0..5, {[], 0, fmi, maps, pool}, fn face, {ids, mask, fmi, maps, pool} ->
            case elem(faces, face) do
              {id, nil} ->
                {[id | ids], mask, fmi, maps, pool}

              {id, texels} ->
                texels =
                  if byte_size(texels) == ext * ext,
                    do: texels,
                    else: :binary.copy(<<id>>, ext * ext)

                {index, maps, pool} =
                  case Map.fetch(pool, texels) do
                    {:ok, i} ->
                      {i, maps, pool}

                    :error ->
                      {map_size(pool), maps <> texels, Map.put(pool, texels, map_size(pool))}
                  end

                {[id | ids], mask ||| 1 <<< face, [index | fmi], maps, pool}
            end
          end)

        row = y + @extent * z

        {[List.to_tuple(Enum.reverse(ids)) | ids_rev], [mask | masks_rev], [x | col_x], fmi, maps,
         pool, Map.update(by_row, row, 1, &(&1 + 1))}
      end)

    ids = Enum.reverse(ids_rev)
    faces = IO.iodata_to_binary(for face <- 0..5, do: Enum.map(ids, &<<elem(&1, face)>>))

    {row_start_rev, _total} =
      Enum.reduce(0..(rows - 1), {[0], 0}, fn row, {acc, count} ->
        n = count + Map.get(by_row, row, 0)
        {[n | acc], n}
      end)

    {Enum.reverse(row_start_rev), Enum.reverse(col_x), faces, Enum.reverse(masks_rev),
     Enum.reverse(fmi), maps}
  end
end
