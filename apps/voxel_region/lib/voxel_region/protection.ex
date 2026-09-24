defmodule VoxelRegion.Protection do
  @moduledoc """
  全局系统功能：受保护区域——把一块指定地面范围交给一个持有者，范围内的世界只允许持有者修改，
  物理上与范围外隔开（边界是理想绝热镜面：导热、辐射、电连接、液体侧流、还原剂接触都不跨过持有者不同的两格）。

  - 区域 = x/z 闭区间宏格矩形，y 不限；`%{holder, min: {x, z}, max: {x, z}, created_seq, created_by}`，
    id `{创建事务 seq, 序号}`。区域两两不重叠；不在任何区域内的格是野外（holder nil），任何人可改。
  - 持有者 holder：`{:character, cid}` | `:reserved`；类型保持开放（以后的组织/政体区域加新 holder 形式），
    本模块只比较相等，不含任何玩家规则。认领工具（上限、面积、占用）与作者保留入口是调用方的两个适配。
  - 查询索引：256 m × 256 m 地面桶 → 与之相交的区域 id 列表；一次查询 = 一次 map 读取 + 桶内少量矩形包含判断。
    没有区域时所有查询直接返回（物理与无此功能时逐位相同）。
  只做值计算，不读取 World、不分配序号。
  """

  @bucket 256

  def new, do: %{regions: %{}, index: %{}}

  def empty?(%{regions: regions}), do: map_size(regions) == 0

  @doc "包含该宏格的 {id, 区域}；野外为 nil。"
  def region_at(%{regions: regions} = p, {x, _y, z}) do
    if map_size(regions) == 0 do
      nil
    else
      p.index
      |> Map.get(bucket(x, z), [])
      |> Enum.find_value(fn id ->
        r = Map.fetch!(regions, id)
        if contains?(r, {x, 0, z}), do: {id, r}
      end)
    end
  end

  @doc "宏格的持有者；野外 nil。"
  def holder(p, cell) do
    case region_at(p, cell) do
      {_, r} -> r.holder
      nil -> nil
    end
  end

  @doc "两格持有者相同（含同为野外）才互相连通；物理边界过滤的唯一判据。"
  def same_holder?(p, a, b), do: empty?(p) or holder(p, a) == holder(p, b)

  @doc "每个受影响格都是野外或属于 holder 时允许；只读查询不经此判定。"
  def permitted?(p, holder, cells),
    do: empty?(p) or Enum.all?(cells, &(holder(p, &1) in [nil, holder]))

  @doc "矩形 {min, max}（闭区间）是否与任一既有区域相交。"
  def overlaps?(p, {x0, z0} = min, {x1, z1} = max) do
    Enum.any?(buckets(min, max), fn b ->
      Enum.any?(Map.get(p.index, b, []), fn id ->
        r = Map.fetch!(p.regions, id)
        {rx0, rz0} = r.min
        {rx1, rz1} = r.max
        x0 <= rx1 and rx0 <= x1 and z0 <= rz1 and rz0 <= z1
      end)
    end)
  end

  @doc "holder 持有的区域 id。"
  def held(p, holder), do: for({id, %{holder: ^holder}} <- p.regions, do: id)

  @doc "面积（m²，1 宏格 = 1 m）。"
  def area(%{min: {x0, z0}, max: {x1, z1}}), do: (x1 - x0 + 1) * (z1 - z0 + 1)

  @doc "应用增量 `%{id => 区域 | nil}`；nil 删除。重放、检查点与提交共用。"
  def apply(p, delta) do
    Enum.reduce(delta, p, fn
      {id, nil}, p -> delete(p, id)
      {id, region}, p -> p |> delete(id) |> put(id, region)
    end)
  end

  @doc "宏格是否在区域矩形内（可向外扩 margin 格）。"
  def contains?(%{min: {x0, z0}, max: {x1, z1}}, {x, _y, z}, margin \\ 0),
    do: x >= x0 - margin and x <= x1 + margin and z >= z0 - margin and z <= z1 + margin

  @doc "区域是否与 canonical 窗口（64 m region 坐标半开盒，y 不限）相交；快照与增量投影用。"
  def relevant?(%{min: {x0, z0}, max: {x1, z1}}, {{bx0, _, bz0}, {bx1, _, bz1}}),
    do: x0 < bx1 * 64 and x1 >= bx0 * 64 and z0 < bz1 * 64 and z1 >= bz0 * 64

  defp put(p, id, region) do
    index =
      Enum.reduce(buckets(region.min, region.max), p.index, fn b, index ->
        Map.update(index, b, [id], &[id | &1])
      end)

    %{p | regions: Map.put(p.regions, id, region), index: index}
  end

  defp delete(p, id) do
    case Map.fetch(p.regions, id) do
      :error ->
        p

      {:ok, region} ->
        index =
          Enum.reduce(buckets(region.min, region.max), p.index, fn b, index ->
            case List.delete(Map.fetch!(index, b), id) do
              [] -> Map.delete(index, b)
              ids -> Map.put(index, b, ids)
            end
          end)

        %{p | regions: Map.delete(p.regions, id), index: index}
    end
  end

  defp bucket(x, z), do: {Integer.floor_div(x, @bucket), Integer.floor_div(z, @bucket)}

  defp buckets({x0, z0}, {x1, z1}) do
    {bx0, bz0} = bucket(x0, z0)
    {bx1, bz1} = bucket(x1, z1)
    for bx <- bx0..bx1, bz <- bz0..bz1, do: {bx, bz}
  end
end
