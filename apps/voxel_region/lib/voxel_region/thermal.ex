defmodule VoxelRegion.Thermal do
  @moduledoc "全局系统功能：普通宏格固体接触导热。只消费 canonical 派生摘要，不拥有世界状态。"

  @doc """
  格所在气候区的环境空气温度（K）；区外为全局 `ambient_kelvin`。

  气候区（热环境资产可选字段 `climate_zones`）：`[%{"min" => [x0, z0], "max" => [x1, z1], "ambient_kelvin" => K}]`，
  canonical 宏格 x/z 闭矩形、全高，列表在前者优先。它与全局 ambient 同性质——大气边界（无限热库），不是热源：
  区内空气换热、对天辐射、未记录格的默认温度与相变天然温度、静止判据都取区温。无该字段时与引入前逐位相同。
  """
  def ambient(config, cell) do
    case zone(config, cell) do
      nil -> config["ambient_kelvin"]
      index -> Enum.at(config["climate_zones"], index)["ambient_kelvin"]
    end
  end

  @doc "格所在气候区的下标；区外（或无气候区）为 nil。两格下标不同即热分区不同：导热与辐射不跨（绝热镜面）。"
  def zone(config, {x, _y, z}) do
    config
    |> Map.get("climate_zones", [])
    |> Enum.find_index(fn %{"min" => [x0, z0], "max" => [x1, z1]} -> x >= x0 and x <= x1 and z >= z0 and z <= z1 end)
  end

  @doc "热环境是否声明了气候区。"
  def zoned?(config), do: Map.get(config, "climate_zones", []) != []

  @doc "气候区字段合法：列表，每项整数闭矩形（min ≤ max）与正区温；缺省视为空列表。"
  def climate_zones?(config) do
    case Map.get(config, "climate_zones", []) do
      zones when is_list(zones) ->
        Enum.all?(zones, fn
          %{"min" => [x0, z0], "max" => [x1, z1], "ambient_kelvin" => k} ->
            Enum.all?([x0, z0, x1, z1], &is_integer/1) and x0 <= x1 and z0 <= z1 and is_number(k) and k > 0

          _ ->
            false
        end)

      _ ->
        false
    end
  end

  @doc "Canonical Y-up 六面相邻宏格，不受 chunk/region 分区影响。"
  def neighbors({x,y,z}), do: [{x-1,y,z},{x+1,y,z},{x,y-1,z},{x,y+1,z},{x,y,z-1},{x,y,z+1}]

  @doc "从实际占用派生每对接触一次的只读摘要。"
  def contacts(nodes) do
    for {cell,_} <- nodes, other <- neighbors(cell), cell < other, Map.has_key?(nodes,other), do: {cell,other}
  end

  @doc "单个显式步进：守恒传热、有限供能和环境交换，返回能量账及温度。量纲为 J、s、K。"
  def step(nodes, sources, config, dt) do
    step(nodes,sources,config,dt,contacts(nodes))
  end

  @doc "复用占用未变时的派生接触对；数值与状态仍由本次输入决定。"
  def step(nodes, sources, config, dt, edges) do
    flows=Enum.reduce(edges,%{},fn {a,b},sum ->
      na=Map.fetch!(nodes,a); nb=Map.fetch!(nodes,b)
      ka=na.material["thermal_conductivity"]; kb=nb.material["thermal_conductivity"]
      conductance=if ka+kb==0,do: 0.0,else: 2*ka*kb/(ka+kb)
      q=conductance*(nb.temperature-na.temperature)*dt
      sum |> Map.update(a,q,&(&1+q)) |> Map.update(b,-q,&(&1-q))
    end)
    {next,supplied,environment}=Enum.reduce(nodes,{%{},0.0,0.0},fn {cell,n},{next,input,loss} ->
      source=Map.get(sources,cell)
      q=if source,do: min(source.remaining_j,source.power_w*dt),else: 0.0
      ambient=config["environment_w_per_m2_k"]*n.exposed_faces*(ambient(config,cell)-n.temperature)*dt
      temperature=n.temperature+(Map.get(flows,cell,0.0)+q+ambient)/n.material["heat_capacity_per_macro"]
      {Map.put(next,cell,temperature),input+q,loss+ambient}
    end)
    sources=Map.new(sources,fn {cell,s} ->
      used=if Map.has_key?(nodes,cell),do: min(s.remaining_j,s.power_w*dt),else: 0.0
      {cell,%{s | remaining_j: s.remaining_j-used}}
    end)
    {next,sources,%{supplied_j: supplied,environment_j: environment}}
  end
end
