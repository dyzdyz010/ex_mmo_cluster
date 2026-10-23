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
            structure: %{},
            attachments: %{},
            liquid_units: %{},
            canopy: %{},
            canopy_instances: %{},
            canopy_residual: %{},
            canopy_residual_structure: %{},
            base_instances: nil,
            base_format_version: nil,
            # 编码复用：已编好的 refined 槽记录（cell_index => Refined.slot_records/1），不进线格式、解码恒为空。
            refined_records: %{},
            format_version: 4

  @doc "region 载荷每轴 cell 数（含边缘）。"
  def extent, do: @extent

  @doc "固定cells和空CSR布局的最小解压字节数。"
  def min_body_bytes, do: 4 + @cell_count * 2 + 16 + 5 * 4

  @doc "覆盖后地形的解压字节下界：完整 CSR 行索引与记录平面，省略贴图和细节尾部。"
  def min_body_bytes(%__MODULE__{} = p, overrides) do
    {records, _extent} = updated_records(p, overrides)
    count = map_size(records)
    rows = if count == 0, do: 0, else: (@extent * @extent + 1) * 4
    min_body_bytes() + rows + count * (2 + 6 + 2)
  end

  # v4 地形段：格/CSR 数量和 u16 贴图索引决定的格式容量。
  @terrain_max_body_bytes 4 + @cell_count * (2 + 2 + 8 + 12) + 16 + 5 * 4 +
                            (@extent * @extent + 1) * 4 +
                            65536 * @max_map_extent * @max_map_extent

  # v5+ 地形之后的尾部段：refined 单段格式容量已是 4 + N×(8 + 512×16) = 2_357_467_204 B（N = 66³），
  # 实例段 u32 计数×69/85 B 无格式上界，附件 2×3×528³ 槽×36 B、液体 4 + N×8 B、VXR6 结构
  # N×(8 + 4096×14) B，合计都超过双端能接纳的解压字节；上限取 Voxim 解码器
  # （VoxelRegionCodec.cpp DecodeRegionPayload，TArray int32 下标）对 v5+ 的同一界。
  @detail_max_body_bytes 2_147_483_647

  @doc """
  按格式版本推导的解压 body 最大编码容量，读写两端共用（`Codec.encode_payload/6` 与
  `Codec.unpack_payload_body/1`），写得出就读得回；不是运行时预算。
  """
  def max_body_bytes(4), do: @terrain_max_body_bytes
  def max_body_bytes(version) when version in 5..13, do: @detail_max_body_bytes

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
         {:ok, payload} <- decode_body(raw, header.version),
         true <- header.version != 6 or header.level >= 1,
         true <- header.version not in [7, 8, 9, 10, 11, 12] or header.level == 0,
         true <-
           Enum.all?(payload.attachments, fn {{_, _, anchor}, _} ->
             Enum.all?(0..2, fn i ->
               x = elem(anchor, i)
               o = elem(header.region, i) * 512
               x >= o - 8 and x < o + 520
             end)
           end),
         true <- header.version == payload.format_version,
         true <- canopy_in_span?(payload, header),
         true <-
           Enum.all?(payload.refined, fn {index, _} ->
             binary_part(payload.cells, index * 2, 2) == <<0, 0>>
           end) do
      {:ok,
       %{
         payload
         | level: header.level,
           region: header.region,
           seq: header.seq,
           content_version: header.content_version
       }}
    else
      false -> {:error, :invalid_payload}
      error -> error
    end
  end

  @doc "只解出载荷的 66³ 格材质段（u16 小端，x 最快）；不解表皮场与细节尾部。"
  def decode_cells(bytes) do
    case MmoContracts.Voxel.Codec.decode_payload_body(bytes) do
      {:ok, _header, <<@cell_count::32-little, cells::binary-size(@cell_count * 2), _::binary>>} -> {:ok, cells}
      {:ok, _header, _raw} -> {:error, :invalid_payload}
      error -> error
    end
  end

  @doc "VXR4 解压后的 CSR body 解码为不可变载荷。"
  def decode_body(raw, version \\ 4)

  def decode_body(raw, 13) do
    with {:ok,_,tail} <- terrain_sections(raw),
         <<base::32-little,size::32-little,base_tail::binary-size(size),canopy::binary>> <- tail,
         true <- base in 4..12,
         terrain = binary_part(raw,0,byte_size(raw)-byte_size(tail)),
         {:ok,payload} <- decode_body(terrain<>base_tail,base),
         true <- payload.format_version==base,
         {:ok,anchors,instances,residual,structure} <- MmoContracts.Voxel.Canopy.decode(canopy),
         true <- Enum.all?(payload.instances,fn {id,value} ->
           not Map.has_key?(instances,id) or Map.take(instances[id],Map.keys(value))==value end) do
      {:ok,%{payload | format_version: 13,base_format_version: base,base_instances: payload.instances,
        instances: Map.merge(payload.instances,instances),canopy: anchors,canopy_instances: instances,canopy_residual: residual,canopy_residual_structure: structure}}
    else
      _ -> {:error,:invalid_payload}
    end
  end

  def decode_body(raw, version) do
    with {:ok, {cells, extent, map_extent, row_start, col_x, faces, masks, fmi, maps}, tail} <-
           terrain_sections(raw),
         {:ok, refined, instances, structure, attachments, liquid_units, version} <-
           decode_tail(tail, version),
         true <-
           Enum.all?(liquid_units, fn {index, _} ->
             material = :binary.decode_unsigned(binary_part(cells, index * 2, 2), :little)

             # VXRC（12，R8-07 散体）：任何非空气宏格都可带有限数量；refined 宏格从不带。
             (material == 21 or (version >= 10 and material == 20) or
                (version >= 11 and material in [4, 13, 22]) or (version >= 12 and material != 0)) and
               not Map.has_key?(refined, index)
           end),
         {:ok, records} <-
           decode_records(extent, map_extent, row_start, col_x, faces, masks, fmi, maps) do
      {:ok,
       %__MODULE__{
         cells: cells,
         map_extent: map_extent,
         records: records,
         fmi: fmi,
         maps: maps,
         refined: refined,
         instances: instances,
         structure: structure,
         attachments: attachments,
         liquid_units: liquid_units,
         format_version: version
       }}
    else
      _ -> {:error, :invalid_payload}
    end
  end

  # 地形段布局只有这一处；完整解码与细节重写共用分段，不重复展开 CSR。
  defp canopy_in_span?(%{format_version: version},_) when version != 13,do: true
  defp canopy_in_span?(payload,header) do
    base=payload.base_format_version
    scale=1 <<< header.level
    origin=origin(header.region)
    expected=MapSet.new(payload.canopy,fn {{x,y,z},_}->
      cell_index({Integer.floor_div(x,scale)-elem(origin,0),Integer.floor_div(y,scale)-elem(origin,1),Integer.floor_div(z,scale)-elem(origin,2)}) end)
    header.level<=5 and (base != 6 or header.level>=1) and
      (base not in [7,8,9,10,11,12] or header.level==0) and
      expected==MapSet.new(Map.keys(payload.canopy_residual)) and
      (header.level>0 or map_size(payload.canopy_residual_structure)==0) and
      Enum.all?(payload.canopy_residual,fn {_,{_,{extent,_}}}->extent<=min(scale,4) end) and
      Enum.all?(payload.canopy,fn {cell,{material,_,_}}->
        in_span=Enum.all?(0..2,fn i->
          local=elem(cell,i)-elem(origin,i)*scale
          local>=0 and local<66*scale
        end)
        in_span and (header.level>0 or
          (not Map.has_key?(payload.refined,cell_index(local(header.region,cell))) and
            material(payload,local(header.region,cell))==material))
      end)
  end
  defp terrain_sections(
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
         {:ok, maps, tail} <- array(rest, 1) do
      {:ok, {cells, {ex, ey, ez}, map_extent, row_start, col_x, faces, masks, fmi, maps}, tail}
    else
      _ -> {:error, :invalid_payload}
    end
  end

  defp terrain_sections(_), do: {:error, :invalid_payload}

  defp decode_tail(tail, 6) do
    with {:ok, structure} <- MmoContracts.Voxel.Structure.decode(tail),
         do: {:ok, %{}, %{}, structure, %{}, %{}, 6}
  end

  # Global system: VXR9 carries finite L0 Water21 quantities with owned/ring occupancy.
  # VXR4-8 Water21 without a record means one full macro at the published inventory scale.
  defp decode_tail(tail, version) when version in [9, 10, 11, 12] do
    with {:ok, refined, instances, tail} <- MmoContracts.Voxel.Refined.decode_prefix(tail, 7),
         <<n::little-32, slots::binary-size(n * 36), tail::binary>> <- tail,
         {:ok, attachments} <-
           MmoContracts.Voxel.Attachments.decode(<<n::little-32, slots::binary>>),
         <<count::little-32, quantities::binary-size(count * 8)>> <- tail,
         true <- count <= @cell_count,
         {:ok, units} <- liquid_records(quantities, -1, %{}),
         do: {:ok, refined, instances, %{}, attachments, units, version}
  end

  defp decode_tail(tail, 8) do
    with {:ok, refined, instances, tail} <- MmoContracts.Voxel.Refined.decode_prefix(tail, 7),
         {:ok, attachments} <- MmoContracts.Voxel.Attachments.decode(tail),
         true <- map_size(attachments) > 0,
         do: {:ok, refined, instances, %{}, attachments, %{}, 8}
  end

  defp decode_tail(tail, version) do
    with {:ok, refined, instances, version} <-
           MmoContracts.Voxel.Refined.decode(tail, if(version == 7, do: 7, else: 5)),
         do: {:ok, refined, instances, %{}, %{}, %{}, version}
  end

  defp liquid_records(<<>>, _, units), do: {:ok, units}

  defp liquid_records(<<index::little-32, quantity::little-32, rest::binary>>, previous, units)
       when index > previous and index < @cell_count and quantity > 0,
       do: liquid_records(rest, index, Map.put(units, index, quantity))

  defp liquid_records(_, _, _), do: {:error, :invalid_liquid}

  defp encode_liquid(units) do
    body =
      for {index, quantity} <- Enum.sort(units),
          into: <<>>,
          do: <<index::little-32, quantity::little-32>>

    <<map_size(units)::little-32, body::binary>>
  end

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
          # 六个 u8 面材质存于一个小整数，避免常驻表皮记录携带六元组。
          ids =
            Enum.reduce(0..5, 0, fn face, ids ->
              ids ||| :binary.at(faces, face * n + k) <<< (face * 8)
            end)

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
            id = ids >>> (face * 8) &&& 255
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
  def encode(%__MODULE__{} = p, overrides, seq, content_version),
    do: encode_with_details(terrain_raw(p, overrides), p, seq, content_version)

  @doc """
  同 encode/4，但已知完整载荷不短于 `limit` 字节时返回 `:not_smaller`，不编细节尾部、不压缩完整 body。

  判据是地形段（格 + CSR，body 的开头）的压缩流前缀（`Codec.compressed_prefix_bytes/1`，与
  `Codec.encode_payload/6` 同一 zlib 流）：已输出的压缩字节只会是最终 body 的前缀，加上定长头已达 `limit`
  即可断定完整载荷不短于它。未达到时照常完整编码返回 `{:ok, bytes}`。
  """
  def encode_below(%__MODULE__{} = p, overrides, seq, content_version, limit) do
    raw = terrain_raw(p, overrides)

    if MmoContracts.Voxel.Codec.payload_header_bytes() + MmoContracts.Voxel.Codec.compressed_prefix_bytes(raw) >= limit,
      do: :not_smaller,
      else: {:ok, encode_with_details(raw, p, seq, content_version)}
  end

  # body 的地形段：格与表皮场 CSR；细节尾部由 encode_with_details/4 接在其后。
  defp terrain_raw(p, overrides) do
    cells = splice_cells(p.cells, overrides)
    {records, ext} = updated_records(p, overrides)
    records = Enum.sort_by(records, fn {{x, y, z}, _} -> {z, y, x} end)

    {row_start, col_x, faces, masks, fmi, maps} = build_csr(records, p)

    # 空场（L0，或编辑后没有非平凡格）与 Rust `skin::encode` / 客户端空 FVoxelSkinField 同字节：Extent 0、MapExtent 1。
    # 客户端写回缓存的副本按同一规则编码，hash 才能与这里物化的载荷相等（否则重启后重发 payload 而不是 unchanged）。
    {field_extent, field_map_extent} = if records == [], do: {0, 1}, else: {@extent, ext}

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
  end

  defp updated_records(p, overrides) do
    base_records = Map.drop(p.records, Map.keys(overrides))

    override_records =
      overrides
      |> Enum.reject(fn {_, {m, s}} -> Skins.trivial?(s, m) end)
      |> Map.new(fn {local, {_, s}} -> {local, s} end)

    # 空CSR的贴图尺寸为1；首次加入非均匀表皮时，输出尺寸由新记录恢复。
    # 旧压紧记录仍按原p.map_extent读取，不能把输出尺寸用于解析旧池。
    ext =
      Enum.reduce(override_records, p.map_extent, fn {_, {extent, _}}, current ->
        max(current, extent)
      end)

    {Map.merge(base_records, override_records), ext}
  end

  @doc "复用有效且地形仍为当前真值的载荷字节；p 提供新的 refined/structure，调用方负责地形缓存失效。"
  def replace_details(bytes, %__MODULE__{} = p, seq, content_version) do
    {:ok, _header, raw} = MmoContracts.Voxel.Codec.unpack_payload_body(bytes)
    {:ok, _sections, tail} = terrain_sections(raw)
    terrain = binary_part(raw, 0, byte_size(raw) - byte_size(tail))
    encode_with_details(terrain, p, seq, content_version)
  end

  @doc "Rewrite admitted cached terrain and new details in one encoding pass."
  def replace_cells_and_details(bytes, overrides, %__MODULE__{} = details, seq, content_version) do
    {:ok, _header, raw} = MmoContracts.Voxel.Codec.unpack_payload_body(bytes)

    {:ok, {cells, _extent, map_extent, rows, xs, faces, masks, fmi, maps}, _tail} =
      terrain_sections(raw)

    payload = %{
      details
      | cells: cells,
        map_extent: map_extent,
        records: build_records(rows, xs, faces, masks),
        fmi: fmi,
        maps: maps
    }

    encode(payload, overrides, seq, content_version)
  end

  @doc "已接纳载荷的若干local格改为uniform材质；空CSR直接改cells并原样保留后缀，非空CSR按现有规则删除被覆盖记录。"
  def replace_uniform_cells(bytes, materials, seq, content_version) do
    {:ok, header, raw} = MmoContracts.Voxel.Codec.unpack_payload_body(bytes)
    {:ok, sections, _tail} = terrain_sections(raw)
    overrides = Map.new(materials, fn {local, m} -> {local, {m, Skins.uniform(m)}} end)

    case sections do
      {cells, {0, 0, 0}, 1, <<>>, <<>>, <<>>, <<>>, <<>>, <<>>} ->
        size = byte_size(cells)
        <<_count::32-little, _cells::binary-size(size), suffix::binary>> = raw

        raw =
          IO.iodata_to_binary([
            <<@cell_count::32-little>>,
            splice_cells(cells, overrides),
            suffix
          ])

        MmoContracts.Voxel.Codec.encode_payload(
          header.level,
          header.region,
          seq,
          content_version,
          raw,
          header.version
        )

      _ ->
        {:ok, payload} = decode_body(raw, header.version)

        encode(
          %{payload | level: header.level, region: header.region},
          overrides,
          seq,
          content_version
        )
    end
  end

  defp encode_with_details(terrain, p, seq, content_version) do
    instances = p.base_instances || p.instances
    materials =
      for {i, _} <- p.liquid_units,
          into: MapSet.new(),
          do: :binary.decode_unsigned(binary_part(terrain, 4 + i * 2, 2), :little)

    version = p.base_format_version ||
      cond do
        Enum.any?(materials, &(&1 not in [4, 13, 20, 21, 22])) ->
          12

        Enum.any?(materials, &(&1 in [4, 13, 22])) ->
          11

        MapSet.member?(materials, 20) ->
          10

        map_size(p.liquid_units) > 0 ->
          9

        map_size(p.attachments) > 0 ->
          8

        map_size(p.structure) > 0 ->
          6

        Enum.any?(instances, fn {_, i} -> Map.get(i, :parent_id, {0, 0}) != {0, 0} end) ->
          7

        map_size(p.refined) > 0 or map_size(instances) > 0 ->
          5

        true ->
          4
      end

    raw =
      case version do
        v when v in [9, 10, 11, 12] ->
          terrain <>
            MmoContracts.Voxel.Refined.encode(p.refined, instances, 7, p.refined_records) <>
            MmoContracts.Voxel.Attachments.encode(p.attachments) <> encode_liquid(p.liquid_units)

        8 ->
          terrain <>
            MmoContracts.Voxel.Refined.encode(p.refined, instances, 7, p.refined_records) <>
            MmoContracts.Voxel.Attachments.encode(p.attachments)

        6 ->
          terrain <> MmoContracts.Voxel.Structure.encode(p.structure)

        v when v in [5, 7] ->
          terrain <> MmoContracts.Voxel.Refined.encode(p.refined, instances, v, p.refined_records)

        4 ->
          terrain
      end

    {raw,version} = if map_size(p.canopy)>0 or map_size(p.canopy_residual)>0 do
      base_tail=binary_part(raw,byte_size(terrain),byte_size(raw)-byte_size(terrain))
      {terrain <> <<version::32-little,byte_size(base_tail)::32-little>> <> base_tail <>
        MmoContracts.Voxel.Canopy.encode(p.canopy,p.canopy_instances,p.canopy_residual,p.canopy_residual_structure),13}
    else
      {raw,version}
    end
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

  defp build_csr([], _p), do: {[], [], [], [], [], <<>>}

  defp build_csr(records, p) do
    rows = @extent * @extent

    {ids_rev, masks_rev, col_x, fmi, maps, _pool, by_row, _canonical} =
      Enum.reduce(records, {[], [], [], [], <<>>, %{}, %{}, %{}}, fn {{x, y, z}, record},
                                                                     {ids_rev, masks_rev, col_x,
                                                                      fmi, maps, pool, by_row,
                                                                      canonical} ->
        {{ids, mask, fmi, maps, pool}, canonical} =
          csr_faces(record, p, 0, {[], 0, fmi, maps, pool}, canonical)

        row = y + @extent * z

        {[List.to_tuple(Enum.reverse(ids)) | ids_rev], [mask | masks_rev], [x | col_x], fmi, maps,
         pool, Map.update(by_row, row, 1, &(&1 + 1)), canonical}
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

  defp csr_faces(_record, _p, 6, acc, canonical), do: {acc, canonical}

  defp csr_faces({ids, mask, base}, p, face, acc, canonical) do
    id = ids &&& 255

    {value, next, canonical} =
      if (mask &&& 1) == 0 do
        {{id, nil}, base, canonical}
      else
        <<index::16-little>> = binary_part(p.fmi, base * 2, 2)

        # 源池在本次编码内不变；同一贴图是否收拢还取决于面材质，不能只按index复用。
        # 输出pool仍由csr_face按首次使用顺序去重，不受这份局部规范形表影响。
        key = {index, id}

        case Map.fetch(canonical, key) do
          {:ok, value} ->
            {value, base + 1, canonical}

          :error ->
            size = p.map_extent * p.map_extent
            value = Skins.canonical_face({id, binary_part(p.maps, index * size, size)})
            {value, base + 1, Map.put(canonical, key, value)}
        end
      end

    acc = csr_face(value, face, acc)
    csr_faces({ids >>> 8, mask >>> 1, next}, p, face + 1, acc, canonical)
  end

  defp csr_faces({_ext, faces} = record, p, face, acc, canonical) do
    acc = csr_face(elem(faces, face), face, acc)
    csr_faces(record, p, face + 1, acc, canonical)
  end

  defp csr_face({id, nil}, _face, {ids, mask, fmi, maps, pool}),
    do: {[id | ids], mask, fmi, maps, pool}

  defp csr_face({id, texels}, face, {ids, mask, fmi, maps, pool}) do
    {index, maps, pool} =
      case Map.fetch(pool, texels) do
        {:ok, i} -> {i, maps, pool}
        :error -> {map_size(pool), maps <> texels, Map.put(pool, texels, map_size(pool))}
      end

    {[id | ids], mask ||| 1 <<< face, [index | fmi], maps, pool}
  end
end
