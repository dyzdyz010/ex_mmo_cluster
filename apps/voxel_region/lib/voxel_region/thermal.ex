defmodule VoxelRegion.Thermal do
  @moduledoc "全局系统功能：普通宏格固体接触导热。只消费 canonical 派生摘要，不拥有世界状态。"

  @doc "Canonical Y-up 六面相邻宏格，不受 chunk/region 分区影响。"
  def neighbors({x,y,z}), do: [{x-1,y,z},{x+1,y,z},{x,y-1,z},{x,y+1,z},{x,y,z-1},{x,y,z+1}]

  @doc "从实际占用派生每对接触一次的只读摘要。"
  def contacts(nodes) do
    for {cell,_} <- nodes, other <- neighbors(cell), cell < other, Map.has_key?(nodes,other), do: {cell,other}
  end

  @doc "单个显式步进：守恒传热、有限供能和环境交换，返回能量账及温度。量纲为 J、s、K。"
  def step(nodes, sources, config, dt) do
    edges=contacts(nodes)
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
      ambient=config["environment_w_per_m2_k"]*n.exposed_faces*(config["ambient_kelvin"]-n.temperature)*dt
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
