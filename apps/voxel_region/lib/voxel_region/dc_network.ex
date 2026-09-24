defmodule VoxelRegion.DCNetwork do
  @moduledoc "全局系统功能：线性电阻网络的 KCL 节点求解；每个连通分量至多一个有限内阻电源。"

  @doc "输入支路 a/b、欧姆 r、伏特 emf；返回节点电压、同序支路电流及多源故障支路索引。"
  def solve(edges) do
    adjacency=Enum.reduce(edges,%{},fn e,g ->
      g |> Map.update(e.a,[e.b],&[e.b|&1]) |> Map.update(e.b,[e.a],&[e.a|&1])
    end)
    parts=components(adjacency)
    # 每条边只归入一次所在分量（保持原边序）；不再对每个分量扫描全部边。
    owner=parts |> Enum.with_index() |> Enum.reduce(%{},fn {nodes,c},m->Enum.reduce(nodes,m,&Map.put(&2,&1,c)) end)
    grouped=edges |> Enum.with_index() |> Enum.group_by(fn {e,_}->Map.fetch!(owner,e.a) end)
    {volts,faults}=parts |> Enum.with_index() |> Enum.reduce({%{},MapSet.new()},fn {nodes,c},{volts,faults}->
      local=Map.get(grouped,c,[])
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

  # 正定接地矩阵的稀疏消元；优先低度节点，线段不产生稠密填充。主元按 {行非零数, 节点} 最小选取，
  # 用有序集合维护，每步只更新受影响的行（原先每步扫描全部剩余行，O(N²)）；选取次序与算术不变。
  defp eliminate(matrix,stack) do
    queue=Enum.reduce(matrix,:gb_sets.empty(),fn {n,{r,_}},q->:gb_sets.add({map_size(r),n},q) end)
    eliminate(matrix,queue,stack)
  end
  defp eliminate(matrix,_queue,stack) when map_size(matrix)==0,do: stack
  defp eliminate(matrix,queue,stack) do
    {{_,node},queue}=:gb_sets.take_smallest(queue)
    {row,rhs}=Map.fetch!(matrix,node)
    diagonal=Map.fetch!(row,node)
    row=Map.delete(row,node)
    matrix=Map.delete(matrix,node)
    {matrix,queue}=Enum.reduce(row,{matrix,queue},fn {other,weight},{m,q} ->
      {r,b}=Map.fetch!(m,other)
      q=:gb_sets.delete({map_size(r),other},q)
      r=Map.delete(r,node)
      r=Enum.reduce(row,r,fn {column,value},r->Map.update(r,column,-weight*value/diagonal,&(&1-weight*value/diagonal)) end)
      {Map.put(m,other,{r,b-weight*rhs/diagonal}),:gb_sets.add({map_size(r),other},q)}
    end)
    eliminate(matrix,queue,[{node,diagonal,row,rhs}|stack])
  end
end
