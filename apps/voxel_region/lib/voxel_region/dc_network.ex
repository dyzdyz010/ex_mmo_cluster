defmodule VoxelRegion.DCNetwork do
  @moduledoc "全局系统功能：线性电阻网络的 KCL 节点求解；每个连通分量至多一个有限内阻电源。"

  @doc "输入支路 a/b、欧姆 r、伏特 emf；返回节点电压、同序支路电流及多源故障支路索引。"
  def solve(edges) do
    adjacency=Enum.reduce(edges,%{},fn e,g ->
      g |> Map.update(e.a,[e.b],&[e.b|&1]) |> Map.update(e.b,[e.a],&[e.a|&1])
    end)
    {volts,faults}=components(adjacency) |> Enum.reduce({%{},MapSet.new()},fn nodes,{volts,faults}->
      local=edges |> Enum.with_index() |> Enum.filter(fn {e,_}->MapSet.member?(nodes,e.a) end)
      sources=Enum.filter(local,fn {e,_}->e.emf  !=  0.0 end)
      case sources do
        [] -> {Enum.reduce(nodes,volts,&Map.put(&2,&1,0.0)),faults}
        [{source,index}] ->
          # 源支路是桥（去掉它两端不再连通，例如开关断开）：严格开路，两侧各自等势、源两端差 emf，全部电流为 0，
          # 不交给消元（大电导网格上的舍入会留下 ~1e-8 A 的假电流）。
          rest=for {e,i}<-local,i != index,reduce: %{},do: (g->g |> Map.update(e.a,[e.b],&[e.b|&1]) |> Map.update(e.b,[e.a],&[e.a|&1]))
          side=walk(Map.put_new(rest,source.a,[]),[source.a],MapSet.new())
          if MapSet.member?(side,source.b),
            do: {Map.merge(volts,component(local,nodes,source.b)),faults},
            else: {Enum.reduce(nodes,volts,&Map.put(&2,&1,if(MapSet.member?(side,&1),do: source.emf,else: 0.0))),faults}
        _ -> {Enum.reduce(nodes,volts,&Map.put(&2,&1,0.0)),Enum.reduce(local,faults,fn {_,i},f->MapSet.put(f,i) end)}
      end
    end)
    currents=edges |> Enum.with_index() |> Enum.map(fn {e,i}->
      if MapSet.member?(faults,i),do: 0.0,else: (volts[e.a]-volts[e.b]-e.emf)/e.r
    end)
    %{volts: volts,currents: currents,faults: faults}
  end

  defp components(g),do: components(g,Map.keys(g),MapSet.new(),[])
  defp components(_g,[],_seen,result),do: result
  defp components(g,[n|rest],seen,result) do
    if MapSet.member?(seen,n),do: components(g,rest,seen,result),else:
      (nodes=walk(g,[n],MapSet.new()); components(g,rest,MapSet.union(seen,nodes),[nodes|result]))
  end
  defp walk(_g,[],seen),do: seen
  defp walk(g,[n|queue],seen) do
    if MapSet.member?(seen,n),do: walk(g,queue,seen),else: walk(g,g[n]++queue,MapSet.put(seen,n))
  end

  defp component(edges,nodes,ground) do
    matrix=for n<-nodes,n != ground,into: %{},do: {n,{%{},0.0}}
    matrix=Enum.reduce(edges,matrix,fn {e,_},m ->
      g=1.0/e.r
      m |> stamp(e.a,e.b,g,g*e.emf,ground) |> stamp(e.b,e.a,g,-g*e.emf,ground)
    end)
    eliminate(matrix,[]) |> Enum.reduce(%{ground=>0.0},fn {node,diagonal,row,rhs},values ->
      value=(rhs-Enum.reduce(row,0.0,fn {other,g},sum->sum+g*Map.fetch!(values,other) end))/diagonal
      Map.put(values,node,value)
    end)
  end
  defp stamp(matrix,node,other,g,current,ground) do
    if node==ground,do: matrix,else: Map.update!(matrix,node,fn {row,rhs}->
      row=Map.update(row,node,g,&(&1+g))
      row=if other==ground,do: row,else: Map.update(row,other,-g,&(&1-g))
      {row,rhs+current}
    end)
  end

  # 正定接地矩阵的稀疏消元；优先低度节点，线段不产生稠密填充。
  defp eliminate(matrix,stack) when map_size(matrix)==0,do: stack
  defp eliminate(matrix,stack) do
    {node,{row,rhs}}=Enum.min_by(matrix,fn {n,{r,_}}->{map_size(r),n} end)
    diagonal=Map.fetch!(row,node)
    row=Map.delete(row,node)
    matrix=Map.delete(matrix,node)
    matrix=Enum.reduce(row,matrix,fn {other,weight},m ->
      Map.update!(m,other,fn {r,b}->
        r=Map.delete(r,node)
        r=Enum.reduce(row,r,fn {column,value},r->Map.update(r,column,-weight*value/diagonal,&(&1-weight*value/diagonal)) end)
        {r,b-weight*rhs/diagonal}
      end)
    end)
    eliminate(matrix,[{node,diagonal,row,rhs}|stack])
  end
end
