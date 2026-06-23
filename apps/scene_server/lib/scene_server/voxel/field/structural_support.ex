defmodule SceneServer.Voxel.Field.StructuralSupport do
  @moduledoc """
  力学应力 · 纯结构支撑分析(chunk-local)。

  「支撑」= 连通可达性:一个**实心结构 cell**(`structural` 属性 > 0 的 solid 块)是否
  经**六向面相邻的结构 cell** 连到**地锚**(本 chunk 底层 local y=0 的结构 cell)。从地锚
  BFS,**可达 = 有支撑;region AABB 内未达的结构 cell = 失支撑 → 坍塌**。

  与电路连通分量(`CircuitComponentAnalysis`)同范式,但 v1 只需 macro 级面相邻(不需微接触
  精度)、且属性派生(`structural`,流体/气/松散材料=0 不参与)。纯函数;逐 cell O(1) header/
  材料默认访问(见 `Storage.index_macro_headers`);O(结构 cell 数)。

  **v1 局限**(见 `docs/2026-06-23-mechanical-stress-structural-collapse.md` §4):
  地锚仅本 chunk 底层(跨 chunk 支撑做近似);连通即支撑(不模拟悬臂/超载弯曲应力)。
  调用方须把 region AABB 的 `min_y` 设为 0(含地锚层),否则会过度判失支撑。
  """

  alias SceneServer.Voxel.MacroCellHeader
  alias SceneServer.Voxel.MaterialCatalog
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.Types

  @structural_attribute "structural"
  # structural 默认 1.0(65536 raw);材料覆写为 0 表示不承重(流体/气/松散)。> 0 即结构。
  @structural_default_raw 65_536

  @doc """
  返回 `aabb` 内**失支撑**的实心结构 cell 的 macro_index 列表(无序)。
  地锚 = AABB 内 local y=0 的结构 cell;BFS 经六向面相邻结构 cell 扩散。
  无失支撑(全连到地)→ `[]`。
  """
  @spec unsupported_cells(Storage.t(), {tuple(), tuple()}) :: [non_neg_integer()]
  def unsupported_cells(%Storage{} = storage, {{_, _, _}, {_, _, _}} = aabb) do
    storage = Storage.normalize!(storage)
    headers = Storage.index_macro_headers(storage)
    blocks = List.to_tuple(storage.normal_blocks)

    {structural, anchors} = collect(headers, blocks, aabb)
    supported = bfs(anchors, structural, aabb)

    structural
    |> MapSet.difference(supported)
    |> MapSet.to_list()
  end

  def unsupported_cells(_storage, _aabb), do: []

  # 扫 AABB:收集结构 cell 集 + 地锚集(y=0 的结构 cell)。
  defp collect(headers, blocks, {{min_x, min_y, min_z}, {max_x, max_y, max_z}}) do
    for x <- min_x..max_x,
        y <- min_y..max_y,
        z <- min_z..max_z,
        macro_index = Types.macro_index!({x, y, z}),
        structural_solid?(headers, blocks, macro_index),
        reduce: {MapSet.new(), MapSet.new()} do
      {structural, anchors} ->
        structural = MapSet.put(structural, macro_index)
        anchors = if y == 0, do: MapSet.put(anchors, macro_index), else: anchors
        {structural, anchors}
    end
  end

  defp structural_solid?(headers, blocks, macro_index) do
    case Storage.header_at_index(headers, macro_index) do
      %MacroCellHeader{mode: mode, payload_index: payload_index} ->
        if mode == MacroCellHeader.cell_mode_solid_block() do
          structural_material?(blocks, payload_index)
        else
          false
        end

      _other ->
        false
    end
  rescue
    _ -> false
  end

  defp structural_material?(blocks, payload_index)
       when is_integer(payload_index) and payload_index >= 0 and payload_index < tuple_size(blocks) do
    case elem(blocks, payload_index) do
      %NormalBlockData{material_id: material_id} ->
        MaterialCatalog.default_attribute_value(
          material_id,
          @structural_attribute,
          @structural_default_raw
        ) > 0

      _other ->
        false
    end
  end

  defp structural_material?(_blocks, _payload_index), do: false

  # 从地锚 BFS,经六向面相邻、且在结构集内的 cell 扩散;返回可达(有支撑)集。
  defp bfs(anchors, structural, aabb) do
    do_bfs(MapSet.to_list(anchors), anchors, structural, aabb)
  end

  defp do_bfs([], visited, _structural, _aabb), do: visited

  defp do_bfs([macro_index | rest], visited, structural, aabb) do
    next =
      macro_index
      |> face_neighbors(aabb)
      |> Enum.filter(fn n -> MapSet.member?(structural, n) and not MapSet.member?(visited, n) end)

    visited = Enum.reduce(next, visited, &MapSet.put(&2, &1))
    do_bfs(next ++ rest, visited, structural, aabb)
  end

  defp face_neighbors(macro_index, {{min_x, min_y, min_z}, {max_x, max_y, max_z}}) do
    {x, y, z} = Types.macro_coord!(macro_index)

    [
      {x + 1, y, z},
      {x - 1, y, z},
      {x, y + 1, z},
      {x, y - 1, z},
      {x, y, z + 1},
      {x, y, z - 1}
    ]
    |> Enum.filter(fn {nx, ny, nz} ->
      nx in min_x..max_x and ny in min_y..max_y and nz in min_z..max_z
    end)
    |> Enum.map(&Types.macro_index!/1)
  end
end
